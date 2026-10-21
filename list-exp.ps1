# 실험 목록과 B에 들어간 내용, 결과 수를 보여 준다.
#   .\list-exp.ps1
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$dirs = @(Get-ChildItem $ExpRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'experiment.json') })
if (-not $dirs.Count) { Write-Host '실험이 없습니다. .\new-exp.ps1 -Name 이름 으로 만드세요.'; return }

$dirs | ForEach-Object {
    $e = Get-Experiment $_.Name
    [pscustomobject]@{
        Name        = $e.Name
        Model       = $e.Meta.model
        Plugins     = (Get-PluginDirs $e | ForEach-Object Name) -join ', '
        Skills      = (Get-SkillDirs $e | ForEach-Object Name) -join ', '
        Installed   = Test-Path (Join-Path $e.ConfigB 'plugins\installed_plugins.json')
        Prompts     = @(Get-ChildItem (Join-Path $e.Dir 'prompts') -Filter *.md -ErrorAction SilentlyContinue | Where-Object Name -notmatch '\.(A|B)\.md$').Count
        Results     = @(Get-ChildItem (Join-Path $e.Dir 'results') -Directory -ErrorAction SilentlyContinue).Count
        BLogin      = Test-Path (Join-Path $e.ConfigB '.credentials.json')
        Description = $e.Meta.description
    }
} | Format-Table -AutoSize -Wrap
