<#
  extract.ps1 - pull the browser JavaScript out of SimpleVideoTrimmer.bat.

  The app is one .bat file. It contains, in order:
      #===PS===            marker: everything after it is the PowerShell payload
      $S.Html = @'         start of the here-string holding the whole HTML page
      <script> ... </script>   the client-side JS we want to test
      '@                   end of the here-string

  This script walks those markers in order and FAILS LOUDLY if any of them
  moves, disappears, or turns up more than once. A silently-empty extraction
  would make the regression suite pass for the wrong reason.
#>
[CmdletBinding()]
param(
  [string] $Source,
  [Parameter(Mandatory = $true)][string] $Out
)

$ErrorActionPreference = 'Stop'

function Die([string] $msg) {
  # written straight to stderr rather than via Write-Error, so that
  # $ErrorActionPreference = 'Stop' cannot pre-empt the explicit exit code
  [Console]::Error.WriteLine("extract.ps1: FATAL: $msg")
  exit 2
}

if (-not $Source) {
  $Source = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'SimpleVideoTrimmer.bat'
}
if (-not (Test-Path -LiteralPath $Source)) { Die "source not found: $Source" }

$lines = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Source))
if ($lines.Count -lt 1500) { Die "source looks truncated ($($lines.Count) lines, expected >=1500): $Source" }

# --- 1. the #===PS=== marker -------------------------------------------------
$psIdx = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i].Trim() -eq '#===PS===') { $psIdx += $i }
}
if ($psIdx.Count -eq 0) { Die "marker '#===PS===' not found - the .bat layout changed." }
if ($psIdx.Count -gt 1) { Die "marker '#===PS===' found $($psIdx.Count) times (expected 1) at lines $(($psIdx | ForEach-Object { $_ + 1 }) -join ', ')." }
$psLine = $psIdx[0]

# --- 2. the $S.Html here-string ---------------------------------------------
$htmlIdx = @()
for ($i = $psLine + 1; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match "^\s*\`$S\.Html\s*=\s*@'\s*$") { $htmlIdx += $i }
}
if ($htmlIdx.Count -eq 0) { Die "here-string start `"`$S.Html = @'`" not found after #===PS=== (line $($psLine + 1))." }
if ($htmlIdx.Count -gt 1) { Die "here-string start `"`$S.Html = @'`" found $($htmlIdx.Count) times (expected 1)." }
$htmlStart = $htmlIdx[0]

# a single-quoted here-string ends at a line that is exactly '@ at column 0
$htmlEnd = -1
for ($i = $htmlStart + 1; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -eq "'@") { $htmlEnd = $i; break }
}
if ($htmlEnd -lt 0) { Die "here-string terminator `"'@`" not found after line $($htmlStart + 1)." }

# --- 3. the <script> block inside it -----------------------------------------
$openIdx = @(); $closeIdx = @()
for ($i = $htmlStart + 1; $i -lt $htmlEnd; $i++) {
  if ($lines[$i].Trim() -eq '<script>')  { $openIdx  += $i }
  if ($lines[$i].Trim() -eq '</script>') { $closeIdx += $i }
}
if ($openIdx.Count -ne 1) { Die "expected exactly 1 '<script>' line inside the HTML here-string, found $($openIdx.Count)." }
if ($closeIdx.Count -ne 1) { Die "expected exactly 1 '</script>' line inside the HTML here-string, found $($closeIdx.Count)." }
$sOpen = $openIdx[0]; $sClose = $closeIdx[0]
if ($sClose -le $sOpen + 1) { Die "'</script>' (line $($sClose + 1)) does not follow '<script>' (line $($sOpen + 1))." }

$body = $lines[($sOpen + 1)..($sClose - 1)]
if ($body.Count -lt 500) { Die "extracted script is only $($body.Count) lines - expected the full app (>=500). Markers probably moved." }

# --- 4. sanity: the functions the suite drives must actually be in there ------
$text = ($body -join "`r`n")
$required = @(
  'function trackOff', 'function trackAt', 'function toLocal', 'function recalc',
  'function segments', 'function inDel', 'function delEndAt', 'function segAt',
  'function addDel', 'function subDel', 'function normTrackDels',
  'function keptRanges', 'function keptParts', 'function outLen',
  'function canSplitAt', 'function doSplit', 'function doDelete', 'function doUndo',
  'function skipIfDeleted', 'function acceptTrack', 'function removeTrack',
  'function moveTrack', 'function clearProgram', 'function snapshot'
)
$missing = @($required | Where-Object { $text.IndexOf($_) -lt 0 })
if ($missing.Count) { Die "extracted script is missing: $($missing -join ', ') - the app was refactored, update the tests." }

# JScript is ES3: bail out early with a clear message rather than a cryptic
# 'expected identifier' from cscript if the app ever gains modern syntax.
# Comments are stripped first - the app's prose says things like "would let a
# discarded file come back", and a bare /\blet\s+/ over the raw text calls that
# ES6. Strings are left alone: none of these patterns appear in the app's
# literals, and stripping them properly needs a real lexer.
$scan = [regex]::Replace($text, '/\*[\s\S]*?\*/', ' ')          # block comments
$scan = [regex]::Replace($scan, '(?m)(^|[^:"''\\])//.*$', '$1')  # line comments
foreach ($pat in @('=>', '\blet\s+', '\bconst\s+', '`')) {
  if ($scan -match $pat) { Die "extracted script contains ES6 syntax matching /$pat/ - the JScript test engine cannot parse it." }
}

# --- 5. ES3 compatibility rewrite -------------------------------------------
# ES3 forbids a reserved word after a dot, so `p.catch(f)` will not COMPILE
# under JScript even though it runs fine in every browser. Rewriting it to the
# exactly-equivalent bracket form `p["catch"](f)` is a parser fix, not a
# behaviour change - it is the only edit made to the shipping source, and the
# count is printed so a silent explosion of rewrites is visible.
$rewrites = 0
$text = [regex]::Replace($text, '\.(catch|delete|default|new|in|class|finally|throw|typeof|void|with|for|if|do|else|case|switch|this|var|return|function|try|while|continue|break|instanceof)\b(?!\s*:)', {
  param($m); $script:rewrites++; '["' + $m.Groups[1].Value + '"]'
})
if ($rewrites -gt 20) { Die "ES3 rewrite touched $rewrites sites - that is far more than expected; inspect before trusting the suite." }

# UTF-8 *without* BOM - cscript //E:JScript chokes on a BOM.
$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[System.IO.File]::WriteAllText($Out, $text + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("extract.ps1: {0} lines of JS (bat lines {1}-{2}), {3} ES3 dot-keyword rewrites -> {4}" -f $body.Count, ($sOpen + 2), $sClose, $rewrites, $Out)
exit 0
