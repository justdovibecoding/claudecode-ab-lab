# 실험의 B 구성(비교 대상)을 관리한다. A에는 영향이 없다.
# 무엇을 어디서 어떤 버전으로 넣었는지 experiments\<이름>\b-manifest.json 에 남긴다.
#
#   .\b-config.ps1 -Exp superpowers                                  # 현재 B 구성(list)
#   .\b-config.ps1 -Exp superpowers -Action available                # 설치 가능한 플러그인
#   .\b-config.ps1 -Exp superpowers -Action install -Plugin superpowers@anthropic-plugin-directory
#   .\b-config.ps1 -Exp superpowers -Action uninstall -Plugin superpowers@anthropic-plugin-directory
#   .\b-config.ps1 -Exp superpowers -Action disable -Plugin <id>     # enable 도 같은 방식
#   .\b-config.ps1 -Exp superpowers -Action add-marketplace -Source owner/repo
#   .\b-config.ps1 -Exp superpowers -Action add-local -Path D:\src\my-skill
#   .\b-config.ps1 -Exp superpowers -Action add-git -Url https://github.com/o/r -Ref v1.2 -SubPath plugins/x
#   .\b-config.ps1 -Exp superpowers -Action remove-local -Kind skill -Name my-skill
#   .\b-config.ps1 -Exp superpowers -Action details -Plugin <id>     # 구성 요소·예상 토큰
#   .\b-config.ps1 -Exp superpowers -Action equivalence              # A/B 동등성 점검
# -Json 을 붙이면 결과를 JSON 한 줄로 출력한다(GUI 앱용).
param(
    [Parameter(Mandatory)][string]$Exp,
    [ValidateSet('list', 'available', 'install', 'uninstall', 'enable', 'disable', 'add-marketplace',
        'add-local', 'add-git', 'remove-local', 'details', 'equivalence')][string]$Action = 'list',
    [string]$Plugin,
    [string]$Source,
    [string]$Path,
    [string]$Url,
    [string]$Ref,
    [string]$SubPath,
    [ValidateSet('', 'plugin', 'skill')][string]$Kind = '',
    [string]$Name,
    [switch]$Json
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$e = Get-Experiment $Exp
if (-not (Test-Path $e.ConfigB)) { throw "B 설정 폴더가 없습니다: $($e.ConfigB)" }

function Out-Result($Value, [string]$Text) {
    if ($Json) { [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 8 -Compress)) }
    elseif ($Text) { Write-Host $Text }
    else { $Value | Format-List | Out-String | Write-Host }
}

function Assert-Arg([string]$Value, [string]$Label) {
    if (-not $Value) { throw "$Label 을(를) 지정하세요." }
}

function Assert-PluginId([string]$Id) {
    if ($Id -notmatch '^[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$') { throw "잘못된 플러그인 이름: $Id" }
}

# git·claude 에 넘기는 값이 옵션(-…)으로 해석되지 않게 막는다. ext:: 는 명령을 실행하는 git 전송 방식이라 거부.
function Assert-NotOption([string]$Value, [string]$Label) {
    if ($Value -match '^\s*-') { throw "$Label 은(는) '-'로 시작할 수 없습니다: $Value" }
    if ($Value -match '^\s*ext::') { throw "$Label 에 ext:: 주소는 쓸 수 없습니다." }
}

# 저장소 안 하위 경로: 상대 경로만, '..' 없이. 결과가 $Root 아래인지 다시 확인한다.
function Resolve-SubPath([string]$Root, [string]$Sub) {
    if (-not $Sub) { return $Root }
    $norm = $Sub -replace '/', '\'
    if ([IO.Path]::IsPathRooted($norm) -or $norm -match ':' -or ($norm -split '\\') -contains '..') {
        throw "하위 경로는 저장소 안의 상대 경로여야 합니다('..', 드라이브, 절대 경로 불가): $Sub"
    }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $norm))
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "하위 경로가 저장소 밖을 가리킵니다: $Sub" }
    $full
}

function Get-Available {
    $r = Invoke-ClaudeIn $e.ConfigB @('plugin', 'list', '--available', '--json')
    $o = ConvertFrom-ClaudeJson $r.Lines
    if (-not $o) { throw "플러그인 목록을 읽지 못했습니다: $($r.Lines -join ' ')" }
    @($o.available)
}

function Get-Installed {
    $r = Invoke-ClaudeIn $e.ConfigB @('plugin', 'list', '--json')
    @(ConvertFrom-ClaudeJson $r.Lines | Where-Object { $_ })
}

# 로컬 폴더(플러그인 또는 스킬)를 실험 폴더로 복사하고 기록한다.
function Add-LocalFolder([string]$From, [string]$SourceLabel, $Git) {
    if (-not (Test-Path $From -PathType Container)) { throw "폴더가 없습니다: $From" }
    $isPlugin = Test-Path (Join-Path $From '.claude-plugin\plugin.json')
    $isSkill = Test-Path (Join-Path $From 'SKILL.md')
    $kindFound = if ($Kind) { $Kind } elseif ($isPlugin) { 'plugin' } elseif ($isSkill) { 'skill' } else { '' }
    if (-not $kindFound) { throw "플러그인(.claude-plugin\plugin.json)도 스킬(SKILL.md)도 아닙니다: $From" }
    if ($kindFound -eq 'plugin' -and -not $isPlugin) { throw "플러그인 폴더가 아닙니다(.claude-plugin\plugin.json 없음): $From" }
    if ($kindFound -eq 'skill' -and -not $isSkill) { throw "스킬 폴더가 아닙니다(SKILL.md 없음): $From" }

    $folderName = if ($Name) { $Name }
        elseif ($kindFound -eq 'plugin') {
            $pj = Get-Content (Join-Path $From '.claude-plugin\plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pj.name) { $pj.name } else { Split-Path $From -Leaf }
        } else { Get-SkillName $From }
    if ($folderName -notmatch '^(?!\.+$)[A-Za-z0-9._-]+$') { throw "폴더 이름으로 쓸 수 없는 이름입니다: $folderName (-Name 으로 지정하세요)" }

    $destRoot = Join-Path $e.Dir ($(if ($kindFound -eq 'plugin') { 'plugins' } else { 'skills' }))
    $dest = Join-Path $destRoot $folderName
    robocopy $From $dest /MIR /XD .git node_modules /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "복사 실패: $From -> $dest (robocopy $LASTEXITCODE)" }

    $version = $null
    if ($kindFound -eq 'plugin') { $version = (Get-Content (Join-Path $dest '.claude-plugin\plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version }
    $item = [ordered]@{
        kind = "local-$kindFound"; name = $folderName; version = $version; source = $SourceLabel
        commit = if ($Git) { $Git.Commit } else { $null }; dirty = if ($Git) { $Git.Dirty } else { $null }
        addedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    }
    Set-BManifestItem $e $item
    $item
}

switch ($Action) {
    'list' {
        $installed = Get-Installed
        $manifest = Get-BManifest $e
        $findMan = { param($kind, $name) $manifest | Where-Object { $_.kind -eq $kind -and $_.name -eq $name } | Select-Object -First 1 }
        $result = [ordered]@{
            installed = @($installed | ForEach-Object {
                $m = & $findMan 'installed-plugin' $_.id
                [ordered]@{ id = $_.id; version = $_.version; enabled = $_.enabled; installedAt = $_.installedAt
                    source = $m.source; commit = $m.commit; recorded = [bool]$m }
            })
            localPlugins = @(Get-PluginDirs $e | ForEach-Object {
                $m = & $findMan 'local-plugin' $_.Name
                [ordered]@{ name = $_.Name; valid = (Test-Path (Join-Path $_.FullName '.claude-plugin\plugin.json'))
                    source = $m.source; commit = $m.commit; version = $m.version; recorded = [bool]$m }
            })
            localSkills = @(Get-SkillDirs $e | ForEach-Object {
                $m = & $findMan 'local-skill' $_.Name
                [ordered]@{ name = $_.Name; valid = (Test-Path (Join-Path $_.FullName 'SKILL.md'))
                    source = $m.source; commit = $m.commit; recorded = [bool]$m }
            })
            marketplaces = @(ConvertFrom-ClaudeJson (Invoke-ClaudeIn $e.ConfigB @('plugin', 'marketplace', 'list', '--json')).Lines | Where-Object { $_ })
        }
        if ($Json) { Out-Result $result }
        else {
            Write-Host "== $Exp B 구성"
            Write-Host '설치한 플러그인:'; foreach ($i in $result.installed) { Write-Host "  $($i.id) $($i.version) $(if ($i.enabled) { '켜짐' } else { '꺼짐' }) $($i.source)" }
            Write-Host '로컬 플러그인(plugins\):'; foreach ($i in $result.localPlugins) { Write-Host "  $($i.name) $(if (-not $i.valid) { '(plugin.json 없음)' }) $($i.source) $($i.commit)" }
            Write-Host '로컬 스킬(skills\):'; foreach ($i in $result.localSkills) { Write-Host "  $($i.name) $(if (-not $i.valid) { '(SKILL.md 없음)' }) $($i.source) $($i.commit)" }
        }
    }
    'available' {
        $list = Get-Available | ForEach-Object {
            [ordered]@{ id = $_.pluginId; name = $_.name; description = $_.description; version = $_.version
                marketplace = $_.marketplaceName; url = $_.source.url; path = $_.source.path; sha = $_.source.sha }
        }
        if ($Json) { Out-Result @($list) } else { $list | ForEach-Object { Write-Host "$($_.id)  $($_.version)  $($_.description)" } }
    }
    'install' {
        Assert-Arg $Plugin '-Plugin'; Assert-PluginId $Plugin
        # 설치하면 "설치 가능" 목록에서 빠지므로 출처·커밋은 설치 전에 읽어 둔다.
        $avail = Get-Available | Where-Object { $_.pluginId -eq $Plugin -or ($Plugin -notmatch '@' -and $_.name -eq $Plugin) } | Select-Object -First 1
        $r = Invoke-ClaudeIn $e.ConfigB @('plugin', 'install', $Plugin, '--json')
        $o = ConvertFrom-ClaudeJson $r.Lines
        if (-not $o -or $o.outcome -ne 'ok') {
            $msg = if ($o -and $o.message) { "$($o.message)" } else { $r.Lines -join ' ' }
            $hint = ''
            if ($o -and $o.shownCommand) { $hint = ' 이 플러그인은 마켓플레이스가 정한 명령 실행 확인이 필요합니다. B 터미널에서 /plugin 으로 설치하세요.' }
            elseif ($msg -match 'Filename too long') { $hint = ' 경로가 너무 깁니다. 저장소를 더 짧은 경로(예: D:\ab-lab)로 옮기거나 Windows 긴 경로 사용(LongPathsEnabled)을 켜세요.' }
            if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + ' …' }
            throw "설치 실패:$hint $msg"
        }
        $id = if ($o.pluginId) { $o.pluginId } else { $Plugin }
        $inst = Get-Installed | Where-Object { $_.id -eq $id } | Select-Object -First 1
        $src = if ($avail.source.path) { "$($avail.source.url)#$($avail.source.path)" } else { $avail.source.url }
        $item = [ordered]@{
            kind = 'installed-plugin'; name = $id
            version = if ($avail.version) { $avail.version } else { $inst.version }
            source = $src; commit = $avail.source.sha; dirty = $null; addedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        }
        Set-BManifestItem $e $item
        Out-Result $item "설치함: $id ($($item.version)) — B에만 적용"
    }
    'uninstall' {
        Assert-Arg $Plugin '-Plugin'; Assert-PluginId $Plugin
        $r = Invoke-ClaudeIn $e.ConfigB @('plugin', 'uninstall', $Plugin)
        if ($r.Code) { throw "제거 실패: $($r.Lines -join ' ')" }
        Remove-BManifestItem $e 'installed-plugin' $Plugin
        Out-Result @{ removed = $Plugin } "제거함: $Plugin"
    }
    { $_ -in 'enable', 'disable' } {
        Assert-Arg $Plugin '-Plugin'; Assert-PluginId $Plugin
        $r = Invoke-ClaudeIn $e.ConfigB @('plugin', $Action, $Plugin)
        if ($r.Code) { throw "$Action 실패: $($r.Lines -join ' ')" }
        Out-Result @{ plugin = $Plugin; action = $Action } "$Action : $Plugin"
    }
    'add-marketplace' {
        Assert-Arg $Source '-Source'
        Assert-NotOption $Source '-Source'
        $r = Invoke-ClaudeIn $e.ConfigB @('plugin', 'marketplace', 'add', $Source)
        if ($r.Code) { throw "마켓플레이스 추가 실패: $($r.Lines -join ' ')" }
        Out-Result @{ added = $Source } "마켓플레이스 추가: $Source"
    }
    'add-local' {
        Assert-Arg $Path '-Path'
        $full = (Resolve-Path $Path).Path
        $item = Add-LocalFolder $full $full (Get-GitInfo $full)
        Out-Result $item "추가함: $($item.kind) $($item.name)"
    }
    'add-git' {
        Assert-Arg $Url '-Url'
        Assert-NotOption $Url '-Url'
        if ($Ref) { Assert-NotOption $Ref '-Ref' }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git 이 필요합니다.' }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ab-git-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            # '--' 뒤의 값은 옵션이 아니라 주소·폴더로만 해석된다.
            & git clone --quiet -- $Url $tmp 2>&1 | Out-Null
            if ($LASTEXITCODE) { throw "git clone 실패: $Url" }
            if ($Ref) { & git -C $tmp checkout --quiet $Ref -- 2>&1 | Out-Null; if ($LASTEXITCODE) { throw "git checkout 실패: $Ref" } }
            $git = Get-GitInfo $tmp
            $from = Resolve-SubPath $tmp $SubPath
            $label = if ($SubPath) { "$Url#$SubPath" } else { $Url }
            $item = Add-LocalFolder $from $label $git
            Out-Result $item "추가함: $($item.kind) $($item.name) @ $($git.Commit.Substring(0, 12))"
        } finally {
            if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
        }
    }
    'remove-local' {
        Assert-Arg $Name '-Name'; Assert-Arg $Kind '-Kind'
        if ($Name -notmatch '^(?!\.+$)[A-Za-z0-9._-]+$') { throw "잘못된 이름: $Name" }
        $dir = Join-Path $e.Dir ($(if ($Kind -eq 'plugin') { 'plugins' } else { 'skills' }) + "\$Name")
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        Remove-BManifestItem $e "local-$Kind" $Name
        Out-Result @{ removed = $Name; kind = $Kind } "제거함: $Kind $Name"
    }
    'details' {
        Assert-Arg $Plugin '-Plugin'; Assert-PluginId $Plugin
        $r = Invoke-ClaudeIn $e.ConfigB @('plugin', 'details', $Plugin)
        if ($r.Code) { throw "상세 정보 실패: $($r.Lines -join ' ')" }
        $text = $r.Lines -join "`n"
        $m = [regex]::Match($text, 'Always-on:\s*~?([\d.,]+)\s*(k?)\s*tok')
        $tokens = $null
        if ($m.Success) { $tokens = [double]($m.Groups[1].Value -replace ',', ''); if ($m.Groups[2].Value) { $tokens *= 1000 } }
        Out-Result ([ordered]@{ plugin = $Plugin; alwaysOnTokens = $tokens; text = $text }) $text
    }
    'equivalence' {
        $eq = Get-Equivalence $e
        if ($Json) { Out-Result ([ordered]@{ ok = $eq.Ok; issues = @($eq.Issues); notes = @($eq.Notes); details = $eq.Details }) }
        elseif ($eq.Ok) { Write-Host 'A/B 동등성: 통과 (계정·계정 스킬·설정이 같음)'; $eq.Notes | ForEach-Object { Write-Host "  (안내) $_" } }
        else { Write-Host 'A/B 동등성: 확인 필요'; $eq.Issues | ForEach-Object { Write-Host "  - $_" } }
    }
}
