# =============================================================================
#  run.ps1 - entry point for the export regression suite
# =============================================================================
#    powershell -NoProfile -ExecutionPolicy Bypass -File tests\export\run.ps1
#
#  Options:
#    -RebuildFixtures   throw the cached test clips away and regenerate them
#
#  Exit code: 0 when every test passed, 1 otherwise. Tests whose name contains
#  [REGRESSION] assert the behaviour the app SHOULD have and fail until the
#  corresponding defect is fixed, so a non-zero exit is expected today - read
#  the summary to see whether any NON-known failure appeared.
#
#  Requirements: ffmpeg and ffprobe on PATH, Windows PowerShell 5.1.
#  Nothing is written into the repository: fixture clips live under
#  %TEMP%\svt_export_fixtures and are cached between runs; scratch output goes
#  to a throwaway %TEMP%\svt_export_run_* directory that is deleted at the end.
# =============================================================================

[CmdletBinding()]
param([switch]$RebuildFixtures)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($tool in 'ffmpeg', 'ffprobe') {
    if (-not (Get-Command "$tool.exe" -ErrorAction SilentlyContinue)) {
        Write-Host "  $tool.exe is not on PATH - cannot run the export suite." -ForegroundColor Red
        exit 2
    }
}

Write-Host ''
Write-Host '  Simple Video Trimmer - export regression suite' -ForegroundColor White
Write-Host ('  ffmpeg: ' + (Get-Command ffmpeg.exe).Source) -ForegroundColor DarkGray

if ($RebuildFixtures) {
    . (Join-Path $here 'fixtures.ps1')
    Write-Host '  Rebuilding fixtures...' -ForegroundColor Gray
    $null = New-Fixtures -Force
}

$sw = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $here 'tests.ps1')
$sw.Stop()

Write-Host ("  total wall time: {0:0.0}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
Write-Host ''

if ($script:ExportSuiteFailures -gt 0) { exit 1 }
exit 0
