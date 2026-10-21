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
$sides = if ($Side -eq 'Both') { @('A', 'B') } else { @($Side) }
$fixture = Join-Path $e.Dir 'fixture'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $e.Dir "results\$stamp-$promptName"
New-Item -ItemType Directory -Force $outDir | Out-Null
Copy-Item $promptFile (Join-Path $outDir 'prompt.md')

# 나중에 같은 조건으로 다시 돌릴 수 있게 실행 조건을 남긴다.
$cond = [ordered]@{
    experiment     = $Exp
    prompt         = $promptName
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
}
Write-Utf8NoBom (Join-Path $outDir 'conditions.json') ($cond | ConvertTo-Json)

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
            $raw = $text | & claude @cliArgs
            $exit = $LASTEXITCODE
            Pop-Location

            $base = Join-Path $outDir "$side-$i"
            Write-Utf8NoBom "$base.json" ($raw -join "`n")
            # 작업 결과물과 fixture 대비 변경 목록을 남긴다.
            Invoke-Mirror $l.Work "$base-work"
            $changes = Compare-Tree $fixture $l.Work
            Write-Utf8NoBom "$base-changes.txt" (($changes -join "`n") + "`n")

            $row = [ordered]@{
                Side = $side; Run = $i; Exit = $exit; IsError = $null; Subtype = $null
                CostUSD = $null; Turns = $null; Seconds = $null
                InputTokens = $null; OutputTokens = $null; CacheReadTokens = $null
                ChangedFiles = $changes.Count; SessionId = $null
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
$rows | Format-Table Side, Run, Exit, IsError, CostUSD, Turns, Seconds, OutputTokens, ChangedFiles -AutoSize

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
    }
} | Format-Table -AutoSize
Write-Host "결과: $outDir"
Write-Host "전체 요약: .\report.ps1 -Exp $Exp"
