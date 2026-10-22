# A/B 에 실제로 무엇이 붙는지(MCP 서버·MCP 도구·스킬·플러그인·에이전트) 보여 준다.
# 측정과 같은 인자로 claude 를 띄워 시작 정보(init)만 읽고 바로 끈다. 모델 응답 전에 끊으므로 토큰은 거의 쓰지 않는다.
#   .\inventory.ps1                  # A(기본 환경)만
#   .\inventory.ps1 -Exp karpathy    # A 와 실험 B, 차이까지
param([string]$Exp, [int]$TimeoutSec = 60)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Get-InitEvent($Launch) {
    $exe = Get-ClaudePath
    if (-not $exe) { throw "claude 를 찾지 못했습니다: $ClaudeCmd" }
    # 목록 확인용이라 가장 싼 모델로 띄운다(로드 목록은 모델과 무관).
    $cliArgs = @('-p', '--output-format', 'stream-json', '--verbose') + $Launch.CliArgs
    $i = [array]::IndexOf($cliArgs, '--model')
    if ($i -ge 0) { $cliArgs[$i + 1] = 'haiku' }
    $quoted = ($cliArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '

    $psi = New-Object Diagnostics.ProcessStartInfo
    if ($exe -like '*.exe') { $psi.FileName = $exe; $psi.Arguments = $quoted }
    else { $psi.FileName = 'cmd.exe'; $psi.Arguments = "/d /s /c `"`"$exe`" $quoted`"" }
    $psi.WorkingDirectory = $Launch.Work
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8NoBom
    $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = $Launch.Config
    # 이 스크립트를 Claude Code 세션 안에서 부를 때 섞이는 세션 변수는 넘기지 않는다.
    foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ($k -like 'CLAUDE_CODE_*' -or $k -eq 'CLAUDECODE') { $psi.EnvironmentVariables.Remove($k) } }

    $p = [Diagnostics.Process]::Start($psi)
    try {
        $p.StandardInput.Write('ok')
        $p.StandardInput.Close()
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $task = $p.StandardOutput.ReadLineAsync()
            if (-not $task.Wait([int][math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds))) { break }
            $line = $task.Result
            if ($null -eq $line) { break }
            if (-not $line.StartsWith('{')) { continue }
            try { $j = $line | ConvertFrom-Json } catch { continue }
            if ($j.type -eq 'system' -and $j.subtype -eq 'init') { return $j }
        }
        throw "시작 정보를 받지 못했습니다($($Launch.Side)). $($p.StandardError.ReadToEnd())"
    } finally {
        if (-not $p.HasExited) { & taskkill /PID $p.Id /T /F 2>&1 | Out-Null }
    }
}

function Get-Inventory($Init) {
    $skills = @($Init.skills | ForEach-Object { "$_" })
    [ordered]@{
        mcpServers = @($Init.mcp_servers | Where-Object { $_ } | ForEach-Object { "$($_.name) ($($_.status))" })
        mcpTools   = @($Init.tools | Where-Object { "$_" -like 'mcp__*' } | ForEach-Object { "$_" })
        plugins    = @($Init.plugins | Where-Object { $_ } | ForEach-Object { if ($_.version) { "$($_.source) $($_.version)" } else { "$($_.source)" } })
        # 이름에 접두사가 없으면 Claude Code 내장, anthropic-skills: 는 claude.ai 계정 동기화, 그 밖의 접두사는 플러그인
        builtinSkills = @($skills | Where-Object { $_ -notlike '*:*' })
        accountSkills = @($skills | Where-Object { $_ -like 'anthropic-skills:*' })
        pluginSkills  = @($skills | Where-Object { $_ -like '*:*' -and $_ -notlike 'anthropic-skills:*' })
        agents     = @($Init.agents | ForEach-Object { "$_" })
        tools      = @($Init.tools | Where-Object { "$_" -notlike 'mcp__*' }).Count
    }
}

function Write-List([string]$Label, [string[]]$Items, [string]$Empty = '없음') {
    $color = if ($Items.Count) { 'White' } else { 'DarkGray' }
    Write-Host ("  {0} {1}개" -f $Label, $Items.Count) -ForegroundColor $color
    if ($Items.Count) { Write-Host ('    ' + ($Items -join ', ')) -ForegroundColor Gray }
}

function Write-Inventory([string]$Title, $Inv) {
    Write-Host "== $Title" -ForegroundColor Cyan
    Write-List 'MCP 서버' $Inv.mcpServers
    Write-List 'MCP 도구' $Inv.mcpTools
    Write-List '플러그인' $Inv.plugins
    Write-List '스킬(Claude Code 내장)' $Inv.builtinSkills
    Write-List '스킬(claude.ai 계정)' $Inv.accountSkills
    Write-List '스킬(플러그인·로컬)' $Inv.pluginSkills
    Write-List '에이전트' $Inv.agents
    Write-Host "  내장 도구 $($Inv.tools)개" -ForegroundColor DarkGray
}

$e = if ($Exp) { Get-Experiment $Exp } else { [pscustomobject]@{ Meta = [pscustomobject]@{ model = $Lab.DefaultModel } } }
$sides = if ($Exp) { @('A', 'B') } else { @('A') }
$inv = @{}
foreach ($side in $sides) {
    if ($side -eq 'A' -and -not $Exp) {
        $work = Join-Path $Lab.WorkRoot '_inventory'
        New-Item -ItemType Directory -Force $work | Out-Null
        $launch = [pscustomobject]@{ Side = 'A'; Config = $VanillaConfig; Work = $work
            CliArgs = @('--model', 'haiku', '--strict-mcp-config', '--mcp-config', $EmptyMcp, '--no-chrome') }
    } else {
        $launch = Get-SideLaunch $e $side
        New-Item -ItemType Directory -Force $launch.Work | Out-Null
    }
    $inv[$side] = Get-Inventory (Get-InitEvent $launch)
    Write-Inventory $(if ($side -eq 'A') { 'A 기본' } else { "B 비교 ($Exp)" }) $inv[$side]
}

if ($Exp) {
    Write-Host '== B 에만 있는 것 (비교 대상)' -ForegroundColor Cyan
    $any = $false
    foreach ($k in 'mcpServers', 'mcpTools', 'plugins', 'builtinSkills', 'accountSkills', 'pluginSkills', 'agents') {
        $onlyB = @($inv.B[$k] | Where-Object { $_ -notin $inv.A[$k] })
        $onlyA = @($inv.A[$k] | Where-Object { $_ -notin $inv.B[$k] })
        if ($onlyB.Count) { $any = $true; Write-Host "  + $k : $($onlyB -join ', ')" -ForegroundColor Green }
        if ($onlyA.Count) { $any = $true; Write-Host "  - $k (A 에만) : $($onlyA -join ', ')" -ForegroundColor Yellow }
    }
    if (-not $any) { Write-Host '  차이 없음 - B 구성이 로드되지 않았을 수 있음' -ForegroundColor Yellow }
}
