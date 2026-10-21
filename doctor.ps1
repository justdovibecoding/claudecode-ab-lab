# 비교 환경이 "깨끗한지" 점검한다. 녹화·측정 전에 실행한다.
#   .\doctor.ps1                 # 공용 환경(A)만 점검
#   .\doctor.ps1 -Exp superpowers # 실험의 B 환경까지 점검
param([string]$Exp)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$script:issues = 0
function Write-Check([ValidateSet('OK', '주의', '오류', '정보')][string]$Level, [string]$Msg) {
    $color = @{ 'OK' = 'Green'; '주의' = 'Yellow'; '오류' = 'Red'; '정보' = 'Gray' }[$Level]
    if ($Level -in '주의', '오류') { $script:issues++ }
    Write-Host ("[{0}] {1}" -f $Level, $Msg) -ForegroundColor $color
}

function Test-ConfigDir([string]$Label, [string]$Dir) {
    if (-not (Test-Path $Dir)) { Write-Check 오류 "$Label 설정 폴더 없음: $Dir (.\setup.ps1 실행)"; return }
    $settingsFile = Join-Path $Dir 'settings.json'
    if (Test-Path $settingsFile) {
        try {
            $s = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($s.syncClaudeAiPlugins -eq $false) { Write-Check OK "$Label 계정 플러그인 동기화 꺼짐" }
            else { Write-Check 주의 "$Label settings.json 에 ""syncClaudeAiPlugins"": false 가 없음 (계정 플러그인이 섞일 수 있음)" }
            if ($s.syncClaudeAiSkills -eq $false) { Write-Check 정보 "$Label 계정 스킬 동기화도 꺼짐 (기본 정의 'Claude Code 단독')" }
            foreach ($k in 'hooks', 'enabledPlugins', 'mcpServers', 'env') {
                if ($s.PSObject.Properties.Name -contains $k) { Write-Check 정보 "$Label settings.json 에 '$k' 항목 있음 - 의도한 것인지 확인" }
            }
        } catch { Write-Check 오류 "$Label settings.json 을 JSON으로 읽지 못함: $settingsFile" }
    } else { Write-Check 주의 "$Label settings.json 없음: $settingsFile" }

    $auth = Get-AuthStatus $Dir
    if ($auth -and $auth.loggedIn) {
        Write-Check OK "$Label 로그인됨 (방식: $($auth.authMethod), 요금제: $($auth.subscriptionType))"
    } else {
        $hint = if ($Label -like '*B*') { ".\login.ps1 -Exp $Exp" } else { '.\login.ps1' }
        Write-Check 주의 "$Label 로그인 안 됨 ($hint)"
    }
}

Write-Host "== 공용 환경 ==" -ForegroundColor Cyan

# Claude Code
$claude = Get-Command $ClaudeCmd -ErrorAction SilentlyContinue
if ($claude) {
    Write-Check OK "claude: $((& $ClaudeCmd --version) -join ' ') ($($claude.Source))"
    if ($env:CC_AB_CLAUDE) { Write-Check 정보 "CC_AB_CLAUDE 로 지정한 실행 파일을 씀(GUI 앱과 같은 파일)" }
}
else { Write-Check 오류 'claude 명령을 찾을 수 없음 (Claude Code 설치 필요)' }

# Windows Terminal (나란히 실행용, 없으면 창 2개로 대체)
if (Get-Command wt -ErrorAction SilentlyContinue) { Write-Check OK 'Windows Terminal(wt) 있음' }
else { Write-Check 정보 'Windows Terminal(wt) 없음 - open-both.ps1 은 창 2개로 띄움' }

# 관리형 설정(모든 실행에 강제 적용됨)
$managed = 'C:\Program Files\ClaudeCode\managed-settings.json'
if (Test-Path $managed) { Write-Check 주의 "관리형 설정이 있음 - A/B 모두에 적용됨: $managed" }
else { Write-Check OK '관리형 설정 없음' }

# 환경 변수(설정 폴더와 무관하게 넘어감). Claude Code 세션 안에서 실행하면 CLAUDE_CODE_* 가 여럿 보이는데,
# 비교 실행은 일반 터미널에서 해야 한다.
$vars = Get-ChildItem env: | Where-Object { $_.Name -match '^(ANTHROPIC_|CLAUDE_|CLAUDECODE)' }
if ($vars) {
    foreach ($v in $vars) {
        $lvl = if ($v.Name -in 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CONFIG_DIR') { '주의' } else { '정보' }
        Write-Check $lvl "환경 변수 $($v.Name) 설정됨 (값은 표시 안 함) - A/B 모두에 영향"
    }
} else { Write-Check OK 'ANTHROPIC_*/CLAUDE_* 환경 변수 없음' }

# 빈 MCP 구성
try {
    $m = Get-Content $EmptyMcp -Raw | ConvertFrom-Json
    if (@($m.mcpServers.PSObject.Properties).Count -eq 0) { Write-Check OK 'empty-mcp.json 비어 있음' }
    else { Write-Check 주의 'empty-mcp.json 에 서버가 들어 있음 - A에도 MCP가 붙음' }
} catch { Write-Check 오류 "empty-mcp.json 을 읽지 못함: $EmptyMcp" }

# 작업 폴더 위치
Write-Check 정보 "작업 폴더 루트: $($Lab.WorkRoot)"
if ($Lab.WorkRoot.TrimEnd('\').StartsWith($LabRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    Write-Check 오류 '작업 폴더 루트가 이 저장소 안에 있음 - .\setup.ps1 -WorkRoot <저장소 밖 경로>'
}
$ctx = Find-AncestorContext (Join-Path $Lab.WorkRoot 'x\work-A')
if ($ctx) { foreach ($c in $ctx) { Write-Check 주의 "작업 폴더 상위에 Claude Code가 읽을 수 있는 항목: $c" } }
else { Write-Check OK '작업 폴더 상위에 CLAUDE.md/.claude/.mcp.json/.git 없음' }

Write-Host ''
Write-Host "== A 기본 환경 ==" -ForegroundColor Cyan
Test-ConfigDir 'A' $VanillaConfig
# plugins\, skills\ 는 계정 동기화·캐시로 자동 생성되므로 여기서 보지 않는다(실행 화면의 /plugin 으로 확인).
foreach ($n in 'agents', 'commands', 'CLAUDE.md') {
    $p = Join-Path $VanillaConfig $n
    if (Test-Path $p) {
        $cnt = if ((Get-Item $p).PSIsContainer) { @(Get-ChildItem $p -Force).Count } else { 1 }
        if ($cnt -gt 0) { Write-Check 주의 "A 설정 폴더에 $n 있음 ($cnt 개) - 기본 환경이 아닐 수 있음: $p" }
    }
}

if ($Exp) {
    $e = Get-Experiment $Exp
    Write-Host ''
    Write-Host "== 실험 $Exp (B) ==" -ForegroundColor Cyan
    Test-ConfigDir 'B' $e.ConfigB

    $fx = @(Get-ChildItem (Join-Path $e.Dir 'fixture') -Force -ErrorAction SilentlyContinue | Where-Object Name -ne '.gitkeep')
    if ($fx.Count) { Write-Check OK "fixture 항목 $($fx.Count)개" } else { Write-Check 주의 'fixture 가 비어 있음' }

    $plugins = Get-PluginDirs $e
    foreach ($p in $plugins) {
        if (Test-Path (Join-Path $p.FullName '.claude-plugin\plugin.json')) { Write-Check OK "플러그인 $($p.Name) (.claude-plugin\plugin.json 있음)" }
        else { Write-Check 주의 "플러그인 $($p.Name) 에 .claude-plugin\plugin.json 없음 - 플러그인 폴더 최상위를 넣었는지 확인" }
    }
    foreach ($s in Get-SkillDirs $e) {
        if (Test-Path (Join-Path $s.FullName 'SKILL.md')) { Write-Check OK "스킬 $($s.Name) (SKILL.md 있음)" }
        else { Write-Check 오류 "스킬 $($s.Name) 에 SKILL.md 없음" }
    }
    $installed = Join-Path $e.ConfigB 'plugins\installed_plugins.json'
    if (Test-Path $installed) { Write-Check 정보 "B 에 /plugin 으로 설치한 기록 있음: $installed" }
    if (-not $plugins.Count -and -not (Get-SkillDirs $e).Count -and -not (Test-Path $installed)) {
        Write-Check 주의 'B 에 비교 대상(plugins\, skills\, /plugin 설치)이 없음 - A와 같은 환경'
    }

    try {
        $mb = Get-Content (Join-Path $e.Dir 'mcp-B.json') -Raw | ConvertFrom-Json
        $names = @($mb.mcpServers.PSObject.Properties | ForEach-Object Name)
        if ($names.Count) { Write-Check 정보 "B 전용 MCP 서버: $($names -join ', ')" } else { Write-Check OK 'B 전용 MCP 서버 없음' }
    } catch { Write-Check 오류 'mcp-B.json 을 JSON으로 읽지 못함' }

    $prompts = @(Get-ChildItem (Join-Path $e.Dir 'prompts') -Filter *.md -ErrorAction SilentlyContinue)
    Write-Check 정보 "지시문 $($prompts.Count)개: $(($prompts | ForEach-Object BaseName) -join ', ')"

    if ($e.Meta.check -and $e.Meta.check.command) { Write-Check OK "확인 명령: $($e.Meta.check.command)" }
    else { Write-Check 정보 '확인 명령 없음 - 반복 측정에서 자동 품질 확인을 하려면 experiment.json 의 check.command 에 지정' }

    foreach ($side in 'A', 'B') {
        $n = Get-ProjectMemoryCount (Get-SideConfig $e $side) (Get-WorkDir $e $side)
        if ($n) { Write-Check 주의 "$side 작업 폴더의 자동 메모리 $n 개가 남아 있음 - 다음 실행이 이전 내용을 기억한 채 시작. .\reset.ps1 -Exp $Exp 로 지워짐" }
    }

    Write-Host ''
    Write-Host "== A/B 동등성 ==" -ForegroundColor Cyan
    $eq = Get-Equivalence $e
    if ($eq.Ok) { Write-Check OK "같은 계정, 계정 스킬 $($eq.Details.syncedSkills.A)개 동일, settings.json·설정 폴더 추가 파일·작업 폴더별 권한 동일" }
    else { foreach ($issue in $eq.Issues) { Write-Check 주의 $issue } }
}

Write-Host ''
if ($script:issues) { Write-Host "확인할 항목 $($script:issues)개" -ForegroundColor Yellow }
else { Write-Host '점검 통과' -ForegroundColor Green }
Write-Host '실행 화면에서도 /context, /plugin, /mcp, /memory 로 한 번 더 확인하세요.'
