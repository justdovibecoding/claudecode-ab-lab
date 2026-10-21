# Electron 앱(GUI)을 실행한다. 처음이면 app\ 의존성을 설치한다.
#   .\app.ps1
#   .\app.ps1 -Dev      # F12 로 개발자 도구, 화면 로그를 이 창에 출력
param([switch]$Dev)

$app = Join-Path $PSScriptRoot 'app'
$electronPkg = Join-Path $app 'node_modules\electron'
$electron = Join-Path $electronPkg 'dist\electron.exe'
if (-not (Test-Path (Join-Path $electronPkg 'package.json'))) {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm 이 없습니다. Node.js(20 이상)를 설치하세요.' }
    Write-Host 'app\ 의존성을 설치합니다(처음 한 번)...'
    Push-Location $app
    try { npm install } finally { Pop-Location }
    if ($LASTEXITCODE) { throw "npm install 실패 (종료 코드 $LASTEXITCODE)" }
}
# Electron 45부터 설치 스크립트(postinstall)가 없어 npm install 만으로는 실행 파일이 생기지 않는다.
# 처음 쓸 때 install.js 로 받는다(npm 11 의 설치 스크립트 차단과도 무관).
if (-not (Test-Path $electron)) {
    Write-Host 'Electron 실행 파일을 받습니다(처음 한 번)...'
    & node (Join-Path $electronPkg 'install.js')
    if ($LASTEXITCODE -or -not (Test-Path $electron)) { throw "Electron 실행 파일 받기 실패: $electron" }
}
if ($Dev) {
    $env:CC_AB_DEV = '1'
    try { & $electron $app } finally { Remove-Item env:CC_AB_DEV -ErrorAction SilentlyContinue }
} else {
    Start-Process -FilePath $electron -ArgumentList "`"$app`"" -WorkingDirectory $app
}
