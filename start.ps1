# 실험의 A(기본) 또는 B(스킬·플러그인) 쪽을 대화형으로 실행한다.
#   .\start.ps1 -Exp superpowers -Side A
#   .\start.ps1 -Exp superpowers -Side B -PermissionMode acceptEdits
# 끝나면 현재 창의 CLAUDE_CONFIG_DIR 과 위치를 원래대로 되돌린다.
param(
    [Parameter(Mandatory)][string]$Exp,
    [Parameter(Mandatory)][ValidateSet('A', 'B')][string]$Side,
    [string]$Model,
    [ValidateSet('', 'manual', 'acceptEdits', 'auto', 'plan', 'dontAsk', 'bypassPermissions')][string]$PermissionMode = '',
    # 실행하지 않고 설정 폴더·작업 폴더·claude 인자를 JSON 한 줄로 출력한다(Electron 앱용).
    [switch]$PrintLaunchJson
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$e = Get-Experiment $Exp
$l = Get-SideLaunch $e $Side $Model $PermissionMode
if (-not (Test-Path $l.Work)) { Reset-Work $e @($Side) }

$ctx = @(Find-AncestorContext $l.Work)

if ($PrintLaunchJson) {
    [ordered]@{
        experiment = $Exp; side = $Side; model = $l.Model
        config = $l.Config; work = $l.Work
        args = @($l.CliArgs); warnings = $ctx
    } | ConvertTo-Json -Compress
    return
}

if ($ctx) { Write-Warning "작업 폴더 상위에 Claude Code가 읽을 수 있는 항목이 있습니다: $($ctx -join ', ')" }

Write-Host "[$Exp/$Side] CLAUDE_CONFIG_DIR=$($l.Config)"
Write-Host "[$Exp/$Side] work=$($l.Work)"
Write-Host "[$Exp/$Side] claude $($l.CliArgs -join ' ')"

$oldConfig = $env:CLAUDE_CONFIG_DIR
$oldTitle = $Host.UI.RawUI.WindowTitle
# 배열은 변수로 펼쳐야 한다(@(...) 는 배열 한 덩어리로 넘어가 claude.ps1 에서 깨진다).
$cliArgs = $l.CliArgs
Push-Location $l.Work
try {
    $env:CLAUDE_CONFIG_DIR = $l.Config
    $Host.UI.RawUI.WindowTitle = "[$Exp/$Side]"
    & claude @cliArgs
} finally {
    $env:CLAUDE_CONFIG_DIR = $oldConfig
    $Host.UI.RawUI.WindowTitle = $oldTitle
    Pop-Location
}
