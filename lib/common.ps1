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
    $cliArgs = @('--model', $Model, '--strict-mcp-config', '--mcp-config', $mcp)
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
# 결과: @{ Ok; Issues(문장 목록); Details }
function Get-Equivalence($Exp) {
    $issues = @()
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
    if ($onlyA.Count -or $onlyB.Count) {
        $issues += "계정 스킬 목록이 다름(A에만: $($onlyA -join ', ') / B에만: $($onlyB -join ', ')). 양쪽을 한 번씩 실행해 동기화하거나 점검을 다시 하세요"
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

    [pscustomobject]@{ Ok = ($issues.Count -eq 0); Issues = $issues; Details = $details }
}

# ---------- 품질 확인 명령 ----------

# 작업 폴더에서 확인 명령(cmd.exe)을 실행한다. 결과: @{ Passed; ExitCode; TimedOut; Seconds; Output }
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
        $text = ((Get-Content $out -Raw -Encoding Default) + (Get-Content $err -Raw -Encoding Default))
        [pscustomobject]@{
            Passed = (-not $timedOut) -and ($code -eq 0); ExitCode = $code; TimedOut = $timedOut
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Output = "$text"
        }
    } finally {
        Remove-Item $out, $err -ErrorAction SilentlyContinue
    }
}
