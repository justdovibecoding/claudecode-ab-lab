# 실험의 작업 폴더를 fixture\ 상태로 되돌린다(작업 중 생긴 변경은 지워진다).
#   .\reset.ps1 -Exp superpowers
#   .\reset.ps1 -Exp superpowers -Side B
param(
    [Parameter(Mandatory)][string]$Exp,
    [ValidateSet('A', 'B', 'Both')][string]$Side = 'Both'
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$e = Get-Experiment $Exp
$sides = if ($Side -eq 'Both') { @('A', 'B') } else { @($Side) }
Reset-Work $e $sides
foreach ($s in $sides) { Write-Host "[$Exp] work-$s <- fixture 초기화 완료 ($(Get-WorkDir $e $s))" }
