# =============================================================================
#  fixtures.ps1 - adversarial test clips for the export/save path
# =============================================================================
#  Generates a small, CACHED set of clips with ffmpeg into a temp directory
#  (never into the repo). Re-running is cheap: everything is skipped when the
#  manifest for $FixtureVersion already matches what is on disk.
#
#  Every clip is SELF-IDENTIFYING in two independent ways:
#
#   1. A flat colour patch fills the whole frame and changes once per second.
#      The colour encodes (source, second):
#          level = 40 + 30 * floor(t)      -> which second of the source
#          which channels are hot          -> which source file
#      A test can therefore sample one pixel of the exported video and prove
#      exactly which source and which source-timestamp landed there.
#          A red   (L,0,0)     B green (0,L,0)   C blue  (0,0,L)
#          D yellow(L,L,0)     E magenta(L,0,L)  F cyan  (0,L,L)
#          G grey  (L,L,L)
#
#   2. A burnt-in "A0 A1 A2 ..." counter in the bottom-left corner, so a human
#      opening the output can see the same thing. The counter is deliberately
#      kept OUT of the sampling region (top-centre) used by Get-FixturePixel.
#
#  Audio, where present, is a continuous sine at a per-source frequency.
# =============================================================================

# NOTE: ErrorActionPreference is deliberately left alone. 'Stop' would turn
# ffmpeg's stderr chatter into terminating errors once 2>&1 is in play.

# Bump this whenever a fixture definition changes - it invalidates the cache.
$script:FixtureVersion = 'v4'

$script:FixtureRoot = Join-Path $env:TEMP ('svt_export_fixtures\' + $script:FixtureVersion)

# The sampling window used to read a fixture's identifying colour. Top-centre,
# well clear of the burnt-in counter in the bottom-left.
$script:SampleBox = @{ W = 40; H = 40; XFrac = 0.5; YFrac = 0.12 }

function Get-FixtureRoot { $script:FixtureRoot }

function Get-FFTool([string]$name) {
    $c = Get-Command "$name.exe" -ErrorAction SilentlyContinue
    if (-not $c) { throw "$name.exe is not on PATH." }
    return $c.Source
}

$script:FFmpeg  = Get-FFTool 'ffmpeg'
$script:FFprobe = Get-FFTool 'ffprobe'

function Get-FFmpegPath  { $script:FFmpeg }
function Get-FFprobePath { $script:FFprobe }

# ---------------------------------------------------------------- helpers --

function script:Invoke-FF([string[]]$ffArgs) {
    $out = & $script:FFmpeg @ffArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("ffmpeg failed ({0}):`n{1}" -f $LASTEXITCODE, (($out | Select-Object -Last 12) -join "`n"))
    }
}

# level = 40 + 30*second, painted as a full-frame drawbox gated on that second.
function script:Get-ColourChain([int]$w, [int]$h, [double]$dur, [string]$family) {
    $parts = @()
    $secs  = [int][math]::Ceiling($dur)
    for ($k = 0; $k -lt $secs; $k++) {
        $L = 40 + 30 * $k
        if ($L -gt 250) { $L = 250 }
        $hx = '{0:x2}' -f $L
        $zz = '00'
        switch ($family) {
            'red'     { $rgb = "$hx$zz$zz" }
            'green'   { $rgb = "$zz$hx$zz" }
            'blue'    { $rgb = "$zz$zz$hx" }
            'yellow'  { $rgb = "$hx$hx$zz" }
            'magenta' { $rgb = "$hx$zz$hx" }
            'cyan'    { $rgb = "$zz$hx$hx" }
            'grey'    { $rgb = "$hx$hx$hx" }
            default   { throw "unknown colour family '$family'" }
        }
        $parts += "drawbox=x=0:y=0:w=${w}:h=${h}:color=0x${rgb}:t=fill:enable='between(t,$k,$($k+1))'"
    }
    return ($parts -join ',')
}

function script:Get-CounterChain([string]$tag, [int]$h) {
    $fs = [int][math]::Max(18, [math]::Round($h / 6.0))
    return ("drawtext=fontfile='C\:/Windows/Fonts/arialbd.ttf':text='${tag}%{eif\:trunc(t)\:d}'" +
            ":fontsize=${fs}:fontcolor=white:box=1:boxcolor=black:x=20:y=h-th-20")
}

function script:New-Clip {
    param(
        [string]$Path, [int]$W, [int]$H, [double]$Fps, [double]$Dur,
        [string]$Family, [string]$Tag,
        [int]$AudioFreq = 0, [int]$AudioRate = 48000, [int]$AudioCh = 2,
        [string]$PixFmt = 'yuv420p', [int]$OutW = 0, [int]$OutH = 0
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $vf = (script:Get-ColourChain $W $H $Dur $Family) + ',' + (script:Get-CounterChain $Tag $H)
    # lavfi's `color` source silently rounds to even dimensions, so an odd-sized
    # fixture has to be scaled up at the tail of the chain instead.
    if ($OutW -gt 0 -and $OutH -gt 0) { $vf += ",scale=${OutW}:${OutH}" }
    $inv = [cultureinfo]::InvariantCulture
    $durS = [string]::Format($inv, '{0:0.###}', $Dur)
    $fpsS = [string]::Format($inv, '{0:0.###}', $Fps)

    $a = @('-y', '-v', 'error', '-f', 'lavfi', '-i', "color=c=black:s=${W}x${H}:r=${fpsS}:d=${durS}")
    if ($AudioFreq -gt 0) {
        $a += @('-f', 'lavfi', '-i', "sine=frequency=${AudioFreq}:r=${AudioRate}:d=${durS}")
    }
    $a += @('-vf', $vf, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '16',
            '-pix_fmt', $PixFmt, '-g', '25')
    if ($AudioFreq -gt 0) {
        $a += @('-c:a', 'aac', '-b:a', '128k', '-ar', "$AudioRate", '-ac', "$AudioCh")
    } else {
        $a += @('-an')
    }
    $a += @('-t', $durS, $Path)
    script:Invoke-FF $a
}

# -------------------------------------------------------------- the clips --

# NOTE: the hostile name exercises everything Windows legally allows that cmd.exe
# or a filter parser might choke on:  %VAR%  &  ^  !  ( )  ,  ;  =  space  unicode
$script:HostileName = 'my %PATH% clip & (test)^ ok! a,b;c=d 日本.mp4'
# Same set MINUS the percent signs - the control that proves % is the culprit.
$script:TameOddName = 'my clip & (test)^ ok! a,b;c=d 日本.mp4'

function script:Get-FixtureSpecs {
    $root = $script:FixtureRoot
    # a directory chain that puts the file at ~245 chars, just under MAX_PATH
    $deep = $root
    foreach ($seg in @('deep_directory_level_one_padding_padding',
                       'deep_directory_level_two_padding_padding',
                       'deep_directory_level_three_padding_pad')) {
        $deep = Join-Path $deep $seg
    }

    @(
        @{ Key='A'; Path=(Join-Path $root 'A_16x9_audio.mp4');    W=640; H=360; Fps=25; Dur=6.0;
           Family='red';     Tag='A'; AudioFreq=440; AudioRate=48000; AudioCh=2; PixFmt='yuv420p'
           Note='16:9, stereo 48k audio, 25fps - the usual track 1' }

        @{ Key='B'; Path=(Join-Path $root 'B_4x3_silent.mp4');    W=480; H=360; Fps=25; Dur=6.0;
           Family='green';   Tag='B'; AudioFreq=0;  AudioRate=48000; AudioCh=2; PixFmt='yuv420p'
           Note='4:3 with NO audio - pillarbox + silence-substitution source' }

        @{ Key='C'; Path=(Join-Path $root 'C_mono_44100.mp4');    W=640; H=360; Fps=30; Dur=5.0;
           Family='blue';    Tag='C'; AudioFreq=660; AudioRate=44100; AudioCh=1; PixFmt='yuv420p'
           Note='odd sample rate + mono + 30fps - audio/fps normalisation source' }

        @{ Key='D'; Path=(Join-Path $root 'D_veryshort.mp4');     W=640; H=360; Fps=25; Dur=0.6;
           Family='yellow';  Tag='D'; AudioFreq=880; AudioRate=48000; AudioCh=2; PixFmt='yuv420p'
           Note='shorter than one second' }

        @{ Key='E'; Path=(Join-Path $root 'E_odd_641x361.mp4');   W=640; H=360; Fps=25; Dur=3.0;
           OutW=641; OutH=361;
           Family='magenta'; Tag='E'; AudioFreq=0;  AudioRate=48000; AudioCh=2; PixFmt='yuv444p'
           Note='ODD 641x361 pixel dimensions - exercises even-dimension rounding' }

        @{ Key='F'; Path=(Join-Path $root $script:HostileName);   W=640; H=360; Fps=25; Dur=4.0;
           Family='cyan';    Tag='F'; AudioFreq=1000; AudioRate=48000; AudioCh=2; PixFmt='yuv420p'
           Note='HOSTILE filename: % & ^ ! ( ) , ; = space unicode' }

        @{ Key='G'; Path=(Join-Path $deep 'G_deep_long_path_fixture_clip_padded_out_to_sit_just_under_max_path.mp4');
           W=640; H=360; Fps=25; Dur=3.0;
           Family='grey';    Tag='G'; AudioFreq=1200; AudioRate=48000; AudioCh=2; PixFmt='yuv420p'
           Note='path close to MAX_PATH' }

        @{ Key='T'; Path=(Join-Path $root $script:TameOddName);   W=640; H=360; Fps=25; Dur=3.0;
           Family='red';     Tag='T'; AudioFreq=440; AudioRate=48000; AudioCh=2; PixFmt='yuv420p'
           Note='same punctuation as F but WITHOUT % - the control clip' }
    )
}

<#
.SYNOPSIS
Builds (or reuses) the fixture clips and returns a hashtable Key -> full path.
.PARAMETER Force
Delete and rebuild everything.
#>
function New-Fixtures {
    param([switch]$Force)

    $root = $script:FixtureRoot
    if ($Force -and (Test-Path -LiteralPath $root)) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }

    $specs = script:Get-FixtureSpecs
    $map   = @{}
    $built = 0
    foreach ($sp in $specs) {
        $map[$sp.Key] = $sp.Path
        if (Test-Path -LiteralPath $sp.Path) {
            if ((Get-Item -LiteralPath $sp.Path).Length -gt 1024) { continue }
        }
        $ow = 0; $oh = 0
        if ($sp.Contains('OutW')) { $ow = [int]$sp.OutW; $oh = [int]$sp.OutH }
        script:New-Clip -Path $sp.Path -W $sp.W -H $sp.H -Fps $sp.Fps -Dur $sp.Dur `
                        -Family $sp.Family -Tag $sp.Tag -AudioFreq $sp.AudioFreq `
                        -AudioRate $sp.AudioRate -AudioCh $sp.AudioCh -PixFmt $sp.PixFmt `
                        -OutW $ow -OutH $oh
        $built++
    }
    if ($built -gt 0) { Write-Host "   (built $built fixture clip(s) in $root)" -ForegroundColor DarkGray }
    return $map
}

function Get-FixtureSpec([string]$Key) {
    foreach ($sp in (script:Get-FixtureSpecs)) { if ($sp.Key -eq $Key) { return $sp } }
    throw "no fixture '$Key'"
}

function Get-HostileFixtureName { $script:HostileName }
function Get-TameFixtureName    { $script:TameOddName }

# ----------------------------------------------------- readback utilities --

<#
.SYNOPSIS
Samples the identifying colour of a video at time $At. Returns @{R;G;B}.
Averages a small top-centre box, well away from the burnt-in counter.
#>
function Get-FixturePixel {
    param([string]$Path, [double]$At)
    $inv = [cultureinfo]::InvariantCulture
    $tmp = [IO.Path]::Combine($env:TEMP, 'svt_px_' + [Guid]::NewGuid().ToString('N') + '.raw')
    $box = $script:SampleBox
    $vf  = "crop=$($box.W):$($box.H):(iw-$($box.W))*$($box.XFrac):ih*$($box.YFrac)," +
           "scale=1:1:flags=area,format=rgb24"
    try {
        $null = & $script:FFmpeg -y -v error -ss ([string]::Format($inv, '{0:0.######}', $At)) `
                    -i $Path -frames:v 1 -vf $vf -f rawvideo $tmp 2>&1
        if (-not (Test-Path -LiteralPath $tmp)) { return $null }
        $b = [IO.File]::ReadAllBytes($tmp)
        if ($b.Length -lt 3) { return $null }
        return @{ R = [int]$b[0]; G = [int]$b[1]; B = [int]$b[2] }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
Decodes a sampled pixel back into @{Family; Second} - i.e. WHICH source clip and
WHICH second of it that frame came from. Returns $null when it does not decode.
#>
function Resolve-FixturePixel {
    param($Px, [int]$Tol = 14)
    if ($null -eq $Px) { return $null }
    $hot = @()
    foreach ($c in 'R', 'G', 'B') { if ($Px[$c] -ge 25) { $hot += $c } }
    $fam = switch (($hot -join '')) {
        'R'   { 'red' }
        'G'   { 'green' }
        'B'   { 'blue' }
        'RG'  { 'yellow' }
        'RB'  { 'magenta' }
        'GB'  { 'cyan' }
        'RGB' { 'grey' }
        default { $null }
    }
    if (-not $fam) { return @{ Family = 'black'; Second = -1; Px = $Px } }
    $lvls = @(); foreach ($c in $hot) { $lvls += $Px[$c] }
    $L = ($lvls | Measure-Object -Average).Average
    $sec = [int][math]::Round(($L - 40) / 30.0)
    if ([math]::Abs(($L - (40 + 30 * $sec))) -gt $Tol) { return @{ Family = $fam; Second = -1; Px = $Px } }
    return @{ Family = $fam; Second = $sec; Px = $Px }
}

function Get-FamilyForKey([string]$Key) { (Get-FixtureSpec $Key).Family }

<#
.SYNOPSIS
Averages an arbitrary WxH region at (X,Y) of the frame at time $At and returns
@{R;G;B}. Used to prove letterbox/pillarbox bars are genuinely black.
#>
function Get-RegionRgb {
    param([string]$Path, [double]$At, [int]$W, [int]$H, [int]$X, [int]$Y)
    $inv = [cultureinfo]::InvariantCulture
    $tmp = [IO.Path]::Combine($env:TEMP, 'svt_rgb_' + [Guid]::NewGuid().ToString('N') + '.raw')
    try {
        $null = & $script:FFmpeg -y -v error -ss ([string]::Format($inv, '{0:0.######}', $At)) `
                    -i $Path -frames:v 1 `
                    -vf "crop=${W}:${H}:${X}:${Y},scale=1:1:flags=area,format=rgb24" `
                    -f rawvideo $tmp 2>&1
        if (-not (Test-Path -LiteralPath $tmp)) { return @{ R = -1; G = -1; B = -1 } }
        $b = [IO.File]::ReadAllBytes($tmp)
        if ($b.Length -lt 3) { return @{ R = -1; G = -1; B = -1 } }
        return @{ R = [int]$b[0]; G = [int]$b[1]; B = [int]$b[2] }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
Mean volume (dB) of a time window. -91 dB (or lower) means digital silence.
Returns $null when the file has no audio at all.
#>
function Get-MeanVolumeDb {
    param([string]$Path, [double]$Start = 0.0, [double]$Duration = 0.0)
    $inv = [cultureinfo]::InvariantCulture
    $a = @('-hide_banner', '-v', 'info', '-ss', [string]::Format($inv, '{0:0.###}', $Start))
    if ($Duration -gt 0) { $a += @('-t', [string]::Format($inv, '{0:0.###}', $Duration)) }
    $a += @('-i', $Path, '-map', '0:a:0?', '-af', 'volumedetect', '-f', 'null', '-')
    $out = & $script:FFmpeg @a 2>&1
    $m = [regex]::Match(($out -join "`n"), 'mean_volume:\s*(-?[\d.]+|-inf) dB')
    if (-not $m.Success) { return $null }
    if ($m.Groups[1].Value -eq '-inf') { return -200.0 }
    return [double]::Parse($m.Groups[1].Value, $inv)
}

function Get-ProbeJson([string]$Path) {
    $raw = & $script:FFprobe -v error -print_format json -show_format -show_streams $Path 2>$null
    if (-not $raw) { return $null }
    return (($raw -join "`n") | ConvertFrom-Json)
}

function Get-VideoDuration([string]$Path) {
    $j = Get-ProbeJson $Path
    if (-not $j) { return -1.0 }
    $inv = [cultureinfo]::InvariantCulture
    $d = 0.0
    if ($j.format.duration -and [double]::TryParse([string]$j.format.duration,
            [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return $d }
    return -1.0
}

function Get-StreamInfo([string]$Path) {
    $j = Get-ProbeJson $Path
    if (-not $j) { return $null }
    $v = $j.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $a = $j.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
    $fps = 0.0
    if ($v -and $v.avg_frame_rate -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -ne 0) {
        $fps = [double]$Matches[1] / [double]$Matches[2]
    }
    [pscustomobject]@{
        Width      = $(if ($v) { [int]$v.width } else { 0 })
        Height     = $(if ($v) { [int]$v.height } else { 0 })
        Fps        = [math]::Round($fps, 3)
        PixFmt     = $(if ($v) { [string]$v.pix_fmt } else { '' })
        HasAudio   = [bool]$a
        SampleRate = $(if ($a) { [int]$a.sample_rate } else { 0 })
        Channels   = $(if ($a) { [int]$a.channels } else { 0 })
        Duration   = Get-VideoDuration $Path
    }
}
