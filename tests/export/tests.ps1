# =============================================================================
#  tests.ps1 - regression suite for SimpleVideoTrimmer's server-side export
# =============================================================================
#  Run via run.ps1. Every test prints PASS/FAIL; the runner exits non-zero if
#  anything failed.
#
#  Tests whose name contains [REGRESSION] pin a defect that adversarial testing
#  found and that has since been fixed. They assert the CORRECT behaviour, so a
#  failure means the bug came back. Do not "fix" one by relaxing its assertion.
#
#  NOTE ON $S: never name a local variable $s here. PowerShell variable names
#  are case-insensitive, so a `[double]$s` parameter would silently shadow the
#  $S state hashtable. The state is called $St throughout.
# =============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'fixtures.ps1')
. (Join-Path $here 'lib.ps1')

# ------------------------------------------------------------- harness ------

$script:Results  = New-Object System.Collections.ArrayList
$script:Failures = New-Object System.Collections.ArrayList

function Assert-True($cond, [string]$msg) {
    if (-not $cond) { throw "assertion failed: $msg" }
}
function Assert-Eq($actual, $expected, [string]$msg) {
    if ("$actual" -ne "$expected") { throw "assertion failed: $msg (expected '$expected', got '$actual')" }
}
function Assert-Near([double]$actual, [double]$expected, [double]$tol, [string]$msg) {
    if ([double]::IsNaN($actual) -or [math]::Abs($actual - $expected) -gt $tol) {
        throw "assertion failed: $msg (expected $expected +/- $tol, got $actual)"
    }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $err = $null
    try { & $Body } catch { $err = $_.Exception.Message }
    $sw.Stop()
    $ms = [int]$sw.Elapsed.TotalMilliseconds
    if ($err) {
        Write-Host ("  FAIL  {0,-6} {1}" -f "${ms}ms", $Name) -ForegroundColor Red
        Write-Host ("           -> {0}" -f $err) -ForegroundColor DarkRed
        [void]$script:Failures.Add(@{ Name = $Name; Error = $err })
        [void]$script:Results.Add(@{ Name = $Name; Ok = $false })
    } else {
        Write-Host ("  pass  {0,-6} {1}" -f "${ms}ms", $Name) -ForegroundColor DarkGreen
        [void]$script:Results.Add(@{ Name = $Name; Ok = $true })
    }
}

function Write-Section([string]$t) {
    Write-Host ''
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("  " + ('-' * $t.Length)) -ForegroundColor DarkCyan
}

# --------------------------------------------------------------- set-up -----

Write-Host ''
Write-Host '  Preparing fixtures...' -ForegroundColor Gray
$FX = New-Fixtures

$Work = Join-Path $env:TEMP ('svt_export_run_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Work | Out-Null

$St = New-SvtState -FFmpeg (Get-FFmpegPath) -FFprobe (Get-FFprobePath) `
                   -CacheDir (Join-Path $Work 'cache')

$TOK = @{}
foreach ($k in 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'T') {
    $TOK[$k] = Add-SvtFile -S $St -Path $FX[$k]
}

# Build the payload exactly as the server sees it: a PSCustomObject that came
# out of ConvertFrom-Json.
function New-Payload($Tokens, $Parts) {
    $o = @{}
    if ($null -ne $Tokens) { $o['tokens'] = $Tokens }
    if ($null -ne $Parts)  { $o['parts']  = $Parts }
    return (ConvertTo-Json $o -Depth 8 -Compress | ConvertFrom-Json)
}
function New-RawPayload([string]$Json) { return ($Json | ConvertFrom-Json) }

function Resolve-P($Tokens, $Parts) { Resolve-SvtSegments -S $St -Payload (New-Payload $Tokens $Parts) }

function Out-Path([string]$leaf) { Join-Path $Work $leaf }

# Runs a full export and returns the Invoke-SvtExport result.
function Export-P($Tokens, $Parts, [string]$leaf) {
    $r = Resolve-P $Tokens $Parts
    Assert-True $r.ok "segment resolution failed: $($r.error)"
    return (Invoke-SvtExport -S $St -Resolved $r -OutPath (Out-Path $leaf))
}

# =============================================================================
Write-Section 'Mirror drift - lib.ps1 must still match the app'
# =============================================================================
#  lib.ps1 is a HAND COPY of the /api/save logic, which is this suite's biggest
#  weakness: edit the app without editing the mirror and every export test below
#  goes on happily testing dead code. These checks do not prove the two agree -
#  only a shared implementation could - but they fail loudly on the specific
#  lines the mirror leans on, which is enough to catch a real refactor.
# =============================================================================

$AppPath = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'SimpleVideoTrimmer.bat'

Test-Case '[MIRROR] the app source is where the tests expect it' {
    Assert-True (Test-Path -LiteralPath $AppPath) "app not found at $AppPath"
    $txt = [IO.File]::ReadAllText($AppPath)
    Assert-True ($txt.Length -gt 50000) 'app source looks truncated'
}

Test-Case '[MIRROR] the load-bearing lines lib.ps1 copies are still present' {
    $txt = [IO.File]::ReadAllText($AppPath)
    $need = @(
        'if ($order -notcontains [string]$sg.t) { continue }',
        'if ([double]::IsNaN($s0) -or [double]::IsNaN($e0)) { continue }',
        '[math]::Abs($sg.s - $prev.e) -le 0.0005 -and $sg.e -gt $prev.e',
        "`$tmpOut = `$outPath + '.svtpart'",
        'scale=trunc(iw/2)*2:trunc(ih/2)*2',
        'force_original_aspect_ratio=decrease',
        '-filter_complex_script',
        'anullsrc=r=48000:cl=stereo',
        '$psi.RedirectStandardError',
        'Quote-Arg'
    )
    $missing = @($need | Where-Object { $txt.IndexOf($_) -lt 0 })
    Assert-Eq $missing.Count 0 ("the app changed but tests\export\lib.ps1 was not updated; missing: " +
                                ($missing -join ' | '))
}

Test-Case '[REGRESSION] the export must never be launched through a shell again' {
    # Routing ffmpeg through cmd.exe is what let %VAR% expand inside quoted
    # paths, so an ordinary file like "100% done.mp4" was rewritten before
    # ffmpeg saw it. Nothing in the app may reach for a command interpreter.
    $txt = [IO.File]::ReadAllText($AppPath)
    Assert-True ($txt.IndexOf('ComSpec') -lt 0) 'the app references ComSpec - a shell is back in the launch path'
}

# =============================================================================
Write-Section 'Validation - tokens'
# =============================================================================

Test-Case '[VAL] missing tokens is rejected' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload '{"parts":[{"t":"x","s":0,"e":1}]}')
    Assert-Eq $r.ok $false 'should be rejected'
    Assert-Eq $r.error 'Those videos are no longer loaded.' 'error text'
}

Test-Case '[VAL] empty tokens array is rejected' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload '{"tokens":[],"parts":[]}')
    Assert-Eq $r.ok $false 'should be rejected'
    Assert-Eq $r.error 'Those videos are no longer loaded.' 'error text'
}

Test-Case '[VAL] null tokens is rejected' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload '{"tokens":null,"parts":null}')
    Assert-Eq $r.ok $false 'should be rejected'
}

Test-Case '[VAL] entirely unknown tokens are rejected' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload '{"tokens":["nope","alsonope"],"parts":[]}')
    Assert-Eq $r.ok $false 'should be rejected'
    Assert-Eq $r.error 'Those videos are no longer loaded.' 'error text'
}

Test-Case '[VAL] unknown tokens are filtered out, known ones survive' {
    $r = Resolve-P @('nope', $TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 })
    Assert-Eq $r.ok $true 'should succeed'
    Assert-Eq $r.order.Count 1 'only the real token is kept'
    Assert-Eq $r.first.name (Split-Path -Leaf $FX.A) 'track 1 is A'
}

Test-Case '[VAL] track 1 sets the output format even when listed after junk' {
    $r = Resolve-P @('nope', $TOK.C, $TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 })
    Assert-Eq $r.first.name (Split-Path -Leaf $FX.C) 'first surviving token is C'
}

# =============================================================================
Write-Section 'Validation - parts'
# =============================================================================

Test-Case '[VAL] missing parts is rejected' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload ('{"tokens":["' + $TOK.A + '"]}'))
    Assert-Eq $r.ok $false 'should be rejected'
    Assert-Eq $r.error 'Nothing is selected to save.' 'error text'
}

Test-Case '[VAL] empty parts array is rejected' {
    $r = Resolve-P @($TOK.A) @()
    Assert-Eq $r.ok $false 'should be rejected'
    Assert-Eq $r.error 'Nothing is selected to save.' 'error text'
}

Test-Case '[VAL] null entries inside parts are skipped' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload (
        '{"tokens":["' + $TOK.A + '"],"parts":[null,{"t":"' + $TOK.A + '","s":0,"e":2},null]}'))
    Assert-Eq $r.ok $true 'should succeed'
    Assert-Eq $r.segs.Count 1 'one surviving part'
}

Test-Case '[VAL] a part with an unknown token is skipped' {
    $r = Resolve-P @($TOK.A) @(@{ t = 'ghost'; s = 0; e = 3 }, @{ t = $TOK.A; s = 0; e = 2 })
    Assert-Eq $r.segs.Count 1 'ghost part dropped'
    Assert-Near $r.span 2.0 0.001 'span is only the real part'
}

Test-Case '[VAL] negative start is clamped to 0' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = -50; e = 2 })
    Assert-Near $r.segs[0].s 0.0 0.0001 'start clamped'
    Assert-Near $r.segs[0].e 2.0 0.0001 'end untouched'
}

Test-Case '[VAL] end beyond the duration is clamped to the duration' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 1; e = 9999 })
    Assert-Near $r.segs[0].e 6.0 0.05 'end clamped to A duration (6s)'
}

Test-Case '[VAL] a wholly out-of-range part collapses and is dropped' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 500; e = 900 }, @{ t = $TOK.A; s = 0; e = 1 })
    Assert-Eq $r.segs.Count 1 'the out-of-range part clamps to 6..6 and is dropped'
}

Test-Case '[VAL] reversed s/e are swapped, not dropped' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 4; e = 1 })
    Assert-Near $r.segs[0].s 1.0 0.0001 'start'
    Assert-Near $r.segs[0].e 4.0 0.0001 'end'
}

Test-Case '[VAL] +/-Infinity is clamped into range' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload (
        '{"tokens":["' + $TOK.A + '"],"parts":[{"t":"' + $TOK.A + '","s":"-Infinity","e":"Infinity"}]}'))
    Assert-Eq $r.ok $true 'should succeed'
    Assert-Near $r.segs[0].s 0.0 0.0001 'start clamped to 0'
    Assert-Near $r.segs[0].e 6.0 0.05 'end clamped to duration'
}

Test-Case '[VAL] null s or e drops the part' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload (
        '{"tokens":["' + $TOK.A + '"],"parts":[{"t":"' + $TOK.A + '","s":null,"e":2},' +
        '{"t":"' + $TOK.A + '","s":0,"e":null},{"t":"' + $TOK.A + '","s":0,"e":3}]}'))
    Assert-Eq $r.segs.Count 1 'only the well-formed part survives'
}

Test-Case '[VAL] non-numeric string s or e drops the part' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload (
        '{"tokens":["' + $TOK.A + '"],"parts":[{"t":"' + $TOK.A + '","s":"abc","e":"2"},' +
        '{"t":"' + $TOK.A + '","s":"0","e":"3"}]}'))
    Assert-Eq $r.segs.Count 1 'only the parsable part survives'
    Assert-Near $r.segs[0].e 3.0 0.0001 'and it is the right one'
}

Test-Case '[VAL] numeric strings are accepted (the client may send text)' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload (
        '{"tokens":["' + $TOK.A + '"],"parts":[{"t":"' + $TOK.A + '","s":"1.5","e":"3.25"}]}'))
    Assert-Near $r.segs[0].s 1.5 0.0001 'start'
    Assert-Near $r.segs[0].e 3.25 0.0001 'end'
}

Test-Case '[VAL] object-shaped s or e drops the part' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload (
        '{"tokens":["' + $TOK.A + '"],"parts":[{"t":"' + $TOK.A + '","s":{"v":1},"e":{"v":2}},' +
        '{"t":"' + $TOK.A + '","s":0,"e":3}]}'))
    Assert-Eq $r.segs.Count 1 'object edges dropped'
}

Test-Case '[VAL] array-shaped s or e drops the part' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload (
        '{"tokens":["' + $TOK.A + '"],"parts":[{"t":"' + $TOK.A + '","s":[1,2],"e":[3,4]},' +
        '{"t":"' + $TOK.A + '","s":0,"e":3}]}'))
    Assert-Eq $r.segs.Count 1 'array edges dropped'
}

Test-Case '[VAL] a sub-0.01s sliver is dropped' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 1; e = 1.009 }, @{ t = $TOK.A; s = 3; e = 4 })
    Assert-Eq $r.segs.Count 1 'sliver gone'
    Assert-Near $r.segs[0].s 3.0 0.0001 'the surviving part is the 1s one'
}

Test-Case '[VAL] exactly 0.01s is kept' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 1; e = 1.01 }, @{ t = $TOK.A; s = 3; e = 4 })
    Assert-Eq $r.segs.Count 2 'the 0.01s part is on the boundary and stays'
}

Test-Case '[VAL] s == e is dropped' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 2; e = 2 }, @{ t = $TOK.A; s = 3; e = 4 })
    Assert-Eq $r.segs.Count 1 'zero-length part gone'
}

Test-Case '[VAL] a total under 0.05s is rejected' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 1; e = 1.02 }, @{ t = $TOK.A; s = 3; e = 3.02 })
    Assert-Eq $r.ok $false 'should be rejected'
    Assert-Eq $r.error 'The selected clip is too short.' 'error text'
}

Test-Case '[VAL] a total just over 0.05s is accepted' {
    # Note: an exact 0.05 total lands on binary-floating-point noise
    # (1.025-1.0 is 0.0249999999999999) and is rejected. That is inherent to
    # comparing a sum of doubles against a literal, and at sub-millisecond
    # scale it is not worth a defect report - so this probes just above it.
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 1; e = 1.026 }, @{ t = $TOK.A; s = 3; e = 3.026 })
    Assert-Eq $r.ok $true 'boundary accepted'
}

# =============================================================================
Write-Section 'Validation - merging'
# =============================================================================

Test-Case '[VAL] touching runs of the SAME token merge into one part' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 }, @{ t = $TOK.A; s = 2; e = 4 })
    Assert-Eq $r.segs.Count 1 'merged'
    Assert-Near $r.segs[0].s 0.0 0.0001 'start'
    Assert-Near $r.segs[0].e 4.0 0.0001 'end'
    Assert-Near $r.span 4.0 0.0001 'span unchanged by merging'
}

Test-Case '[VAL] a gap larger than the 0.5ms tolerance does NOT merge' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 }, @{ t = $TOK.A; s = 2.001; e = 4 })
    Assert-Eq $r.segs.Count 2 'still two parts'
}

Test-Case '[VAL] a gap inside the 0.5ms tolerance DOES merge' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 }, @{ t = $TOK.A; s = 2.0004; e = 4 })
    Assert-Eq $r.segs.Count 1 'merged'
}

Test-Case '[VAL] touching parts from DIFFERENT tokens must NOT merge' {
    # Merging across a join would silently delete a whole clip from the export.
    $r = Resolve-P @($TOK.A, $TOK.B) @(@{ t = $TOK.A; s = 0; e = 2 }, @{ t = $TOK.B; s = 2; e = 4 })
    Assert-Eq $r.segs.Count 2 'two distinct parts'
    Assert-Eq $r.multi $true 'and it is a multi-source export'
    Assert-Near $r.span 4.0 0.0001 'span is the sum of both'
}

Test-Case '[VAL] an A,B,A sandwich keeps all three parts' {
    $r = Resolve-P @($TOK.A, $TOK.B) @(@{ t = $TOK.A; s = 0; e = 1 },
                                       @{ t = $TOK.B; s = 1; e = 2 },
                                       @{ t = $TOK.A; s = 2; e = 3 })
    Assert-Eq $r.segs.Count 3 'three parts'
    Assert-Eq $r.used.Count 2 'two distinct sources'
}

Test-Case '[REGRESSION] a same-token part that does not extend the previous one must not be swallowed' {
    # The merge test is `$sg.s -le ($prev.e + 0.0005)`, which is true for ANY
    # part that starts at or before the previous end - including one that goes
    # BACKWARDS. When such a part also ends before $prev.e it is discarded
    # outright, silently removing content from the export.
    # Reachable by any client that repeats or rewinds a clip; not reachable
    # from the current browser UI, which only emits monotonic ranges per track.
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 4; e = 6 }, @{ t = $TOK.A; s = 0; e = 2 })
    Assert-Eq $r.segs.Count 2 'both parts must survive - 4..6 then 0..2'
    Assert-Near $r.span 4.0 0.0001 'span must be 2 + 2 = 4s'
}

Test-Case '[REGRESSION] an overlapping earlier part must not lose its unique tail' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 2; e = 5 }, @{ t = $TOK.A; s = 1; e = 3 })
    Assert-Near $r.span 5.0 0.0001 'span must be 3 + 2 = 5s, not 3s'
}

Test-Case '[REGRESSION] a part naming a token absent from tokens[] must be ignored' {
    # The part loop resolves $sg.t against $S.Files, never against the tokens
    # list that was just validated - so `tokens` does not actually constrain
    # which sources contribute. A client can stitch in any loaded file.
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 }, @{ t = $TOK.B; s = 0; e = 1 })
    Assert-Eq $r.used.Count 1 'only the declared track may contribute'
    Assert-Eq $r.multi $false 'and therefore this is not a multi-source export'
}

Test-Case '[REGRESSION] NaN edges must be rejected, not carried into the encode' {
    # [double]::TryParse("NaN", Float, Invariant) succeeds, and every subsequent
    # guard (`$e0 -lt $s0`, Min/Max, `-lt 0.01`, `$span -lt 0.05`) is false for
    # NaN, so the part sails through and poisons $span. The app then throws out
    # of [timespan]::FromSeconds($span) and answers HTTP 500 with a .NET message.
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload (
        '{"tokens":["' + $TOK.A + '"],"parts":[{"t":"' + $TOK.A + '","s":"NaN","e":"NaN"}]}'))
    Assert-Eq $r.ok $false 'the only part is unusable, so this must be rejected'
    Assert-Eq $r.error 'Nothing is selected to save.' 'with the normal message'
}

Test-Case '[REGRESSION] a NaN part alongside valid parts must be dropped, not fatal' {
    $r = Resolve-SvtSegments -S $St -Payload (New-RawPayload (
        '{"tokens":["' + $TOK.A + '"],"parts":[{"t":"' + $TOK.A + '","s":0,"e":2},' +
        '{"t":"' + $TOK.A + '","s":"NaN","e":"NaN"}]}'))
    Assert-Eq $r.ok $true 'the good part is still exportable'
    Assert-Eq $r.segs.Count 1 'the NaN part is dropped'
    Assert-Near $r.span 2.0 0.0001 'span stays finite'
    # Nothing downstream may explode on the span.
    $null = Get-SvtDefaultOutName -Resolved $r
}

# =============================================================================
Write-Section 'Export path selection'
# =============================================================================

Test-Case '[PLAN] a single part takes the fast -ss/-t path' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 1; e = 3 })
    $plan = New-SvtExportPlan -S $St -Resolved $r -OutPath (Out-Path 'plan1.mp4')
    Assert-Eq $plan.kind 'fast' 'fast path'
    Assert-Eq $plan.filt '' 'no filter file'
    Assert-True (($plan.ffArgs -join ' ') -match '-ss 1 ') 'seeks to the start'
    Assert-True (($plan.ffArgs -join ' ') -match '-t 2 ')  'and runs for the span'
}

Test-Case '[PLAN] touching parts collapse to one and therefore take the fast path' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 }, @{ t = $TOK.A; s = 2; e = 4 })
    $plan = New-SvtExportPlan -S $St -Resolved $r -OutPath (Out-Path 'plan2.mp4')
    Assert-Eq $plan.kind 'fast' 'merged down to one part'
}

Test-Case '[PLAN] several parts from ONE file skip normalisation' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 }, @{ t = $TOK.A; s = 3; e = 4 })
    $plan = New-SvtExportPlan -S $St -Resolved $r -OutPath (Out-Path 'plan3.mp4')
    Assert-Eq $plan.kind 'concat-single' 'concat without normalisation'
    Assert-True ($plan.filterText -notmatch 'force_original_aspect_ratio') 'no scale/pad'
    Assert-True ($plan.filterText -notmatch 'aformat') 'no audio normalisation'
    Assert-True ($plan.filterText -match 'concat=n=2:v=1:a=1') 'concat of 2 with audio'
    Remove-Item -LiteralPath $plan.filt -Force -ErrorAction SilentlyContinue
}

Test-Case '[PLAN] several source files normalise every part into track 1' {
    $r = Resolve-P @($TOK.A, $TOK.C) @(@{ t = $TOK.A; s = 0; e = 1 }, @{ t = $TOK.C; s = 0; e = 1 })
    $plan = New-SvtExportPlan -S $St -Resolved $r -OutPath (Out-Path 'plan4.mp4')
    Assert-Eq $plan.kind 'concat-multi' 'multi-source concat'
    Assert-True ($plan.filterText -match 'scale=640:360:force_original_aspect_ratio=decrease') 'scaled to A'
    Assert-True ($plan.filterText -match 'pad=640:360') 'padded to A'
    Assert-True ($plan.filterText -match 'setsar=1') 'sar reset'
    Assert-True ($plan.filterText -match 'fps=25') 'fps forced to A'
    Assert-True ($plan.filterText -match 'sample_rates=48000') 'audio resampled'
    Assert-True ($plan.filterText -match 'channel_layouts=stereo') 'audio downmixed/upmixed'
    Remove-Item -LiteralPath $plan.filt -Force -ErrorAction SilentlyContinue
}

Test-Case '[PLAN] a silent part in a mixed export gets its own anullsrc input' {
    $r = Resolve-P @($TOK.A, $TOK.B) @(@{ t = $TOK.A; s = 0; e = 1 },
                                       @{ t = $TOK.B; s = 0; e = 1 },
                                       @{ t = $TOK.B; s = 2; e = 3 })
    $plan = New-SvtExportPlan -S $St -Resolved $r -OutPath (Out-Path 'plan5.mp4')
    $line = $plan.ffArgs -join ' '
    $n = ([regex]::Matches($line, 'anullsrc')).Count
    Assert-Eq $n 2 'one silence input per silent part - a filter pad cannot be reused'
    Assert-True ($plan.filterText -match '\[2:a\]') 'silence slots follow the file inputs'
    Assert-True ($plan.filterText -match '\[3:a\]') 'and are numbered consecutively'
    Remove-Item -LiteralPath $plan.filt -Force -ErrorAction SilentlyContinue
}

Test-Case '[PLAN] an all-silent multi-part export maps no audio at all' {
    $r = Resolve-P @($TOK.B) @(@{ t = $TOK.B; s = 0; e = 1 }, @{ t = $TOK.B; s = 3; e = 4 })
    $plan = New-SvtExportPlan -S $St -Resolved $r -OutPath (Out-Path 'plan6.mp4')
    Assert-True ($plan.filterText -match 'concat=n=2:v=1:a=0') 'video-only concat'
    Assert-True (($plan.ffArgs -join ' ') -match '-an') 'and -an on the output'
    Assert-True (($plan.ffArgs -join ' ') -notmatch 'anullsrc') 'no pointless silence inputs'
    Remove-Item -LiteralPath $plan.filt -Force -ErrorAction SilentlyContinue
}

Test-Case '[PLAN] the concat branch is never reached with a single part' {
    # concat=n=1 is degenerate; the count check must always divert to the fast
    # path first, including when the single part comes from track 2.
    foreach ($tk in @($TOK.A, $TOK.B, $TOK.C)) {
        $r = Resolve-P @($TOK.A, $TOK.B, $TOK.C) @(@{ t = $tk; s = 0; e = 2 })
        $plan = New-SvtExportPlan -S $St -Resolved $r -OutPath (Out-Path 'plan7.mp4')
        Assert-Eq $plan.kind 'fast' 'single part always takes the fast path'
    }
}

Test-Case '[PLAN] the default save name reflects the export kind' {
    $r1 = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 1; e = 3 })
    Assert-True ((Get-SvtDefaultOutName -Resolved $r1) -match '_trim_') 'single part -> trim'
    $r2 = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 }, @{ t = $TOK.A; s = 3; e = 4 })
    Assert-True ((Get-SvtDefaultOutName -Resolved $r2) -match '_edit_') 'multi part, one file -> edit'
    $r3 = Resolve-P @($TOK.A, $TOK.B) @(@{ t = $TOK.A; s = 0; e = 1 }, @{ t = $TOK.B; s = 0; e = 1 })
    Assert-True ((Get-SvtDefaultOutName -Resolved $r3) -match '_stitched_') 'multi file -> stitched'
}

# =============================================================================
Write-Section 'Export correctness (real ffmpeg + ffprobe)'
# =============================================================================

Test-Case '[EXP] fast path produces the requested duration' {
    $res = Export-P @($TOK.A) @(@{ t = $TOK.A; s = 1.5; e = 4.5 }) 'fast_dur.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    Assert-Near (Get-VideoDuration (Out-Path 'fast_dur.mp4')) 3.0 0.15 'duration'
}

Test-Case '[EXP] fast path lands on the requested source content' {
    $out = Out-Path 'fast_dur.mp4'   # A, 1.5s..4.5s
    $q = Resolve-FixturePixel (Get-FixturePixel $out 0.2)
    Assert-Eq $q.Family 'red' 'came from A'
    Assert-Eq $q.Second 1 'starts inside A second 1'
    $q = Resolve-FixturePixel (Get-FixturePixel $out 2.2)
    Assert-Eq $q.Second 3 'and 2.2s later is A second 3'
}

Test-Case '[EXP] multi-part single-file export has the summed duration' {
    $res = Export-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 },
                                @{ t = $TOK.A; s = 2; e = 3 },
                                @{ t = $TOK.A; s = 4; e = 5 }) 'multi1.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $d = Get-VideoDuration (Out-Path 'multi1.mp4')
    Assert-True ($d -ge 3.0) "at least the requested 3s, got $d"
    Assert-True ($d -le 3.3) "and no more than a frame per join over, got $d"
}

Test-Case '[EXP] multi-part single-file export keeps the right sections in order' {
    $out = Out-Path 'multi1.mp4'
    foreach ($pair in @(@(0.5, 0), @(1.5, 2), @(2.5, 4))) {
        $q = Resolve-FixturePixel (Get-FixturePixel $out $pair[0])
        Assert-Eq $q.Family 'red' "output t=$($pair[0]) came from A"
        Assert-Eq $q.Second $pair[1] "output t=$($pair[0]) is A second $($pair[1])"
    }
}

Test-Case '[EXP] a multi-file stitch normalises size and fps to track 1' {
    # C is 640x360 @30fps with mono 44.1k audio; A is 640x360 @25fps stereo 48k.
    $res = Export-P @($TOK.A, $TOK.C) @(@{ t = $TOK.A; s = 0; e = 2 },
                                        @{ t = $TOK.C; s = 0; e = 2 }) 'norm.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $si = Get-StreamInfo (Out-Path 'norm.mp4')
    Assert-Eq $si.Width 640 'width from track 1'
    Assert-Eq $si.Height 360 'height from track 1'
    Assert-Near $si.Fps 25.0 0.01 'fps from track 1'
    Assert-Eq $si.SampleRate 48000 'audio resampled to 48k'
    Assert-Eq $si.Channels 2 'audio forced to stereo'
}

Test-Case '[EXP] a 4:3 clip is pillarboxed into a 16:9 track 1 (real pixels)' {
    # B is 480x360 (4:3). Fitted into A's 640x360 it keeps 480 px of picture,
    # leaving 80 px of black down each side.
    $res = Export-P @($TOK.A, $TOK.B) @(@{ t = $TOK.A; s = 0; e = 2 },
                                        @{ t = $TOK.B; s = 0; e = 2 }) 'pillar.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $out = Out-Path 'pillar.mp4'
    Assert-Eq (Get-StreamInfo $out).Width 640 'output is track 1 width'

    $bar    = Get-RegionRgb $out 3.0 40 200 10  80    # inside the left black bar
    $centre = Get-RegionRgb $out 3.0 40 200 300 80    # inside B's picture
    Assert-True ($bar.R -le 6 -and $bar.G -le 6 -and $bar.B -le 6) `
                "left pillarbox must be black, got $($bar.R),$($bar.G),$($bar.B)"
    Assert-True ($centre.G -ge 25) "centre must carry B's green, got $($centre.R),$($centre.G),$($centre.B)"
    Assert-True ($centre.R -le 12) "centre must not be red (that would be A)"
}

Test-Case '[EXP] interleaved A,B,A maps to the right input slots' {
    $res = Export-P @($TOK.A, $TOK.B) @(@{ t = $TOK.A; s = 0; e = 1 },
                                        @{ t = $TOK.B; s = 3; e = 4 },
                                        @{ t = $TOK.A; s = 5; e = 6 }) 'aba.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $out = Out-Path 'aba.mp4'
    $q0 = Resolve-FixturePixel (Get-FixturePixel $out 0.5)
    $q1 = Resolve-FixturePixel (Get-FixturePixel $out 1.5)
    $q2 = Resolve-FixturePixel (Get-FixturePixel $out 2.5)
    Assert-Eq $q0.Family 'red';   Assert-Eq $q0.Second 0
    Assert-Eq $q1.Family 'green'; Assert-Eq $q1.Second 3
    Assert-Eq $q2.Family 'red';   Assert-Eq $q2.Second 5
}

Test-Case '[EXP] a silent clip gets real silence at the right offset' {
    $out = Out-Path 'pillar.mp4'   # A 0-2s (sine) then B 0-2s (no audio)
    $si = Get-StreamInfo $out
    Assert-Eq $si.HasAudio $true 'the export keeps an audio track'
    $loud  = Get-MeanVolumeDb $out 0.2 1.6
    $quiet = Get-MeanVolumeDb $out 2.3 1.5
    Assert-True ($loud -gt -40)  "A's half must carry sound, got $loud dB"
    Assert-True ($quiet -lt -80) "B's half must be digital silence, got $quiet dB"
}

Test-Case '[EXP] audio stays aligned with the picture across joins' {
    # Three parts: loud (A), silent (B), loud (A). Sound must switch off and
    # back on at the same instants the picture does.
    $res = Export-P @($TOK.A, $TOK.B) @(@{ t = $TOK.A; s = 0; e = 2 },
                                        @{ t = $TOK.B; s = 0; e = 2 },
                                        @{ t = $TOK.A; s = 3; e = 5 }) 'sync.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $out = Out-Path 'sync.mp4'
    Assert-Near (Get-VideoDuration $out) 6.0 0.25 'total duration'
    Assert-True ((Get-MeanVolumeDb $out 0.2 1.6) -gt -40) 'part 1 audible'
    Assert-True ((Get-MeanVolumeDb $out 2.3 1.5) -lt -80) 'part 2 silent'
    Assert-True ((Get-MeanVolumeDb $out 4.3 1.5) -gt -40) 'part 3 audible again'
    foreach ($pair in @(@(1.0, 'red'), @(3.0, 'green'), @(5.0, 'red'))) {
        $q = Resolve-FixturePixel (Get-FixturePixel $out $pair[0])
        Assert-Eq $q.Family $pair[1] "picture at $($pair[0])s"
    }
}

Test-Case '[EXP] an all-silent stitch produces a video-only file' {
    $res = Export-P @($TOK.B, $TOK.E) @(@{ t = $TOK.B; s = 0; e = 1 },
                                        @{ t = $TOK.B; s = 3; e = 4 }) 'silent.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $si = Get-StreamInfo (Out-Path 'silent.mp4')
    Assert-Eq $si.HasAudio $false 'no audio stream at all'
    Assert-True ($si.Duration -ge 2.0) 'and the picture is all there'
}

Test-Case '[EXP] the fast path on a silent source produces a video-only file' {
    $res = Export-P @($TOK.B) @(@{ t = $TOK.B; s = 1; e = 3 }) 'silentfast.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $si = Get-StreamInfo (Out-Path 'silentfast.mp4')
    Assert-Eq $si.HasAudio $false "-map 0:a:0? must tolerate a missing audio stream"
    Assert-Near $si.Duration 2.0 0.15 'duration'
}

Test-Case '[EXP] a clip shorter than one second exports whole' {
    $res = Export-P @($TOK.D) @(@{ t = $TOK.D; s = 0; e = 0.6 }) 'short.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    Assert-Near (Get-VideoDuration (Out-Path 'short.mp4')) 0.6 0.1 'duration'
}

Test-Case '[EXP] a sub-second clip survives being stitched into a longer track' {
    $res = Export-P @($TOK.A, $TOK.D) @(@{ t = $TOK.A; s = 0; e = 1 },
                                        @{ t = $TOK.D; s = 0; e = 0.5 },
                                        @{ t = $TOK.A; s = 3; e = 4 }) 'shortmix.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $q = Resolve-FixturePixel (Get-FixturePixel (Out-Path 'shortmix.mp4') 1.2)
    Assert-Eq $q.Family 'yellow' 'the 0.5s D part is really in there'
}

Test-Case '[EXP] parts totalling less than one frame each still encode' {
    # 4 x 0.015s at 25fps is 0.375 of a frame per part. Frame quantisation
    # rounds each up, so the file is longer than the 0.06s asked for - what
    # matters is that it encodes at all and holds real picture.
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 0.015 },
                               @{ t = $TOK.A; s = 1; e = 1.015 },
                               @{ t = $TOK.A; s = 2; e = 2.015 },
                               @{ t = $TOK.A; s = 3; e = 3.015 })
    Assert-Eq $r.ok $true 'accepted'
    $res = Invoke-SvtExport -S $St -Resolved $r -OutPath (Out-Path 'tiny.mp4')
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    Assert-True ((Get-VideoDuration (Out-Path 'tiny.mp4')) -gt 0) 'non-empty'
}

# =============================================================================
Write-Section 'Hostile paths through cmd.exe'
# =============================================================================

Test-Case '[ROB] & ^ ! ( ) , ; = space and unicode in a SOURCE name are fine' {
    $res = Export-P @($TOK.T) @(@{ t = $TOK.T; s = 0; e = 2 }) 'tame_src.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    Assert-Near (Get-VideoDuration (Out-Path 'tame_src.mp4')) 2.0 0.15 'duration'
}

Test-Case '[ROB] & ^ ! ( ) and a bare 100% in the OUTPUT name are fine' {
    $leaf = '100% done ! & (take 2)^ a,b;c=d.mp4'
    $res = Export-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 }) $leaf
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    Assert-True (Test-Path -LiteralPath (Out-Path $leaf)) 'file written under the requested name'
}

Test-Case '[ROB] a source path near MAX_PATH works' {
    Assert-True ($FX.G.Length -gt 200) "fixture path is only $($FX.G.Length) chars"
    $res = Export-P @($TOK.G) @(@{ t = $TOK.G; s = 0; e = 2 }) 'deep_src.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
}

Test-Case '[ROB] an output path near MAX_PATH works' {
    $dir = Join-Path $Work ('out_padding_directory_one_padding_padding\' +
                            'out_padding_directory_two_padding_padding')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $out = Join-Path $dir 'exported_video_with_a_deliberately_long_leaf_name_for_max_path.mp4'
    Assert-True ($out.Length -gt 200) "output path is only $($out.Length) chars"
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 })
    $res = Invoke-SvtExport -S $St -Resolved $r -OutPath $out
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
}

Test-Case '[REGRESSION] %VAR% in a SOURCE filename must not be expanded by cmd.exe' {
    # The command line is assembled as a string and handed to %ComSpec% /c, so
    # cmd performs environment substitution INSIDE the quoted path. The fixture
    # is literally named "my %PATH% clip & (test)^ ok! a,b;c=d <unicode>.mp4";
    # cmd rewrites %PATH% and ffmpeg is handed a path that does not exist.
    # /api/play (line 2099) already shows the fix: build ProcessStartInfo
    # directly instead of routing through a shell.
    $res = Export-P @($TOK.F) @(@{ t = $TOK.F; s = 0; e = 2 }) 'from_pct_src.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    Assert-Near (Get-VideoDuration (Out-Path 'from_pct_src.mp4')) 2.0 0.15 'duration'
    $q = Resolve-FixturePixel (Get-FixturePixel (Out-Path 'from_pct_src.mp4') 0.5)
    Assert-Eq $q.Family 'cyan' 'and the picture really came from F'
}

Test-Case '[REGRESSION] %VAR% in the OUTPUT filename must not be expanded by cmd.exe' {
    # Worse than the input case: ffmpeg succeeds, so a perfectly good file is
    # written - under the WRONG name. The job then fails its Test-Path check
    # (line 2362) and the user is shown ffmpeg's last three log lines, which
    # are encoder statistics, as the "error".
    $env:SVT_TEST_MARKER = 'EXPANDED'
    $wanted   = Out-Path 'holiday %SVT_TEST_MARKER% cut.mp4'
    $expanded = Out-Path 'holiday EXPANDED cut.mp4'
    foreach ($p in @($wanted, $expanded)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 })
    $res = Invoke-SvtExport -S $St -Resolved $r -OutPath $wanted
    Assert-True (-not (Test-Path -LiteralPath $expanded)) 'nothing may be written to the expanded name'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    Assert-True (Test-Path -LiteralPath $wanted) 'the file must exist under the name the user chose'
}

Test-Case '[ROB] the cache dir path also reaches cmd.exe unescaped' {
    # -progress and the 2> redirect target both go on the command line by hand.
    # They live under %TEMP%\SimpleVideoTrimmer, which is user-controlled: a
    # Windows account name may legally contain %, & and ^. This test documents
    # the exposure by driving a cache directory that contains those characters.
    $cd = Join-Path $Work 'ca ch e & (x)^ dir'
    $St2 = New-SvtState -FFmpeg (Get-FFmpegPath) -FFprobe (Get-FFprobePath) -CacheDir $cd
    $St2.Files[$TOK.A] = $St.Files[$TOK.A]
    $r = Resolve-SvtSegments -S $St2 -Payload (New-Payload @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 },
                                                                       @{ t = $TOK.A; s = 2; e = 3 }))
    $res = Invoke-SvtExport -S $St2 -Resolved $r -OutPath (Out-Path 'weird_cache.mp4')
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
}

# =============================================================================
Write-Section 'Degenerate geometry'
# =============================================================================

Test-Case '[EXP] odd track-1 dimensions are rounded up in a multi-file stitch' {
    # E is 641x361; the concat target must become 642x362 or x264 refuses it.
    $res = Export-P @($TOK.E, $TOK.A) @(@{ t = $TOK.E; s = 0; e = 1 },
                                        @{ t = $TOK.A; s = 0; e = 1 }) 'oddmulti.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $si = Get-StreamInfo (Out-Path 'oddmulti.mp4')
    Assert-Eq ($si.Width % 2) 0 'even width'
    Assert-Eq ($si.Height % 2) 0 'even height'
}

Test-Case '[REGRESSION] an odd-dimension source exports on the fast path' {
    # The even-dimension rounding at lines 2256-2258 only exists inside the
    # multi-FILE branch. The fast path pipes 641x361 straight into
    # "-c:v libx264 -pix_fmt yuv420p", which x264 rejects outright:
    #   "width not divisible by 2 (641x361)".
    # Odd geometry is legal in yuv444p/yuv422p H.264, in VP8/VP9 webm and in
    # MJPEG mov - all of which this app opens.
    $out = Out-Path 'odd_fast.mp4'
    $res = Export-P @($TOK.E) @(@{ t = $TOK.E; s = 0; e = 2 }) 'odd_fast.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $si = Get-StreamInfo $out
    Assert-True ($si.Width -ge 640) 'picture survives'
    Assert-Near $si.Duration 2.0 0.2 'duration'
}

Test-Case '[REGRESSION] an odd-dimension source exports on the single-file concat path' {
    $res = Export-P @($TOK.E) @(@{ t = $TOK.E; s = 0; e = 1 },
                                @{ t = $TOK.E; s = 2; e = 3 }) 'odd_concat.mp4'
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
}

# Forces a real ffmpeg failure the way a renamed or unplugged source would: the
# token resolves, but the path behind it is gone, so ffmpeg fails at input-open.
# Odd dimensions used to serve this purpose and no longer fail.
function New-DoomedResolved {
    param([hashtable]$State = $St)
    $tok = 'DOOMED_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $State.Files[$tok] = [pscustomobject]@{
        path = (Join-Path $State.CacheDir 'no_such_source_file.mp4')
        name = 'no_such_source_file.mp4'; duration = 10.0
        width = 640; height = 480; fps = 25.0; hasAudio = $false
    }
    Resolve-SvtSegments -S $State -Payload (New-Payload @($tok) @(@{ t = $tok; s = 0; e = 2 }))
}

Test-Case '[REGRESSION] a failed export must not destroy an existing file at the target' {
    # ffmpeg is launched with -y, so it truncates the destination before it
    # discovers it cannot encode. An export that fails for ANY reason therefore
    # wipes whatever the user picked in the Save dialog - and OverwritePrompt
    # means they deliberately chose to replace something.
    $victim = Out-Path 'precious.mp4'
    Copy-Item -LiteralPath $FX.A -Destination $victim -Force
    $before = (Get-Item -LiteralPath $victim).Length
    Assert-True ($before -gt 1000) 'victim starts out as a real file'
    $r = New-DoomedResolved
    $res = Invoke-SvtExport -S $St -Resolved $r -OutPath $victim
    Assert-Eq $res.state 'failed' 'this export is expected to fail'
    $after = $(if (Test-Path -LiteralPath $victim) { (Get-Item -LiteralPath $victim).Length } else { -1 })
    Assert-Eq $after $before 'the previous file must still be intact after a failed export'
}

# =============================================================================
Write-Section 'Do-not-overwrite-the-source check'
# =============================================================================

Test-Case '[ROB] saving over the exact source path is refused' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 })
    Assert-Eq (Test-SvtOutputClash -S $St -Resolved $r -OutPath $FX.A) $true 'clash detected'
}

Test-Case '[ROB] the clash check is case-insensitive' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 })
    Assert-Eq (Test-SvtOutputClash -S $St -Resolved $r -OutPath $FX.A.ToUpper()) $true 'clash detected'
}

Test-Case '[ROB] the clash check normalises slashes, dots and trailing dots' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 })
    $dir  = Split-Path -Parent $FX.A
    $leaf = Split-Path -Leaf $FX.A
    foreach ($variant in @(($FX.A -replace '\\', '/'),
                           ($FX.A + '.'),
                           (Join-Path $dir (".\$leaf")),
                           (Join-Path (Join-Path $dir 'sub\..') $leaf))) {
        Assert-Eq (Test-SvtOutputClash -S $St -Resolved $r -OutPath $variant) $true "clash for '$variant'"
    }
}

Test-Case '[ROB] the clash check sees through an 8.3 short path' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 2 })
    $fso = New-Object -ComObject Scripting.FileSystemObject
    $short = $fso.GetFile($FX.A).ShortPath
    if ($short -eq $FX.A) { return }    # 8.3 generation disabled on this volume
    Assert-Eq (Test-SvtOutputClash -S $St -Resolved $r -OutPath $short) $true 'clash detected'
}

Test-Case '[ROB] the clash check covers EVERY contributing source, not just track 1' {
    $r = Resolve-P @($TOK.A, $TOK.B) @(@{ t = $TOK.A; s = 0; e = 1 }, @{ t = $TOK.B; s = 0; e = 1 })
    Assert-Eq (Test-SvtOutputClash -S $St -Resolved $r -OutPath $FX.B) $true 'clash on track 2'
    Assert-Eq (Test-SvtOutputClash -S $St -Resolved $r -OutPath $FX.C) $false 'no clash on an uninvolved file'
}

Test-Case '[ROB] a source that contributes no parts does not block saving over it' {
    $r = Resolve-P @($TOK.A, $TOK.C) @(@{ t = $TOK.A; s = 0; e = 2 })
    Assert-Eq (Test-SvtOutputClash -S $St -Resolved $r -OutPath $FX.C) $false 'C is not read, so it is fair game'
}

# =============================================================================
Write-Section 'Scale, progress and cleanup'
# =============================================================================

Test-Case '[ROB] 40 parts stay well inside the cmd.exe command-line limit' {
    $parts = @()
    for ($i = 0; $i -lt 40; $i++) {
        $a = [math]::Round(0.05 + $i * 0.145, 3)
        $parts += @{ t = $TOK.A; s = $a; e = [math]::Round($a + 0.1, 3) }
    }
    $r = Resolve-P @($TOK.A) $parts
    Assert-Eq $r.segs.Count 40 'all 40 parts survive'
    $plan = New-SvtExportPlan -S $St -Resolved $r -OutPath (Out-Path 'p40.mp4')
    Assert-True ($plan.cmdLine.Length -lt 8000) "command line is $($plan.cmdLine.Length) chars"
    Assert-True ($plan.filterText.Length -gt $plan.cmdLine.Length) 'the bulk really is in the filter file'
    Remove-Item -LiteralPath $plan.filt -Force -ErrorAction SilentlyContinue
}

Test-Case '[ROB] 40 interleaved parts across two files also fit, and encode' {
    $parts = @()
    for ($i = 0; $i -lt 40; $i++) {
        $tk = $(if ($i % 2) { $TOK.B } else { $TOK.A })
        $a = [math]::Round(0.05 + ($i % 20) * 0.25, 3)
        $parts += @{ t = $tk; s = $a; e = [math]::Round($a + 0.1, 3) }
    }
    $r = Resolve-P @($TOK.A, $TOK.B) $parts
    Assert-Eq $r.segs.Count 40 'no accidental merging across the alternation'
    $plan = New-SvtExportPlan -S $St -Resolved $r -OutPath (Out-Path 'p40m.mp4')
    # 20 silent parts each add their own "-f lavfi -t X -i anullsrc=..." input
    Assert-Eq ([regex]::Matches(($plan.ffArgs -join ' '), 'anullsrc')).Count 20 'one silence input per silent part'
    Assert-True ($plan.cmdLine.Length -lt 8000) "command line is $($plan.cmdLine.Length) chars"
    Remove-Item -LiteralPath $plan.filt -Force -ErrorAction SilentlyContinue
    $res = Invoke-SvtExport -S $St -Resolved $r -OutPath (Out-Path 'p40m.mp4')
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
}

Test-Case '[ROB] frame quantisation makes the output longer, never shorter' {
    # trim snaps to frame boundaries, so N parts can each gain up to a frame.
    # This is expected, not a defect - but it must stay bounded and one-sided.
    $parts = @()
    for ($i = 0; $i -lt 40; $i++) {
        $a = [math]::Round(0.05 + $i * 0.145, 3)
        $parts += @{ t = $TOK.A; s = $a; e = [math]::Round($a + 0.1, 3) }
    }
    $r = Resolve-P @($TOK.A) $parts
    $res = Invoke-SvtExport -S $St -Resolved $r -OutPath (Out-Path 'p40.mp4')
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $d = Get-VideoDuration (Out-Path 'p40.mp4')
    Assert-True ($d -ge ($r.span - 0.05)) "output ($d s) must not be shorter than the span ($($r.span) s)"
    $maxOver = 40 * (1.0 / 25.0)      # at most one frame of track 1 per part
    Assert-True (($d - $r.span) -le $maxOver) "overshoot $([math]::Round($d - $r.span,3))s exceeds $maxOver s"
}

Test-Case '[ROB] out_time parses and drives the percentage' {
    $job = @{ prog = (Out-Path 'prog_synth.txt'); span = 5.0; percent = 0.0 }
    Set-Content -LiteralPath $job.prog -Encoding ascii -Value @(
        'frame=25', 'out_time_us=1000000', 'out_time=00:00:01.000000', 'progress=continue',
        'frame=63', 'out_time_us=2500000', 'out_time=00:00:02.500000', 'progress=continue')
    Assert-Near (Get-SvtJobPercent $job) 50.0 0.01 'the LAST out_time wins'
    Add-Content -LiteralPath $job.prog -Encoding ascii -Value @('out_time=01:02:03.500000', 'progress=end')
    Assert-Near (Get-SvtJobPercent $job) 99.0 0.01 'a runaway out_time is capped at 99'
}

Test-Case '[ROB] a negative or N/A out_time never yields a negative percentage' {
    $job = @{ prog = (Out-Path 'prog_neg.txt'); span = 5.0; percent = 0.0 }
    Set-Content -LiteralPath $job.prog -Encoding ascii -Value @(
        'out_time=N/A', 'out_time=-00:00:00.033000', 'progress=continue')
    $p = Get-SvtJobPercent $job
    Assert-True ($p -ge 0.0 -and $p -le 100.0) "percent out of range: $p"
    Assert-Near $p 0.0 0.0001 'unparsable values leave the percentage alone'
}

Test-Case '[ROB] a real job only ever reports 0..100' {
    $r = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 }, @{ t = $TOK.A; s = 2; e = 4 })
    $res = Invoke-SvtExport -S $St -Resolved $r -OutPath (Out-Path 'pct.mp4')
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    foreach ($p in $res.percents) {
        Assert-True ($p -ge 0.0 -and $p -le 100.0) "percent out of range during the run: $p"
    }
    Assert-Eq $res.job.percent 100.0 'a finished job reads 100'
}

Test-Case '[ROB] a successful job removes prog_, log_ and filter_' {
    $cd = Join-Path $Work 'cache_ok'
    $St2 = New-SvtState -FFmpeg (Get-FFmpegPath) -FFprobe (Get-FFprobePath) -CacheDir $cd
    $St2.Files[$TOK.A] = $St.Files[$TOK.A]
    $r = Resolve-SvtSegments -S $St2 -Payload (New-Payload @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 },
                                                                       @{ t = $TOK.A; s = 2; e = 3 }))
    $res = Invoke-SvtExport -S $St2 -Resolved $r -OutPath (Out-Path 'clean_ok.mp4')
    Assert-Eq $res.state 'done' "export failed: $($res.error)"
    $left = @(Get-ChildItem -LiteralPath $cd -ErrorAction SilentlyContinue)
    Assert-Eq $left.Count 0 "cache dir should be empty, holds: $(($left.Name) -join ', ')"
}

Test-Case '[ROB] a FAILED job also removes prog_, log_ and filter_' {
    $cd = Join-Path $Work 'cache_fail'
    $St2 = New-SvtState -FFmpeg (Get-FFmpegPath) -FFprobe (Get-FFprobePath) -CacheDir $cd
    $r = New-DoomedResolved -State $St2
    $res = Invoke-SvtExport -S $St2 -Resolved $r -OutPath (Out-Path 'clean_fail.mp4')
    Assert-Eq $res.state 'failed' 'this export is expected to fail (missing source)'
    $left = @(Get-ChildItem -LiteralPath $cd -ErrorAction SilentlyContinue)
    Assert-Eq $left.Count 0 "cache dir should be empty, holds: $(($left.Name) -join ', ')"
}

Test-Case '[ROB] the shutdown sweep clears artefacts an unpolled job left behind' {
    # /api/job is the ONLY place that deletes these. A browser tab closed
    # mid-export never polls again, so the files survive until shutdown.
    $cd = Join-Path $Work 'cache_sweep'
    $St2 = New-SvtState -FFmpeg (Get-FFmpegPath) -FFprobe (Get-FFprobePath) -CacheDir $cd
    foreach ($n in 'prog_abc.txt', 'log_abc.txt', 'filter_abc.txt', 'frame_abc.jpg') {
        Set-Content -LiteralPath (Join-Path $cd $n) -Value 'x' -Encoding ascii
    }
    Set-Content -LiteralPath (Join-Path $cd 'strip_keepme.jpg') -Value 'x' -Encoding ascii
    Invoke-SvtShutdownSweep -S $St2
    $left = @(Get-ChildItem -LiteralPath $cd -ErrorAction SilentlyContinue)
    Assert-Eq $left.Count 1 "only the cached strip should remain, holds: $(($left.Name) -join ', ')"
    Assert-Eq $left[0].Name 'strip_keepme.jpg' 'the thumbnail cache is deliberately kept'
}

Test-Case '[ROB] two concurrent exports do not collide in the cache dir' {
    $r1 = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 0; e = 1 }, @{ t = $TOK.A; s = 2; e = 3 })
    $r2 = Resolve-P @($TOK.A) @(@{ t = $TOK.A; s = 1; e = 2 }, @{ t = $TOK.A; s = 4; e = 5 })
    $p1 = New-SvtExportPlan -S $St -Resolved $r1 -OutPath (Out-Path 'cc1.mp4')
    $p2 = New-SvtExportPlan -S $St -Resolved $r2 -OutPath (Out-Path 'cc2.mp4')
    Assert-True ($p1.filt -ne $p2.filt) 'distinct filter files'
    Assert-True ($p1.prog -ne $p2.prog) 'distinct progress files'
    Assert-True ($p1.log  -ne $p2.log)  'distinct log files'
    $j1 = Start-SvtExport -S $St -Plan $p1
    $j2 = Start-SvtExport -S $St -Plan $p2
    foreach ($j in @($j1, $j2)) {
        $j.proc.WaitForExit(120000) | Out-Null
        Assert-Eq (Complete-SvtJob $j) 'done' "concurrent export failed: $($j.error)"
    }
    Assert-Near (Get-VideoDuration (Out-Path 'cc1.mp4')) 2.0 0.2 'job 1 duration'
    Assert-Near (Get-VideoDuration (Out-Path 'cc2.mp4')) 2.0 0.2 'job 2 duration'
}

# ------------------------------------------------------------- summary ------

Write-Host ''
$total  = $script:Results.Count
$failed = $script:Failures.Count
$passed = $total - $failed
$known  = @($script:Failures | Where-Object { $_.Name -match 'REGRESSION' }).Count
$other  = $failed - $known

Write-Host ('  ' + ('=' * 66)) -ForegroundColor DarkGray
Write-Host ("  {0} tests: {1} passed, {2} failed" -f $total, $passed, $failed) `
           -ForegroundColor $(if ($failed) { 'Yellow' } else { 'Green' })
if ($failed) {
    Write-Host ("  of the failures, {0} are [REGRESSION] (a fixed bug came back) and {1} are not" -f $known, $other) `
               -ForegroundColor Yellow
    Write-Host ''
    foreach ($f in $script:Failures) { Write-Host ("    - " + $f.Name) -ForegroundColor Red }
}
Write-Host ('  ' + ('=' * 66)) -ForegroundColor DarkGray
Write-Host ''

Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue

$script:ExportSuiteFailures = $failed
