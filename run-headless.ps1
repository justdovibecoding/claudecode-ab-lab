# 실험의 지시문을 A, B에서 번갈아 N회씩 헤드리스(claude -p)로 실행하고 결과를 모은다.
#   .\run-headless.ps1 -Exp superpowers -Prompt 01-task
#   .\run-headless.ps1 -Exp superpowers -Prompt 01-task -Runs 5 -PermissionMode bypassPermissions -MaxBudgetUsd 2
# -Prompt 는 prompts\ 안의 파일 이름(.md 생략 가능) 또는 파일 경로.
param(
    [Parameter(Mandatory)][string]$Exp,
    [Parameter(Mandatory)][string]$Prompt,
    [ValidateRange(1, 50)][int]$Runs = 3,
    [string]$Model,
    [ValidateSet('acceptEdits', 'auto', 'plan', 'dontAsk', 'bypassPermissions')][string]$PermissionMode = 'acceptEdits',
    [double]$MaxBudgetUsd = 0,
    [ValidateSet('A', 'B', 'Both')][string]$Side = 'Both'
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$e = Get-Experiment $Exp
$promptFile = @($Prompt, (Join-Path $e.Dir "prompts\$Prompt"), (Join-Path $e.Dir "prompts\$Prompt.md")) |
    Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
if (-not $promptFile) { throw "지시문을 찾을 수 없습니다: $Prompt" }
$text = Get-Content $promptFile -Raw -Encoding UTF8
if (-not ($text -replace '(?s)<!--.*?-->', '').Trim()) { throw "지시문이 비어 있습니다(주석만 있음): $promptFile" }
$promptName = [IO.Path]::GetFileNameWithoutExtension($promptFile)

# 쪽별 변형: 01-task.md 옆에 01-task.A.md / 01-task.B.md 가 있으면 그쪽에는 변형을 보낸다
# (예: B에만 "superpowers 스킬을 사용해줘" 를 덧붙임). 변형은 conditions.json 과 보고서에 표시된다.
$promptBase = $promptFile -replace '\.md$', ''
$texts = @{}
$override = @()
foreach ($s in 'A', 'B') {
    $variantFile = "$promptBase.$s.md"
    if (Test-Path $variantFile -PathType Leaf) {
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
$outDir = Join-Path $e.Dir "results\$stamp-$promptName"
New-Item -ItemType Directory -Force $outDir | Out-Null
Copy-Item $promptFile (Join-Path $outDir 'prompt.md')
foreach ($s in $override) { Copy-Item "$promptBase.$s.md" (Join-Path $outDir "prompt.$s.md") }

# 나중에 같은 조건으로 다시 돌릴 수 있게 실행 조건을 남긴다.
$cond = [ordered]@{
    experiment     = $Exp
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
    claudeVersion  = (& claude --version) -join ' '
    startedAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    bManifest      = @(Get-BManifest $e)
    check          = $e.Meta.check
    equivalence    = $null
}

# A/B 동등성(계정·계정 스킬·설정). 다르면 경고하고 조건에 남긴다(측정은 계속).
Write-Host 'A/B 동등성 점검 중...'
$eq = Get-Equivalence $e
$cond.equivalence = [ordered]@{ ok = $eq.Ok; issues = @($eq.Issues) }
if (-not $eq.Ok) { foreach ($issue in $eq.Issues) { Write-Warning "A/B 동등성: $issue" } }
Write-Utf8NoBom (Join-Path $outDir 'conditions.json') ($cond | ConvertTo-Json -Depth 6)

# 품질 확인 명령(experiment.json 의 check.command). 매 실행 뒤 작업 폴더에서 실행한다.
$checkCmd = if ($e.Meta.check -and $e.Meta.check.command) { "$($e.Meta.check.command)" } else { '' }
$checkTimeout = if ($e.Meta.check -and $e.Meta.check.timeoutSec) { [int]$e.Meta.check.timeoutSec } else { 600 }
if ($checkCmd) { Write-Host "확인 명령: $checkCmd (제한 $checkTimeout 초)" }

$oldConfig = $env:CLAUDE_CONFIG_DIR
$oldOutputEncoding = $OutputEncoding
$oldConsoleEncoding = [Console]::OutputEncoding
$rows = @()
try {
    # PowerShell 5.1은 파이프 기본 인코딩이 ASCII라서 한국어 지시문이 깨진다.
    $OutputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom

    for ($i = 1; $i -le $Runs; $i++) {
        # 순서 효과(캐시 등)를 줄이려고 회차마다 A/B 순서를 바꾼다.
        $order = if ($i % 2 -eq 1) { $sides } else { @($sides)[($sides.Count - 1)..0] }
        foreach ($side in $order) {
            Reset-Work $e @($side)
            $l = Get-SideLaunch $e $side $Model
            $cliArgs = @('-p', '--output-format', 'json', '--permission-mode', $PermissionMode) + $l.CliArgs
            if ($MaxBudgetUsd -gt 0) { $cliArgs += @('--max-budget-usd', $MaxBudgetUsd) }

            $env:CLAUDE_CONFIG_DIR = $l.Config
            Push-Location $l.Work
            Write-Host "[$Exp/$side] $i/$Runs 실행 중..."
            $global:LASTEXITCODE = 0  # 앞의 robocopy 종료 코드가 남지 않게
            $raw = $texts[$side] | & claude @cliArgs
            $exit = $LASTEXITCODE
            Pop-Location

            $base = Join-Path $outDir "$side-$i"
            Write-Utf8NoBom "$base.json" ($raw -join "`n")
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
                InputTokens = $null; OutputTokens = $null; CacheReadTokens = $null
                ChangedFiles = $changes.Count; CheckPassed = $checkPassed; SessionId = $null
            }
            try {
                $r = ($raw -join "`n") | ConvertFrom-Json
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
                }
                if ($r.result) { Write-Utf8NoBom "$base-result.md" $r.result }
            } catch {
                $row.IsError = $true
                $row.Subtype = 'JSON 해석 실패'
            }
            $rows += [pscustomobject]$row
        }
    }
} finally {
    $env:CLAUDE_CONFIG_DIR = $oldConfig
    $OutputEncoding = $oldOutputEncoding
    [Console]::OutputEncoding = $oldConsoleEncoding
}

$rows | Export-Csv (Join-Path $outDir 'summary.csv') -NoTypeInformation -Encoding UTF8
$rows | Format-Table Side, Run, Exit, IsError, CostUSD, Turns, Seconds, OutputTokens, ChangedFiles, CheckPassed -AutoSize

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
    }
} | Format-Table -AutoSize
if (-not $eq.Ok) { Write-Warning 'A/B 동등성 경고가 있었습니다. conditions.json 과 보고서에 기록됨.' }
Write-Host "결과: $outDir"
Write-Host "전체 요약: .\report.ps1 -Exp $Exp"
