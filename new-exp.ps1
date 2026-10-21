# 비교 실험 하나를 새로 만든다.
#   .\new-exp.ps1 -Name superpowers -Description "superpowers 플러그인 유무 비교"
#   .\new-exp.ps1 -Name pdf-skill -FixtureFrom D:\some\project -Model claude-sonnet-5-5
param(
    # 점으로만 된 이름(".", "..")은 상위 폴더를 가리키므로 거부한다.
    [Parameter(Mandatory)][ValidatePattern('^(?!\.+$)[A-Za-z0-9._-]+$')][string]$Name,
    [string]$Description = '',
    [string]$Model,
    [string]$FixtureFrom
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

if (-not $Model) { $Model = $Lab.DefaultModel }
$dir = Join-Path $ExpRoot $Name
if (Test-Path $dir) { throw "이미 있는 실험입니다: $dir" }

foreach ($sub in 'fixture', 'plugins', 'skills', 'prompts', 'results', 'config-B') {
    New-Item -ItemType Directory -Force (Join-Path $dir $sub) | Out-Null
}

$meta = [ordered]@{
    name = $Name; description = $Description; model = $Model
    createdAt = (Get-Date -Format 'yyyy-MM-dd')
    # 품질 확인 명령: 반복 측정의 매 실행 뒤 작업 폴더에서 실행, 종료 코드 0이면 통과(예: "npm test")
    check = [ordered]@{ command = ''; timeoutSec = 600 }
    # 판정 카드 기준(보고서). 측정 전에 정해 두고, 결과를 본 뒤에는 바꾸지 않는다.
    #   품질 차이가 ±minQualityGainPct %p 를 넘어야 향상/하락, 비용·시간 증가는 max…Pct % 까지 허용,
    #   비교 대상이 B 실행의 minTargetRunPct % 이상에서 호출돼야 판정한다.
    decision = [ordered]@{ minQualityGainPct = 10; maxCostIncreasePct = 30; maxTimeIncreasePct = 50; minTargetRunPct = 50 }
}
Write-Utf8NoBom (Join-Path $dir 'experiment.json') ($meta | ConvertTo-Json)

# B 설정은 A와 같은 템플릿에서 출발한다. 비교 대상만 B에 더한다.
Copy-Item (Join-Path $TemplateDir 'settings.json') (Join-Path $dir 'config-B\settings.json')
Write-Utf8NoBom (Join-Path $dir 'mcp-B.json') "{`n  `"mcpServers`": {}`n}`n"

# 빈 폴더도 git에 남도록 표시 파일을 둔다.
foreach ($sub in 'fixture', 'plugins', 'skills') { Write-Utf8NoBom (Join-Path $dir "$sub\.gitkeep") '' }

if ($FixtureFrom) {
    Invoke-Mirror $FixtureFrom (Join-Path $dir 'fixture')
    Write-Host "fixture 복사: $FixtureFrom"
}

Write-Utf8NoBom (Join-Path $dir 'prompts\01-task.md') @"
<!--
A와 B에 똑같이 넣을 지시문. 이 주석은 지우고 지시문만 남긴다.
- 특정 스킬·플러그인 이름을 직접 부르지 않는다(A에는 없으므로 불공정).
- 결과를 확인할 수 있는 완료 조건을 적는다(예: "테스트가 모두 통과하면 끝").
-->
"@

Write-Utf8NoBom (Join-Path $dir 'NOTES.md') @"
# $Name

- 목적: $Description
- 기본(A): Claude Code + claude.ai 계정 기본 스킬, 계정 플러그인·MCP 제외
- 비교(B): A + 이 실험의 plugins\ / skills\ / /plugin 설치 / mcp-B.json
- 모델: $Model
- 만든 날: $($meta.createdAt)

## B에 넣은 것

| 종류 | 이름 | 버전/커밋 | 출처 |
|---|---|---|---|
|  |  |  |  |

## fixture(실습 프로젝트)

- 출처:
- 기준 커밋:

## 지시문

- prompts\01-task.md:

## 관찰

## 결론
"@

Write-Host "실험 '$Name' 생성: $dir"
Write-Host '다음 순서:'
Write-Host "  1) fixture\ 에 실습 프로젝트 (또는 -FixtureFrom 으로 복사)"
Write-Host "  2) B 비교 대상: plugins\<플러그인>\ , skills\<스킬>\SKILL.md , 또는 B에서 /plugin 설치"
Write-Host "  3) prompts\01-task.md 에 지시문"
Write-Host "  4) .\login.ps1 -Exp $Name   (B 로그인, 실험마다 1회)"
Write-Host "  5) .\doctor.ps1 -Exp $Name  (점검)"
Write-Host "  6) .\open-both.ps1 -Exp $Name  또는  .\run-headless.ps1 -Exp $Name -Prompt 01-task"
