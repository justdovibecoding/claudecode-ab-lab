# 실험의 지시문을 A, B에서 번갈아 N회씩 헤드리스(claude -p)로 실행하고 결과를 모은다.
#   .\run-headless.ps1 -Exp superpowers -Prompt 01-task
#   .\run-headless.ps1 -Exp superpowers -Prompt 01-task -Runs 5 -PermissionMode bypassPermissions -MaxBudgetUsd 2
#   .\run-headless.ps1 -Exp superpowers -Prompt 01-task -Mode AA     # A/A 시험: 양쪽 모두 기본 환경(잡음 크기 측정)
# -Prompt 는 prompts\ 안의 파일 이름(.md 생략 가능) 또는 파일 경로.
param(
    [Parameter(Mandatory)][string]$Exp,
    [Parameter(Mandatory)][string]$Prompt,
    [ValidateRange(1, 50)][int]$Runs = 3,
    [string]$Model,
    [ValidateSet('acceptEdits', 'auto', 'plan', 'dontAsk', 'bypassPermissions')][string]$PermissionMode = 'acceptEdits',
    [double]$MaxBudgetUsd = 0,
    [ValidateSet('A', 'B', 'Both')][string]$Side = 'Both',
    # AB: 보통 비교. AA: B 열도 기본 환경(A 설정 폴더)으로 실행해 우연 변동(잡음)을 잰다. 결과는 A/B 와 같은 형식.
    [ValidateSet('AB', 'AA')][string]$Mode = 'AB'
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$e = Get-Experiment $Exp
$promptFile = @($Prompt, (Join-Path $e.Dir "prompts\$Prompt"), (Join-Path $e.Dir "prompts\$Prompt.md")) |
    Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
if (-not $promptFile) { throw "지시문을 찾을 수 없습니다: $Prompt" }
$text = Get-Content $promptFile -Raw -Encoding UTF8
if (-not ($text -replace '(?s)<!--.*?-->', '').Trim()) { throw "지시문이 비어 있습니다(주석만 있음): $promptFile" }
$promptName = [IO.Path]::GetFileNameWithoutExtension($promptFile)
if ($Mode -eq 'AA' -and $Side -ne 'Both') { throw 'A/A 시험(-Mode AA)은 -Side Both 로만 실행합니다.' }

# 쪽별 변형: 01-task.md 옆에 01-task.A.md / 01-task.B.md 가 있으면 그쪽에는 변형을 보낸다
# (예: B에만 "superpowers 스킬을 사용해줘" 를 덧붙임). 변형은 conditions.json 과 보고서에 표시된다.
$promptBase = $promptFile -replace '\.md$', ''
$texts = @{}
$override = @()
foreach ($s in 'A', 'B') {
    $variantFile = "$promptBase.$s.md"
    # A/A 시험은 양쪽이 똑같아야 하므로 변형을 쓰지 않는다.
    if ($Mode -ne 'AA' -and (Test-Path $variantFile -PathType Leaf)) {
        $texts[$s] = Get-Content $variantFile -Raw -Encoding UTF8
        if (-not ($texts[$s] -replace '(?s)<!--.*?-->', '').Trim()) { throw "변형 지시문이 비어 있습니다: $variantFile" }
        $override += $s
    } else {
        $texts[$s] = $text
    }
}
$sides = if ($Side -eq 'Both') { @('A', 'B') } else { @($Side) }
$fixture = Join-Path $e.Dir 'fixture'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $e.Dir "results\$stamp-$promptName$(if ($Mode -eq 'AA') { '-AA' })"
New-Item -ItemType Directory -Force $outDir | Out-Null
Copy-Item $promptFile (Join-Path $outDir 'prompt.md')
foreach ($s in $override) { Copy-Item "$promptBase.$s.md" (Join-Path $outDir "prompt.$s.md") }

# 나중에 같은 조건으로 다시 돌릴 수 있게 실행 조건을 남긴다.
$cond = [ordered]@{
    experiment     = $Exp
    mode           = $Mode   # AA 면 B 열도 기본 환경
    prompt         = $promptName
    promptOverride = @($override)
    runs           = $Runs
    sides          = $sides
    model          = if ($Model) { $Model } else { $e.Meta.model }
    permissionMode = $PermissionMode
    maxBudgetUsd   = $MaxBudgetUsd
    plugins        = @(Get-PluginDirs $e | ForEach-Object Name)
    skills         = @(Get-SkillDirs $e | ForEach-Object Name)
    installedB     = Test-Path (Join-Path $e.ConfigB 'plugins\installed_plugins.json')
    mcpB           = @((Get-Content (Join-Path $e.Dir 'mcp-B.json') -Raw | ConvertFrom-Json).mcpServers.PSObject.Properties | ForEach-Object Name)
    claudeVersion  = (& $ClaudeCmd --version) -join ' '
    claudePath     = Get-ClaudePath
    memoryReset    = $true   # 매 실행 전 작업 폴더 초기화 때 자동 메모리도 지움(Reset-Work)
    startedAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    bManifest      = @(Get-BManifest $e)
    check          = $e.Meta.check
    decision       = $e.Meta.decision   # 측정 때의 판정 기준(나중에 기준을 바꿨는지 보고서가 확인)
    equivalence    = $null
    loaded         = $null   # 측정 뒤 채움: 쪽별로 실제 로드된 플러그인·스킬·에이전트·MCP(init 이벤트)
    targets        = $null   # 측정 뒤 채움: 비교 대상 = B에서만 로드된 것
}

# A/B 동등성(계정·계정 스킬·설정). 다르면 경고하고 조건에 남긴다(측정은 계속). A/A 는 양쪽이 같은 설정 폴더라 건너뛴다.
if ($Mode -eq 'AA') {
    Write-Host 'A/A 시험: 양쪽 모두 기본 환경(config-vanilla)으로 실행합니다.'
    $eq = [pscustomobject]@{ Ok = $true; Issues = @() }
} else {
    Write-Host 'A/B 동등성 점검 중...'
    $eq = Get-Equivalence $e
}
$cond.equivalence = [ordered]@{ ok = $eq.Ok; issues = @($eq.Issues); notes = @($eq.Notes) }
if (-not $eq.Ok) { foreach ($issue in $eq.Issues) { Write-Warning "A/B 동등성: $issue" } }
Write-Utf8NoBom (Join-Path $outDir 'conditions.json') ($cond | ConvertTo-Json -Depth 6)

# 작업 폴더를 초기화하기 전에, 앱에서 "종료" 없이 닫은 대화형 세션의 결과물이 있으면 먼저 남긴다.
try {
    $saved = Save-PendingLiveSession $e
    if ($saved) { Write-Host "대화형 세션 결과를 먼저 남김: $($saved.dir)" }
} catch { Write-Warning "대화형 세션 결과를 남기지 못함: $($_.Exception.Message)" }

# 품질 확인 명령(experiment.json 의 check.command). 매 실행 뒤 작업 폴더에서 실행한다.
$checkCmd = if ($e.Meta.check -and $e.Meta.check.command) { "$($e.Meta.check.command)" } else { '' }
$checkTimeout = if ($e.Meta.check -and $e.Meta.check.timeoutSec) { [int]$e.Meta.check.timeoutSec } else { 600 }
if ($checkCmd) { Write-Host "확인 명령: $checkCmd (제한 $checkTimeout 초)" }

$oldConfig = $env:CLAUDE_CONFIG_DIR
$oldOutputEncoding = $global:OutputEncoding
$oldConsoleEncoding = [Console]::OutputEncoding
$rows = @()
$streams = @()
try {
    # PowerShell 5.1은 파이프 기본 인코딩이 ASCII라서 한국어 지시문이 깨진다(한글이 ?로 바뀜).
    # 외부 프로그램 파이프는 전역 $OutputEncoding 을 쓰므로 전역에 설정해야 한다. 스크립트 범위에만 두면
    # -File 실행(앱)에서는 맞지만 대화형 프롬프트에서 .\run-headless.ps1 로 부르면 ASCII 그대로다.
    $global:OutputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom

    for ($i = 1; $i -le $Runs; $i++) {
        # 순서 효과(캐시 등)를 줄이려고 회차마다 A/B 순서를 바꾼다.
        $order = if ($i % 2 -eq 1) { $sides } else { @($sides)[($sides.Count - 1)..0] }
        foreach ($side in $order) {
            # A/A 시험에서는 B 열도 A 설정 폴더·작업 폴더로 실행한다(순서대로 돌므로 작업 폴더를 같이 써도 됨).
            $launchSide = if ($Mode -eq 'AA') { 'A' } else { $side }
            Reset-Work $e @($launchSide)
            $l = Get-SideLaunch $e $launchSide $Model
            # stream-json: 최종 결과 말고도 로드 목록(init)과 도구·스킬 호출을 남긴다(--verbose 필수).
            $cliArgs = @('-p', '--output-format', 'stream-json', '--verbose', '--permission-mode', $PermissionMode) + $l.CliArgs
            if ($MaxBudgetUsd -gt 0) { $cliArgs += @('--max-budget-usd', $MaxBudgetUsd) }

            $env:CLAUDE_CONFIG_DIR = $l.Config
            Push-Location $l.Work
            Write-Host "[$Exp/$side] $i/$Runs 실행 중..."
            $global:LASTEXITCODE = 0  # 앞의 robocopy 종료 코드가 남지 않게
            $raw = $texts[$side] | & $ClaudeCmd @cliArgs
            $exit = $LASTEXITCODE
            Pop-Location

            $base = Join-Path $outDir "$side-$i"
            $raw = @($raw | ForEach-Object { "$_" })
            Write-Utf8NoBom "$base-stream.jsonl" (($raw -join "`n") + "`n")
            $st = Read-ClaudeStream $raw
            # A-1.json 은 예전 --output-format json 결과와 같은 최종 결과(result 이벤트)만 둔다.
            Write-Utf8NoBom "$base.json" $(if ($st.Result) { $st.Result | ConvertTo-Json -Depth 20 } else { '' })
            # 작업 결과물과 fixture 대비 변경 목록을 남긴다.
            Invoke-Mirror $l.Work "$base-work"
            $changes = Compare-Tree $fixture $l.Work
            Write-Utf8NoBom "$base-changes.txt" (($changes -join "`n") + "`n")

            # 확인 명령은 결과물 사본을 뜬 뒤 작업 폴더에서 실행한다(사본에는 확인 명령의 부산물이 섞이지 않음).
            $checkPassed = $null
            if ($checkCmd) {
                $env:CLAUDE_CONFIG_DIR = $oldConfig
                $ck = Invoke-CheckCommand $l.Work $checkCmd $checkTimeout
                $checkPassed = $ck.Passed
                $status = if ($ck.TimedOut) { "시간 초과($checkTimeout 초)" } else { "종료 코드 $($ck.ExitCode)" }
                Write-Utf8NoBom "$base-check.txt" ("명령: $checkCmd`n결과: $(if ($ck.Passed) { '통과' } else { '실패' }) · $status · $($ck.Seconds)초`n`n$($ck.Output)")
                Write-Host "[$Exp/$side] $i/$Runs 확인: $(if ($ck.Passed) { '통과' } else { '실패' }) ($status)"
            }

            $row = [ordered]@{
                Side = $side; Run = $i; Exit = $exit; IsError = $null; Subtype = $null
                CostUSD = $null; Turns = $null; Seconds = $null
                InputTokens = $null; OutputTokens = $null; CacheReadTokens = $null; CacheCreationTokens = $null
                FirstContextTokens = $st.FirstContext
                ChangedFiles = $changes.Count; CheckPassed = $checkPassed
                ToolCalls = @($st.Calls).Count; SkillCalls = @($st.Calls | Where-Object Kind -eq 'skill').Count
                TargetCalls = $null; Skills = Format-CallCounts @($st.Calls | Where-Object Kind -in 'skill', 'agent')
                HookContextChars = $st.HookChars; SessionId = $null
            }
            $streams += [pscustomobject]@{ Base = $base; Side = $side; Stream = $st; Row = $row }
            try {
                $r = $st.Result
                if (-not $r) { throw '결과 이벤트 없음' }
                $row.IsError = $r.is_error
                $row.Subtype = $r.subtype
                $row.CostUSD = $r.total_cost_usd
                $row.Turns = $r.num_turns
                $row.Seconds = [math]::Round($r.duration_ms / 1000, 1)
                $row.SessionId = $r.session_id
                if ($r.usage) {
                    $row.InputTokens = $r.usage.input_tokens
                    $row.OutputTokens = $r.usage.output_tokens
                    $row.CacheReadTokens = $r.usage.cache_read_input_tokens
                    $row.CacheCreationTokens = $r.usage.cache_creation_input_tokens
                }
                if ($r.result) { Write-Utf8NoBom "$base-result.md" $r.result }
            } catch {
                $row.IsError = $true
                $row.Subtype = '결과 해석 실패'
            }
        }
    }
} finally {
    $env:CLAUDE_CONFIG_DIR = $oldConfig
    $global:OutputEncoding = $oldOutputEncoding
    [Console]::OutputEncoding = $oldConsoleEncoding
}

# 비교 대상(B에서만 로드된 플러그인·스킬·에이전트·MCP)을 정하고, 실행마다 대상 호출을 센다.
$initOf = { param($s) Get-InitSummary (@($streams | Where-Object { $_.Side -eq $s -and $_.Stream.Init }) | Select-Object -First 1).Stream.Init }
$loaded = [ordered]@{ A = & $initOf 'A'; B = & $initOf 'B' }
$targets = if ($loaded.A -and $loaded.B) { Get-StreamTargets $loaded.A $loaded.B $cond.bManifest } else { $null }
foreach ($s in $streams) {
    $hits = @($s.Stream.Calls | Where-Object { Test-TargetCall $_ $targets })
    $s.Row.TargetCalls = if ($targets) { $hits.Count } else { $null }
    $tools = [ordered]@{
        firstContextTokens = $s.Stream.FirstContext
        hooks = [ordered]@{ count = $s.Stream.HookCount; contextChars = $s.Stream.HookChars }
        calls = @($s.Stream.Calls | ForEach-Object {
                [ordered]@{ tool = $_.Tool; kind = $_.Kind; name = $_.Name; target = [bool](Test-TargetCall $_ $targets) } })
    }
    Write-Utf8NoBom "$($s.Base)-tools.json" ($tools | ConvertTo-Json -Depth 6)
    $rows += [pscustomobject]$s.Row
}
$cond.loaded = $loaded
$cond.targets = $targets
if ($Mode -eq 'AB') {
    $cond.equivalence = Resolve-EquivalenceWithInit $cond.equivalence $loaded.A $loaded.B
    if ($cond.equivalence.ok -and @($cond.equivalence.preRunIssues | Where-Object { $_ }).Count) {
        Write-Host 'A/B 동등성: 측정 전 경고는 실제 로드 목록(init)으로 확인한 결과 해소됨(B 계정 스킬이 첫 실행 때 동기화됨).'
    }
}
Write-Utf8NoBom (Join-Path $outDir 'conditions.json') ($cond | ConvertTo-Json -Depth 6)
if ($Mode -eq 'AB' -and $loaded.B -and $targets -and -not ($targets.plugins.Count + $targets.skills.Count + $targets.agents.Count + $targets.mcp.Count)) {
    Write-Warning 'B에서만 로드된 비교 대상이 없습니다. B 구성이 실제로 로드되는지 확인하세요(conditions.json 의 loaded).'
}

$rows | Export-Csv (Join-Path $outDir 'summary.csv') -NoTypeInformation -Encoding UTF8
$rows | Format-Table Side, Run, Exit, IsError, CostUSD, Turns, Seconds, OutputTokens, ChangedFiles, CheckPassed, TargetCalls -AutoSize

Write-Host '쪽별 평균(오류 제외):'
$rows | Where-Object { -not $_.IsError } | Group-Object Side | ForEach-Object {
    [pscustomobject]@{
        Side         = $_.Name
        N            = $_.Count
        AvgCostUSD   = [math]::Round(($_.Group | Measure-Object CostUSD -Average).Average, 4)
        AvgTurns     = [math]::Round(($_.Group | Measure-Object Turns -Average).Average, 1)
        AvgSeconds   = [math]::Round(($_.Group | Measure-Object Seconds -Average).Average, 1)
        AvgOutTokens = [math]::Round(($_.Group | Measure-Object OutputTokens -Average).Average, 0)
        AvgChanged   = [math]::Round(($_.Group | Measure-Object ChangedFiles -Average).Average, 1)
        CheckPassed  = if ($checkCmd) { "$(@($_.Group | Where-Object CheckPassed).Count)/$($_.Count)" } else { '-' }
        TargetRuns   = if ($targets) { "$(@($_.Group | Where-Object { $_.TargetCalls -gt 0 }).Count)/$($_.Count)" } else { '-' }
    }
} | Format-Table -AutoSize
if (-not $eq.Ok) { Write-Warning 'A/B 동등성 경고가 있었습니다. conditions.json 과 보고서에 기록됨.' }
Write-Host "결과: $outDir"
Write-Host "전체 요약: .\report.ps1 -Exp $Exp"
