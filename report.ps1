# 실험의 모든 헤드리스 결과를 모아 REPORT.md 로 정리한다(영상 비교표·근거용).
#   .\report.ps1 -Exp superpowers
# 맨 위에 판정 카드(채택/조건부 채택/보류/비채택)를 두고, 측정마다 비교표·분포·스킬 사용을 적는다.
# 판정 카드는 decision.json 으로도 남긴다(그래프·설명란용).
param([Parameter(Mandatory)][string]$Exp)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$e = Get-Experiment $Exp
$runDirs = @(Get-ChildItem (Join-Path $e.Dir 'results') -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'summary.csv') } | Sort-Object Name)
if (-not $runDirs.Count) { Write-Host "결과가 없습니다. .\run-headless.ps1 -Exp $Exp -Prompt <지시문> 을 먼저 실행하세요."; return }

function Get-Avg($rows, [string]$Prop) {
    $v = @($rows | Where-Object { $_.$Prop -ne '' -and $_.$Prop -ne $null } | ForEach-Object { [double]$_.$Prop })
    if ($v.Count) { ($v | Measure-Object -Average).Average } else { $null }
}
function Format-Num($v, [int]$Digits) { if ($null -eq $v) { '-' } else { [math]::Round($v, $Digits).ToString() } }
# A 대비 B 변화율(%). 계산할 수 없으면 $null
function Get-Pct($a, $b) { if ($null -eq $a -or $null -eq $b -or $a -eq 0) { $null } else { ($b - $a) / $a * 100 } }
function Format-Pct($d) { if ($null -eq $d) { '-' } else { '{0}{1:N0}%' -f ($(if ($d -ge 0) { '+' } else { '' })), $d } }
function Format-Delta($a, $b) { Format-Pct (Get-Pct $a $b) }
# 최소·최대·표준편차(표본)
function Get-Spread($rows, [string]$Prop) {
    $v = @($rows | Where-Object { $_.$Prop -ne '' -and $_.$Prop -ne $null } | ForEach-Object { [double]$_.$Prop })
    if ($v.Count -lt 2) { return $null }
    $m = ($v | Measure-Object -Average).Average
    $sd = [math]::Sqrt((($v | ForEach-Object { ($_ - $m) * ($_ - $m) } | Measure-Object -Sum).Sum) / ($v.Count - 1))
    [pscustomobject]@{ Min = ($v | Measure-Object -Minimum).Minimum; Max = ($v | Measure-Object -Maximum).Maximum; Sd = $sd }
}

# 판정 기준(experiment.json 의 decision). 없으면 기본값.
$DefaultCriteria = [ordered]@{ minQualityGainPct = 10; maxCostIncreasePct = 30; maxTimeIncreasePct = 50; minTargetRunPct = 50 }
function Get-Criteria($Meta) {
    $c = [ordered]@{}
    foreach ($k in $DefaultCriteria.Keys) {
        $c[$k] = if ($Meta -and $Meta.decision -and $null -ne $Meta.decision.$k) { [double]$Meta.decision.$k } else { $DefaultCriteria[$k] }
    }
    $c
}

# ---------- 측정 하나 읽기 ----------

function Read-Run($Dir) {
    $cond = Get-Content (Join-Path $Dir.FullName 'conditions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = @(Import-Csv (Join-Path $Dir.FullName 'summary.csv'))
    # 사람 판정(judgments.json, 앱의 결과 화면에서 블라인드로 기록)
    $judged = @{}
    $jFile = Join-Path $Dir.FullName 'judgments.json'
    if (Test-Path $jFile) {
        $j = Get-Content $jFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in @($j.items.PSObject.Properties)) { if ($p.Value.verdict) { $judged[$p.Name] = $p.Value.verdict } }
    }
    $hasCheck = @($rows | Where-Object { $_.CheckPassed -in 'True', 'False' }).Count -gt 0
    $hasTools = [bool]($rows | Where-Object { $_.PSObject.Properties['ToolCalls'] -and $_.ToolCalls -ne '' })
    $sides = @{}
    foreach ($side in 'A', 'B') {
        $all = @($rows | Where-Object Side -eq $side)
        if (-not $all.Count) { continue }
        $ok = @($all | Where-Object { $_.IsError -ne 'True' })
        $mine = @($judged.Keys | Where-Object { $_ -like "$side-*" } | ForEach-Object { $judged[$_] })
        $sides[$side] = [pscustomobject]@{
            All = $all; Ok = $ok; Judged = $mine
            Cost = Get-Avg $ok CostUSD; Turns = Get-Avg $ok Turns; Sec = Get-Avg $ok Seconds
            Out = Get-Avg $ok OutputTokens; Chg = Get-Avg $ok ChangedFiles; Ctx = Get-Avg $all FirstContextTokens
            TargetPct = if ($hasTools -and $cond.targets) { @($all | Where-Object { $_.TargetCalls -ne '' -and [int]$_.TargetCalls -gt 0 }).Count / $all.Count * 100 } else { $null }
        }
    }
    # 품질: 양쪽 모두 판정을 마쳤으면 사람 판정(통과 1, 부분 0.5), 아니면 확인 명령, 둘 다 없으면 오류 없이 끝난 비율
    $allJudged = $sides.Count -eq 2 -and @($sides.Values | Where-Object { $_.Judged.Count -lt $_.All.Count }).Count -eq 0
    $source = if ($allJudged) { 'judge' } elseif ($hasCheck) { 'check' } else { 'success' }
    foreach ($s in $sides.Values) {
        $q = switch ($source) {
            'judge' { (@($s.Judged | Where-Object { $_ -eq 'pass' }).Count + 0.5 * @($s.Judged | Where-Object { $_ -eq 'partial' }).Count) / $s.Judged.Count * 100 }
            'check' {
                $c = @($s.All | Where-Object { $_.CheckPassed -in 'True', 'False' })
                if ($c.Count) { @($c | Where-Object CheckPassed -eq 'True').Count / $c.Count * 100 } else { $null }
            }
            default { $s.Ok.Count / $s.All.Count * 100 }
        }
        $s | Add-Member -NotePropertyName Quality -NotePropertyValue $q
    }
    [pscustomobject]@{
        Name = $Dir.Name; Dir = $Dir; Cond = $cond; Rows = $rows; Judged = $judged
        Mode = if ($cond.mode) { "$($cond.mode)" } else { 'AB' }
        Prompt = "$($cond.prompt)"; HasCheck = $hasCheck; HasJudge = $judged.Count -gt 0; HasTools = $hasTools
        Sides = $sides; QualitySource = $source
    }
}

$QualityLabel = @{ judge = '사람 판정'; check = '확인 명령'; success = '오류 없이 끝남(약한 근거)' }

# A/A 측정의 쪽 간 차이(%) = 우연 변동(잡음)의 크기
function Get-Noise($Run) {
    if (-not $Run -or $Run.Sides.Count -lt 2) { return $null }
    $A = $Run.Sides['A']; $B = $Run.Sides['B']
    $abs = { param($v) if ($null -eq $v) { $null } else { [math]::Abs($v) } }
    [pscustomobject]@{
        Run = $Run.Name; Cost = & $abs (Get-Pct $A.Cost $B.Cost); Sec = & $abs (Get-Pct $A.Sec $B.Sec)
        Out = & $abs (Get-Pct $A.Out $B.Out); Quality = [math]::Abs([double]$B.Quality - [double]$A.Quality)
    }
}

# ---------- 판정 ----------
# dq: 품질 차이(%p, B-A), dCost/dTime: 변화율(%), targetPct: B 대상 호출 회차 비율(%), noise: A/A 잡음
function Get-Verdict($dq, $dCost, $dTime, $targetPct, $Crit, $Noise) {
    $reasons = @()
    $cost = if ($null -eq $dCost) { 0 } else { $dCost }
    $time = if ($null -eq $dTime) { 0 } else { $dTime }
    # 비용·시간 차이가 의미 있으려면 A/A 잡음과 10% 중 큰 값보다 커야 한다.
    $costGate = [math]::Max(10, $(if ($Noise -and $null -ne $Noise.Cost) { $Noise.Cost } else { 0 }))
    $timeGate = [math]::Max(10, $(if ($Noise -and $null -ne $Noise.Sec) { $Noise.Sec } else { 0 }))
    $qGate = [math]::Max($Crit.minQualityGainPct, $(if ($Noise -and $null -ne $Noise.Quality) { $Noise.Quality } else { 0 }))
    $over = @()
    if ($cost -gt $Crit.maxCostIncreasePct) { $over += "비용 $(Format-Pct $cost)" }
    if ($time -gt $Crit.maxTimeIncreasePct) { $over += "시간 $(Format-Pct $time)" }

    if ($null -ne $targetPct -and $targetPct -lt $Crit.minTargetRunPct) {
        return [pscustomobject]@{ Verdict = '보류'; Reasons = @("비교 대상이 실행의 $([math]::Round($targetPct))%에서만 호출됨(기준 $($Crit.minTargetRunPct)%). 차이를 대상 덕분이라 보기 어려움 — 호출 문구 변형(.B.md)이나 과제를 검토") }
    }
    if ($null -eq $dq) { return [pscustomobject]@{ Verdict = '보류'; Reasons = @('품질을 비교할 자료가 없음') } }
    if ($dq -lt -$qGate) {
        $v = '비채택'; $reasons += "품질 하락($(Format-Pct $dq)p)"
    } elseif ($dq -gt $qGate) {
        if ($over.Count) { $v = '조건부 채택'; $reasons += "품질 향상($(Format-Pct $dq)p), 대신 $($over -join '·') (기준 초과) — 품질이 중요한 작업에만" }
        else { $v = '채택'; $reasons += "품질 향상($(Format-Pct $dq)p), 비용 $(Format-Pct $dCost)·시간 $(Format-Pct $dTime)은 기준 안" }
    } else {
        # 품질이 같으면 비용·시간이 잡음보다 크게 줄면 채택, 크게 늘면(허용 기준 안이라도) 쓸 이유가 없어 비채택.
        $saves = @(); $costs = @()
        if ($cost -lt -$costGate) { $saves += "비용 $(Format-Pct $cost)" }
        if ($time -lt -$timeGate) { $saves += "시간 $(Format-Pct $time)" }
        if ($cost -gt $costGate) { $costs += "비용 $(Format-Pct $cost)" }
        if ($time -gt $timeGate) { $costs += "시간 $(Format-Pct $time)" }
        if ($costs.Count -and -not $saves.Count) { $v = '비채택'; $reasons += "품질 차이 없음(±$([math]::Round($qGate))%p 안), $($costs -join '·')만 늘어남" }
        elseif ($saves.Count -and -not $costs.Count) { $v = '채택'; $reasons += "품질은 같고 $($saves -join '·') (잡음보다 큼) — 효율 향상" }
        elseif ($saves.Count) { $v = '보류'; $reasons += "품질은 같고 $($saves -join '·')이지만 $($costs -join '·') — 무엇을 중시할지에 달림" }
        else { $v = '보류'; $reasons += "품질·비용·시간 모두 의미 있는 차이 없음(품질 ±$([math]::Round($qGate))%p, 비용 ±$([math]::Round($costGate))%, 시간 ±$([math]::Round($timeGate))% 안)" }
    }
    [pscustomobject]@{ Verdict = $v; Reasons = $reasons }
}

$runs = @($runDirs | ForEach-Object { Read-Run $_ })
$crit = Get-Criteria $e.Meta

# 과제(지시문)마다 가장 최근 A/B 측정과, 같은 지시문의 가장 최근 A/A 측정
$tasks = @()
foreach ($g in @($runs | Where-Object { $_.Mode -eq 'AB' -and $_.Sides.Count -eq 2 } | Group-Object Prompt)) {
    $ab = $g.Group | Sort-Object Name | Select-Object -Last 1
    $aa = $runs | Where-Object { $_.Mode -eq 'AA' -and $_.Prompt -eq $g.Name -and $_.Sides.Count -eq 2 } | Sort-Object Name | Select-Object -Last 1
    $noise = Get-Noise $aa
    $A = $ab.Sides['A']; $B = $ab.Sides['B']
    $dq = if ($null -ne $A.Quality -and $null -ne $B.Quality) { $B.Quality - $A.Quality } else { $null }
    $dCost = Get-Pct $A.Cost $B.Cost
    $dTime = Get-Pct $A.Sec $B.Sec
    $v = Get-Verdict $dq $dCost $dTime $B.TargetPct $crit $noise
    $tasks += [pscustomobject]@{
        Prompt = $g.Name; Run = $ab; Noise = $noise; QA = $A.Quality; QB = $B.Quality; Dq = $dq
        DCost = $dCost; DTime = $dTime; TargetPct = $B.TargetPct
        Ctx = if ($null -ne $A.Ctx -and $null -ne $B.Ctx) { $B.Ctx - $A.Ctx } else { $null }
        Verdict = $v.Verdict; Reasons = $v.Reasons
    }
}

$mean = { param($xs) $v = @($xs | Where-Object { $null -ne $_ }); if ($v.Count) { ($v | Measure-Object -Average).Average } else { $null } }
$lines = @(
    "# $Exp 비교 결과"
    ''
    "- 설명: $($e.Meta.description)"
    "- 생성: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    '- 비용은 Claude Code가 보고한 API 기준 추정값(total_cost_usd)이다. 구독 요금제에서는 실제 청구액이 아니다.'
    '- 평균은 오류 없이 끝난 실행만으로 계산했다. 차이(%)는 A 대비 B.'
    ''
)

# ---------- 판정 카드 ----------
$decision = $null
if ($tasks.Count) {
    $overallNoise = if (@($tasks | Where-Object Noise).Count) {
        [pscustomobject]@{
            Cost = & $mean @($tasks | ForEach-Object { $_.Noise.Cost }); Sec = & $mean @($tasks | ForEach-Object { $_.Noise.Sec })
            Quality = & $mean @($tasks | ForEach-Object { $_.Noise.Quality })
        }
    } else { $null }
    $o = [pscustomobject]@{
        Dq = & $mean @($tasks.Dq); DCost = & $mean @($tasks.DCost); DTime = & $mean @($tasks.DTime)
        TargetPct = & $mean @($tasks | ForEach-Object { $_.TargetPct }); Ctx = & $mean @($tasks | ForEach-Object { $_.Ctx })
    }
    $ov = Get-Verdict $o.Dq $o.DCost $o.DTime $o.TargetPct $crit $overallNoise

    # 근거 강도 주의
    $cautions = @()
    $minN = ($tasks | ForEach-Object { $_.Run.Sides.Values | ForEach-Object { $_.All.Count } } | Measure-Object -Minimum).Minimum
    if ($minN -lt 3) { $cautions += "회차가 적음(쪽당 최소 $minN 회). 3회 이상, 영상 숫자는 5회 이상 권장" }
    if (@($tasks | Where-Object { $_.Run.QualitySource -eq 'success' }).Count) { $cautions += '확인 명령·사람 판정이 없는 과제가 있음 — 품질을 "오류 없이 끝남"으로만 봄' }
    if (-not @($tasks | Where-Object Noise).Count) { $cautions += 'A/A 시험이 없음 — 잡음 크기를 모름(.\run-headless.ps1 -Mode AA)' }
    if (@($tasks | Where-Object { $_.Run.Cond.equivalence -and -not $_.Run.Cond.equivalence.ok }).Count) { $cautions += 'A/B 동등성 경고가 있는 측정이 있음' }
    if (@($tasks | Where-Object { @($_.Run.Cond.promptOverride).Count }).Count) { $cautions += '지시문 변형(.A.md/.B.md)을 쓴 측정이 있음 — 영상에서 밝힐 것' }
    if (@($tasks | Where-Object { -not $_.Run.HasTools }).Count) { $cautions += '스킬 호출 기록이 없는 예전 측정이 있음 — 대상 호출 여부를 모름' }
    $changed = @($tasks | Where-Object {
            $d = $_.Run.Cond.decision
            $d -and @($crit.Keys | Where-Object { $null -ne $d.$_ -and [double]$d.$_ -ne $crit[$_] }).Count
        })
    if ($changed.Count) { $cautions += "판정 기준이 측정 뒤 바뀜($(@($changed.Prompt) -join ', ')) — 결과를 보고 기준을 고치지 않았는지 확인" }

    $lines += '## 판정 카드'
    $lines += ''
    $lines += "**결론: $($ov.Verdict)** — $($ov.Reasons -join ' / ')"
    $byVerdict = @($tasks | Group-Object Verdict)
    if ($tasks.Count -gt 1) {
        $lines += ''
        $mixed = if ($byVerdict.Count -gt 1) { ' — 과제마다 다르므로 어떤 작업에 쓸지 함께 밝힐 것' } else { '' }
        $lines += "과제별 판정: $(($byVerdict | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ' · ')$mixed"
    }
    $lines += ''
    $lines += '| 과제 | 측정(쪽당 회차) | 품질 A→B (근거) | 비용 | 시간 | 대상 호출 | 첫 요청 컨텍스트 | 잡음(A/A 비용·시간) | 판정 |'
    $lines += '|---|---|---|---|---|---|---|---|---|'
    foreach ($t in $tasks) {
        $n = "$($t.Run.Sides['A'].All.Count)/$($t.Run.Sides['B'].All.Count)"
        $q = "$(Format-Num $t.QA 0)%→$(Format-Num $t.QB 0)% ($($QualityLabel[$t.Run.QualitySource]))"
        $tp = if ($null -ne $t.TargetPct) { "$([math]::Round($t.TargetPct))%" } else { '-' }
        $ctx = if ($null -ne $t.Ctx) { '{0:+#,0;-#,0;0}' -f $t.Ctx } else { '-' }
        $nz = if ($t.Noise) { "±$(Format-Num $t.Noise.Cost 0)%·±$(Format-Num $t.Noise.Sec 0)%" } else { '-' }
        $lines += "| ``$($t.Prompt)`` | $($t.Run.Name) ($n) | $q | $(Format-Pct $t.DCost) | $(Format-Pct $t.DTime) | $tp | $ctx | $nz | **$($t.Verdict)** |"
    }
    $lines += ''
    if ($null -ne $o.Ctx) { $lines += "- 상시 비용: 첫 요청 컨텍스트 $('{0:+#,0;-#,0;0}' -f $o.Ctx) 토큰(과제 평균). 비교 대상을 쓰지 않는 작업에서도 매 세션 드는 비용" }
    $lines += "- 판정 기준(experiment.json 의 decision): 품질 차이 ±$($crit.minQualityGainPct)%p, 비용 +$($crit.maxCostIncreasePct)%까지, 시간 +$($crit.maxTimeIncreasePct)%까지, 대상 호출 $($crit.minTargetRunPct)% 이상. 비용·시간 차이는 A/A 잡음과 10% 중 큰 값보다 커야 의미 있다고 봄"
    $lines += '- 과제마다 가장 최근 A/B 측정을 쓰고, 결론은 과제 평균으로 같은 규칙을 적용한 것'
    foreach ($c in $cautions) { $lines += "- **주의**: $c" }
    $lines += ''

    $decision = [ordered]@{
        experiment = $Exp; generatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); criteria = $crit
        overall = [ordered]@{ verdict = $ov.Verdict; reasons = @($ov.Reasons); qualityDeltaPp = $o.Dq; costDeltaPct = $o.DCost; timeDeltaPct = $o.DTime; targetRunPct = $o.TargetPct; firstContextDeltaTokens = $o.Ctx }
        tasks = @($tasks | ForEach-Object {
                [ordered]@{
                    prompt = $_.Prompt; run = $_.Run.Name; runsA = $_.Run.Sides['A'].All.Count; runsB = $_.Run.Sides['B'].All.Count
                    qualitySource = $_.Run.QualitySource; qualityA = $_.QA; qualityB = $_.QB; qualityDeltaPp = $_.Dq
                    costA = $_.Run.Sides['A'].Cost; costB = $_.Run.Sides['B'].Cost; costDeltaPct = $_.DCost
                    secondsA = $_.Run.Sides['A'].Sec; secondsB = $_.Run.Sides['B'].Sec; timeDeltaPct = $_.DTime
                    targetRunPct = $_.TargetPct; firstContextDeltaTokens = $_.Ctx
                    noise = if ($_.Noise) { [ordered]@{ run = $_.Noise.Run; costPct = $_.Noise.Cost; timePct = $_.Noise.Sec; qualityPp = $_.Noise.Quality } } else { $null }
                    verdict = $_.Verdict; reasons = @($_.Reasons)
                }
            })
        cautions = @($cautions)
    }
}

# ---------- 측정별 ----------

# 스킬·도구 사용(stream-json 으로 측정한 결과만. 예전 json 결과는 건너뜀)
function Get-UsageSection($Run) {
    if (-not $Run.HasTools) { return @() }
    $Cond = $Run.Cond; $Rows = $Run.Rows
    $out = @('### 스킬·도구 사용', '')
    $tg = $Cond.targets
    if ($Run.Mode -eq 'AA') {
        $out += '- A/A 시험이라 비교 대상이 없음(양쪽 모두 기본 환경).'
    } elseif ($Cond.loaded -and $Cond.loaded.B) {
        $names = @(@($tg.plugins) + @($tg.agents) + @($tg.mcp) | Where-Object { $_ })
        $nSkills = @($tg.skills | Where-Object { $_ }).Count
        if ($names.Count -or $nSkills) {
            $out += "- 실제 로드 확인(init): B에만 있는 것 — 플러그인 [$(@($tg.plugins) -join ', ')] · 스킬 $($nSkills)개 · 에이전트 [$(@($tg.agents) -join ', ')] · MCP [$(@($tg.mcp) -join ', ')]"
        } else {
            $out += '- **B에만 로드된 것이 없음**: 비교 대상이 실제로 로드되지 않았을 수 있습니다(conditions.json 의 loaded 확인).'
        }
    }
    $out += ''
    $out += '| 쪽 | 대상 호출 회차 | 평균 대상 호출 | 평균 스킬 호출 | 평균 도구 호출 | 평균 첫 요청 컨텍스트(토큰) | 평균 훅 문맥(글자) |'
    $out += '|---|---|---|---|---|---|---|'
    foreach ($side in 'A', 'B') {
        $s = $Run.Sides[$side]
        if (-not $s) { continue }
        $hit = if ($tg) { "$(@($s.All | Where-Object { $_.TargetCalls -ne '' -and [int]$_.TargetCalls -gt 0 }).Count)/$($s.All.Count)" } else { '-' }
        $out += "| $side | $hit | $(Format-Num (Get-Avg $s.All TargetCalls) 1) | $(Format-Num (Get-Avg $s.All SkillCalls) 1) | $(Format-Num (Get-Avg $s.All ToolCalls) 1) | $(Format-Num $s.Ctx 0) | $(Format-Num (Get-Avg $s.All HookContextChars) 0) |"
    }
    $A = $Run.Sides['A']; $B = $Run.Sides['B']
    if ($A -and $B -and $null -ne $A.Ctx -and $null -ne $B.Ctx) {
        $out += "| 차이 | | | | | $('{0:+#,0;-#,0;0}' -f ($B.Ctx - $A.Ctx)) ($(Format-Delta $A.Ctx $B.Ctx)) | |"
    }
    $out += ''
    $out += '첫 요청 컨텍스트 = 첫 요청에 들어간 입력 전체(시스템 지시·도구·스킬 목록·훅 문맥·지시문). A/B 차이가 비교 대상의 상시 비용이다. 호출 내역의 굵은 글씨가 비교 대상.'
    # 쪽별 스킬·에이전트 호출 내역(실행 몇 번에서 몇 회)
    foreach ($side in 'A', 'B') {
        $per = @{}
        foreach ($row in @($Rows | Where-Object Side -eq $side)) {
            $f = Join-Path $Run.Dir.FullName "$side-$($row.Run)-tools.json"
            if (-not (Test-Path $f)) { continue }
            $t = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($g in @($t.calls | Where-Object { $_.kind -in 'skill', 'agent' } | Group-Object name)) {
                if (-not $per.ContainsKey($g.Name)) { $per[$g.Name] = @{ Calls = 0; Runs = 0; Target = $false } }
                $per[$g.Name].Calls += $g.Count
                $per[$g.Name].Runs += 1
                if (@($g.Group | Where-Object target).Count) { $per[$g.Name].Target = $true }
            }
        }
        if ($per.Count) {
            $items = $per.GetEnumerator() | Sort-Object { -$_.Value.Calls }, Name | ForEach-Object {
                "$(if ($_.Value.Target) { '**' + $_.Name + '**' } else { $_.Name }) ×$($_.Value.Calls)($($_.Value.Runs)회)"
            }
            $out += "- $side 스킬·에이전트 호출: $($items -join ', ')"
        }
    }
    $out += ''
    $out
}

# 분포(회차 2 이상): 최소–최대와 표준편차
function Get-SpreadSection($Run) {
    $out = @()
    $metrics = @(@{ P = 'CostUSD'; L = '비용(USD)'; D = 4 }, @{ P = 'Seconds'; L = '시간(초)'; D = 1 }, @{ P = 'OutputTokens'; L = '출력 토큰'; D = 0 }, @{ P = 'Turns'; L = '턴'; D = 1 })
    $body = @()
    foreach ($side in 'A', 'B') {
        $s = $Run.Sides[$side]
        if (-not $s -or $s.Ok.Count -lt 2) { continue }
        $cells = foreach ($m in $metrics) {
            $sp = Get-Spread $s.Ok $m.P
            if ($sp) { "$(Format-Num $sp.Min $m.D)–$(Format-Num $sp.Max $m.D) (±$(Format-Num $sp.Sd $m.D))" } else { '-' }
        }
        $body += "| $side | $($cells -join ' | ') |"
    }
    if ($body.Count) {
        $out += '분포(오류 없이 끝난 실행의 최소–최대, 괄호는 표준편차):'
        $out += ''
        $out += "| 쪽 | $(($metrics | ForEach-Object { $_.L }) -join ' | ') |"
        $out += "|---|$(($metrics | ForEach-Object { '---' }) -join '|')|"
        $out += $body
        $out += ''
    }
    $out
}

foreach ($run in $runs) {
    $cond = $run.Cond
    $lines += if ($run.Mode -eq 'AA') { "## $($run.Name) (A/A 잡음 측정)" } else { "## $($run.Name)" }
    $lines += ''
    if ($run.Mode -eq 'AA') {
        $lines += '- **A/A 시험**: B 열도 기본 환경(A 설정 폴더)으로 실행했다. 두 열의 차이는 우연 변동(잡음)의 크기이며, 같은 지시문의 A/B 판정에 기준으로 쓴다.'
    }
    $lines += "- 지시문: ``$($cond.prompt)`` / 모델: ``$($cond.model)`` / 권한 모드: ``$($cond.permissionMode)`` / Claude Code: $($cond.claudeVersion)"
    if ($run.Mode -ne 'AA') {
        $lines += "- B 구성: 플러그인 [$($cond.plugins -join ', ')] · 스킬 [$($cond.skills -join ', ')] · /plugin 설치 $($cond.installedB) · MCP [$($cond.mcpB -join ', ')]"
        foreach ($m in @($cond.bManifest | Where-Object { $_ })) {
            $commit = if ($m.commit) { " · 커밋 ``$("$($m.commit)".Substring(0, [Math]::Min(12, "$($m.commit)".Length)))``$(if ($m.dirty) { '(수정본)' })" } else { '' }
            $lines += "  - $($m.kind) ``$($m.name)``$(if ($m.version) { " $($m.version)" })$commit$(if ($m.source) { " · $($m.source)" })"
        }
    }
    if (@($cond.promptOverride).Count) {
        $lines += "- **지시문 변형**: $(@($cond.promptOverride) -join ', ') 쪽은 다른 지시문을 받음(``prompt.<쪽>.md`` 참고). 비교 조건이 다르므로 결과 해석 시 밝힐 것"
    }
    if ($cond.equivalence -and -not $cond.equivalence.ok) {
        $lines += "- **A/B 동등성 경고**: $(@($cond.equivalence.issues) -join ' / ')"
    }
    if ($cond.check -and $cond.check.command) { $lines += "- 확인 명령: ``$($cond.check.command)``" }

    $lines += ''
    $lines += '| 쪽 | 성공/전체 | 확인 통과 | 사람 판정(통과·부분/판정) | 평균 비용(USD) | 평균 턴 | 평균 시간(초) | 평균 출력 토큰 | 평균 변경 파일 |'
    $lines += '|---|---|---|---|---|---|---|---|---|'
    foreach ($side in 'A', 'B') {
        $s = $run.Sides[$side]
        if (-not $s) { continue }
        $check = if ($run.HasCheck) { "$(@($s.All | Where-Object CheckPassed -eq 'True').Count)/$(@($s.All | Where-Object { $_.CheckPassed -in 'True', 'False' }).Count)" } else { '-' }
        $judge = if ($run.HasJudge -and $s.Judged.Count) { "$(@($s.Judged | Where-Object { $_ -eq 'pass' }).Count)·$(@($s.Judged | Where-Object { $_ -eq 'partial' }).Count)/$($s.Judged.Count)" } else { '-' }
        $lines += "| $side | $($s.Ok.Count)/$($s.All.Count) | $check | $judge | $(Format-Num $s.Cost 4) | $(Format-Num $s.Turns 1) | $(Format-Num $s.Sec 1) | $(Format-Num $s.Out 0) | $(Format-Num $s.Chg 1) |"
    }
    $A = $run.Sides['A']; $B = $run.Sides['B']
    if ($A -and $B) {
        $lines += "| 차이 | | | | $(Format-Delta $A.Cost $B.Cost) | $(Format-Delta $A.Turns $B.Turns) | $(Format-Delta $A.Sec $B.Sec) | $(Format-Delta $A.Out $B.Out) | $(Format-Delta $A.Chg $B.Chg) |"
    }
    $lines += ''
    if ($run.Mode -eq 'AB') {
        $aa = $runs | Where-Object { $_.Mode -eq 'AA' -and $_.Prompt -eq $run.Prompt -and $_.Sides.Count -eq 2 } | Sort-Object Name | Select-Object -Last 1
        $nz = Get-Noise $aa
        if ($nz) {
            $lines += "- A/A 잡음(같은 지시문, $($nz.Run)): 비용 ±$(Format-Num $nz.Cost 0)% · 시간 ±$(Format-Num $nz.Sec 0)% · 출력 토큰 ±$(Format-Num $nz.Out 0)%. 이보다 작은 차이는 우연일 수 있음"
            $lines += ''
        }
    }
    $lines += Get-SpreadSection $run
    $lines += Get-UsageSection $run
    $lines += "실행별 결과물: ``results\$($run.Name)\<쪽>-<회차>-work\`` · 변경 목록 ``*-changes.txt`` · 최종 응답 ``*-result.md`` · 확인 결과 ``*-check.txt`` · 도구 호출 ``*-tools.json``"
    $lines += ''
}

$reportFile = Join-Path $e.Dir 'REPORT.md'
Write-Utf8NoBom $reportFile (($lines -join "`n") + "`n")
if ($decision) { Write-Utf8NoBom (Join-Path $e.Dir 'decision.json') ($decision | ConvertTo-Json -Depth 8) }
$lines | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host "저장: $reportFile"
