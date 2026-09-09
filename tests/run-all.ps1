# =============================================================================
#  run-all.ps1 - every regression suite for Simple Video Trimmer
# =============================================================================
#    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
#
#  Exits 0 only if every suite passes.
# =============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$fail = 0

$suites = @(
    @{ Name = 'client logic (JScript, headless)'; Script = (Join-Path $here 'js\run.ps1') }
    @{ Name = 'export path (real ffmpeg)';        Script = (Join-Path $here 'export\run.ps1') }
)

foreach ($s in $suites) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host ("  {0}" -f $s.Name) -ForegroundColor White
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    & powershell -NoProfile -ExecutionPolicy Bypass -File $s.Script
    if ($LASTEXITCODE -ne 0) {
        $fail++
        Write-Host ("  >> {0}: FAILED (exit {1})" -f $s.Name, $LASTEXITCODE) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkGray
if ($fail) {
    Write-Host ("  {0} of {1} suites failed" -f $fail, $suites.Count) -ForegroundColor Red
    exit 1
}
Write-Host ("  all {0} suites passed" -f $suites.Count) -ForegroundColor Green
exit 0
