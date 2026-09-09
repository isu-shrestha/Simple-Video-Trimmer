<#
  run.ps1 - extract the app's JavaScript, bundle it with the shim and the
  suite, and run the lot under cscript's JScript engine.

      powershell -NoProfile -ExecutionPolicy Bypass -File tests\js\run.ps1

  Exit code: 0 = every test passed, 1 = at least one test failed,
             2 = extraction or the engine itself went wrong.

  There is no node/deno/bun on this machine, so the engine is the JScript host
  that ships with Windows. It is ES3, which is why shim.js has to polyfill
  Array.prototype.map and friends before the app source is loaded.
#>
[CmdletBinding()]
param(
  [string] $Source,
  [string] $WorkDir,
  [switch] $KeepBundle
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

if (-not $Source)  { $Source = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'SimpleVideoTrimmer.bat' }
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('svt-jstests-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }

$appJs    = Join-Path $WorkDir 'app.js'
$bundleJs = Join-Path $WorkDir 'bundle.js'

try {
  # 1. extract ---------------------------------------------------------------
  & (Join-Path $here 'extract.ps1') -Source $Source -Out $appJs
  if ($LASTEXITCODE -ne 0) { Write-Error "run.ps1: extraction failed (exit $LASTEXITCODE)."; exit 2 }
  if (-not (Test-Path -LiteralPath $appJs)) { Write-Error 'run.ps1: extract.ps1 produced no output.'; exit 2 }

  # 2. bundle ----------------------------------------------------------------
  # shim first (polyfills + fake DOM), then the app verbatim, then the suite.
  # One global scope on purpose: the tests drive TR/recalc/segments directly.
  $shim  = Join-Path $here 'shim.js'
  $tests = Join-Path $here 'tests.js'
  foreach ($f in @($shim, $tests)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Error "run.ps1: missing $f"; exit 2 }
  }
  $parts = @(
    "/* ==== shim.js ==== */",  [IO.File]::ReadAllText($shim),
    "/* ==== SimpleVideoTrimmer.bat <script> (extracted, unmodified) ==== */", [IO.File]::ReadAllText($appJs),
    "/* ==== tests.js ==== */", [IO.File]::ReadAllText($tests)
  )
  [IO.File]::WriteAllText($bundleJs, ($parts -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

  # 3. run -------------------------------------------------------------------
  $cscript = Join-Path $env:SystemRoot 'System32\cscript.exe'
  if (-not (Test-Path -LiteralPath $cscript)) { $cscript = 'cscript.exe' }
  & $cscript //nologo //E:JScript $bundleJs
  $code = $LASTEXITCODE

  # cscript reports a compile/runtime blow-up as a non-1 exit; the suite itself
  # only ever quits 0 or 1, so anything else is an engine-level failure.
  if ($code -ne 0 -and $code -ne 1) {
    Write-Error "run.ps1: the JScript engine exited $code - the bundle did not run to completion. Bundle kept at $bundleJs"
    $KeepBundle = $true
    exit 2
  }
  exit $code
}
finally {
  if (-not $KeepBundle -and (Test-Path -LiteralPath $WorkDir)) {
    Remove-Item -Recurse -Force -LiteralPath $WorkDir -ErrorAction SilentlyContinue
  } elseif ($KeepBundle) {
    Write-Host "run.ps1: bundle kept at $bundleJs"
  }
}
