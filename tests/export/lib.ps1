# =============================================================================
#  lib.ps1 - a FAITHFUL EXTRACTION of SimpleVideoTrimmer.bat's export path
# =============================================================================
#  !!! THIS MIRRORS THE APP. IT MUST BE UPDATED WHENEVER THE APP CHANGES. !!!
#
#  Everything below is transcribed from the '^/api/save$' and '^/api/job$'
#  routes inside the $Handler scriptblock in SimpleVideoTrimmer.bat, with the
#  two GUI dialogs removed so the logic can be driven headlessly:
#
#     Get-SvtMediaInfo      <- function Get-MediaInfo            (~line 1718)
#     Read-SvtCrop          <- function Read-Crop                (~line 2025)
#     Get-SvtCropFilter     <- function Get-CropFilter           (~line 2060)
#     Resolve-SvtSegments   <- /api/save token+part validation   (~lines 2134-2182)
#     Test-SvtOutputClash   <- /api/save "don't overwrite source" (~line 2205-2212)
#     New-SvtExportPlan     <- /api/save arg + filter building   (~lines 2214-2321)
#     Start-SvtExport       <- /api/save process launch          (~lines 2319-2335)
#     Get-SvtJobPercent     <- /api/job progress parsing         (~lines 2343-2358)
#     Complete-SvtJob       <- /api/job completion + cleanup     (~lines 2359-2377)
#
#  Deliberate fidelity notes:
#   * the command line is built with the app's exact format string and run
#     through %ComSpec% /c, because that is where the quoting defects live;
#   * paths are quoted by hand with '"' + $p + '"', exactly as the app does;
#   * numbers go through Num() with the app's precision ('0.###' for segment
#     edges and durations), because that rounding is observable in the output.
# =============================================================================

# No Set-StrictMode: the app's handler runs non-strict, and strict mode would
# change how missing JSON properties behave. Fidelity beats tidiness here.

$script:Inv = [cultureinfo]::InvariantCulture

# --- app: function Num([double]$v, [string]$f = '0.######')  (line 1674) ------
function Num([double]$v, [string]$f = '0.######') { [string]::Format($script:Inv, "{0:$f}", $v) }

# --- app: shared state $S  (line 195) ----------------------------------------
# Mirrors Quote-Arg in the app: ProcessStartInfo takes one string which the
# child re-splits with CommandLineToArgvW rules.
function Quote-SvtArg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $tail = [regex]::Match($a, '\\*$').Value
    return '"' + $a.Substring(0, $a.Length - $tail.Length) + ($tail * 2) + '"'
}

# --- app: function Read-Crop (line 2025) -------------------------------------
function Read-SvtCrop($c) {
    if (-not $c) { return $null }
    $vals = @{}
    foreach ($f in @('x', 'y', 'ow', 'oh')) {
        $d = 0.0
        if (-not [double]::TryParse([string]$c.$f, [Globalization.NumberStyles]::Float,
                                    $script:Inv, [ref]$d)) { return $null }
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
        $vals[$f] = $d
    }
    $x = [math]::Max(0.0, [math]::Min($vals['x'], 1.0))
    $y = [math]::Max(0.0, [math]::Min($vals['y'], 1.0))

    $ow = [int][math]::Floor([math]::Round($vals['ow']) / 2) * 2
    $oh = [int][math]::Floor([math]::Round($vals['oh']) / 2) * 2
    if ($ow -lt 16 -or $oh -lt 16 -or $ow -gt 8192 -or $oh -gt 8192) { return $null }

    @{ x = $x; y = $y; ow = $ow; oh = $oh }
}

# --- app: function Get-CropFilter (line 2060) --------------------------------
function Get-SvtCropFilter($c, [int]$fw, [int]$fh) {
    $mw = [int][math]::Floor($fw / 2) * 2
    $mh = [int][math]::Floor($fh / 2) * 2
    if ($mw -lt 2) { $mw = 2 }; if ($mh -lt 2) { $mh = 2 }

    # A window bigger than the picture is shrunk to fit, and BOTH sides shrink
    # by the same factor so a capped request keeps the shape it asked for - the
    # client caps the same way, so the two agree even on a malformed request.
    $cw = [int]$c.ow; $ch = [int]$c.oh
    $k = 1.0
    if ($cw -gt $mw) { $k = [math]::Min($k, $mw / [double]$cw) }
    if ($ch -gt $mh) { $k = [math]::Min($k, $mh / [double]$ch) }
    if ($k -lt 1.0) {
        $cw = [int][math]::Floor($cw * $k / 2) * 2
        $ch = [int][math]::Floor($ch * $k / 2) * 2
    }
    if ($cw -lt 2) { $cw = 2 }; if ($ch -lt 2) { $ch = 2 }
    if ($cw -gt $mw) { $cw = $mw }; if ($ch -gt $mh) { $ch = $mh }

    $cx = [int][math]::Floor($c.x * $fw / 2) * 2
    $cy = [int][math]::Floor($c.y * $fh / 2) * 2
    if ($cx + $cw -gt $mw) { $cx = $mw - $cw }
    if ($cy + $ch -gt $mh) { $cy = $mh - $ch }
    if ($cx -lt 0) { $cx = 0 }; if ($cy -lt 0) { $cy = 0 }

    "crop=${cw}:${ch}:${cx}:${cy}"
}

function New-SvtState {
    param([string]$FFmpeg, [string]$FFprobe, [string]$CacheDir)
    if (-not $CacheDir) { $CacheDir = Join-Path $env:TEMP 'SimpleVideoTrimmer' }
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    @{
        FFmpeg   = $FFmpeg
        FFprobe  = $FFprobe
        CacheDir = $CacheDir
        Files    = @{}
        Jobs     = @{}
        Audio    = @{}
    }
}

# --- app: function Get-MediaInfo (line 1718) ---------------------------------
#  Only the fields the export path reads are reproduced. The playability
#  classification is irrelevant to /api/save and is omitted.
function Get-SvtMediaInfo {
    param([hashtable]$S, [string]$Path)
    $raw = & $S.FFprobe -v error -print_format json -show_format -show_streams $Path 2>$null
    if (-not $raw) { throw 'ffprobe returned nothing for that file.' }
    $j = ($raw -join "`n") | ConvertFrom-Json

    $vs = $j.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    if (-not $vs) { throw 'That file does not contain a video track.' }
    $as = $j.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1

    $dur = 0.0
    foreach ($cand in @($j.format.duration, $vs.duration)) {
        if ($cand -and [double]::TryParse([string]$cand, [Globalization.NumberStyles]::Float,
                                          $script:Inv, [ref]$dur) -and $dur -gt 0) { break }
    }
    $fps = 0.0
    foreach ($r in @($vs.avg_frame_rate, $vs.r_frame_rate)) {
        if ($r -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -ne 0) {
            $fps = [double]$Matches[1] / [double]$Matches[2]
            if ($fps -gt 0) { break }
        }
    }
    if ($fps -le 0) { $fps = 25.0 }

    $fi = Get-Item -LiteralPath $Path
    [pscustomobject]@{
        path     = $fi.FullName
        name     = $fi.Name
        duration = [math]::Round($dur, 3)
        width    = [int]$vs.width
        height   = [int]$vs.height
        fps      = [math]::Round($fps, 3)
        hasAudio = [bool]$as
    }
}

# Registers a file the way /api/open does and returns its token.
function Add-SvtFile {
    param([hashtable]$S, [string]$Path, [string]$Token)
    if (-not $Token) { $Token = [Guid]::NewGuid().ToString('N') }
    $S.Files[$Token] = Get-SvtMediaInfo -S $S -Path $Path
    return $Token
}

# Registers a soundtrack the way /api/audio/open does - only what /api/save reads.
function Add-SvtAudio {
    param([hashtable]$S, [string]$Path)
    $raw = & $S.FFprobe -v error -print_format json -show_format $Path 2>$null
    $j = ($raw -join "`n") | ConvertFrom-Json
    $d = 0.0
    [void][double]::TryParse([string]$j.format.duration, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)
    $tok = [Guid]::NewGuid().ToString('N')
    $S.Audio[$tok] = [pscustomobject]@{ path = (Get-Item -LiteralPath $Path).FullName
                                         name = [IO.Path]::GetFileName($Path); duration = $d }
    return $tok
}

# =============================================================================
#  Resolve-SvtSegments  <- /api/save lines 2134-2182
# =============================================================================
#  $Payload is whatever `$body | ConvertFrom-Json` produced: normally a
#  PSCustomObject with .tokens and .parts. Tests hand it the same shapes the
#  browser (or a hostile client) can produce.
#
#  Returns @{ ok; error; order; first; segs; span; used; multi }
# =============================================================================
function Resolve-SvtSegments {
    param([hashtable]$S, $Payload)

    $p = $Payload
    $fail = { param($msg) @{ ok = $false; error = $msg; order = @(); segs = @();
                             span = 0.0; used = @(); multi = $false; first = $null } }

    # tokens carries the track order; the FIRST track sets the output format.
    $order = @()
    if ($p.PSObject.Properties['tokens'] -and $p.tokens) {
        foreach ($tk in $p.tokens) { if ($S.Files[[string]$tk]) { $order += [string]$tk } }
    }
    if ($order.Count -eq 0) { return (& $fail 'Those videos are no longer loaded.') }
    $first = $S.Files[$order[0]]

    $segs = New-Object System.Collections.ArrayList
    if ($p.PSObject.Properties['parts'] -and $p.parts) {
        foreach ($sg in $p.parts) {
            if ($null -eq $sg) { continue }
            if ($order -notcontains [string]$sg.t) { continue }
            $ti = $S.Files[[string]$sg.t]
            if (-not $ti) { continue }
            $s0 = 0.0; $e0 = 0.0
            if (-not [double]::TryParse([string]$sg.s, [Globalization.NumberStyles]::Float,
                                        $script:Inv, [ref]$s0)) { continue }
            if (-not [double]::TryParse([string]$sg.e, [Globalization.NumberStyles]::Float,
                                        $script:Inv, [ref]$e0)) { continue }
            if ([double]::IsNaN($s0) -or [double]::IsNaN($e0)) { continue }
            if ($e0 -lt $s0) { $t = $s0; $s0 = $e0; $e0 = $t }
            $s0 = [math]::Max(0.0, [math]::Min($s0, $ti.duration))
            $e0 = [math]::Max(0.0, [math]::Min($e0, $ti.duration))
            if (($e0 - $s0) -lt 0.01) { continue }
            $rv = ([string]$sg.r) -in @('1', 'True', 'true')
            # m marks a part whose track is muted - it goes out silent
            $mu = ([string]$sg.m) -in @('1', 'True', 'true')
            [void]$segs.Add(@{ tok = [string]$sg.t; info = $ti; s = $s0; e = $e0; r = $rv; m = $mu })
        }
    }
    if ($segs.Count -eq 0) { return (& $fail 'Nothing is selected to save.') }

    # Runs of the same clip that touch end to end are one encode, not two.
    $merged = New-Object System.Collections.ArrayList
    foreach ($sg in $segs) {
        $prev = $(if ($merged.Count) { $merged[$merged.Count - 1] } else { $null })
        if ($prev -and $prev.tok -eq $sg.tok -and
            [math]::Abs($sg.s - $prev.e) -le 0.0005 -and $sg.e -gt $prev.e -and -not $prev.r -and -not $sg.r -and
            $prev.m -eq $sg.m) {
            $prev.e = $sg.e
        } else {
            [void]$merged.Add(@{ tok = $sg.tok; info = $sg.info; s = $sg.s; e = $sg.e; r = $sg.r; m = $sg.m })
        }
    }
    $segs = @($merged)

    $span = 0.0
    foreach ($sg in $segs) { $span += ($sg.e - $sg.s) }
    if ($span -lt 0.05) { return (& $fail 'The selected clip is too short.') }

    $used = @()
    foreach ($sg in $segs) { if ($used -notcontains $sg.tok) { $used += $sg.tok } }

    $crop = $(if ($p.PSObject.Properties['crop']) { Read-SvtCrop $p.crop } else { $null })
    $snd = $(if ($p.PSObject.Properties['audio'] -and $p.audio) { $S.Audio[[string]$p.audio] } else { $null })

    @{ ok = $true; error = ''; order = $order; first = $first; segs = $segs
       span = $span; used = $used; multi = ($used.Count -gt 1); crop = $crop; snd = $snd }
}

# =============================================================================
#  Test-SvtOutputClash  <- /api/save lines 2205-2212
# =============================================================================
function Test-SvtOutputClash {
    param([hashtable]$S, $Resolved, [string]$OutPath)
    $clash = $false
    foreach ($tk in $Resolved.used) {
        if ([IO.Path]::GetFullPath($OutPath) -eq $S.Files[$tk].path) { $clash = $true }
    }
    return $clash
}

# The default filename the SaveFileDialog is pre-filled with (lines 2184-2199).
function Get-SvtDefaultOutName {
    param($Resolved)
    $first = $Resolved.first
    $segs  = $Resolved.segs
    $span  = $Resolved.span
    $multi = $Resolved.multi
    $crop  = $Resolved.crop
    $base  = [IO.Path]::GetFileNameWithoutExtension($first.name)
    $tag   = $(if ($multi) { [timespan]::FromSeconds($span).ToString('hhmmss') }
               else { '{0}-{1}' -f ([timespan]::FromSeconds($segs[0].s).ToString('hhmmss')),
                                   ([timespan]::FromSeconds($segs[$segs.Count - 1].e).ToString('hhmmss')) })
    $word  = $(if ($crop) { 'crop' }
               elseif ($multi) { 'stitched' }
               elseif ($segs.Count -gt 1) { 'edit' } else { 'trim' })
    $dim   = $(if ($crop) { '_{0}x{1}' -f $crop.ow, $crop.oh } else { '' })
    return "${base}_${word}_${tag}${dim}.mp4"
}

# =============================================================================
#  New-SvtExportPlan  <- /api/save lines 2214-2321
# =============================================================================
#  Returns @{ id; prog; log; filt; filterText; ffArgs; cmdLine; path } where
#  `path` is 'fast' | 'concat-single' | 'concat-multi'.
# =============================================================================
function New-SvtExportPlan {
    param([hashtable]$S, $Resolved, [string]$OutPath, [string]$Id)

    if (-not $Id) { $Id = [Guid]::NewGuid().ToString('N') }
    $segs  = $Resolved.segs
    $span  = $Resolved.span
    $first = $Resolved.first
    $used  = $Resolved.used
    $multi = $Resolved.multi
    $crop  = $Resolved.crop
    $snd   = $Resolved.snd

    $prog = Join-Path $S.CacheDir "prog_$Id.txt"
    $log  = Join-Path $S.CacheDir "log_$Id.txt"
    $filt = ''
    $filterText = ''

    $tmpOut = $OutPath + '.svtpart'

    $oddSrc = $false
    foreach ($tk in $used) {
        if (([int]$S.Files[$tk].width % 2) -or ([int]$S.Files[$tk].height % 2)) { $oddSrc = $true }
    }
    $evenFix = 'scale=trunc(iw/2)*2:trunc(ih/2)*2'

    $encArgs = @(
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
        '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '192k',
        '-movflags', '+faststart',
        '-f', 'mp4',            # the sidecar has no .mp4 extension to infer from
        $tmpOut
    )

    if ($segs.Count -eq 1 -and -not $segs[0].r) {
        $kind = 'fast'
        $vf = ''
        if ($crop) {
            $vf = Get-SvtCropFilter $crop ([int]$segs[0].info.width) ([int]$segs[0].info.height)
        } elseif ($oddSrc) {
            $vf = $evenFix
        }
        $sndIn  = $(if ($snd) { @('-stream_loop', '-1', '-i', $snd.path) } else { @() })
        $sndMap = $(if ($snd) { @('-map', '1:a:0') }
                    elseif ($segs[0].m) { @('-an') }
                    else { @('-map', '0:a:0?') })
        $ffArgs = @(
            '-y', '-hide_banner', '-nostats',
            '-progress', $prog,
            '-ss', (Num $segs[0].s '0.###'),
            '-i',  $segs[0].info.path
        ) + $sndIn + @(
            '-t',  (Num $span '0.###'),
            '-map', '0:v:0'
        ) + $sndMap + $(if ($vf) { @('-vf', $vf) } else { @() }) + $encArgs
    } else {
        $kind = $(if ($multi) { 'concat-multi' } else { 'concat-single' })
        $filt = Join-Path $S.CacheDir "filter_$Id.txt"

        $tw = [int]$first.width; $th = [int]$first.height
        $tf = [double]$first.fps
        if ($tw -lt 2) { $tw = 2 }; if ($th -lt 2) { $th = 2 }
        if ($tf -le 0) { $tf = 25.0 }
        # x264 needs even dimensions for yuv420p
        if ($tw % 2) { $tw += 1 }
        if ($th % 2) { $th += 1 }
        $vfit = ''
        if ($multi) {
            $vfit = ",scale=${tw}:${th}:force_original_aspect_ratio=decrease" +
                    ",pad=${tw}:${th}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=$(Num $tf '0.###')"
        } elseif ($oddSrc -and -not $crop) {
            $vfit = ",$evenFix"
        }
        $afit = $(if ($multi) { ',aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo' } else { '' })

        $anyAudio = $false
        foreach ($sg in $segs) { if ($sg.info.hasAudio -and -not $sg.m) { $anyAudio = $true } }
        if ($snd) { $anyAudio = $false }

        $inArgs = @()
        $slot   = @{}
        $n      = 0
        foreach ($tk in $used) {
            $slot[$tk] = $n
            $inArgs += @('-i', $S.Files[$tk].path)
            $n++
        }

        $sb = New-Object Text.StringBuilder
        $chain = ''
        for ($i = 0; $i -lt $segs.Count; $i++) {
            $sg = $segs[$i]
            $s0 = Num $sg.s '0.###'
            $e0 = Num $sg.e '0.###'
            $ix = $slot[$sg.tok]
            [void]$sb.Append("[${ix}:v]trim=start=${s0}:end=${e0},setpts=PTS-STARTPTS$(if ($sg.r) { ',reverse' })${vfit}[v$i];`n")
            $chain += "[v$i]"
            if ($anyAudio) {
                if ($sg.info.hasAudio -and -not $sg.m) {
                    [void]$sb.Append("[${ix}:a]atrim=start=${s0}:end=${e0},asetpts=PTS-STARTPTS$(if ($sg.r) { ',areverse' })${afit}[a$i];`n")
                } else {
                    $len = Num ($sg.e - $sg.s) '0.###'
                    $inArgs += @('-f', 'lavfi', '-t', $len, '-i', 'anullsrc=r=48000:cl=stereo')
                    [void]$sb.Append("[${n}:a]atrim=start=0:end=${len},asetpts=PTS-STARTPTS${afit}[a$i];`n")
                    $n++
                }
                $chain += "[a$i]"
            }
        }
        $vend = $(if ($crop) { '[vcat]' } else { '[vout]' })
        if ($anyAudio) {
            [void]$sb.Append($chain + "concat=n=$($segs.Count):v=1:a=1${vend}[aout]")
        } else {
            [void]$sb.Append($chain + "concat=n=$($segs.Count):v=1:a=0${vend}")
        }
        if ($crop) {
            $cfw = $(if ($multi) { $tw } else { [int]$S.Files[$used[0]].width })
            $cfh = $(if ($multi) { $th } else { [int]$S.Files[$used[0]].height })
            [void]$sb.Append(";`n[vcat]" + (Get-SvtCropFilter $crop $cfw $cfh) + "[vout]")
        }
        $filterText = $sb.ToString()
        [IO.File]::WriteAllText($filt, $filterText, (New-Object Text.UTF8Encoding $false))

        if ($snd) {
            $sndIx   = $n
            $inArgs += @('-stream_loop', '-1', '-i', $snd.path)
            $mapArgs = @('-map', '[vout]', '-map', "${sndIx}:a:0", '-t', (Num $span '0.###'))
        } else {
            $mapArgs = $(if ($anyAudio) { @('-map', '[vout]', '-map', '[aout]') }
                         else { @('-map', '[vout]', '-an') })
        }
        $ffArgs = @(
            '-y', '-hide_banner', '-nostats',
            '-progress', $prog
        ) + $inArgs + @(
            '-filter_complex_script', $filt
        ) + $mapArgs + $encArgs
    }

    # ffmpeg is launched directly now, so this is the real argument string the
    # child re-splits - no shell, and therefore no %VAR% expansion
    $cmdLine = (($ffArgs | ForEach-Object { Quote-SvtArg $_ }) -join ' ')

    @{ id = $Id; prog = $prog; log = $log; filt = $filt; filterText = $filterText
       ffArgs = $ffArgs; cmdLine = $cmdLine; kind = $kind; out = $OutPath; span = $span
       parts = $segs.Count; tmp = $tmpOut }
}

# =============================================================================
#  Start-SvtExport  <- /api/save lines 2319-2335
# =============================================================================
function Start-SvtExport {
    param([hashtable]$S, $Plan)
    # app line 2322-2329
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName              = $S.FFmpeg
    $psi.Arguments             = $Plan.cmdLine
    $psi.UseShellExecute       = $false
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow        = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $logFs = [IO.File]::Create($Plan.log)
    $null = $proc.StandardError.BaseStream.CopyToAsync($logFs)
    $job = @{
        state = 'running'; percent = 0.0; proc = $proc; prog = $Plan.prog; log = $Plan.log
        out = $Plan.out; outName = [IO.Path]::GetFileName($Plan.out); span = $Plan.span
        error = ''; kind = 'save'; filt = $Plan.filt; parts = $Plan.parts
        tmp = $Plan.tmp; logFs = $logFs
    }
    $S.Jobs[$Plan.id] = $job
    return $job
}

# --- app: /api/job progress block (lines 2343-2358) --------------------------
function Get-SvtJobPercent {
    param($Job)
    if (Test-Path -LiteralPath $Job.prog) {
        try {
            $fs  = [IO.File]::Open($Job.prog, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                   [IO.FileShare]::ReadWrite)
            $txt = (New-Object IO.StreamReader($fs)).ReadToEnd()
            $fs.Dispose()
            $m = [regex]::Matches($txt, 'out_time=(\d+):(\d+):(\d+(?:\.\d+)?)')
            if ($m.Count -gt 0) {
                $g = $m[$m.Count - 1].Groups
                $done = [double]$g[1].Value * 3600 + [double]$g[2].Value * 60 +
                        [double]::Parse($g[3].Value, $script:Inv)
                $Job.percent = [math]::Min(99.0, $done / $Job.span * 100.0)
            }
        } catch { }
    }
    return $Job.percent
}

# --- app: /api/job completion block (lines 2359-2377) ------------------------
function Complete-SvtJob {
    param($Job)
    if ($Job.state -ne 'running') { return $Job.state }
    if (-not $Job.proc.HasExited) { return 'running' }
    $code = $Job.proc.ExitCode
    if ($null -eq $code) { $code = -1 }
    if ($Job.logFs) { try { $Job.logFs.Dispose() } catch { }; $Job.logFs = $null }
    $made = $(if ($Job.tmp) { $Job.tmp } else { $Job.out })
    if ($code -eq 0 -and (Test-Path -LiteralPath $made)) {
        $moved = $true
        if ($Job.tmp) {
            try { Move-Item -LiteralPath $Job.tmp -Destination $Job.out -Force }
            catch { $moved = $false; $Job.state = 'failed'
                    $Job.error = "Could not write $($Job.outName): $($_.Exception.Message)" }
        }
        if ($moved) { $Job.state = 'done'; $Job.percent = 100.0 }
    } else {
        $tail = ''
        try {
            $lines = Get-Content -LiteralPath $Job.log -ErrorAction SilentlyContinue |
                     Where-Object { $_.Trim() } | Select-Object -Last 3
            $tail = ($lines -join ' | ')
        } catch { }
        if (-not $tail) { $tail = "ffmpeg exited with code $code" }
        $Job.state = 'failed'; $Job.error = $tail
    }
    if ($Job.tmp) { Remove-Item -LiteralPath $Job.tmp -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $Job.prog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Job.log  -Force -ErrorAction SilentlyContinue
    if ($Job.filt) { Remove-Item -LiteralPath $Job.filt -Force -ErrorAction SilentlyContinue }
    return $Job.state
}

# =============================================================================
#  Convenience: run a whole export the way the browser drives it - start, poll
#  /api/job every 100ms, then read the terminal state.
# =============================================================================
function Invoke-SvtExport {
    param([hashtable]$S, $Resolved, [string]$OutPath, [int]$TimeoutSec = 180,
          [switch]$KeepArtifacts)

    $plan = New-SvtExportPlan -S $S -Resolved $Resolved -OutPath $OutPath
    $job  = Start-SvtExport -S $S -Plan $plan
    $sw   = [Diagnostics.Stopwatch]::StartNew()
    $pcts = New-Object System.Collections.ArrayList
    while ($true) {
        [void]$pcts.Add((Get-SvtJobPercent $job))
        $st = Complete-SvtJob $job
        if ($st -ne 'running') { break }
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            try { $job.proc.Kill() } catch { }
            $job.state = 'failed'; $job.error = 'timed out'
            break
        }
        Start-Sleep -Milliseconds 100
    }
    @{ plan = $plan; job = $job; state = $job.state; error = $job.error
       percents = @($pcts); seconds = $sw.Elapsed.TotalSeconds }
}

# The cleanup sweep from the very bottom of the app (lines 2473-2476).
function Invoke-SvtShutdownSweep {
    param([hashtable]$S)
    foreach ($pat in @('prog_*.txt', 'log_*.txt', 'filter_*.txt', 'frame_*.jpg')) {
        Get-ChildItem -LiteralPath $S.CacheDir -Filter $pat -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}
