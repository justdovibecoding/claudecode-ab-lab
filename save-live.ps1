# 대화형 세션의 결과(작업 폴더 사본, 변경 목록, 확인 명령, 비용·토큰·턴, 최종 응답)를 results\<세션>-live\ 에 남긴다.
# 앱이 세션을 끝낼 때 부른다. 블라인드 판정과 보고서(참고용 구간)에 나온다. 토큰은 더 들지 않는다.
#   .\save-live.ps1 -Exp superpowers -Session 20261021-201011
#   .\save-live.ps1 -Exp superpowers -Pending      # 마지막 세션을 아직 남기지 않았으면 남김
param(
    [Parameter(Mandatory)][string]$Exp,
    [string]$Session,
    [switch]$Pending,
    [switch]$Json
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$e = Get-Experiment $Exp
$r = if ($Pending) { Save-PendingLiveSession $e } elseif ($Session) { Save-LiveSession $e $Session } else { throw '-Session 또는 -Pending 을 주세요.' }

$summary = if ($r) {
    [ordered]@{
        saved = $true; run = $r.run; dir = $r.dir
        sides = @($r.rows | ForEach-Object { [ordered]@{ side = $_.Side; cost = $_.CostUSD; turns = $_.Turns; changed = $_.ChangedFiles; check = $_.CheckPassed; error = $_.IsError } })
    }
} else { [ordered]@{ saved = $false } }
if ($Json) { [Console]::Out.WriteLine(($summary | ConvertTo-Json -Depth 5 -Compress)) }
elseif ($r) {
    Write-Host "대화형 결과 저장: $($r.dir)"
    $r.rows | Format-Table Side, IsError, CostUSD, Turns, Seconds, ChangedFiles, CheckPassed, ToolCalls, Skills -AutoSize
} else { Write-Host '남길 대화형 세션이 없습니다.' }
