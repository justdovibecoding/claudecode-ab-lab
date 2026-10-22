# 비교 실험 스크립트 공용 함수.
# 각 스크립트에서 . (Join-Path $PSScriptRoot 'lib\common.ps1') 로 불러온다.

$LabRoot = Split-Path $PSScriptRoot -Parent
$ExpRoot = Join-Path $LabRoot 'experiments'
$TemplateDir = Join-Path $LabRoot 'templates'
$VanillaConfig = Join-Path $LabRoot 'config-vanilla'
$EmptyMcp = Join-Path $LabRoot 'empty-mcp.json'
$LabLocalFile = Join-Path $LabRoot 'lab.local.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# 모든 스크립트가 같은 claude 실행 파일을 쓰도록 한다. GUI 앱은 자기가 찾은 claude.exe 를 CC_AB_CLAUDE 로 넘긴다.
# (npm 설치와 네이티브 설치가 함께 있으면 PATH 의 claude 와 앱의 claude 가 다른 버전일 수 있음)
$ClaudeCmd = if ($env:CC_AB_CLAUDE -and (Test-Path $env:CC_AB_CLAUDE)) { $env:CC_AB_CLAUDE } else { 'claude' }

function Get-ClaudePath {
    $c = Get-Command $ClaudeCmd -ErrorAction SilentlyContinue
    if ($c) { $c.Source } else { $null }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

# 이 PC 전용 설정(lab.local.json, git 제외). 없으면 기본값을 쓴다.
#   workRoot     : 작업 폴더를 만들 곳. 저장소 밖이어야 한다(상위 폴더의 .git/CLAUDE.md 영향 차단).
#   defaultModel : 새 실험의 기본 모델
function Get-LabConfig {
    $s = $null
    if (Test-Path $LabLocalFile) { $s = Get-Content $LabLocalFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    $workRoot = if ($s -and $s.workRoot) { $s.workRoot } else { (Split-Path $LabRoot -Qualifier) + '\cc-ab-work' }
    $model = if ($s -and $s.defaultModel) { $s.defaultModel } else { 'claude-opus-5-5' }
    [pscustomobject]@{ WorkRoot = $workRoot; DefaultModel = $model }
}
$Lab = Get-LabConfig

function Get-Experiment([string]$Name) {
    if ($Name -notmatch '^(?!\.+$)[A-Za-z0-9._-]+$') { throw "잘못된 실험 이름: $Name" }
    $dir = Join-Path $ExpRoot $Name
    $metaFile = Join-Path $dir 'experiment.json'
    if (-not (Test-Path $metaFile)) {
        throw "실험 '$Name'이(가) 없습니다. .\list-exp.ps1 로 목록을 보거나 .\new-exp.ps1 -Name $Name 으로 만드세요."
    }
    $meta = Get-Content $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $meta.model) { $meta | Add-Member -NotePropertyName model -NotePropertyValue $Lab.DefaultModel -Force }
    [pscustomobject]@{ Name = $Name; Dir = $dir; Meta = $meta; ConfigB = Join-Path $dir 'config-B' }
}

function Get-WorkDir($Exp, [string]$Side) {
    Join-Path $Lab.WorkRoot "$($Exp.Name)\work-$Side"
}

function Get-PluginDirs($Exp) {
    @(Get-ChildItem (Join-Path $Exp.Dir 'plugins') -Directory -ErrorAction SilentlyContinue)
}

function Get-SkillDirs($Exp) {
    @(Get-ChildItem (Join-Path $Exp.Dir 'skills') -Directory -ErrorAction SilentlyContinue)
}

function Invoke-Mirror([string]$From, [string]$To, [string[]]$KeepDirs = @()) {
    # /MIR: 원본과 똑같이 맞춘다(대상에만 있는 파일은 지워짐). robocopy는 8 이상이 실패.
    # .gitkeep 은 빈 폴더를 git에 남기기 위한 표시라서 복사하지 않는다.
    # $KeepDirs 에 적은 폴더 이름은 복사도, 삭제도 하지 않는다(/XD).
    $xd = if ($KeepDirs.Count) { @('/XD') + $KeepDirs } else { @() }
    robocopy $From $To /MIR /XF .gitkeep @xd /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "복사 실패: $From -> $To (robocopy $LASTEXITCODE)" }
}

# 실험 폴더의 skills\ 를 B 설정 폴더의 skills\ 로 똑같이 맞춘다(원본은 실험 폴더 쪽).
# claude.ai 계정 스킬은 같은 폴더의 synced\ 에 저장되므로(.trash\ 포함) 건드리지 않는다.
# 지우면 B에서만 계정 스킬이 빠져 A와 조건이 달라진다.
function Sync-Skills($Exp) {
    $src = Join-Path $Exp.Dir 'skills'
    if (Test-Path $src) { Invoke-Mirror $src (Join-Path $Exp.ConfigB 'skills') @('synced', '.trash') }
}

# fixture\ 를 작업 폴더에 똑같이 덮어써서 출발점을 맞추고, 그 작업 폴더의 자동 메모리도 비운다.
# 메모리를 남기면 다음 회차·다음 촬영이 이전 실행에서 배운 것을 안고 시작해 회차가 독립이 아니게 된다.
function Reset-Work($Exp, [string[]]$Sides = @('A', 'B')) {
    $fixture = Join-Path $Exp.Dir 'fixture'
    foreach ($side in $Sides) {
        $work = Get-WorkDir $Exp $side
        Invoke-Mirror $fixture $work
        [void](Clear-ProjectMemory (Get-SideConfig $Exp $side) $work)
    }
}

function Get-SideConfig($Exp, [string]$Side) {
    if ($Side -eq 'A') { $VanillaConfig } else { $Exp.ConfigB }
}

# ---------- 작업 폴더별 상태(설정 폴더 안) ----------
# Claude Code 는 작업 폴더마다 <설정 폴더>\projects\<경로 이름>\ 에 대화 기록과 자동 메모리(memory\)를 둔다.
# 경로 이름은 영문·숫자 외 문자를 모두 '-'로 바꾼 것(예: D:\cc-ab-work\x\work-A → D--cc-ab-work-x-work-A).

function Get-ProjectSlug([string]$WorkDir) {
    $WorkDir.TrimEnd('\') -replace '[^A-Za-z0-9]', '-'
}

function Get-ProjectMemoryDir([string]$ConfigDir, [string]$WorkDir) {
    Join-Path $ConfigDir ('projects\' + (Get-ProjectSlug $WorkDir) + '\memory')
}

# 자동 메모리 파일 수(없으면 0)
function Get-ProjectMemoryCount([string]$ConfigDir, [string]$WorkDir) {
    $dir = Get-ProjectMemoryDir $ConfigDir $WorkDir
    if (Test-Path $dir) { @(Get-ChildItem $dir -Recurse -File -Force).Count } else { 0 }
}

# 자동 메모리를 지운다. 지운 파일 수를 돌려준다. 대화 기록(*.jsonl)은 남긴다.
function Clear-ProjectMemory([string]$ConfigDir, [string]$WorkDir) {
    $dir = Get-ProjectMemoryDir $ConfigDir $WorkDir
    if (-not (Test-Path $dir)) { return 0 }
    $n = @(Get-ChildItem $dir -Recurse -File -Force).Count
    Remove-Item -Recurse -Force $dir
    $n
}

# .claude.json 의 작업 폴더별 항목(키는 슬래시 경로). 없으면 $null.
function Get-ProjectEntry([string]$ConfigDir, [string]$WorkDir) {
    $file = Join-Path $ConfigDir '.claude.json'
    if (-not (Test-Path $file)) { return $null }
    try { $j = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not $j.projects) { return $null }
    $key = $WorkDir.TrimEnd('\') -replace '\\', '/'
    $p = $j.projects.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
    if ($p) { $p.Value } else { $null }
}

# 설정 폴더에 사용자가 직접 넣을 수 있는 것(CLAUDE.md, agents, commands, output-styles, skills)의 파일별 해시.
# skills\ 에서 계정 스킬(synced, .trash)과 $SkipSkills(실험이 넣은 스킬)는 뺀다.
function Get-ConfigExtras([string]$ConfigDir, [string[]]$SkipSkills = @()) {
    $h = @{}
    $md = Join-Path $ConfigDir 'CLAUDE.md'
    if (Test-Path $md) { $h['CLAUDE.md'] = (Get-FileHash $md -Algorithm SHA256).Hash }
    foreach ($sub in 'agents', 'commands', 'output-styles', 'skills') {
        $root = Join-Path $ConfigDir $sub
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -Recurse -File -Force | ForEach-Object {
            $rel = $_.FullName.Substring($ConfigDir.TrimEnd('\').Length + 1)
            if ($sub -eq 'skills') {
                $top = ($rel -split '\\')[1]
                if ($top -in @('synced', '.trash') + $SkipSkills) { return }
            }
            $h[$rel] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
        }
    }
    $h
}

# 한쪽(A 또는 B)을 실행할 설정 폴더, 작업 폴더, claude 인자를 만든다.
function Get-SideLaunch($Exp, [string]$Side, [string]$Model, [string]$PermissionMode) {
    if (-not $Model) { $Model = $Exp.Meta.model }
    if ($Side -eq 'A') {
        $config = $VanillaConfig
        $mcp = $EmptyMcp
    } else {
        $config = $Exp.ConfigB
        $mcp = Join-Path $Exp.Dir 'mcp-B.json'
        Sync-Skills $Exp
    }
    # --no-chrome: Claude in Chrome(MCP 도구 22개)은 대화형에서만 켜져 측정과 조건이 달라지므로 양쪽 모두 끈다.
    $cliArgs = @('--model', $Model, '--strict-mcp-config', '--mcp-config', $mcp, '--no-chrome')
    if ($PermissionMode) { $cliArgs += @('--permission-mode', $PermissionMode) }
    if ($Side -eq 'B') {
        foreach ($p in Get-PluginDirs $Exp) { $cliArgs += @('--plugin-dir', $p.FullName) }
    }
    [pscustomobject]@{
        Side = $Side; Model = $Model; Config = $config
        Work = Get-WorkDir $Exp $Side; CliArgs = $cliArgs
    }
}

# 지정한 설정 폴더의 로그인 상태(claude auth status JSON). 실패하면 $null.
function Get-AuthStatus([string]$ConfigDir) {
    $old = $env:CLAUDE_CONFIG_DIR
    try {
        $env:CLAUDE_CONFIG_DIR = $ConfigDir
        $raw = & $ClaudeCmd auth status
        ($raw -join "`n") | ConvertFrom-Json
    } catch { $null } finally { $env:CLAUDE_CONFIG_DIR = $old }
}

# 작업 폴더의 상위 폴더에서 Claude Code가 자동으로 읽을 수 있는 것을 찾는다.
function Find-AncestorContext([string]$Path) {
    $found = @()
    $dir = Split-Path $Path -Parent
    while ($dir) {
        foreach ($n in 'CLAUDE.md', 'CLAUDE.local.md', '.claude', '.mcp.json', '.git') {
            $p = Join-Path $dir $n
            if (Test-Path $p) { $found += $p }
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $found
}

# 폴더 안 파일별 해시(.git, .gitkeep 제외). 실행 전후 비교용.
function Get-TreeHashes([string]$Root) {
    $h = @{}
    if (-not (Test-Path $Root)) { return $h }
    $rootFull = (Resolve-Path $Root).Path.TrimEnd('\')
    Get-ChildItem $Root -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Name -ne '.gitkeep' } |
        ForEach-Object { $h[$_.FullName.Substring($rootFull.Length + 1)] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    $h
}

# fixture 대비 바뀐 파일 목록. "A 경로"=추가, "M 경로"=수정, "D 경로"=삭제.
function Compare-Tree([string]$Before, [string]$After) {
    $a = Get-TreeHashes $Before
    $b = Get-TreeHashes $After
    $out = @()
    foreach ($k in $b.Keys) {
        if (-not $a.ContainsKey($k)) { $out += "A $k" }
        elseif ($a[$k] -ne $b[$k]) { $out += "M $k" }
    }
    foreach ($k in $a.Keys) { if (-not $b.ContainsKey($k)) { $out += "D $k" } }
    @($out | Sort-Object { $_.Substring(2) })
}

# ---------- claude 명령을 특정 설정 폴더로 실행 ----------

# 결과: @{ Code; Lines } . 설정 폴더 환경 변수는 끝나면 되돌린다.
function Invoke-ClaudeIn([string]$ConfigDir, [string[]]$Arguments) {
    $old = $env:CLAUDE_CONFIG_DIR
    try {
        $env:CLAUDE_CONFIG_DIR = $ConfigDir
        $global:LASTEXITCODE = 0
        $lines = @(& $ClaudeCmd @Arguments 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $lines }
    } finally { $env:CLAUDE_CONFIG_DIR = $old }
}

# claude ... --json 결과에서 JSON 부분만 골라 객체로 만든다(안내 문구가 섞여 나와도 견딤).
function ConvertFrom-ClaudeJson([string[]]$Lines) {
    $text = ($Lines -join "`n").Trim()
    $start = $text.IndexOfAny([char[]]'[{')
    if ($start -lt 0) { return $null }
    try { $text.Substring($start) | ConvertFrom-Json } catch { $null }
}

# ---------- B 구성 기록(b-manifest.json) ----------
# items: { kind: installed-plugin | local-plugin | local-skill, name, version, source, commit, dirty, addedAt }

function Get-BManifestPath($Exp) { Join-Path $Exp.Dir 'b-manifest.json' }

function Get-BManifest($Exp) {
    $file = Get-BManifestPath $Exp
    if (Test-Path $file) {
        $m = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($m.items | Where-Object { $_ })
    }
    @()
}

function Save-BManifest($Exp, $Items) {
    $sorted = @($Items | Sort-Object kind, name)
    Write-Utf8NoBom (Get-BManifestPath $Exp) ((@{ items = $sorted } | ConvertTo-Json -Depth 6) + "`n")
}

function Set-BManifestItem($Exp, $Item) {
    $items = @(Get-BManifest $Exp | Where-Object { -not ($_.kind -eq $Item.kind -and $_.name -eq $Item.name) })
    Save-BManifest $Exp ($items + [pscustomobject]$Item)
}

function Remove-BManifestItem($Exp, [string]$Kind, [string]$Name) {
    Save-BManifest $Exp @(Get-BManifest $Exp | Where-Object { -not ($_.kind -eq $Kind -and $_.name -eq $Name) })
}

# 폴더가 git 저장소 안이면 커밋·변경 여부를 알려 준다(재현 기록용).
function Get-GitInfo([string]$Path) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $commit = (& git -C $Path rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -or -not $commit) { return $null }
    $dirty = [bool](& git -C $Path status --porcelain 2>$null)
    $remote = (& git -C $Path config --get remote.origin.url 2>$null)
    [pscustomobject]@{ Commit = "$commit".Trim(); Dirty = $dirty; Remote = "$remote".Trim() }
}

# SKILL.md frontmatter 의 name (없으면 폴더 이름)
function Get-SkillName([string]$SkillDir) {
    $file = Join-Path $SkillDir 'SKILL.md'
    $m = Select-String -Path $file -Pattern '^name:\s*(.+?)\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value.Trim('"', "'") } else { Split-Path $SkillDir -Leaf }
}

# ---------- A/B 동등성 ----------

# 설정 폴더의 claude.ai 계정 스킬 이름 목록(skills\synced\<계정>\<스킬>\SKILL.md)
function Get-SyncedSkills([string]$ConfigDir) {
    $root = Join-Path $ConfigDir 'skills\synced'
    @(Get-ChildItem $root -Recurse -Filter SKILL.md -ErrorAction SilentlyContinue |
        ForEach-Object { Get-SkillName $_.DirectoryName } | Sort-Object -Unique)
}

# A/B 설정 폴더가 비교 대상 말고는 같은지 본다.
#   계정(로그인), claude.ai 계정 스킬 목록, settings.json(enabledPlugins, theme 제외)
# 결과: @{ Ok; Issues(문장 목록); Notes(안내, Ok 에 영향 없음); Details }
function Get-Equivalence($Exp) {
    $issues = @()
    $notes = @()   # 문제는 아니지만 알아 둘 것(Ok 에 영향 없음)
    $details = [ordered]@{}

    $authA = Get-AuthStatus $VanillaConfig
    $authB = Get-AuthStatus $Exp.ConfigB
    if (-not ($authA -and $authA.loggedIn)) { $issues += 'A 로그인 안 됨' }
    if (-not ($authB -and $authB.loggedIn)) { $issues += 'B 로그인 안 됨' }
    if ($authA -and $authB -and $authA.loggedIn -and $authB.loggedIn) {
        $same = ($authA.orgId -eq $authB.orgId) -and ($authA.email -eq $authB.email)
        $details.sameAccount = $same
        if (-not $same) { $issues += 'A와 B가 서로 다른 계정으로 로그인됨(계정 스킬·사용량 한도가 달라질 수 있음)' }
        if ($authA.subscriptionType -ne $authB.subscriptionType) { $issues += "요금제가 다름(A: $($authA.subscriptionType), B: $($authB.subscriptionType))" }
    }

    $skillsA = Get-SyncedSkills $VanillaConfig
    $skillsB = Get-SyncedSkills $Exp.ConfigB
    $onlyA = @($skillsA | Where-Object { $_ -notin $skillsB })
    $onlyB = @($skillsB | Where-Object { $_ -notin $skillsA })
    $details.syncedSkills = [ordered]@{ A = $skillsA.Count; B = $skillsB.Count; onlyA = $onlyA; onlyB = $onlyB }
    # 계정 스킬은 그 설정 폴더로 Claude Code 를 처음 실행할 때 받는다. 한쪽이 아직 한 번도 받지 않았으면
    # (로그인 전이거나 실행 전) 문제가 아니라 순서의 문제이므로 경고 대신 안내로 둔다. 측정 뒤에는
    # 실제 로드 목록(init)으로 다시 판단한다(Resolve-EquivalenceWithInit).
    $neverA = -not (Test-Path (Join-Path $VanillaConfig 'skills\synced'))
    $neverB = -not (Test-Path (Join-Path $Exp.ConfigB 'skills\synced'))
    $short = { param($names) if ($names.Count -gt 3) { "$(($names | Select-Object -First 3) -join ', ') 외 $($names.Count - 3)개" } else { $names -join ', ' } }
    if ($onlyA.Count -or $onlyB.Count) {
        if ($neverB -and -not $onlyB.Count) {
            $notes += "B 계정 스킬을 아직 받지 않음(A는 $($skillsA.Count)개). B를 한 번 실행하면 받아지며, 측정 결과는 실제 로드 목록으로 다시 확인합니다"
        } elseif ($neverA -and -not $onlyA.Count) {
            $notes += "A 계정 스킬을 아직 받지 않음(B는 $($skillsB.Count)개). A를 한 번 실행하면 받아집니다"
        } else {
            $parts = @()
            if ($onlyA.Count) { $parts += "A에만 $($onlyA.Count)개: $(& $short $onlyA)" }
            if ($onlyB.Count) { $parts += "B에만 $($onlyB.Count)개: $(& $short $onlyB)" }
            $issues += "계정 스킬 목록이 다름($($parts -join ' / ')). 양쪽을 한 번씩 실행해 동기화한 뒤 다시 점검하세요"
        }
    }

    $read = {
        param($dir)
        $f = Join-Path $dir 'settings.json'
        if (Test-Path $f) { try { Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } else { $null }
    }
    $sA = & $read $VanillaConfig
    $sB = & $read $Exp.ConfigB
    $ignore = @('enabledPlugins', 'theme')
    $keys = @(@($sA.PSObject.Properties.Name) + @($sB.PSObject.Properties.Name) | Where-Object { $_ -and $_ -notin $ignore } | Sort-Object -Unique)
    $diffKeys = @()
    # 파이프로 넘기면 빈 배열은 사라지고 원소 하나짜리 배열은 풀리므로 -InputObject 로 비교한다.
    $toJson = { param($o, $k) if ($o) { ConvertTo-Json -InputObject $o.$k -Compress -Depth 10 } else { $null } }
    foreach ($k in $keys) {
        if ((& $toJson $sA $k) -ne (& $toJson $sB $k)) { $diffKeys += $k }
    }
    $details.settingsDiff = $diffKeys
    if ($diffKeys.Count) { $issues += "settings.json 이 다름: $($diffKeys -join ', ') (enabledPlugins·theme 제외)" }

    # 설정 폴더에 직접 넣은 것(CLAUDE.md, agents, commands, output-styles, skills). b-manifest 에 기록되지 않는 차이다.
    $xA = Get-ConfigExtras $VanillaConfig
    $xB = Get-ConfigExtras $Exp.ConfigB @(Get-SkillDirs $Exp | ForEach-Object Name)
    $extraDiff = @()
    foreach ($k in @(@($xA.Keys) + @($xB.Keys) | Sort-Object -Unique)) {
        if (-not $xB.ContainsKey($k)) { $extraDiff += "A에만 $k" }
        elseif (-not $xA.ContainsKey($k)) { $extraDiff += "B에만 $k" }
        elseif ($xA[$k] -ne $xB[$k]) { $extraDiff += "내용 다름 $k" }
    }
    $details.configExtras = $extraDiff
    if ($extraDiff.Count) {
        $more = if ($extraDiff.Count -gt 8) { " 외 $($extraDiff.Count - 8)개" } else { '' }
        $issues += "설정 폴더에 직접 넣은 파일이 다름(B 구성 기록에 없음): $(($extraDiff | Select-Object -First 8) -join ', ')$more"
    }

    # 작업 폴더별 권한·MCP 상태(.claude.json). 대화형에서 한쪽만 "항상 허용"을 누르면 다음 측정 조건이 달라진다.
    # (폴더 신뢰 여부는 대화형 첫 화면에만 영향을 주고 헤드리스에는 무관해 비교하지 않는다)
    $pA = Get-ProjectEntry $VanillaConfig (Get-WorkDir $Exp 'A')
    $pB = Get-ProjectEntry $Exp.ConfigB (Get-WorkDir $Exp 'B')
    $projDiff = @()
    foreach ($k in 'allowedTools', 'mcpServers', 'enabledMcpjsonServers', 'disabledMcpjsonServers', 'hasClaudeMdExternalIncludesApproved') {
        $va = & $toJson $pA $k
        $vb = & $toJson $pB $k
        # 한쪽만 아직 실행한 적이 없으면(항목 없음) 기본값과 같은 빈 값으로 본다.
        $empty = @($null, 'null', '[]', '{}', 'false')
        if (($va -in $empty) -and ($vb -in $empty)) { continue }
        if ($va -ne $vb) { $projDiff += $k }
    }
    $details.projectDiff = $projDiff
    if ($projDiff.Count) { $issues += "작업 폴더별 권한·MCP 상태(.claude.json)가 다름: $($projDiff -join ', '). 대화형에서 한쪽만 허용한 경우이므로 양쪽에 같은 답을 하세요" }

    # 자동 메모리는 작업 폴더 초기화 때 지워지므로 동등성 문제로 보지 않고 개수만 남긴다(점검에서 따로 경고).
    $details.memory = [ordered]@{
        A = Get-ProjectMemoryCount $VanillaConfig (Get-WorkDir $Exp 'A')
        B = Get-ProjectMemoryCount $Exp.ConfigB (Get-WorkDir $Exp 'B')
    }

    [pscustomobject]@{ Ok = ($issues.Count -eq 0); Issues = $issues; Notes = $notes; Details = $details }
}

# ---------- stream-json 해석(스킬·도구 사용 기록) ----------
# claude -p --output-format stream-json --verbose 출력 한 줄이 이벤트 하나다.
#   system/init      : 실제로 로드된 plugins(name, source, version), skills, agents, mcp_servers
#   system/hook_*    : 훅 실행(SessionStart 훅이 넣는 문맥 포함)
#   assistant        : 모델 응답. content 의 tool_use 가 도구 호출(Skill → input.skill, Agent/Task → input.subagent_type)
#   result           : --output-format json 과 같은 최종 결과
# user 이벤트(도구 결과)는 파일 내용 등으로 커서 읽지 않는다.

function Read-ClaudeStream([string[]]$Lines) {
    $init = $null; $result = $null; $firstContext = $null
    $calls = @()   # @{ Tool; Kind(skill|agent|mcp|tool); Name }
    $seen = @{}
    $hookCount = 0; $hookChars = 0
    foreach ($line in $Lines) {
        if (-not $line -or $line[0] -ne '{' -or $line.StartsWith('{"type":"user"')) { continue }
        try { $j = $line | ConvertFrom-Json } catch { continue }
        if ($j.type -eq 'system' -and $j.subtype -eq 'init') { if (-not $init) { $init = $j } }
        elseif ($j.type -eq 'system' -and $j.subtype -eq 'hook_response') {
            $hookCount++
            $out = "$($j.output)".Trim()
            $ctx = $null
            try { $ctx = ($out | ConvertFrom-Json).hookSpecificOutput.additionalContext } catch { }
            if ($ctx) { $hookChars += "$ctx".Length }
            elseif ($j.hook_event -in 'SessionStart', 'UserPromptSubmit' -and $out -and $out -ne '{}') { $hookChars += $out.Length }
        }
        elseif ($j.type -eq 'assistant') {
            $u = $j.message.usage
            # 첫 요청의 입력 전체(시스템 지시·도구·스킬 목록·지시문) = 상시 컨텍스트 비교용
            if ($null -eq $firstContext -and -not $j.parent_tool_use_id -and $u) {
                $firstContext = [int]$u.input_tokens + [int]$u.cache_creation_input_tokens + [int]$u.cache_read_input_tokens
            }
            foreach ($c in @($j.message.content)) {
                if ($c.type -ne 'tool_use' -or $seen.ContainsKey("$($c.id)")) { continue }
                $seen["$($c.id)"] = $true
                $kind = 'tool'; $name = "$($c.name)"
                if ($c.name -eq 'Skill' -and $c.input.skill) { $kind = 'skill'; $name = "$($c.input.skill)" }
                elseif ($c.name -in 'Agent', 'Task' -and $c.input.subagent_type) { $kind = 'agent'; $name = "$($c.input.subagent_type)" }
                elseif ($c.name -like 'mcp__*') { $kind = 'mcp' }
                $calls += [pscustomobject]@{ Tool = "$($c.name)"; Kind = $kind; Name = $name }
            }
        }
        elseif ($j.type -eq 'result') { $result = $j }
    }
    [pscustomobject]@{
        Init = $init; Result = $result; FirstContext = $firstContext; Calls = $calls
        HookCount = $hookCount; HookChars = $hookChars
    }
}

# init 이벤트에서 로드 목록만 뽑는다(conditions.json·보고서용).
function Get-InitSummary($Init) {
    if (-not $Init) { return $null }
    [ordered]@{
        plugins = @($Init.plugins | Where-Object { $_ } | ForEach-Object {
                [ordered]@{ name = "$($_.name)"; source = "$($_.source)"; version = "$($_.version)" } })
        skills  = @($Init.skills | Where-Object { $_ } | ForEach-Object { "$_" })
        agents  = @($Init.agents | Where-Object { $_ } | ForEach-Object { "$_" })
        mcp     = @($Init.mcp_servers | Where-Object { $_ } | ForEach-Object { "$($_.name)" })
    }
}

# 비교 대상 = B에서만 로드된 것(A init 과 B init 의 차이) + B 구성 기록의 이름.
# 결과: @{ plugins; skills; agents; mcp } (이름 목록)
function Get-StreamTargets($InitA, $InitB, $Manifest) {
    $only = { param($b, $a) @($b | Where-Object { $_ -and $_ -notin @($a) } | Sort-Object -Unique) }
    # 스크립트 블록 결과는 파이프로 풀리므로(원소 하나 → 값, 없음 → $null) @() 로 다시 배열로 만든다.
    $t = [ordered]@{
        plugins = @(& $only @($InitB.plugins | ForEach-Object { $_.name }) @($InitA.plugins | ForEach-Object { $_.name }))
        skills  = @(& $only $InitB.skills $InitA.skills)
        agents  = @(& $only $InitB.agents $InitA.agents)
        mcp     = @(& $only $InitB.mcp $InitA.mcp)
    }
    foreach ($m in @($Manifest | Where-Object { $_ })) {
        $n = "$($m.name)" -replace '@.*$', ''
        if ($m.kind -in 'installed-plugin', 'local-plugin' -and $n -notin $t.plugins) { $t.plugins += $n }
        if ($m.kind -eq 'local-skill' -and $n -notin $t.skills) { $t.skills += $n }
    }
    $t
}

# 측정 전 동등성 점검을 실제 로드 목록(init)으로 바로잡는다.
# B 설정 폴더의 계정 스킬은 B를 처음 실행할 때 동기화되므로, 새 실험의 첫 측정 전에는 synced\ 가 비어
# "계정 스킬 목록이 다름" 거짓 경고가 난다. 측정 뒤에는 init 이 진짜 근거다:
# A에서 로드됐는데 B에서 빠진 스킬이 있을 때만 차이로 본다(B에만 있는 것은 비교 대상).
# 결과: @{ ok; issues; preRunIssues(측정 전 점검 원문) }
function Resolve-EquivalenceWithInit($Equivalence, $InitA, $InitB) {
    $pre = @($Equivalence.issues | Where-Object { $_ })
    if (-not ($InitA -and $InitB)) { return $Equivalence }
    $issues = @($pre | Where-Object { $_ -notlike '계정 스킬 목록이 다름*' })
    $missing = @($InitA.skills | Where-Object { $_ -and $_ -notin @($InitB.skills) } | Sort-Object -Unique)
    if ($missing.Count) { $issues += "A에서 로드된 스킬이 B에서 빠짐(init): $($missing -join ', ')" }
    [ordered]@{ ok = -not $issues.Count; issues = @($issues); preRunIssues = $pre }
}

# 도구 호출 하나가 비교 대상의 것인지. 플러그인 스킬·에이전트는 "<플러그인>:<이름>" 형식이다.
function Test-TargetCall($Call, $Targets) {
    if (-not $Targets) { return $false }
    $plugin = if ($Call.Name -match '^([^:]+):') { $Matches[1] } else { $null }
    switch ($Call.Kind) {
        'skill' { return ($Call.Name -in $Targets.skills) -or ($plugin -and $plugin -in $Targets.plugins) }
        'agent' { return ($Call.Name -in $Targets.agents) -or ($plugin -and $plugin -in $Targets.plugins) }
        'mcp' {
            # MCP 도구 이름은 mcp__<서버 이름(영문·숫자·_- 외는 _)>__<도구>
            foreach ($s in @($Targets.mcp) + @($Targets.plugins | ForEach-Object { "plugin:$_" })) {
                $san = "$s" -replace '[^A-Za-z0-9_-]', '_'
                if ($Call.Tool -like "mcp__$($san)__*" -or $Call.Tool -like "mcp__$($san)_*__*") { return $true }
            }
            return $false
        }
    }
    $false
}

# 호출 목록 → "이름×횟수; ..." (많은 순)
function Format-CallCounts($Calls) {
    @($Calls | Group-Object Name | Sort-Object @{ e = 'Count'; Descending = $true }, Name |
        ForEach-Object { "$($_.Name)×$($_.Count)" }) -join '; '
}

# ---------- 품질 확인 명령 ----------

# 작업 폴더에서 확인 명령(cmd.exe)을 실행한다. 결과: @{ Passed; ExitCode; TimedOut; Seconds; Output }
# 명령 출력 파일 읽기. node·npm 은 UTF-8, cmd.exe 자체 메시지는 시스템 코드 페이지(CP949)로 쓰므로
# 올바른 UTF-8이면 UTF-8로, 아니면 시스템 기본 인코딩으로 읽는다.
function Read-CommandOutput([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if (-not $bytes.Length) { return '' }
    try { (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch { [Text.Encoding]::Default.GetString($bytes) }
}

function Invoke-CheckCommand([string]$WorkDir, [string]$Command, [int]$TimeoutSec = 600) {
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/d', '/s', '/c', "`"$Command`"" -WorkingDirectory $WorkDir `
            -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
        $null = $p.Handle  # 종료 코드를 읽으려면 미리 핸들을 잡아 둬야 한다(PowerShell 5.1)
        $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
        if ($timedOut) { & taskkill /PID $p.Id /T /F 2>&1 | Out-Null; $p.WaitForExit(5000) | Out-Null }
        $code = if ($timedOut) { $null } else { $p.ExitCode }
        $text = (Read-CommandOutput $out) + (Read-CommandOutput $err)
        [pscustomobject]@{
            Passed = (-not $timedOut) -and ($code -eq 0); ExitCode = $code; TimedOut = $timedOut
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Output = "$text"
        }
    } finally {
        Remove-Item $out, $err -ErrorAction SilentlyContinue
    }
}

# ---------- 대화형 세션 결과 ----------
# 대화형 세션(앱의 "대화형 비교")의 결과를 반복 측정과 같은 형식으로 results\<세션>-live\ 에 남긴다.
# 비용·토큰은 Claude Code 가 설정 폴더에 남기는 대화 기록(projects\<작업 폴더>\<대화>.jsonl)의 cost-state 에서
# 읽으므로 토큰이 더 들지 않는다. 세션 동안 시작된 대화 기록만 더한다(한쪽을 다시 시작하면 기록이 여러 개).

function ConvertTo-UtcTime($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Read-LiveTranscripts([string]$ConfigDir, [string]$WorkDir, [datetime]$StartUtc, [datetime]$EndUtc) {
    $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $fromMs = ($StartUtc - $epoch).TotalMilliseconds - 60000
    $toMs = ($EndUtc - $epoch).TotalMilliseconds + 60000
    $dir = Join-Path $ConfigDir "projects\$(Get-ProjectSlug $WorkDir)"
    $r = [ordered]@{
        Files = @(); Cost = 0.0; ApiMs = 0; ToolMs = 0
        InputTokens = 0; OutputTokens = 0; CacheReadTokens = 0; CacheCreationTokens = 0
        Turns = 0; Prompts = 0; LastText = ''; Stream = $null
    }
    $assistant = @()
    if (Test-Path $dir) {
        $files = Get-ChildItem $dir -Filter *.jsonl -File | Where-Object { $_.LastWriteTimeUtc -ge $StartUtc.AddMinutes(-1) } | Sort-Object LastWriteTimeUtc
        foreach ($f in $files) {
            $lines = [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)
            $state = $null
            foreach ($l in $lines) { if ($l.StartsWith('{"type":"cost-state"')) { try { $state = $l | ConvertFrom-Json } catch { } } }
            # 이 세션 동안 시작된 대화만(이전 대화를 이어 쓴 기록·반복 측정 기록은 뺀다)
            if (-not $state -or [double]$state.startTime -lt $fromMs -or [double]$state.startTime -gt $toMs) { continue }
            $r.Files += $f.Name
            $r.Cost += [double]$state.totalCostUSD
            $r.ApiMs += [double]$state.totalAPIDuration
            $r.ToolMs += [double]$state.totalToolDuration
            foreach ($m in @($state.modelUsage.PSObject.Properties)) {
                $u = $m.Value
                $r.InputTokens += [long]$u.inputTokens; $r.OutputTokens += [long]$u.outputTokens
                $r.CacheReadTokens += [long]$u.cacheReadInputTokens; $r.CacheCreationTokens += [long]$u.cacheCreationInputTokens
            }
            $assistant += @($lines | Where-Object { $_.Contains('"type":"assistant"') })
            # 사람이 입력한 지시(문자열 content, 명령 출력·메타 제외)
            $r.Prompts += @($lines | Where-Object { $_.Contains('"type":"user"') -and $_.Contains('"content":"') -and -not $_.Contains('"isMeta":true') }).Count
        }
    }
    # 응답 하나가 내용 블록마다 줄로 나뉘어 저장되므로 message.id 로 묶는다.
    $texts = [ordered]@{}
    foreach ($l in $assistant) {
        try { $j = $l | ConvertFrom-Json } catch { continue }
        if ($j.isSidechain) { continue }
        $id = "$($j.message.id)"
        if (-not $texts.Contains($id)) { $texts[$id] = '' }
        foreach ($c in @($j.message.content)) { if ($c.type -eq 'text' -and $c.text) { $texts[$id] += $c.text } }
    }
    $r.Turns = $texts.Count
    $last = @($texts.Values | Where-Object { $_ }) | Select-Object -Last 1
    $r.LastText = if ($last) { "$last" } else { '' }
    $r.Stream = Read-ClaudeStream $assistant
    [pscustomobject]$r
}

function Save-LiveSession($Exp, [string]$Session) {
    if ($Session -notmatch '^\d{8}-\d{6}$') { throw "잘못된 세션 이름: $Session" }
    $sdir = Join-Path $Exp.Dir "sessions\$Session"
    $metaFile = Join-Path $sdir 'session.json'
    if (-not (Test-Path $metaFile)) { throw "세션 기록이 없습니다: $sdir" }
    $meta = Get-Content $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $startUtc = ConvertTo-UtcTime $meta.startedAt
    $endUtc = if ($meta.endedAt) { ConvertTo-UtcTime $meta.endedAt } else { [datetime]::UtcNow }

    # 앱 입력창으로 보낸 지시문(turns.jsonl). 터미널에 직접 친 것은 대화 기록에만 있다.
    $sends = @()
    $turnsFile = Join-Path $sdir 'turns.jsonl'
    if (Test-Path $turnsFile) {
        $sends = @(Get-Content $turnsFile -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_.event -eq 'send' })
    }
    $promptName = @($sends | Where-Object { $_.promptName } | ForEach-Object { "$($_.promptName)" }) | Select-Object -First 1
    if (-not $promptName) { $promptName = 'live' }

    # 양쪽 모두 대화가 없으면(세션만 열었다 닫음) 남길 것이 없다. 다시 묻지 않게 표시만 해 둔다.
    $trans = @{}
    foreach ($side in 'A', 'B') {
        $l = $meta.launches.$side
        if ($l) { $trans[$side] = Read-LiveTranscripts "$($l.config)" "$($l.work)" $startUtc $endUtc }
    }
    if (-not @($trans.Values | Where-Object { $_.Files.Count }).Count) {
        Write-Utf8NoBom (Join-Path $sdir 'result.txt') "(대화 없음 - 남기지 않음)`n"
        return $null
    }

    $runName = "$Session-live"
    $outDir = Join-Path $Exp.Dir "results\$runName"
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $fixture = Join-Path $Exp.Dir 'fixture'
    $checkCmd = if ($Exp.Meta.check -and $Exp.Meta.check.command) { "$($Exp.Meta.check.command)" } else { '' }
    $checkTimeout = if ($Exp.Meta.check -and $Exp.Meta.check.timeoutSec) { [int]$Exp.Meta.check.timeoutSec } else { 600 }
    $manifest = @(Get-BManifest $Exp)
    $targets = Get-StreamTargets $null $null $manifest

    $rows = @()
    foreach ($side in 'A', 'B') {
        $l = $meta.launches.$side
        if (-not $l) { continue }
        $t = $trans[$side]
        $base = Join-Path $outDir "$side-1"

        $changes = @()
        if (Test-Path $l.work) {
            Invoke-Mirror "$($l.work)" "$base-work"
            $changes = Compare-Tree $fixture "$($l.work)"
        }
        Write-Utf8NoBom "$base-changes.txt" (($changes -join "`n") + "`n")

        $checkPassed = $null
        if ($checkCmd -and (Test-Path $l.work)) {
            $env:AB_PROMPT = $promptName
            $ck = Invoke-CheckCommand "$($l.work)" $checkCmd $checkTimeout
            $checkPassed = $ck.Passed
            $status = if ($ck.TimedOut) { "시간 초과($checkTimeout 초)" } else { "종료 코드 $($ck.ExitCode)" }
            Write-Utf8NoBom "$base-check.txt" ("명령: $checkCmd`n결과: $(if ($ck.Passed) { '통과' } else { '실패' }) · $status · $($ck.Seconds)초`n`n$($ck.Output)")
        }

        $none = -not $t.Files.Count
        $seconds = [math]::Round(($t.ApiMs + $t.ToolMs) / 1000, 1)
        if ($t.LastText) { Write-Utf8NoBom "$base-result.md" $t.LastText }
        # A-1.json: 반복 측정의 result 이벤트와 같은 모양(판정 화면·보고서가 읽는다)
        $res = [ordered]@{
            type = 'result'; subtype = $(if ($none) { 'no_conversation' } else { 'live' }); is_error = $none
            total_cost_usd = $t.Cost; num_turns = $t.Turns; duration_ms = [math]::Round($t.ApiMs + $t.ToolMs)
            usage = [ordered]@{ input_tokens = $t.InputTokens; output_tokens = $t.OutputTokens; cache_read_input_tokens = $t.CacheReadTokens; cache_creation_input_tokens = $t.CacheCreationTokens }
            transcripts = @($t.Files); prompts = $t.Prompts; result = $t.LastText
        }
        Write-Utf8NoBom "$base.json" ($res | ConvertTo-Json -Depth 6)
        $calls = @($t.Stream.Calls)
        $hits = @($calls | Where-Object { Test-TargetCall $_ $targets })
        Write-Utf8NoBom "$base-tools.json" ([ordered]@{
                firstContextTokens = $t.Stream.FirstContext
                calls = @($calls | ForEach-Object { [ordered]@{ tool = $_.Tool; kind = $_.Kind; name = $_.Name; target = [bool](Test-TargetCall $_ $targets) } })
            } | ConvertTo-Json -Depth 6)

        $rows += [pscustomobject][ordered]@{
            Side = $side; Run = 1; Exit = 0; IsError = $none; Subtype = $res.subtype
            CostUSD = $(if ($none) { $null } else { $t.Cost }); Turns = $t.Turns; Seconds = $seconds
            InputTokens = $t.InputTokens; OutputTokens = $t.OutputTokens; CacheReadTokens = $t.CacheReadTokens; CacheCreationTokens = $t.CacheCreationTokens
            FirstContextTokens = $t.Stream.FirstContext
            ChangedFiles = $changes.Count; CheckPassed = $checkPassed
            ToolCalls = $calls.Count; SkillCalls = @($calls | Where-Object Kind -eq 'skill').Count
            TargetCalls = $(if ($side -eq 'B') { $hits.Count } else { 0 }); Skills = Format-CallCounts @($calls | Where-Object Kind -in 'skill', 'agent')
            HookContextChars = $null; SessionId = (@($t.Files) -join ' ')
        }
    }

    $cond = [ordered]@{
        experiment = $Exp.Name; mode = 'live'; prompt = $promptName; session = $Session
        note = '대화형 세션 1회(사람이 중간에 개입할 수 있음). 참고용이며 보고서 판정 카드에는 넣지 않는다. 시간은 API+도구 실행 시간 합(사람이 생각한 시간 제외).'
        sides = @('A', 'B'); runs = 1
        model = "$($meta.launches.A.model)"; permissionMode = $(if ($meta.permissionMode) { "$($meta.permissionMode)" } else { '기본(확인 창에 사람이 답함)' })
        plugins = @(Get-PluginDirs $Exp | ForEach-Object Name); skills = @(Get-SkillDirs $Exp | ForEach-Object Name)
        installedB = Test-Path (Join-Path $Exp.ConfigB 'plugins\installed_plugins.json')
        mcpB = @(if (Test-Path (Join-Path $Exp.Dir 'mcp-B.json')) { try { (Get-Content (Join-Path $Exp.Dir 'mcp-B.json') -Raw | ConvertFrom-Json).mcpServers.PSObject.Properties | ForEach-Object Name } catch { } })
        reset = $meta.reset; sends = $sends.Count
        promptOverride = @(@('A', 'B') | Where-Object { $s = $_; @($sends | Where-Object { $_."extra$s" }).Count })
        claudeVersion = "$($meta.claudeVersion)"; claudePath = "$($meta.claudeExe)"
        startedAt = "$($meta.startedAt)"; endedAt = "$($meta.endedAt)"
        bManifest = $manifest; check = $Exp.Meta.check; decision = $Exp.Meta.decision
        targets = $targets
    }
    Write-Utf8NoBom (Join-Path $outDir 'conditions.json') ($cond | ConvertTo-Json -Depth 6)
    $rows | Export-Csv (Join-Path $outDir 'summary.csv') -NoTypeInformation -Encoding UTF8
    Write-Utf8NoBom (Join-Path $sdir 'result.txt') "$runName`n"
    [pscustomobject]@{ run = $runName; dir = $outDir; rows = $rows }
}

# 마지막 대화형 세션의 결과를 아직 남기지 않았으면 남긴다. 작업 폴더를 초기화하기 전에 부른다
# (세션을 "종료" 없이 닫은 경우에도 결과물이 지워지지 않게). 이 기능 전에 만든 세션(autoSave 없음)은 건너뛴다.
function Save-PendingLiveSession($Exp) {
    $root = Join-Path $Exp.Dir 'sessions'
    if (-not (Test-Path $root)) { return $null }
    $latest = Get-ChildItem $root -Directory | Where-Object Name -match '^\d{8}-\d{6}$' | Sort-Object Name | Select-Object -Last 1
    if (-not $latest -or (Test-Path (Join-Path $latest.FullName 'result.txt'))) { return $null }
    try { $meta = Get-Content (Join-Path $latest.FullName 'session.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not $meta.autoSave) { return $null }
    Save-LiveSession $Exp $latest.Name
}
