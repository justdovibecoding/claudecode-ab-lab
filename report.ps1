# 실험의 모든 헤드리스 결과를 모아 REPORT.md 로 정리한다(영상 비교표·근거용).
#   .\report.ps1 -Exp superpowers
param([Parameter(Mandatory)][string]$Exp)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$e = Get-Experiment $Exp
$runs = @(Get-ChildItem (Join-Path $e.Dir 'results') -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'summary.csv') } | Sort-Object Name)
if (-not $runs.Count) { Write-Host "결과가 없습니다. .\run-headless.ps1 -Exp $Exp -Prompt <지시문> 을 먼저 실행하세요."; return }

function Get-Avg($rows, [string]$Prop) {
    $v = @($rows | Where-Object { $_.$Prop -ne '' -and $_.$Prop -ne $null } | ForEach-Object { [double]$_.$Prop })
    if ($v.Count) { ($v | Measure-Object -Average).Average } else { $null }
}
function Format-Num($v, [int]$Digits) { if ($null -eq $v) { '-' } else { [math]::Round($v, $Digits).ToString() } }
function Format-Delta($a, $b) {
    if ($null -eq $a -or $null -eq $b -or $a -eq 0) { return '-' }
    $d = ($b - $a) / $a * 100
    '{0}{1:N0}%' -f ($(if ($d -ge 0) { '+' } else { '' })), $d
}

$lines = @(
    "# $Exp 비교 결과"
    ''
    "- 설명: $($e.Meta.description)"
    "- 생성: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    '- 비용은 Claude Code가 보고한 API 기준 추정값(total_cost_usd)이다. 구독 요금제에서는 실제 청구액이 아니다.'
    '- 평균은 오류 없이 끝난 실행만으로 계산했다. 차이(%)는 A 대비 B.'
    ''
)

foreach ($r in $runs) {
    $cond = Get-Content (Join-Path $r.FullName 'conditions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = @(Import-Csv (Join-Path $r.FullName 'summary.csv'))
    $lines += "## $($r.Name)"
    $lines += ''
    $lines += "- 지시문: ``$($cond.prompt)`` / 모델: ``$($cond.model)`` / 권한 모드: ``$($cond.permissionMode)`` / Claude Code: $($cond.claudeVersion)"
    $lines += "- B 구성: 플러그인 [$($cond.plugins -join ', ')] · 스킬 [$($cond.skills -join ', ')] · /plugin 설치 $($cond.installedB) · MCP [$($cond.mcpB -join ', ')]"
    foreach ($m in @($cond.bManifest | Where-Object { $_ })) {
        $commit = if ($m.commit) { " · 커밋 ``$("$($m.commit)".Substring(0, [Math]::Min(12, "$($m.commit)".Length)))``$(if ($m.dirty) { '(수정본)' })" } else { '' }
        $lines += "  - $($m.kind) ``$($m.name)``$(if ($m.version) { " $($m.version)" })$commit$(if ($m.source) { " · $($m.source)" })"
    }
    if (@($cond.promptOverride).Count) {
        $lines += "- **지시문 변형**: $(@($cond.promptOverride) -join ', ') 쪽은 다른 지시문을 받음(``prompt.<쪽>.md`` 참고). 비교 조건이 다르므로 결과 해석 시 밝힐 것"
    }
    if ($cond.equivalence -and -not $cond.equivalence.ok) {
        $lines += "- **A/B 동등성 경고**: $(@($cond.equivalence.issues) -join ' / ')"
    }
    if ($cond.check -and $cond.check.command) { $lines += "- 확인 명령: ``$($cond.check.command)``" }

    # 사람 판정(judgments.json, 앱의 결과 화면에서 블라인드로 기록)
    $judged = @{}
    $jFile = Join-Path $r.FullName 'judgments.json'
    if (Test-Path $jFile) {
        $j = Get-Content $jFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in @($j.items.PSObject.Properties)) { if ($p.Value.verdict) { $judged[$p.Name] = $p.Value.verdict } }
    }
    $hasCheck = @($rows | Where-Object { $_.CheckPassed -in 'True', 'False' }).Count -gt 0
    $hasJudge = $judged.Count -gt 0

    $lines += ''
    $lines += '| 쪽 | 성공/전체 | 확인 통과 | 사람 판정(통과·부분/판정) | 평균 비용(USD) | 평균 턴 | 평균 시간(초) | 평균 출력 토큰 | 평균 변경 파일 |'
    $lines += '|---|---|---|---|---|---|---|---|---|'
    $avg = @{}
    foreach ($side in 'A', 'B') {
        $all = @($rows | Where-Object Side -eq $side)
        if (-not $all.Count) { continue }
        $ok = @($all | Where-Object { $_.IsError -ne 'True' })
        $avg[$side] = @{
            Cost = Get-Avg $ok CostUSD; Turns = Get-Avg $ok Turns; Sec = Get-Avg $ok Seconds
            Out = Get-Avg $ok OutputTokens; Chg = Get-Avg $ok ChangedFiles
        }
        $a = $avg[$side]
        $check = if ($hasCheck) { "$(@($all | Where-Object CheckPassed -eq 'True').Count)/$(@($all | Where-Object { $_.CheckPassed -in 'True', 'False' }).Count)" } else { '-' }
        $mine = @($judged.Keys | Where-Object { $_ -like "$side-*" } | ForEach-Object { $judged[$_] })
        $judge = if ($hasJudge -and $mine.Count) { "$(@($mine | Where-Object { $_ -eq 'pass' }).Count)·$(@($mine | Where-Object { $_ -eq 'partial' }).Count)/$($mine.Count)" } else { '-' }
        $lines += "| $side | $($ok.Count)/$($all.Count) | $check | $judge | $(Format-Num $a.Cost 4) | $(Format-Num $a.Turns 1) | $(Format-Num $a.Sec 1) | $(Format-Num $a.Out 0) | $(Format-Num $a.Chg 1) |"
    }
    if ($avg.ContainsKey('A') -and $avg.ContainsKey('B')) {
        $A = $avg['A']; $B = $avg['B']
        $lines += "| 차이 | | | | $(Format-Delta $A.Cost $B.Cost) | $(Format-Delta $A.Turns $B.Turns) | $(Format-Delta $A.Sec $B.Sec) | $(Format-Delta $A.Out $B.Out) | $(Format-Delta $A.Chg $B.Chg) |"
    }
    $lines += ''
    $lines += "실행별 결과물: ``results\$($r.Name)\<쪽>-<회차>-work\`` · 변경 목록 ``*-changes.txt`` · 최종 응답 ``*-result.md`` · 확인 결과 ``*-check.txt``"
    $lines += ''
}

$reportFile = Join-Path $e.Dir 'REPORT.md'
Write-Utf8NoBom $reportFile (($lines -join "`n") + "`n")
$lines | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host "저장: $reportFile"
