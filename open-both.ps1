# Windows Terminal 창 하나를 좌우로 나눠 왼쪽 A, 오른쪽 B를 실행한다.
# Windows Terminal 이 없으면 PowerShell 창 2개로 띄운다.
#   .\open-both.ps1 -Exp superpowers            # 출발점 초기화 후 실행
#   .\open-both.ps1 -Exp superpowers -NoReset   # 작업 폴더를 그대로 두고 실행
param(
    [Parameter(Mandatory)][string]$Exp,
    [string]$Model,
    [ValidateSet('', 'manual', 'acceptEdits', 'auto', 'plan', 'dontAsk', 'bypassPermissions')][string]$PermissionMode = '',
    [switch]$NoReset
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$e = Get-Experiment $Exp
if (-not $NoReset) { Reset-Work $e; Write-Host "[$Exp] work-A, work-B 초기화 완료" }

$start = Join-Path $LabRoot 'start.ps1'
$extra = @('-Exp', $Exp)
if ($Model) { $extra += @('-Model', $Model) }
if ($PermissionMode) { $extra += @('-PermissionMode', $PermissionMode) }

if (Get-Command wt -ErrorAction SilentlyContinue) {
    wt -w new new-tab --title "$Exp A 기본" -d $LabRoot powershell -NoExit -ExecutionPolicy Bypass -File $start -Side A @extra `; split-pane -V --title "$Exp B 비교" -d $LabRoot powershell -NoExit -ExecutionPolicy Bypass -File $start -Side B @extra
} else {
    foreach ($side in 'A', 'B') {
        Start-Process powershell -WorkingDirectory $LabRoot -ArgumentList (@('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $start, '-Side', $side) + $extra)
    }
}
