# 비교 실험 스크립트 공용 함수.
# 각 스크립트에서 . (Join-Path $PSScriptRoot 'lib\common.ps1') 로 불러온다.

$LabRoot = Split-Path $PSScriptRoot -Parent
$ExpRoot = Join-Path $LabRoot 'experiments'
$TemplateDir = Join-Path $LabRoot 'templates'
$VanillaConfig = Join-Path $LabRoot 'config-vanilla'
$EmptyMcp = Join-Path $LabRoot 'empty-mcp.json'
$LabLocalFile = Join-Path $LabRoot 'lab.local.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

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

function Invoke-Mirror([string]$From, [string]$To) {
    # /MIR: 원본과 똑같이 맞춘다(대상에만 있는 파일은 지워짐). robocopy는 8 이상이 실패.
    # .gitkeep 은 빈 폴더를 git에 남기기 위한 표시라서 복사하지 않는다.
    robocopy $From $To /MIR /XF .gitkeep /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "복사 실패: $From -> $To (robocopy $LASTEXITCODE)" }
}

# 실험 폴더의 skills\ 를 B 설정 폴더의 skills\ 로 똑같이 맞춘다(원본은 실험 폴더 쪽).
function Sync-Skills($Exp) {
    $src = Join-Path $Exp.Dir 'skills'
    if (Test-Path $src) { Invoke-Mirror $src (Join-Path $Exp.ConfigB 'skills') }
}

# fixture\ 를 작업 폴더에 똑같이 덮어써서 출발점을 맞춘다.
function Reset-Work($Exp, [string[]]$Sides = @('A', 'B')) {
    $fixture = Join-Path $Exp.Dir 'fixture'
    foreach ($side in $Sides) { Invoke-Mirror $fixture (Get-WorkDir $Exp $side) }
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
        $raw = & claude auth status
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
