# 처음 한 번 실행한다. A 기본 환경 설정 폴더와 이 PC 전용 설정을 만들고 점검까지 한다.
#   .\setup.ps1
#   .\setup.ps1 -WorkRoot E:\cc-ab-work -DefaultModel claude-sonnet-5-5
param(
    [string]$WorkRoot,
    [string]$DefaultModel
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

# 1) A 기본 환경 설정 폴더
if (-not (Test-Path $VanillaConfig)) { New-Item -ItemType Directory $VanillaConfig | Out-Null }
$vanillaSettings = Join-Path $VanillaConfig 'settings.json'
if (-not (Test-Path $vanillaSettings)) {
    Copy-Item (Join-Path $TemplateDir 'settings.json') $vanillaSettings
    Write-Host "만듦: $vanillaSettings"
} else {
    Write-Host "그대로 둠(이미 있음): $vanillaSettings"
}

# 2) 이 PC 전용 설정
if (-not (Test-Path $LabLocalFile) -or $WorkRoot -or $DefaultModel) {
    $cur = Get-LabConfig
    $cfg = [ordered]@{
        workRoot = if ($WorkRoot) { $WorkRoot } else { $cur.WorkRoot }
        defaultModel = if ($DefaultModel) { $DefaultModel } else { $cur.DefaultModel }
    }
    Write-Utf8NoBom $LabLocalFile ($cfg | ConvertTo-Json)
    Write-Host "저장: $LabLocalFile (workRoot=$($cfg.workRoot), defaultModel=$($cfg.defaultModel))"
    $Lab = Get-LabConfig
}

# 3) 실험·작업 폴더
foreach ($d in $ExpRoot, $Lab.WorkRoot) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null; Write-Host "만듦: $d" }
}

Write-Host ''
& (Join-Path $LabRoot 'doctor.ps1')
Write-Host ''
Write-Host '다음: .\login.ps1  (A 기본 환경 로그인)'
