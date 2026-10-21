# 설정 폴더별로 로그인한다. 로그인 정보는 설정 폴더 안에 따로 저장된다.
#   .\login.ps1                  # A 기본 환경(config-vanilla)
#   .\login.ps1 -Exp superpowers # 그 실험의 B 환경(config-B)
#   .\login.ps1 -Exp superpowers -Logout
param(
    [string]$Exp,
    [switch]$Logout
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$config = if ($Exp) { (Get-Experiment $Exp).ConfigB } else { $VanillaConfig }
$label = if ($Exp) { "$Exp B" } else { 'A 기본' }

$old = $env:CLAUDE_CONFIG_DIR
try {
    $env:CLAUDE_CONFIG_DIR = $config
    if ($Logout) {
        & $ClaudeCmd auth logout
        return
    }
    $s = Get-AuthStatus $config
    if ($s -and $s.loggedIn) {
        Write-Host "[$label] 이미 로그인됨 (방식: $($s.authMethod), 요금제: $($s.subscriptionType))"
        return
    }
    Write-Host "[$label] 로그인을 시작합니다. 설정 폴더: $config"
    & $ClaudeCmd auth login
    $s = Get-AuthStatus $config
    if ($s -and $s.loggedIn) { Write-Host "[$label] 로그인 완료 (방식: $($s.authMethod))" }
    else { Write-Warning "[$label] 로그인 상태를 확인하지 못했습니다. .\doctor.ps1 로 점검하세요." }
} finally {
    $env:CLAUDE_CONFIG_DIR = $old
}
