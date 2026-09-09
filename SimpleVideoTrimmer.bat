@echo off
setlocal EnableExtensions
title Simple Video Trimmer
cd /d "%~dp0"
set "SVT_PS1=%TEMP%\SimpleVideoTrimmer.ps1"
rem %~dp0 ends in a backslash, which would escape the closing quote below
set "SVT_DIR=%~dp0"
if "%SVT_DIR:~-1%"=="\" set "SVT_DIR=%SVT_DIR:~0,-1%"
echo.
echo   ======================================
echo    Simple Video Trimmer
echo   ======================================
echo.
echo   Starting the local server...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$m='#==='+'PS==='; $s=[IO.File]::ReadAllText('%~f0'); $i=$s.IndexOf($m); if($i -lt 0){ Write-Host '   Could not find the script marker.'; exit 2 }; [IO.File]::WriteAllText($env:SVT_PS1, $s.Substring($i+$m.Length), (New-Object Text.UTF8Encoding $false))"
if errorlevel 1 goto fail
powershell -NoProfile -ExecutionPolicy Bypass -File "%SVT_PS1%" -AppDir "%SVT_DIR%"
set "RC=%ERRORLEVEL%"
del "%SVT_PS1%" >nul 2>&1
if not "%RC%"=="0" (
  echo.
  echo   The app stopped. Exit code: %RC%
  echo   If there is a message above, that explains why.
  echo.
  pause
)
exit /b 0

:fail
echo.
echo   Setup failed - see the message above.
echo.
pause
exit /b 1

#===PS===
param([string]$AppDir = "$PSScriptRoot")

# Guard against a stray quote or trailing slash arriving from the batch wrapper.
$AppDir = ($AppDir -replace '"', '').TrimEnd([char]92)
if ([string]::IsNullOrWhiteSpace($AppDir) -or -not (Test-Path -LiteralPath $AppDir)) {
    $AppDir = (Get-Location).Path
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing       | Out-Null

function Write-Step($m) { Write-Host "   $m" -ForegroundColor Gray }
function Write-Ok  ($m) { Write-Host "   $m" -ForegroundColor Green }
function Write-Bad ($m) { Write-Host "   $m" -ForegroundColor Red }

# ------------------------------------------------------------------ ffmpeg --

function Resolve-Tool([string]$name) {
    $local = Join-Path $AppDir "ffmpeg\bin\$name.exe"
    if (Test-Path -LiteralPath $local) { return (Resolve-Path -LiteralPath $local).Path }
    $cmd = Get-Command "$name.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# The exact build this app was tested against. Publishers prune old artifacts,
# so a hard pin WILL 404 eventually - hence pinned first, rolling as a fallback.
$PinnedVersion = '9.0.1'
$PinnedSha256  = 'FEC81AE03971D9DD4BE3EBE02E263BD2EC1D789483F931BDBA5F5715E65DA2E9'

# Every ffmpeg switch this app uses (-ss before -i for accurate seeks, -progress,
# -movflags +faststart, scale/force_original_aspect_ratio, optional -map 0:a:0?)
# has been stable since 4.0, so that is the floor we enforce.
$MinFFmpegMajor = 4

function Get-FFmpegVersion([string]$exe) {
    try { $line = (& $exe -version 2>$null | Select-Object -First 1) } catch { return $null }
    if (-not $line) { return $null }
    $m = [regex]::Match([string]$line, 'ffmpeg version n?(\d+)\.(\d+)')
    if ($m.Success) {
        return [pscustomobject]@{ Major = [int]$m.Groups[1].Value
                                  Minor = [int]$m.Groups[2].Value
                                  Text  = ([string]$line).Trim() }
    }
    # git/nightly builds report like "N-12345-gabcdef" - unparseable, assume current
    return [pscustomobject]@{ Major = 0; Minor = 0; Text = ([string]$line).Trim() }
}

function Get-RemoteSha256([string]$url) {
    try {
        $t = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content
        $m = [regex]::Match([string]$t, '[0-9a-fA-F]{64}')
        if ($m.Success) { return $m.Value.ToUpperInvariant() }
    } catch { }
    return $null
}

function Install-FFmpeg {
    $dest = Join-Path $AppDir 'ffmpeg\bin'
    $zip  = Join-Path $env:TEMP 'svt_ffmpeg.zip'

    $sources = @(
        @{ Name = "pinned $PinnedVersion"
           Url  = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-$PinnedVersion-essentials_build.zip"
           Sha  = $PinnedSha256; ShaUrl = $null },
        @{ Name = 'current gyan.dev release'
           Url  = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
           Sha  = $null; ShaUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256' },
        @{ Name = 'BtbN build'
           Url  = 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
           Sha  = $null; ShaUrl = $null }
    )

    Write-Host ''
    Write-Step 'ffmpeg was not found on this PC.'
    Write-Step "Downloading a portable copy - about 90 MB - into the folder beside this app."
    Write-Step 'This happens once. No admin rights, nothing installed system-wide.'
    Write-Host ''

    $got = $false
    foreach ($src in $sources) {
        try {
            Write-Step "Trying the $($src.Name)..."
            if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
            try   { Start-BitsTransfer -Source $src.Url -Destination $zip -Description 'ffmpeg' -ErrorAction Stop }
            catch { Invoke-WebRequest -Uri $src.Url -OutFile $zip -UseBasicParsing }

            $want = $src.Sha
            if (-not $want -and $src.ShaUrl) { $want = Get-RemoteSha256 $src.ShaUrl }
            if ($want) {
                $have = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($have -ne $want) {
                    Write-Bad "checksum mismatch - discarding this download"
                    Write-Bad "  expected $want"
                    Write-Bad "  got      $have"
                    continue
                }
                Write-Step '  checksum verified.'
            } else {
                Write-Step '  no published checksum for this source; skipping verification.'
            }
            $got = $true
            break
        } catch {
            Write-Bad "failed: $($_.Exception.Message)"
        }
    }
    if (-not $got) {
        throw 'Could not download ffmpeg. Check your internet connection, or install ffmpeg yourself and put it on PATH.'
    }

    Write-Step 'Unpacking...'
    $tmp = Join-Path $env:TEMP ('svt_ffmpeg_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp  -Force | Out-Null
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force

    foreach ($exe in @('ffmpeg.exe', 'ffprobe.exe')) {
        $found = Get-ChildItem -LiteralPath $tmp -Recurse -Filter $exe -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if (-not $found) { throw "The downloaded archive did not contain $exe." }
        Copy-Item -LiteralPath $found.FullName -Destination (Join-Path $dest $exe) -Force
    }

    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Write-Ok 'ffmpeg is ready.'
}

$FFmpeg  = Resolve-Tool 'ffmpeg'
$FFprobe = Resolve-Tool 'ffprobe'
if (-not $FFmpeg -or -not $FFprobe) {
    Install-FFmpeg
    $FFmpeg  = Resolve-Tool 'ffmpeg'
    $FFprobe = Resolve-Tool 'ffprobe'
}
if (-not $FFmpeg -or -not $FFprobe) { throw 'ffmpeg is still unavailable after setup.' }

$ver = Get-FFmpegVersion $FFmpeg
if (-not $ver) { throw "Found $FFmpeg but it would not run. Delete the ffmpeg folder beside this app and try again." }
if ($ver.Major -gt 0 -and $ver.Major -lt $MinFFmpegMajor) {
    Write-Bad "ffmpeg $($ver.Major).$($ver.Minor) is older than $MinFFmpegMajor.0 and may trim inaccurately."
    Write-Bad 'Remove it from PATH and let this app download its own copy, or upgrade ffmpeg.'
    Write-Host ''
}
$verText = $(if ($ver.Major -gt 0) { "v$($ver.Major).$($ver.Minor)" } else { 'git build' })
Write-Ok "ffmpeg:  $FFmpeg  ($verText)"

# ------------------------------------------------------------ shared state --

$CacheDir = Join-Path $env:TEMP 'SimpleVideoTrimmer'
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

$S = [hashtable]::Synchronized(@{
    FFmpeg    = $FFmpeg
    FFprobe   = $FFprobe
    CacheDir  = $CacheDir
    Key       = [Guid]::NewGuid().ToString('N')
    Files     = [hashtable]::Synchronized(@{})
    Jobs      = [hashtable]::Synchronized(@{})
    Audio     = [hashtable]::Synchronized(@{})
    Running   = $true
    LastDir   = ''
    Listener  = $null
    TileCount = 48
    TileW     = 160
    TileH     = 90
    Html      = ''
})

# -------------------------------------------------------------------- HTML --

$S.Html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Simple Video Trimmer</title>
<style>
  :root{
    --bg:#0e1116; --panel:#161b22; --panel2:#1c232d; --line:#2a3441;
    --text:#e6edf3; --dim:#8b98a5; --accent:#4da3ff; --accent2:#2f6fd0;
    --good:#3fb950; --warn:#d29922; --bad:#f85149;
  }
  *{box-sizing:border-box}
  html,body{height:100%}
  body{
    margin:0;background:var(--bg);color:var(--text);
    font:14px/1.45 "Segoe UI",system-ui,-apple-system,sans-serif;
    display:flex;flex-direction:column;overflow:hidden;
  }
  button{font:inherit;color:var(--text);background:var(--panel2);border:1px solid var(--line);
    border-radius:7px;padding:7px 12px;cursor:pointer;display:inline-flex;align-items:center;gap:7px}
  button:hover:not(:disabled){background:#243040;border-color:#3b4a5c}
  button:active:not(:disabled){transform:translateY(1px)}
  button:disabled{opacity:.4;cursor:not-allowed}
  button.primary{background:var(--accent2);border-color:var(--accent2)}
  button.primary:hover:not(:disabled){background:#3a80e6;border-color:#3a80e6}
  button.ghost{background:transparent}
  input[type=text]{font:13px/1 "Consolas","Cascadia Mono",monospace;color:var(--text);
    background:#0b0f14;border:1px solid var(--line);border-radius:6px;padding:8px 9px;width:118px;text-align:center}
  input[type=text]:focus{outline:none;border-color:var(--accent)}
  svg{width:15px;height:15px;fill:currentColor;flex:none}

  header{display:flex;align-items:center;gap:12px;padding:10px 14px;background:var(--panel);
    border-bottom:1px solid var(--line);flex:none}
  .brand{font-weight:600;letter-spacing:.2px;margin-right:4px;white-space:nowrap}
  .brand span{color:var(--accent)}
  .fname{color:var(--dim);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;min-width:0}
  .fname b{color:var(--text);font-weight:500}

  main{flex:1;min-height:0;display:flex;flex-direction:column;padding:14px;gap:12px}
  .stage{flex:1;min-height:0;background:#000;border:1px solid var(--line);border-radius:10px;
    display:flex;align-items:center;justify-content:center;position:relative;overflow:hidden}
  video{max-width:100%;max-height:100%;display:none;background:#000}
  .empty{text-align:center;color:var(--dim);padding:20px}
  .empty svg{width:46px;height:46px;opacity:.35;margin-bottom:10px}
  .empty h2{margin:0 0 6px;font-size:17px;font-weight:600;color:#c2cdd8}
  .empty p{margin:0 0 16px;font-size:13px}
  #frame{max-width:100%;max-height:100%;display:none;object-fit:contain}
  .notice{display:none;align-items:center;gap:10px;flex:none;font-size:12.5px;color:#d8c9a8;
    background:#211d14;border:1px solid #4a3f26;border-left:3px solid var(--warn);
    border-radius:8px;padding:8px 12px}
  .notice svg{width:15px;height:15px;color:var(--warn);flex:none}
  .notice .txt{flex:1;min-width:0}
  .chip{font:12px/1 "Consolas",monospace;white-space:nowrap;padding:5px 9px;border-radius:20px;
    border:1px solid var(--line);background:#0b0f14;color:var(--dim)}
  .chip.work{color:#8cc6ff;border-color:#2f4a68}
  .chip.done{color:var(--good);border-color:#2b5c34}
  .chip.off{color:#6c7986}
  .spin{display:inline-block;width:9px;height:9px;margin-right:6px;border-radius:50%;
    border:2px solid #2f4a68;border-top-color:#8cc6ff;animation:sp .7s linear infinite;vertical-align:-1px}
  @keyframes sp{to{transform:rotate(360deg)}}

  .panel{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px;flex:none}
  .transport{display:flex;align-items:center;gap:10px;margin-bottom:11px;flex-wrap:wrap}
  .time{font:13px/1 "Consolas","Cascadia Mono",monospace;color:var(--dim);white-space:nowrap}
  .time b{color:var(--text);font-weight:600}
  .spacer{flex:1}
  input[type=range]{width:96px;accent-color:var(--accent);background:transparent}

  .tl{position:relative;height:62px;border-radius:8px;overflow:hidden;background:#0b0f14;
    border:1px solid var(--line);cursor:pointer;touch-action:none;user-select:none}
  .tl.busy{background-image:linear-gradient(90deg,#0b0f14,#18202b,#0b0f14);
    background-size:200% 100%;animation:sh 1.4s linear infinite}
  @keyframes sh{0%{background-position:100% 0}100%{background-position:-100% 0}}
  #strip{position:absolute;left:0;right:0;top:0;bottom:0;background-repeat:no-repeat;
    background-size:100% 100%;opacity:.85}
  .shade{position:absolute;top:0;bottom:0;background:rgba(5,8,12,.72);pointer-events:none}
  .sel{position:absolute;top:0;bottom:0;border-top:2px solid var(--accent);border-bottom:2px solid var(--accent);
    background:rgba(77,163,255,.10);pointer-events:none}
  /* cuts + deleted sections: drawn over the strip, but never hit-tested -
     the timeline resolves clicks by time, so the handles keep their own events */
  #segs{position:absolute;left:0;right:0;top:0;bottom:0;z-index:3;pointer-events:none}
  #segs .cut{position:absolute;top:0;bottom:0;width:0;margin-left:-1px;border-left:2px dashed #ffe08a;
    opacity:.85;box-shadow:0 0 3px rgba(0,0,0,.8)}
  #segs .gone{position:absolute;top:0;bottom:0;background:rgba(12,6,8,.66);
    background-image:repeating-linear-gradient(45deg,transparent 0 5px,rgba(248,81,73,.30) 5px 10px)}
  #segs .gone::after{content:"";position:absolute;left:0;right:0;top:50%;height:2px;
    margin-top:-1px;background:rgba(248,81,73,.75)}
  #segs .pick{position:absolute;top:0;bottom:0;border:2px solid #ffe08a;border-radius:4px;
    background:rgba(255,224,138,.09);box-shadow:inset 0 0 10px rgba(255,224,138,.16)}
  .h{position:absolute;top:0;bottom:0;width:14px;margin-left:-7px;cursor:ew-resize;z-index:4;touch-action:none}
  .h::before{content:"";position:absolute;left:5px;top:0;bottom:0;width:4px;background:var(--accent);
    border-radius:2px;box-shadow:0 0 0 1px rgba(0,0,0,.5)}
  .h::after{content:"";position:absolute;left:2px;top:50%;margin-top:-10px;width:10px;height:20px;
    background:var(--accent);border-radius:3px;box-shadow:0 0 0 1px rgba(0,0,0,.5)}
  .h:hover::after,.h.drag::after{background:#7dc0ff}
  #hB::before,#hB::after{background:#ffb05c}
  #hB:hover::after,#hB.drag::after{background:#ffc98c}
  .ph{position:absolute;top:0;bottom:0;width:2px;margin-left:-1px;background:#fff;z-index:5;pointer-events:none;
    box-shadow:0 0 4px rgba(0,0,0,.8)}
  .ph::after{content:"";position:absolute;top:-1px;left:-4px;border:5px solid transparent;border-top-color:#fff}
  .pop{position:absolute;bottom:calc(100% + 9px);width:160px;pointer-events:none;z-index:9;display:none;
    border:1px solid var(--line);border-radius:6px;overflow:hidden;background:#000;
    box-shadow:0 8px 24px rgba(0,0,0,.6)}
  .pop .img{width:160px;height:90px;background-repeat:no-repeat}
  .pop .lab{font:11px/18px "Consolas",monospace;text-align:center;background:var(--panel2);color:var(--text)}
  .tlwrap{position:relative}
  .ruler{display:flex;justify-content:space-between;font:11px/1 "Consolas",monospace;color:#6c7986;margin-top:5px}

  .trim{display:flex;align-items:center;gap:9px;flex-wrap:wrap;margin-top:12px;
    padding-top:12px;border-top:1px solid var(--line)}
  .lab{font-size:12px;color:var(--dim);text-transform:uppercase;letter-spacing:.6px;font-weight:600}
  .lab.a{color:#63b3ff}.lab.b{color:#ffb05c}
  .grp{display:flex;align-items:center;gap:6px}
  .iconbtn{padding:7px 8px}
  /* coloured = moves the marker; grey = moves the scrubber */
  .mark,.jump{padding:7px 10px;font-size:13px}
  .mark.a{color:#8cc6ff;border-color:#2f4a68}
  .mark.b{color:#ffc186;border-color:#69492a}
  .mark.a:hover:not(:disabled){background:#1b2c3f;border-color:#3f6d9e}
  .mark.b:hover:not(:disabled){background:#33261a;border-color:#8a5f2e}
  /* split = the same yellow as the cut markers it drops on the timeline */
  .mark.cut{color:#ffe08a;border-color:#6a5a2c}
  .mark.cut:hover:not(:disabled){background:#2f2a17;border-color:#96813d}
  .mark.del{color:#ff9d96;border-color:#6d3230}
  .mark.del:hover:not(:disabled){background:#341d1c;border-color:#96413d}
  /* the START label is itself the "jump there" control */
  .labbtn{font-size:12px;text-transform:uppercase;letter-spacing:.6px;font-weight:600;
    background:transparent;border:1px solid transparent;padding:6px 8px;gap:5px}
  .labbtn svg{width:13px;height:13px;opacity:.55}
  .labbtn.a{color:#63b3ff}
  .labbtn:hover:not(:disabled){background:#1b2c3f;border-color:#2f4a68}
  .labbtn:hover:not(:disabled) svg{opacity:1}
  .sep{width:1px;height:22px;background:var(--line);margin:0 2px}
  .len{margin-left:auto;display:flex;align-items:center;gap:10px}
  .len .box{font:13px/1 "Consolas",monospace;background:#0b0f14;border:1px solid var(--line);
    border-radius:6px;padding:8px 11px;color:var(--dim);white-space:nowrap}
  .len .box b{color:var(--good)}

  .bar{position:relative;height:6px;border-radius:3px;background:#0b0f14;border:1px solid var(--line);
    overflow:hidden;width:130px;display:none}
  .bar i{position:absolute;left:0;top:0;bottom:0;right:100%;background:var(--accent);transition:right .2s}

  #toast{position:fixed;left:50%;bottom:22px;transform:translateX(-50%);z-index:50;
    display:flex;flex-direction:column;gap:8px;align-items:center;pointer-events:none}
  .t{background:#1e2732;border:1px solid var(--line);border-left:3px solid var(--accent);
    border-radius:8px;padding:10px 14px;font-size:13px;box-shadow:0 8px 26px rgba(0,0,0,.55);
    max-width:70vw;pointer-events:auto;animation:in .18s ease}
  .t.good{border-left-color:var(--good)} .t.warn{border-left-color:var(--warn)} .t.bad{border-left-color:var(--bad)}
  .t button{padding:3px 9px;font-size:12px;margin-left:10px}
  @keyframes in{from{opacity:0;transform:translateY(8px)}}
  kbd{font:11px/1 "Consolas",monospace;background:#0b0f14;border:1px solid var(--line);
    border-bottom-width:2px;border-radius:4px;padding:2px 5px;color:var(--dim)}
  .hint{font-size:12px;color:#6c7986;text-align:center;padding-bottom:2px;flex:none}
</style>
</head>
<body>

<header>
  <div class="brand">Simple <span>Video Trimmer</span></div>
  <button id="bOpen" class="primary"><svg viewBox="0 0 24 24"><path d="M10 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-8l-2-2z"/></svg>Open Video</button>
  <div class="fname" id="fname">No video loaded</div>
  <button id="bQuit" class="ghost" title="Shut down the local server">Quit</button>
</header>

<main>
  <div class="notice" id="notice">
    <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2 1 21h22L12 2zm1 14h-2v2h2v-2zm0-7h-2v5h2V9z"/></svg>
    <span class="txt" id="noticeText"></span>
  </div>

  <div class="stage">
    <video id="v" preload="auto"></video>
    <div class="empty" id="empty">
      <svg viewBox="0 0 24 24"><path d="M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V4h-4z"/></svg>
      <h2>No video loaded</h2>
      <p>Open an MP4, M4V, MOV or WebM file to start trimming.</p>
      <button id="bOpen2" class="primary">Choose a video...</button>
    </div>
    <img id="frame" alt="">
  </div>

  <div class="panel">
    <div class="transport">
      <button id="bSetA" class="mark a" disabled title="Move the START point to the scrubber  (shortcut: I)"><svg viewBox="0 0 24 24"><path d="M11 4h2v9h3.5L12 18l-4.5-5H11z" /><path d="M5 20h14v2H5z"/></svg>Set Start</button>
      <button id="bPlay" disabled title="Play / Pause (Space)"><svg id="icPlay" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg><span id="txPlay">Play</span></button>
      <button id="bSetB" class="mark b" disabled title="Move the END point to the scrubber  (shortcut: O)"><svg viewBox="0 0 24 24"><path d="M11 4h2v9h3.5L12 18l-4.5-5H11z" /><path d="M5 20h14v2H5z"/></svg>Set End</button>
      <span class="sep"></span>
      <button id="bPrev" class="iconbtn" disabled title="Previous frame (Left arrow)"><svg viewBox="0 0 24 24"><path d="M6 6h2v12H6zm12 0v12l-9-6z"/></svg></button>
      <button id="bNext" class="iconbtn" disabled title="Next frame (Right arrow)"><svg viewBox="0 0 24 24"><path d="M16 6h2v12h-2zM6 6l9 6-9 6z"/></svg></button>
      <button id="bSplit" class="mark cut" disabled title="Cut the video in two at the scrubber  (shortcut: S)"><svg viewBox="0 0 24 24"><path d="M9.64 7.64A3.98 3.98 0 0 0 10 6a4 4 0 1 0-4 4c.59 0 1.14-.13 1.64-.36L10 12l-2.36 2.36A3.98 3.98 0 0 0 6 14a4 4 0 1 0 4 4c0-.59-.13-1.14-.36-1.64L12 14l7 7h3v-1L9.64 7.64zM6 8a2 2 0 1 1 2-2 2 2 0 0 1-2 2zm0 12a2 2 0 1 1 2-2 2 2 0 0 1-2 2zm6-7.5a.5.5 0 1 1 .5-.5.5.5 0 0 1-.5.5zM19 3l-6 6 2 2 7-7V3z"/></svg>Split</button>
      <button id="bSel" disabled title="Play only the selected range"><svg viewBox="0 0 24 24"><path d="M4 5v14l8-7zm9 0v14l8-7z"/></svg>Play Selection</button>
      <div class="time"><b id="tNow">00:00:00.000</b> / <span id="tDur">00:00:00.000</span></div>
      <div class="spacer"></div>
      <button id="bMute" class="iconbtn" disabled title="Mute"><svg id="icVol" viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z"/></svg></button>
      <input type="range" id="vol" min="0" max="1" step="0.01" value="1" disabled title="Volume">
    </div>

    <div class="tlwrap">
      <div class="tl" id="tl">
        <div id="strip"></div>
        <div class="shade" id="shL"></div>
        <div class="shade" id="shR"></div>
        <div class="sel" id="sel"></div>
        <div id="segs"></div>
        <div class="h" id="hA" title="Drag to move the start point"></div>
        <div class="h" id="hB" title="Drag to move the end point"></div>
        <div class="ph" id="ph"></div>
      </div>
      <div class="pop" id="pop"><div class="img" id="popImg"></div><div class="lab" id="popLab">00:00</div></div>
    </div>
    <div class="ruler"><span>00:00</span><span id="rMid">--:--</span><span id="rEnd">--:--</span></div>

    <div class="trim">
      <div class="grp">
        <button id="bGoA" class="labbtn a" disabled title="Jump the scrubber to the start point">START<svg viewBox="0 0 24 24"><path d="M4 11h9V7.5L18 12l-5 4.5V13H4z"/></svg></button>
        <input type="text" id="inA" value="00:00:00.000" disabled title="Type a time, e.g. 1:23.500">
      </div>
      <div class="grp">
        <span class="lab b">End</span>
        <input type="text" id="inB" value="00:00:00.000" disabled title="Type a time, e.g. 1:23.500">
      </div>
      <span class="sep"></span>
      <button id="bDel" class="mark del" disabled title="Remove the highlighted section - what is left closes up (shortcut: Delete)"><svg id="icDel" viewBox="0 0 24 24"><path d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg><span id="txDel">Delete Section</span></button>
      <button id="bUndo" class="ghost iconbtn" disabled title="Undo the last split or delete (Ctrl+Z)"><svg viewBox="0 0 24 24"><path d="M12.5 8c-2.65 0-5.05.99-6.9 2.6L2 7v9h9l-3.62-3.62A7.98 7.98 0 0 1 20 16l2.36-.78A10 10 0 0 0 12.5 8z"/></svg></button>
      <button id="bReset" class="ghost" disabled title="Clear every cut and select the whole video again">Reset</button>
      <div class="len">
        <div class="box">Clip length <b id="tLen">00:00:00.000</b></div>
        <div class="bar" id="bar"><i id="barFill"></i></div>
        <button id="bSave" class="primary" disabled title="Trim and save as MP4 (Ctrl+S)"><svg viewBox="0 0 24 24"><path d="M17 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V7l-4-4zm-5 16a3 3 0 1 1 0-6 3 3 0 0 1 0 6zm3-10H6V5h9v4z"/></svg><span id="txSave">Save Trimmed Video</span></button>
      </div>
    </div>
  </div>

  <div class="hint">
    <kbd>Space</kbd> play/pause &nbsp; <kbd>&larr;</kbd> <kbd>&rarr;</kbd> step frame (hold <kbd>Shift</kbd> for 1s)
    &nbsp; <kbd>I</kbd> set start &nbsp; <kbd>O</kbd> set end &nbsp; <kbd>S</kbd> split
    &nbsp; <kbd>Del</kbd> delete section &nbsp; <kbd>Ctrl</kbd>+<kbd>Z</kbd> undo &nbsp; <kbd>Ctrl</kbd>+<kbd>S</kbd> save
  </div>
</main>

<div id="toast"></div>

<script>
"use strict";
var K = "__KEY__";
function $(id){ return document.getElementById(id); }
var v = $("v");
var MIN_LEN = 0.05;

var M = null;            // media info from the server
var A = 0, B = 0, D = 0; // start, end, duration
var PH = 0;              // playhead, kept independent of <video> so the timeline
                         // still works on files the browser cannot decode
var vOk = false;         // is the <video> element actually usable?
var mode = "video";      // "video" = browser decodes it | "frames" = live-remuxed stream
var playStart = 0;       // offset the preview stream was started at
var dragging = null;     // "A" | "B" | "scrub"
var resumeAfterScrub = false;
var selPlay = false;
var pollTimer = null;

/* ---- cuts and deleted sections ----
   The timeline always shows SOURCE time - it has to, because the filmstrip
   behind it is one fixed render of the whole file. So a deleted section stays
   where it is and is drawn struck through; the closing-up happens in the
   output, whose length is what the "Clip length" box reports.

   Deletions are stored as time RANGES rather than segment indices on purpose:
   adding a new split then never has to remap which segments were deleted. */
var cuts = [];           // split points in source time, sorted, exclusive of 0 and D
var dels = [];           // deleted [start,end] ranges, sorted and merged
var selSeg = -1;         // index into segments() of the highlighted section
var hist = [];           // undo snapshots of {cuts, dels, selSeg}
var skipGuardUntil = 0;  // suppress skip checks until the playhead passes this
var restarting = false;  // a preview stream is being respun across a cut

var EPS = 0.0005;
function frameEps(){ return Math.max(0.02, 0.5 / ((M && M.fps) || 25)); }

/* [0, ...cuts, D] -> the sections the user sees and clicks */
function segments(){
  if (!M || !(D > 0)) return [];
  var b = [0], i;
  for (i = 0; i < cuts.length; i++) b.push(cuts[i]);
  b.push(D);
  b.sort(function(x, y){ return x - y; });
  var out = [];
  for (i = 0; i < b.length - 1; i++){
    if (b[i + 1] - b[i] <= EPS) continue;
    var mid = (b[i] + b[i + 1]) / 2;
    out.push({ s: b[i], e: b[i + 1], del: inDel(mid) });
  }
  return out;
}
function inDel(t){
  for (var i = 0; i < dels.length; i++) if (t > dels[i][0] && t < dels[i][1]) return true;
  return false;
}
/* the far edge of the deleted range containing t, or -1 */
function delEndAt(t){
  for (var i = 0; i < dels.length; i++) if (t >= dels[i][0] && t < dels[i][1] - EPS) return dels[i][1];
  return -1;
}
function segAt(t){
  var sg = segments();
  for (var i = 0; i < sg.length; i++) if (t >= sg[i].s && t <= sg[i].e) return i;
  return sg.length ? sg.length - 1 : -1;
}
function normDels(){
  dels.sort(function(x, y){ return x[0] - y[0]; });
  var out = [];
  for (var i = 0; i < dels.length; i++){
    var r = dels[i];
    if (out.length && r[0] <= out[out.length - 1][1] + EPS){
      if (r[1] > out[out.length - 1][1]) out[out.length - 1][1] = r[1];
    } else out.push([r[0], r[1]]);
  }
  dels = out;
}
function addDel(s, e){ dels.push([s, e]); normDels(); }
function subDel(s, e){
  var out = [];
  for (var i = 0; i < dels.length; i++){
    var r = dels[i];
    if (r[1] <= s + EPS || r[0] >= e - EPS){ out.push(r); continue; }
    if (r[0] < s - EPS) out.push([r[0], s]);
    if (r[1] > e + EPS) out.push([e, r[1]]);
  }
  dels = out;
}

/* what actually gets exported: kept sections clipped to the A/B trim */
function keptRanges(){
  var sg = segments(), out = [];
  for (var i = 0; i < sg.length; i++){
    if (sg[i].del) continue;
    var s = Math.max(sg[i].s, A), e = Math.min(sg[i].e, B);
    if (e - s < 0.01) continue;
    if (out.length && s - out[out.length - 1][1] < EPS) out[out.length - 1][1] = e;
    else out.push([s, e]);
  }
  return out;
}
function outLen(){
  var r = keptRanges(), t = 0;
  for (var i = 0; i < r.length; i++) t += r[i][1] - r[i][0];
  return t;
}
function hasEdits(){ return cuts.length > 0 || dels.length > 0; }

function snapshot(){
  hist.push({ cuts: cuts.slice(), dels: dels.map(function(r){ return r.slice(); }), sel: selSeg });
  if (hist.length > 60) hist.shift();
}

function clamp(x, lo, hi){ return x < lo ? lo : (x > hi ? hi : x); }
function api(p, q){ return p + "?k=" + K + (q ? "&" + q : ""); }
function pad(n, w){ var s = String(n); while (s.length < w) s = "0" + s; return s; }

function fmt(t, withMs){
  if (withMs === undefined) withMs = true;
  if (!isFinite(t) || t < 0) t = 0;
  /* work in whole ms so 4.05 never renders as .049 */
  var ms = Math.round(t * 1000);
  var out = pad(Math.floor(ms / 3600000), 2) + ":" +
            pad(Math.floor(ms % 3600000 / 60000), 2) + ":" +
            pad(Math.floor(ms % 60000 / 1000), 2);
  if (withMs) out += "." + pad(ms % 1000, 3);
  return out;
}
function fmtShort(t){
  if (!isFinite(t) || t < 0) t = 0;
  return pad(Math.floor(t / 60), 2) + ":" + pad(Math.floor(t % 60), 2);
}
/* accepts 83.5 | 1:23 | 1:23.5 | 00:01:23.500 */
function parseTime(str){
  var t = String(str).trim();
  if (!t) return NaN;
  if (!/^\d{1,3}(:\d{1,2}){0,2}([.,]\d{1,3})?$/.test(t)) return NaN;
  var parts = t.replace(",", ".").split(":").map(Number);
  for (var i = 0; i < parts.length; i++) if (isNaN(parts[i])) return NaN;
  return parts.reduce(function(acc, n){ return acc * 60 + n; }, 0);
}

function toast(msg, kind, actionLabel, action){
  var d = document.createElement("div");
  d.className = "t " + (kind || "");
  d.appendChild(document.createTextNode(msg));
  if (actionLabel){
    var b = document.createElement("button");
    b.textContent = actionLabel;
    b.onclick = function(){ action(); d.parentNode && d.parentNode.removeChild(d); };
    d.appendChild(b);
  }
  $("toast").appendChild(d);
  setTimeout(function(){
    d.style.transition = "opacity .3s"; d.style.opacity = 0;
    setTimeout(function(){ d.parentNode && d.parentNode.removeChild(d); }, 320);
  }, actionLabel ? 10000 : 3400);
  return d;
}
function kill(el){ if (el && el.parentNode) el.parentNode.removeChild(el); }

/* ---- trim points: every clamp rule lives here, so nothing can error out ---- */
function setA(t, quiet){
  if (!M) return;
  var x = clamp(t, 0, D);
  var cap = Math.max(0, B - MIN_LEN);
  if (x > cap){ x = cap; if (!quiet) toast("Start point cannot pass the end point - clamped.", "warn"); }
  A = x; render();
}
function setB(t, quiet){
  if (!M) return;
  var x = clamp(t, 0, D);
  var floorV = Math.min(D, A + MIN_LEN);
  if (x < floorV){ x = floorV; if (!quiet) toast("End point cannot precede the start point - clamped.", "warn"); }
  B = x; render();
}

function render(){
  var pa = D ? A / D * 100 : 0, pb = D ? B / D * 100 : 100;
  $("hA").style.left = pa + "%";
  $("hB").style.left = pb + "%";
  $("sel").style.left = pa + "%";
  $("sel").style.width = Math.max(0, pb - pa) + "%";
  $("shL").style.left = "0"; $("shL").style.width = pa + "%";
  $("shR").style.left = pb + "%"; $("shR").style.width = Math.max(0, 100 - pb) + "%";
  if (document.activeElement !== $("inA")) $("inA").value = fmt(A);
  if (document.activeElement !== $("inB")) $("inB").value = fmt(B);
  $("tLen").textContent = fmt(Math.max(0, outLen()));
  renderSegs();
  syncEditButtons();
  renderPlayhead();
}

function renderSegs(){
  var host = $("segs");
  while (host.firstChild) host.removeChild(host.firstChild);
  if (!M || !(D > 0)) return;
  var sg = segments(), i, el;
  var pct = function(t){ return clamp(t / D, 0, 1) * 100; };

  for (i = 0; i < sg.length; i++){
    if (!sg[i].del) continue;
    el = document.createElement("div");
    el.className = "gone";
    el.style.left  = pct(sg[i].s) + "%";
    el.style.width = Math.max(0, pct(sg[i].e) - pct(sg[i].s)) + "%";
    host.appendChild(el);
  }
  for (i = 0; i < cuts.length; i++){
    el = document.createElement("div");
    el.className = "cut";
    el.style.left = pct(cuts[i]) + "%";
    host.appendChild(el);
  }
  if (selSeg >= 0 && selSeg < sg.length && cuts.length){
    el = document.createElement("div");
    el.className = "pick";
    el.style.left  = pct(sg[selSeg].s) + "%";
    el.style.width = Math.max(0, pct(sg[selSeg].e) - pct(sg[selSeg].s)) + "%";
    host.appendChild(el);
  }
}

/* Split / Delete / Undo enablement, plus the Delete <-> Restore flip. */
function syncEditButtons(){
  var on = !!M;
  $("bSplit").disabled = !on || (on && !canSplitAt(PH));
  $("bUndo").disabled  = !on || hist.length === 0;
  $("bReset").disabled = !on;

  var sg = on ? segments() : [];
  var cur = (selSeg >= 0 && selSeg < sg.length) ? sg[selSeg] : null;
  var restore = !!(cur && cur.del);
  $("txDel").textContent = restore ? "Restore Section" : "Delete Section";
  $("icDel").innerHTML = restore
    ? '<path d="M13 3a9 9 0 0 0-9 9H1l4 4 4-4H6a7 7 0 1 1 7 7v2a9 9 0 0 0 0-18z"/>'
    : '<path d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/>';
  $("bDel").title = restore
    ? "Put the highlighted section back into the video (shortcut: Delete)"
    : "Remove the highlighted section - what is left closes up (shortcut: Delete)";
  /* nothing to delete until there is more than one section to choose between */
  $("bDel").disabled = !cur || (!restore && sg.length < 2);
}

/* A split is pointless on top of an existing boundary, and a zero-length
   section would only confuse the export. */
function canSplitAt(t){
  if (!M || !(D > 0)) return false;
  var eps = frameEps(), i;
  if (t <= eps || t >= D - eps) return false;
  for (i = 0; i < cuts.length; i++) if (Math.abs(cuts[i] - t) < eps) return false;
  return true;
}
function renderPlayhead(){
  $("ph").style.left = (D ? clamp(PH / D, 0, 1) * 100 : 0) + "%";
  $("tNow").textContent = fmt(PH);
  /* cheap enough to run on every timeupdate; the rest of syncEditButtons
     rewrites innerHTML, so it stays in render() */
  if (M) $("bSplit").disabled = !canSplitAt(PH);
}

/* ---------------------------- open a video ---------------------------- */
function openVideo(){
  $("bOpen").disabled = true; $("bOpen2").disabled = true;
  var waiting = toast("Waiting for the file dialog...", "");
  fetch(api("/api/open"), { method: "POST" })
    .then(function(r){ return r.json(); })
    .then(function(j){
      kill(waiting);
      if (j.cancelled) return;
      if (!j.ok){ toast(j.error || "Could not open that file.", "bad"); return; }
      loadMedia(j);
    })
    .catch(function(e){ kill(waiting); toast("Could not reach the local server: " + e.message, "bad"); })
    .then(function(){ $("bOpen").disabled = false; $("bOpen2").disabled = false; });
}

function loadMedia(j){
  M = j; D = j.duration; A = 0; B = D; selPlay = false;
  cuts = []; dels = []; hist = []; selSeg = -1;
  skipGuardUntil = 0; restarting = false;
  var fn = $("fname");
  while (fn.firstChild) fn.removeChild(fn.firstChild);
  var b = document.createElement("b"); b.textContent = j.name;
  fn.appendChild(b);
  fn.appendChild(document.createTextNode(
    "  -  " + j.width + "x" + j.height + " - " + j.fps.toFixed(2) + " fps - " +
    j.sizeText + " - " + fmt(D, false)));

  $("empty").style.display = "none";
  PH = 0;
  playStart = 0;
  stopStream();
  if (j.playable){
    mode = "video";
    vOk = true;
    $("notice").style.display = "none";
    $("frame").style.display = "none";
    $("frame").removeAttribute("src");
    v.style.display = "block";
    v.src = api("/api/stream", "t=" + j.token);
    v.load();
  } else {
    enterFramesMode(j);
  }

  $("tDur").textContent = fmt(D);
  $("rMid").textContent = fmtShort(D / 2);
  $("rEnd").textContent = fmtShort(D);
  /* trimming never needs a decoder, so those controls are always live */
  var always = ["bPrev","bNext","inA","inB","bSetA","bSetB","bGoA","bReset","bSave"];
  for (var i = 0; i < always.length; i++) $(always[i]).disabled = false;
  syncPlayButtons();

  render();
  loadStrip(j.token);
}

function loadStrip(token){
  var tl = $("tl");
  tl.className = "tl busy";
  $("strip").style.backgroundImage = "";
  var url = api("/api/strip", "t=" + token);
  var img = new Image();
  img.onload = function(){
    tl.className = "tl";
    $("strip").style.backgroundImage = "url('" + url + "')";
    $("popImg").style.backgroundImage = "url('" + url + "')";
    $("popImg").style.backgroundSize = (M.tiles * M.tileW) + "px " + M.tileH + "px";
  };
  img.onerror = function(){ tl.className = "tl"; };
  img.src = url;
}

/* ---------- files the browser cannot decode: stills + sidecar audio ---------- */
/* One frame is ~100ms server-side, so requests are coalesced rather than queued. */
var frameBusy = false, framePending = null, lastFrameAt = -1;

function showFrame(t){
  if (mode !== "frames" || !M) return;
  var at = clamp(t, 0, D);
  if (Math.abs(at - lastFrameAt) < 0.0005 && lastFrameAt >= 0) return;
  if (frameBusy){ framePending = at; return; }
  frameBusy = true;
  var url = api("/api/frame", "t=" + M.token + "&at=" + at.toFixed(6));
  var pre = new Image();
  pre.onload = function(){
    lastFrameAt = at;
    $("frame").src = url;          /* already in cache, so this swaps with no flicker */
    frameBusy = false;
    if (framePending !== null){ var q = framePending; framePending = null; showFrame(q); }
  };
  pre.onerror = function(){ frameBusy = false; framePending = null; };
  pre.src = url;
}

/* Preview mode used to animate server-rendered stills, which capped out near
   6fps because every frame was its own ffmpeg process. Playback now streams a
   live-remuxed fragmented MP4 into the same <video> element, so the browser
   decodes it natively. Stills are still used for scrubbing and frame stepping,
   where exactness matters more than smoothness. */

function canPlayNow(){ return !!M && (mode === "video" ? vOk : true); }

function playbackIsPlaying(){ return !!M && !v.paused && v.style.display !== "none"; }

function stopStream(){
  try { v.pause(); } catch (e) {}
  v.removeAttribute("src");
  try { v.load(); } catch (e) {}   /* aborts the request, which kills ffmpeg */
}

/* play() can be refused - autoplay policy, or Chrome pausing silent video in a
   background tab - so never leave the button claiming to be playing. */
function guardPlay(){
  var pr = v.play();
  if (pr && pr.catch) pr.catch(function(){
    playbackPause();
    toast((M && !M.hasAudio)
      ? "The browser blocked playback of a silent video. Click the page, or bring this tab to the front."
      : "The browser blocked playback. Click the page and try again.", "warn");
  });
}

function playbackPlay(){
  if (!canPlayNow()) return;
  if (PH >= D - 0.05) seek(0);
  if (mode === "video"){ guardPlay(); return; }

  var want = PH;
  playStart = want;                /* corrected below once the real start is known */
  $("frame").style.display = "none";
  v.style.display = "block";
  v.src = api("/api/play", "t=" + M.token + "&start=" + want.toFixed(6));
  v.load();
  guardPlay();
  setPlayIcon(true);

  /* a stream copy can only begin on a keyframe, so ask where it really starts;
     runs alongside the stream so play is not held up waiting for it */
  fetch(api("/api/playinfo", "t=" + M.token + "&at=" + want.toFixed(6)))
    .then(function(r){ return r.json(); })
    .then(function(j){ if (j && j.ok && isFinite(j.start)) playStart = j.start; })
    .catch(function(){ });
}

/* Tearing the stream down fires timeupdate with currentTime 0, so the playhead
   has to be carried across by hand or it snaps back to the stream's start. */
function exitStreamToStill(){
  var at = PH;
  stopStream();
  v.style.display = "none";
  $("frame").style.display = "block";
  PH = at;
  lastFrameAt = -1;
  showFrame(at);
  setPlayIcon(false);
}

function playbackPause(){
  if (mode === "video"){
    try { v.pause(); } catch (e) {}
    setPlayIcon(false);
    return;
  }
  exitStreamToStill();
}

function syncPlayButtons(){
  var on = canPlayNow();
  $("bPlay").disabled = !on;
  $("bSel").disabled  = !on;
  var haveAudio = on && (!M || M.hasAudio);
  $("bMute").disabled = !haveAudio;
  $("vol").disabled   = !haveAudio;
  $("bPlay").title = "Play / Pause (Space)";
  $("bSel").title  = (M && !M.hasAudio)
    ? "Play only the selected range - this file has no audio track"
    : "Play only the selected range";
}

function enterFramesMode(j){
  mode = "frames";
  vOk = false;
  v.style.display = "none";
  v.removeAttribute("src");
  try { v.load(); } catch (e) {}
  $("frame").style.display = "block";
  $("notice").style.display = "flex";
  $("noticeText").textContent =
    "Preview mode - your browser cannot decode this file directly because " + (j.why || "of an unsupported codec") +
    ", so it is converted on the fly as you play. This affects preview only - the video you " +
    "save is trimmed from the original file, at full quality.";
  lastFrameAt = -1;
  showFrame(0);
  syncPlayButtons();
}

/* --------------------------- timeline input --------------------------- */
function posToTime(clientX){
  var r = $("tl").getBoundingClientRect();
  return clamp((clientX - r.left) / r.width, 0, 1) * D;
}
function seek(t){
  if (!M) return;
  PH = clamp(t, 0, D);
  skipGuardUntil = 0;   /* an explicit move always beats a pending skip */
  if (mode === "video"){
    if (vOk) { try { v.currentTime = PH; } catch (e) {} }
  } else {
    if (playbackIsPlaying()) exitStreamToStill();
    else showFrame(PH);
  }
  renderPlayhead();
}

$("tl").addEventListener("pointerdown", function(e){
  if (!M) return;
  dragging = (e.target === $("hA")) ? "A" : (e.target === $("hB")) ? "B" : "scrub";
  try { $("tl").setPointerCapture(e.pointerId); } catch (err) {}
  if (dragging === "scrub"){
    resumeAfterScrub = playbackIsPlaying();
    playbackPause();
    selPlay = false;
    var at = posToTime(e.clientX);
    /* clicking the timeline both moves the scrubber and picks the section
       under it - that is what Delete Section then acts on */
    selSeg = segAt(at);
    seek(at);
    render();
  } else {
    $(dragging === "A" ? "hA" : "hB").classList.add("drag");
  }
  e.preventDefault();
});
$("tl").addEventListener("pointermove", function(e){
  if (!M) return;
  var t = posToTime(e.clientX);
  if (dragging === "scrub") seek(t);
  else if (dragging === "A") setA(t, true);
  else if (dragging === "B") setB(t, true);
  else showPop(e.clientX);
});
function endDrag(){
  $("hA").classList.remove("drag");
  $("hB").classList.remove("drag");
  if (dragging === "scrub" && resumeAfterScrub){
    playbackPlay();
    resumeAfterScrub = false;
  }
  dragging = null;
}
$("tl").addEventListener("pointerup", endDrag);
$("tl").addEventListener("pointercancel", endDrag);
$("tl").addEventListener("pointerleave", function(){ $("pop").style.display = "none"; });

function showPop(clientX){
  if (!M || !M.tiles) return;
  var r = $("tl").getBoundingClientRect();
  var f = clamp((clientX - r.left) / r.width, 0, 1);
  var idx = clamp(Math.floor(f * M.tiles), 0, M.tiles - 1);
  var pop = $("pop");
  $("popImg").style.backgroundPosition = (-idx * M.tileW) + "px 0";
  $("popLab").textContent = fmt(f * D, false);
  pop.style.display = "block";
  pop.style.left = clamp(clientX - r.left - 80, 2, Math.max(2, r.width - 162)) + "px";
}

/* --------------------------- split and delete -------------------------- */
function doSplit(){
  if (!M) return;
  if (!canSplitAt(PH)){
    toast("There is already a cut here - move the scrubber first.", "warn");
    return;
  }
  snapshot();
  cuts.push(PH);
  cuts.sort(function(x, y){ return x - y; });
  selSeg = segAt(PH);
  render();
  toast("Split at " + fmt(PH, false) + " - click a section, then Delete Section.", "good");
}

function doDelete(){
  if (!M) return;
  var sg = segments();
  if (selSeg < 0 || selSeg >= sg.length){
    toast("Click a section on the timeline first.", "warn");
    return;
  }
  var cur = sg[selSeg];
  if (cur.del){
    snapshot();
    subDel(cur.s, cur.e);
    render();
    toast("Section restored.", "good");
    return;
  }
  if (sg.length < 2){
    toast("Split the video first - there is only one section.", "warn");
    return;
  }
  /* try it on a copy so we never strand the user with nothing to export */
  var keep = dels.map(function(r){ return r.slice(); });
  dels.push([cur.s, cur.e]); normDels();
  if (outLen() < MIN_LEN){
    dels = keep;
    toast("That would leave nothing to save.", "warn");
    return;
  }
  dels = keep;
  snapshot();
  addDel(cur.s, cur.e);
  render();
  /* if the playhead is now inside the hole, walk it out to the join */
  var edge = delEndAt(PH);
  if (edge >= 0) seek(Math.min(edge, D));
  toast("Section removed - the ends will close up on save. New length " +
        fmt(outLen(), false) + ".", "good");
}

function doUndo(){
  if (!hist.length){ toast("Nothing to undo.", "warn"); return; }
  var h = hist.pop();
  cuts = h.cuts; dels = h.dels; selSeg = h.sel;
  render();
}

/* ------------------------- skipping deleted parts ---------------------- */
/* Playback jumps the holes in both modes. In native mode that is a plain
   currentTime move. In preview mode the stream has to be respun, which stalls
   briefly - and because a stream copy can only begin on a keyframe, ffmpeg may
   hand back a moment of footage from BEFORE the join. skipGuardUntil stops that
   replayed audio from re-triggering the same jump forever. */
function skipTo(edge, wasPlaying){
  skipGuardUntil = edge;
  PH = clamp(edge, 0, D);
  if (mode === "video"){
    if (vOk) { try { v.currentTime = PH; } catch (e) {} }
    renderPlayhead();
    return;
  }
  if (wasPlaying){
    restarting = true;
    setTimeout(function(){ restarting = false; }, 3000);
    playbackPlay();
  } else {
    lastFrameAt = -1;
    showFrame(PH);
  }
  renderPlayhead();
}

/* Returns true when playback was diverted, so callers stop what they were doing. */
function skipIfDeleted(){
  if (!M || !dels.length) return false;
  if (skipGuardUntil > 0){
    if (PH < skipGuardUntil - EPS) return false;   /* still inside the guard */
    skipGuardUntil = 0;
  }
  var edge = delEndAt(PH);
  if (edge < 0) return false;
  if (edge >= D - 0.02 || (selPlay && edge >= B - EPS)){
    playbackPause(); selPlay = false; skipGuardUntil = 0;
    seek(Math.min(edge, D));
    return true;
  }
  skipTo(edge, playbackIsPlaying());
  return true;
}

/* ----------------------------- transport ------------------------------ */
function togglePlay(){
  if (!M || !canPlayNow()) return;
  if (playbackIsPlaying()) playbackPause(); else playbackPlay();
}
function setPlayIcon(on){
  $("icPlay").innerHTML = on ? '<path d="M6 5h4v14H6zm8 0h4v14h-4z"/>'
                             : '<path d="M8 5v14l11-7z"/>';
  $("txPlay").textContent = on ? "Pause" : "Play";
}
v.addEventListener("play",  function(){ setPlayIcon(true); restarting = false; });
v.addEventListener("pause", function(){
  setPlayIcon(false);
  /* a respin across a cut tears the stream down first - that pause is ours,
     not the user's, so it must not cancel Play Selection */
  if (!restarting) selPlay = false;
});
v.addEventListener("timeupdate", function(){
  if (mode === "frames" && !playbackIsPlaying()) return;
  PH = (mode === "video") ? v.currentTime : (playStart + v.currentTime);
  if (skipIfDeleted()) return;
  if (selPlay && PH >= B){ playbackPause(); selPlay = false; seek(B); }
  renderPlayhead();
});
v.addEventListener("seeked", function(){
  if (mode === "video"){ PH = v.currentTime; renderPlayhead(); }
});
v.addEventListener("loadedmetadata", function(){
  if (M && (!D || !isFinite(D)) && isFinite(v.duration)){ D = v.duration; B = D; render(); }
});
v.addEventListener("error", function(){
  if (!M) return;
  if (mode === "video"){ enterFramesMode(M); }
  else if (playbackIsPlaying()) { playbackPause(); toast("Preview stream stopped.", "warn"); }
});
v.addEventListener("ended", function(){ if (mode === "frames") playbackPause(); });

function step(dir, big){
  if (!M) return;
  playbackPause();
  if (big){ seek(PH + dir); return; }
  /* ask for the real timestamp of the neighbouring frame rather than
     assuming frames sit on exact 1/fps boundaries */
  var from = PH;
  var fallback = function(){ seek(from + dir / (M.fps || 25)); };
  fetch(api("/api/step", "t=" + M.token + "&at=" + from.toFixed(6) + "&dir=" + dir))
    .then(function(r){ return r.json(); })
    .then(function(j){ if (j && j.ok && isFinite(j.t)) seek(j.t); else fallback(); })
    .catch(fallback);
}

/* ------------------------------- wiring ------------------------------- */
$("bOpen").onclick = openVideo;
$("bOpen2").onclick = openVideo;
$("bPlay").onclick = togglePlay;
$("bPrev").onclick = function(e){ step(-1, e.shiftKey); };
$("bNext").onclick = function(e){ step(1, e.shiftKey); };
$("bSel").onclick = function(){
  if (!M || !canPlayNow()) return;
  var r = keptRanges();
  if (!r.length){ toast("Nothing is selected to play.", "warn"); return; }
  seek(r[0][0]); selPlay = true;
  playbackPlay();
};
$("bMute").onclick = function(){
  v.muted = !v.muted;
  $("icVol").innerHTML = v.muted
    ? '<path d="M3 9v6h4l5 5V4L7 9H3zm18.6 1.4L20.2 9l-2.1 2.1L16 9l-1.4 1.4 2.1 2.1-2.1 2.1L16 16l2.1-2.1L20.2 16l1.4-1.4-2.1-2.1z"/>'
    : '<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z"/>';
};
$("vol").oninput = function(e){ v.volume = +e.target.value; v.muted = false; };
$("bSetA").onclick = function(){ setA(PH); };
$("bSetB").onclick = function(){ setB(PH); };
$("bGoA").onclick  = function(){ playbackPause(); seek(A); };
$("bSplit").onclick = doSplit;
$("bDel").onclick   = doDelete;
$("bUndo").onclick  = doUndo;
$("bReset").onclick = function(){
  if (hasEdits()) snapshot();
  A = 0; B = D; cuts = []; dels = []; selSeg = -1; skipGuardUntil = 0;
  render();
  toast("Every cut cleared - the whole video is selected again.");
};

function commit(which){
  var el = $(which === "A" ? "inA" : "inB");
  var t = parseTime(el.value);
  if (isNaN(t)){ toast("Could not read that time. Try 1:23.500 or 83.5", "warn"); render(); return; }
  if (which === "A") setA(t); else setB(t);
  render();
}
$("inA").addEventListener("change", function(){ commit("A"); });
$("inB").addEventListener("change", function(){ commit("B"); });
$("inA").addEventListener("keydown", function(e){ if (e.key === "Enter"){ commit("A"); e.target.blur(); } });
$("inB").addEventListener("keydown", function(e){ if (e.key === "Enter"){ commit("B"); e.target.blur(); } });

document.addEventListener("keydown", function(e){
  if (/^(INPUT|TEXTAREA)$/.test(e.target.tagName)) return;
  if (e.ctrlKey && (e.key === "s" || e.key === "S")){ e.preventDefault(); save(); return; }
  if (e.ctrlKey && (e.key === "z" || e.key === "Z")){ e.preventDefault(); doUndo(); return; }
  if (e.ctrlKey || e.altKey || e.metaKey) return;
  switch (e.key){
    case "s": case "S": e.preventDefault(); doSplit(); break;
    case "Delete": e.preventDefault(); doDelete(); break;
    case " ": case "Spacebar": e.preventDefault(); togglePlay(); break;
    case "ArrowLeft":  e.preventDefault(); step(-1, e.shiftKey); break;
    case "ArrowRight": e.preventDefault(); step(1, e.shiftKey); break;
    case "Home": e.preventDefault(); seek(0); break;
    case "End":  e.preventDefault(); seek(D); break;
    case "i": case "I": setA(PH); break;
    case "o": case "O": setB(PH); break;
  }
});

/* -------------------------------- save -------------------------------- */
function save(){
  if (!M || $("bSave").disabled) return;
  var segs = keptRanges();
  if (!segs.length || outLen() < MIN_LEN){
    toast("The selected clip is too short to save.", "warn"); return;
  }
  $("bSave").disabled = true;
  $("txSave").textContent = "Choose location...";
  fetch(api("/api/save"), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    /* start/end stay for the single-range case, which keeps the fast
       seek-based export exactly as it was */
    body: JSON.stringify({ token: M.token, start: A, end: B, segments: segs })
  })
  .then(function(r){ return r.json(); })
  .then(function(j){
    if (j.cancelled){ finishSave(); return; }
    if (!j.ok){ finishSave(); toast(j.error || "Could not start the export.", "bad"); return; }
    $("txSave").textContent = "Exporting...";
    $("bar").style.display = "block";
    $("barFill").style.right = "100%";
    poll(j.job);
  })
  .catch(function(e){ finishSave(); toast("Could not reach the local server: " + e.message, "bad"); });
}
function finishSave(){
  $("bSave").disabled = false;
  $("txSave").textContent = "Save Trimmed Video";
  $("bar").style.display = "none";
  if (pollTimer){ clearInterval(pollTimer); pollTimer = null; }
}
function poll(id){
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(function(){
    fetch(api("/api/job", "id=" + id))
      .then(function(r){ return r.json(); })
      .then(function(j){
        if (j.state === "running"){
          $("barFill").style.right = (100 - clamp(j.percent, 0, 100)) + "%";
          $("txSave").textContent = "Exporting " + Math.round(j.percent) + "%";
          return;
        }
        finishSave();
        if (j.state === "done"){
          toast("Saved: " + j.outName, "good", "Show in folder", function(){
            fetch(api("/api/reveal", "id=" + id));
          });
        } else {
          toast("Export failed: " + (j.error || "unknown error"), "bad");
        }
      })
      .catch(function(){ /* transient - keep polling */ });
  }, 350);
}
$("bSave").onclick = save;

$("bQuit").onclick = function(){
  if (!confirm("Shut down Simple Video Trimmer?")) return;
  fetch(api("/api/quit"), { method: "POST" }).catch(function(){});
  setTimeout(function(){
    document.body.innerHTML =
      '<div style="margin:auto;text-align:center;color:#8b98a5;font:15px Segoe UI,sans-serif">' +
      'Simple Video Trimmer has shut down.<br><br>You can close this tab.</div>';
  }, 200);
};

window.addEventListener("resize", render);
render();
</script>
</body>
</html>
'@
$S.Html = $S.Html.Replace('__KEY__', $S.Key)

# ----------------------------------------------------------- request handler --

$Handler = {
param($ctx, $S)

$ErrorActionPreference = 'Continue'
$req = $ctx.Request
$res = $ctx.Response
$inv = [cultureinfo]::InvariantCulture

function Num([double]$v, [string]$f = '0.######') { [string]::Format($inv, "{0:$f}", $v) }

function Send-Bytes([byte[]]$bytes, [string]$type, [int]$code = 200) {
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
function Send-Text([string]$text, [string]$type = 'text/plain; charset=utf-8', [int]$code = 200) {
    Send-Bytes ([Text.Encoding]::UTF8.GetBytes($text)) $type $code
}
function Send-Json($obj, [int]$code = 200) {
    Send-Text (ConvertTo-Json $obj -Depth 6 -Compress) 'application/json; charset=utf-8' $code
}
function Human([long]$b) {
    if ($b -ge 1073741824) { return (Num ($b / 1073741824.0) '0.##') + ' GB' }
    if ($b -ge 1048576)    { return (Num ($b / 1048576.0)    '0.#')  + ' MB' }
    if ($b -ge 1024)       { return (Num ($b / 1024.0)       '0')    + ' KB' }
    return "$b B"
}
function Mime([string]$path) {
    switch -Regex ([IO.Path]::GetExtension($path).ToLower()) {
        '\.(mp4|m4v)$' { 'video/mp4' ; break }
        '\.mov$'       { 'video/quicktime' ; break }
        '\.webm$'      { 'video/webm' ; break }
        '\.mkv$'       { 'video/x-matroska' ; break }
        default        { 'application/octet-stream' }
    }
}

# Run a WinForms dialog on top of everything else.
function Show-Dialog($dlg) {
    $owner = New-Object System.Windows.Forms.Form
    $owner.Opacity = 0; $owner.ShowInTaskbar = $false; $owner.TopMost = $true
    $owner.FormBorderStyle = 'None'; $owner.Size = New-Object System.Drawing.Size -ArgumentList 1, 1
    $owner.StartPosition = 'CenterScreen'
    try {
        $owner.Show(); $owner.Activate()
        return $dlg.ShowDialog($owner)
    } finally {
        $owner.Close(); $owner.Dispose()
    }
}

function Get-MediaInfo([string]$path) {
    $raw = & $S.FFprobe -v error -print_format json -show_format -show_streams $path 2>$null
    if (-not $raw) { throw 'ffprobe returned nothing for that file.' }
    $j = ($raw -join "`n") | ConvertFrom-Json

    $vs = $j.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    if (-not $vs) { throw 'That file does not contain a video track.' }
    $as = $j.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1

    $dur = 0.0
    foreach ($cand in @($j.format.duration, $vs.duration)) {
        if ($cand -and [double]::TryParse([string]$cand, [Globalization.NumberStyles]::Float, $inv, [ref]$dur) -and $dur -gt 0) { break }
    }

    $fps = 0.0
    foreach ($r in @($vs.avg_frame_rate, $vs.r_frame_rate)) {
        if ($r -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -ne 0) {
            $fps = [double]$Matches[1] / [double]$Matches[2]
            if ($fps -gt 0) { break }
        }
    }
    if ($fps -le 0) { $fps = 25.0 }

    $fi  = Get-Item -LiteralPath $path
    $ext = $fi.Extension.ToLower()

    # A browser needs EVERY track it is handed to be decodable. One unsupported
    # audio track (PCM in a .MOV, for instance) kills the whole media element,
    # which is why such a file renders as a black frame rather than a warning.
    $cOk = $ext -in @('.mp4', '.m4v', '.mov', '.webm')
    $vOk = $vs.codec_name -in @('h264', 'vp8', 'vp9', 'av1')
    $aOk = (-not $as) -or ($as.codec_name -in @('aac', 'mp3', 'opus', 'vorbis', 'flac'))
    $playable = $cOk -and $vOk -and $aOk

    $why = ''
    if (-not $cOk) { $why = "the $($ext.TrimStart('.').ToUpper()) container is not supported by browsers" }
    elseif (-not $vOk -and -not $aOk) { $why = "neither its $($vs.codec_name) video nor its $($as.codec_name) audio can be decoded by a browser" }
    elseif (-not $vOk) { $why = "its $($vs.codec_name) video cannot be decoded by a browser" }
    elseif (-not $aOk) { $why = "its $($as.codec_name) audio cannot be decoded by a browser" }

    [pscustomobject]@{
        ok       = $true
        path     = $fi.FullName
        name     = $fi.Name
        duration = [math]::Round($dur, 3)
        width    = [int]$vs.width
        height   = [int]$vs.height
        fps      = [math]::Round($fps, 3)
        vcodec   = [string]$vs.codec_name
        acodec   = $(if ($as) { [string]$as.codec_name } else { 'none' })
        hasAudio = [bool]$as
        why      = $why
        vOk      = $vOk
        aOk      = $aOk
        audioMode = $(if (-not $as) { 'none' } elseif ($aOk) { 'copy' } else { 'encode' })
        size     = $fi.Length
        sizeText = Human $fi.Length
        playable = $playable
        tiles    = $S.TileCount
        tileW    = $S.TileW
        tileH    = $S.TileH
    }
}

function Get-StripPath([string]$path) {
    $fi  = Get-Item -LiteralPath $path
    $sig = '{0}|{1}|{2}|{3}x{4}x{5}' -f $fi.FullName, $fi.Length, $fi.LastWriteTimeUtc.Ticks,
                                        $S.TileCount, $S.TileW, $S.TileH
    $md5 = [Security.Cryptography.MD5]::Create()
    try   { $h = ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($sig)) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $md5.Dispose() }
    Join-Path $S.CacheDir "strip_$h.jpg"
}

# One still frame taken straight from the source. Roughly 100 ms even on a 4 GB
# file, which is what lets an undecodable video be scrubbed without copying any
# video data at all.
function Get-Frame([object]$info, [double]$at) {
    $fw = [math]::Min(960, [int]$info.width)
    if ($fw -lt 16) { $fw = 960 }
    $fps = [double]$info.fps
    if ($fps -le 0) { $fps = 25.0 }

    # -ss returns the first frame at OR AFTER the seek point, so aim a quarter
    # of a frame early. That absorbs the rounding in a timestamp that has been
    # round-tripped as text, without ever reaching back into the frame before.
    $back = 0.25 / $fps
    $dst  = Join-Path $S.CacheDir ('frame_' + [Guid]::NewGuid().ToString('N') + '.jpg')
    $t    = [math]::Max(0.0, [math]::Min(([double]$info.duration - 0.04), $at - $back))
    & $S.FFmpeg -y -v error -ss (Num $t '0.######') -i $info.path -frames:v 1 -vf "scale=${fw}:-2" -an -sn -q:v 4 $dst 2>&1 | Out-Null
    return $dst
}

# The real presentation timestamps of the neighbouring frames.
#
# Stepping by 1/fps cannot work: at 60fps a frame is 16.667ms, and rounding that
# to any fixed number of decimals eventually lands past a frame boundary, which
# is what made "next frame" show the same picture twice.
#
# ffprobe -read_intervals is not usable here - it honours the duration but
# ignores the start, so it always reads from 0 - hence ffmpeg + showinfo, which
# reports the true pts of each decoded frame.
function Get-FrameTimes([object]$info, [double]$from, [int]$count) {
    $out = & $S.FFmpeg -hide_banner -v info -copyts -ss (Num $from '0.######') `
                       -i $info.path -frames:v $count -vf showinfo -an -sn -f null - 2>&1
    $times = New-Object System.Collections.Generic.List[double]
    foreach ($line in @($out)) {
        foreach ($m in [regex]::Matches([string]$line, 'pts_time:([0-9]+\.?[0-9]*)')) {
            $d = 0.0
            if ([double]::TryParse($m.Groups[1].Value, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) {
                $times.Add($d)
            }
        }
    }
    $times.Sort()
    return $times
}

function Get-StepTime([object]$info, [double]$at, [int]$dir) {
    $dur = [double]$info.duration
    $fps = [double]$info.fps
    if ($fps -le 0) { $fps = 25.0 }
    $span = 1.0 / $fps
    $eps  = 0.4 * $span

    if ($dir -ge 0) {
        $from  = [math]::Max(0.0, $at - (0.25 * $span))
        $count = 3
    } else {
        $from  = [math]::Max(0.0, $at - 0.5)
        $count = [int][math]::Min(240, [math]::Ceiling(0.5 * $fps) + 4)
    }

    $times = Get-FrameTimes $info $from $count
    $cand  = $null
    if ($dir -ge 0) { foreach ($x in $times) { if ($x -gt ($at + $eps)) { $cand = $x; break } } }
    else            { foreach ($x in $times) { if ($x -lt ($at - $eps)) { $cand = $x } } }

    if ($null -eq $cand) { $cand = $at + ($dir * $span) }
    return [math]::Max(0.0, [math]::Min($dur, [double]$cand))
}

# -ss with -c:v copy can only start on a keyframe, so the caller needs to know
# where the stream will actually begin or the playhead would disagree with the
# picture. -copyts is required here or showinfo reports times relative to the seek.
function Get-KeyframeTime([object]$info, [double]$at) {
    foreach ($win in @(4.0, 30.0)) {
        $from = [math]::Max(0.0, $at - $win)
        $out  = & $S.FFmpeg -hide_banner -v info -copyts -skip_frame nokey `
                            -ss (Num $from '0.######') -i $info.path -frames:v 60 `
                            -vf showinfo -an -sn -f null - 2>&1
        $best = $null
        foreach ($line in @($out)) {
            foreach ($m in [regex]::Matches([string]$line, 'pts_time:([0-9]+\.?[0-9]*)')) {
                $d = 0.0
                if ([double]::TryParse($m.Groups[1].Value, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) {
                    if ($d -le ($at + 0.0005)) {
                        if (($null -eq $best) -or ($d -gt $best)) { $best = $d }
                    }
                }
            }
        }
        if ($null -ne $best) { return [double]$best }
        if ($from -le 0.0) { break }
    }
    return [math]::Max(0.0, $at)
}

# Build one wide sprite of evenly spaced thumbnails by seeking - stays fast on long videos.
function New-Strip([string]$path, [double]$dur, [string]$out) {
    $n    = $S.TileCount
    $w    = $S.TileW
    $h    = $S.TileH
    $work = Join-Path $S.CacheDir ('work_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $vf = "scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2:black"
    try {
        for ($i = 0; $i -lt $n; $i++) {
            $t   = [math]::Max(0.0, [math]::Min($dur - 0.05, ($i + 0.5) * $dur / $n))
            $dst = Join-Path $work ('{0:d3}.jpg' -f $i)
            & $S.FFmpeg -y -v error -ss (Num $t '0.###') -i $path -frames:v 1 -vf $vf -an -sn -q:v 5 $dst 2>&1 | Out-Null
        }
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList ($n * $w), $h
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::FromArgb(11, 15, 20))
            for ($i = 0; $i -lt $n; $i++) {
                $src = Join-Path $work ('{0:d3}.jpg' -f $i)
                if (-not (Test-Path -LiteralPath $src)) { continue }
                $ms = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($src))
                try {
                    $img = [System.Drawing.Image]::FromStream($ms)
                    try { $g.DrawImage($img, ($i * $w), 0, $w, $h) } finally { $img.Dispose() }
                } catch { } finally { $ms.Dispose() }
            }
        } finally { $g.Dispose() }
        $tmpOut = "$out.tmp"
        $bmp.Save($tmpOut, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $bmp.Dispose()
        Move-Item -LiteralPath $tmpOut -Destination $out -Force
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Send-FileRange([string]$path) {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $len   = $fs.Length
        $from  = 0L
        $to    = $len - 1
        $range = $req.Headers['Range']
        $partial = $false
        if ($range -and $range -match 'bytes=(\d*)-(\d*)') {
            $a = $Matches[1]; $b = $Matches[2]
            if ($a -ne '') {
                $from = [long]$a
                if ($b -ne '') { $to = [long]$b }
            } elseif ($b -ne '') {
                $from = [math]::Max(0L, $len - [long]$b)
            }
            if ($from -ge $len) {
                $res.StatusCode = 416
                $res.Headers['Content-Range'] = "bytes */$len"
                return
            }
            if ($to -ge $len) { $to = $len - 1 }
            $partial = $true
        }
        $count = $to - $from + 1
        $res.StatusCode = $(if ($partial) { 206 } else { 200 })
        $res.ContentType = Mime $path
        $res.Headers['Accept-Ranges'] = 'bytes'
        if ($partial) { $res.Headers['Content-Range'] = "bytes $from-$to/$len" }
        $res.ContentLength64 = $count
        $res.SendChunked = $false

        $fs.Position = $from
        $buf = New-Object byte[] 262144
        $left = $count
        while ($left -gt 0) {
            # both args must be Int64 or PowerShell binds Math.Min(Int32,Int32)
            # and overflows on anything past the 2 GB mark
            $want = [int][math]::Min([int64]$buf.Length, [int64]$left)
            $got  = $fs.Read($buf, 0, $want)
            if ($got -le 0) { break }
            $res.OutputStream.Write($buf, 0, $got)
            $left -= $got
        }
    } finally { $fs.Dispose() }
}

# ----------------------------------------------------------------- routing --
try {
    $path = $req.Url.AbsolutePath
    $q    = $req.QueryString

    if ($path -eq '/favicon.ico') { $res.StatusCode = 204; return }

    if ($path -ne '/' -and $q['k'] -ne $S.Key) {
        Send-Text 'Forbidden' 'text/plain' 403
        return
    }

    switch -Regex ($path) {

        '^/$' {
            $res.Headers['Cache-Control'] = 'no-store'
            Send-Text $S.Html 'text/html; charset=utf-8'
            break
        }

        '^/api/open$' {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title  = 'Choose a video to trim'
            $dlg.Filter = 'Video files (*.mp4;*.m4v;*.mov;*.webm)|*.mp4;*.m4v;*.mov;*.webm|All files (*.*)|*.*'
            $dlg.Multiselect = $false
            $dlg.CheckFileExists = $true
            if ($S.LastDir -and (Test-Path -LiteralPath $S.LastDir)) { $dlg.InitialDirectory = $S.LastDir }
            $r = Show-Dialog $dlg
            if ($r -ne [System.Windows.Forms.DialogResult]::OK) {
                Send-Json @{ cancelled = $true }
                break
            }
            try {
                $info = Get-MediaInfo $dlg.FileName
            } catch {
                Send-Json @{ ok = $false; error = "Could not read that file: $($_.Exception.Message)" }
                break
            }
            if ($info.duration -le 0) {
                Send-Json @{ ok = $false; error = 'That file has no readable duration.' }
                break
            }
            $S.LastDir = [IO.Path]::GetDirectoryName($info.path)
            $token = [Guid]::NewGuid().ToString('N')
            $S.Files[$token] = $info
            $out = $info | Select-Object *
            $out | Add-Member -NotePropertyName token -NotePropertyValue $token -Force
            Send-Json $out
            break
        }

        '^/api/stream$' {
            $tok  = [string]$q['t']
            $info = $S.Files[$tok]
            if (-not $info) { Send-Text 'Unknown token' 'text/plain' 404; break }
            Send-FileRange $info.path
            break
        }

        '^/api/strip$' {
            $info = $S.Files[[string]$q['t']]
            if (-not $info) { Send-Text 'Unknown token' 'text/plain' 404; break }
            $sp = Get-StripPath $info.path
            if (-not (Test-Path -LiteralPath $sp)) {
                [System.Threading.Monitor]::Enter($S)   # serialise strip builds
                try {
                    if (-not (Test-Path -LiteralPath $sp)) { New-Strip $info.path $info.duration $sp }
                } finally { [System.Threading.Monitor]::Exit($S) }
            }
            if (-not (Test-Path -LiteralPath $sp)) { Send-Text 'Strip failed' 'text/plain' 500; break }
            $res.Headers['Cache-Control'] = 'max-age=86400'
            Send-Bytes ([IO.File]::ReadAllBytes($sp)) 'image/jpeg'
            break
        }

        '^/api/frame$' {
            $info = $S.Files[[string]$q['t']]
            if (-not $info) { Send-Text 'Unknown token' 'text/plain' 404; break }
            $at = 0.0
            [void][double]::TryParse([string]$q['at'], [Globalization.NumberStyles]::Float, $inv, [ref]$at)
            $f = Get-Frame $info $at
            if (-not (Test-Path -LiteralPath $f)) { Send-Text 'Frame failed' 'text/plain' 500; break }
            try {
                $res.Headers['Cache-Control'] = 'max-age=3600'
                Send-Bytes ([IO.File]::ReadAllBytes($f)) 'image/jpeg'
            } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            break
        }

        '^/api/step$' {
            $info = $S.Files[[string]$q['t']]
            if (-not $info) { Send-Json @{ ok = $false }; break }
            $at = 0.0
            [void][double]::TryParse([string]$q['at'], [Globalization.NumberStyles]::Float, $inv, [ref]$at)
            $dir = $(if ([string]$q['dir'] -eq '-1') { -1 } else { 1 })
            Send-Json @{ ok = $true; t = (Get-StepTime $info $at $dir) }
            break
        }

        '^/api/playinfo$' {
            $info = $S.Files[[string]$q['t']]
            if (-not $info) { Send-Json @{ ok = $false }; break }
            $at = 0.0
            [void][double]::TryParse([string]$q['at'], [Globalization.NumberStyles]::Float, $inv, [ref]$at)
            $at = [math]::Max(0.0, [math]::Min([double]$info.duration, $at))
            # a re-encode can start exactly where asked; a stream copy cannot
            $start = $(if ($info.vOk) { Get-KeyframeTime $info $at } else { $at })
            Send-Json @{ ok = $true; start = $start }
            break
        }

        '^/api/play$' {
            $info = $S.Files[[string]$q['t']]
            if (-not $info) { Send-Text 'Unknown token' 'text/plain' 404; break }
            $at = 0.0
            [void][double]::TryParse([string]$q['start'], [Globalization.NumberStyles]::Float, $inv, [ref]$at)
            $at = [math]::Max(0.0, [math]::Min([double]$info.duration, $at))

            # Remux live into the response: copy the picture when the browser can
            # decode it, re-encode only what it cannot. Nothing is written to disk.
            $vArgs = $(if ($info.vOk) { @('-c:v', 'copy') }
                       else { @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p') })
            $aArgs = $(if (-not $info.hasAudio) { @('-an') }
                       elseif ($info.aOk) { @('-c:a', 'copy') }
                       else { @('-c:a', 'aac', '-b:a', '160k') })
            $ffArgs = @('-hide_banner', '-v', 'error', '-ss', (Num $at '0.######'), '-i', $info.path) +
                      $vArgs + $aArgs +
                      @('-movflags', 'frag_keyframe+empty_moov+default_base_moof', '-f', 'mp4', 'pipe:1')

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $S.FFmpeg
            # PowerShell 5.1 has no ArgumentList, so quote by hand
            $psi.Arguments = (($ffArgs | ForEach-Object {
                if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ }
            }) -join ' ')
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            # stderr must be drained or a full pipe buffer would stall ffmpeg
            $null = $proc.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)

            $res.ContentType = 'video/mp4'
            $res.SendChunked = $true
            $res.Headers['Cache-Control'] = 'no-store'
            try {
                $proc.StandardOutput.BaseStream.CopyTo($res.OutputStream, 65536)
            } catch {
                # the browser seeked or paused - that closes the socket, which is normal
            } finally {
                try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
                try { $proc.Dispose() } catch { }
            }
            break
        }

        '^/api/save$' {
            $body = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
            $p    = $body | ConvertFrom-Json
            $info = $S.Files[[string]$p.token]
            if (-not $info) { Send-Json @{ ok = $false; error = 'That video is no longer loaded.' }; break }

            # Belt and braces: the browser clamps too, but never trust the client.
            $a = [math]::Max(0.0, [math]::Min([double]$p.start, $info.duration))
            $b = [math]::Max(0.0, [math]::Min([double]$p.end,   $info.duration))
            if ($b -lt $a) { $t = $a; $a = $b; $b = $t }

            # The client may send the kept sections left over after splitting and
            # deleting. Rebuild that list here rather than trusting it: clamp every
            # edge, drop slivers, sort, and merge anything that touches.
            $segs = New-Object System.Collections.ArrayList
            if ($p.PSObject.Properties['segments'] -and $p.segments) {
                foreach ($sg in $p.segments) {
                    if ($null -eq $sg -or $sg.Count -lt 2) { continue }
                    $s0 = 0.0; $e0 = 0.0
                    if (-not [double]::TryParse([string]$sg[0], [Globalization.NumberStyles]::Float, $inv, [ref]$s0)) { continue }
                    if (-not [double]::TryParse([string]$sg[1], [Globalization.NumberStyles]::Float, $inv, [ref]$e0)) { continue }
                    if ($e0 -lt $s0) { $t = $s0; $s0 = $e0; $e0 = $t }
                    $s0 = [math]::Max(0.0, [math]::Min($s0, $info.duration))
                    $e0 = [math]::Max(0.0, [math]::Min($e0, $info.duration))
                    if (($e0 - $s0) -lt 0.01) { continue }
                    [void]$segs.Add(@($s0, $e0))
                }
            }
            if ($segs.Count -eq 0) { [void]$segs.Add(@($a, $b)) }
            $segs = @($segs | Sort-Object { $_[0] })
            $merged = New-Object System.Collections.ArrayList
            foreach ($sg in $segs) {
                if ($merged.Count -gt 0 -and $sg[0] -le ($merged[$merged.Count - 1][1] + 0.0005)) {
                    if ($sg[1] -gt $merged[$merged.Count - 1][1]) { $merged[$merged.Count - 1][1] = $sg[1] }
                } else {
                    [void]$merged.Add(@($sg[0], $sg[1]))
                }
            }
            $segs = @($merged)

            $span = 0.0
            foreach ($sg in $segs) { $span += ($sg[1] - $sg[0]) }
            if ($span -lt 0.05) { Send-Json @{ ok = $false; error = 'The selected clip is too short.' }; break }

            $base = [IO.Path]::GetFileNameWithoutExtension($info.name)
            $tag  = '{0}-{1}' -f ([timespan]::FromSeconds($segs[0][0]).ToString('hhmmss')),
                                 ([timespan]::FromSeconds($segs[$segs.Count - 1][1]).ToString('hhmmss'))
            $word = $(if ($segs.Count -gt 1) { 'edit' } else { 'trim' })
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Title            = $(if ($segs.Count -gt 1) { 'Save edited video as' } else { 'Save trimmed video as' })
            $dlg.Filter           = 'MP4 video (*.mp4)|*.mp4'
            $dlg.DefaultExt       = 'mp4'
            $dlg.AddExtension     = $true
            $dlg.OverwritePrompt  = $true
            $dlg.FileName         = "${base}_${word}_${tag}.mp4"
            $dlg.InitialDirectory = [IO.Path]::GetDirectoryName($info.path)
            $r = Show-Dialog $dlg
            if ($r -ne [System.Windows.Forms.DialogResult]::OK) { Send-Json @{ cancelled = $true }; break }

            $outPath = $dlg.FileName
            if ([IO.Path]::GetFullPath($outPath) -eq $info.path) {
                Send-Json @{ ok = $false; error = 'Please save to a different file than the source video.' }
                break
            }

            $id   = [Guid]::NewGuid().ToString('N')
            $prog = Join-Path $S.CacheDir "prog_$id.txt"
            $log  = Join-Path $S.CacheDir "log_$id.txt"
            $filt = ''

            $encArgs = @(
                '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                '-pix_fmt', 'yuv420p',
                '-c:a', 'aac', '-b:a', '192k',
                '-movflags', '+faststart',
                ('"' + $outPath + '"')
            )

            if ($segs.Count -eq 1) {
                # One range: seek to it and copy forward. Unchanged from before
                # splitting existed, and far cheaper on a long file than decoding
                # from frame zero the way the filter path has to.
                $ffArgs = @(
                    '-y', '-hide_banner', '-nostats',
                    '-progress', ('"' + $prog + '"'),
                    '-ss', (Num $segs[0][0] '0.###'),
                    '-i',  ('"' + $info.path + '"'),
                    '-t',  (Num $span '0.###'),
                    '-map', '0:v:0', '-map', '0:a:0?'
                ) + $encArgs
            } else {
                # Several ranges: trim each one, rebase its timestamps to zero and
                # concat, all in a single pass. The graph goes in a file because a
                # dozen sections would otherwise overrun the command line that
                # cmd.exe accepts - see the stderr redirect below.
                $filt = Join-Path $S.CacheDir "filter_$id.txt"
                $sb   = New-Object Text.StringBuilder
                $chain = ''
                for ($i = 0; $i -lt $segs.Count; $i++) {
                    $s0 = Num $segs[$i][0] '0.###'
                    $e0 = Num $segs[$i][1] '0.###'
                    [void]$sb.Append("[0:v]trim=start=${s0}:end=${e0},setpts=PTS-STARTPTS[v$i];`n")
                    $chain += "[v$i]"
                    if ($info.hasAudio) {
                        [void]$sb.Append("[0:a]atrim=start=${s0}:end=${e0},asetpts=PTS-STARTPTS[a$i];`n")
                        $chain += "[a$i]"
                    }
                }
                if ($info.hasAudio) {
                    [void]$sb.Append($chain + "concat=n=$($segs.Count):v=1:a=1[vout][aout]")
                } else {
                    [void]$sb.Append($chain + "concat=n=$($segs.Count):v=1:a=0[vout]")
                }
                [IO.File]::WriteAllText($filt, $sb.ToString(), (New-Object Text.UTF8Encoding $false))

                $mapArgs = $(if ($info.hasAudio) { @('-map', '"[vout]"', '-map', '"[aout]"') }
                             else { @('-map', '"[vout]"', '-an') })
                $ffArgs = @(
                    '-y', '-hide_banner', '-nostats',
                    '-progress', ('"' + $prog + '"'),
                    '-i', ('"' + $info.path + '"'),
                    '-filter_complex_script', ('"' + $filt + '"')
                ) + $mapArgs + $encArgs
            }
            # Start-Process -PassThru never populates ExitCode, so drive the process
            # directly. cmd handles the stderr redirect, which means no pipe to deadlock on.
            $cmdLine = '"{0}" {1} 2>"{2}"' -f $S.FFmpeg, ($ffArgs -join ' '), $log
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName        = $env:ComSpec
            $psi.Arguments       = '/c "' + $cmdLine + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow  = $true
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()
            $S.Jobs[$id] = @{
                state = 'running'; percent = 0.0; proc = $proc; prog = $prog; log = $log
                out = $outPath; outName = [IO.Path]::GetFileName($outPath); span = $span; error = ''
                kind = 'save'; token = [string]$p.token; filt = $filt; parts = $segs.Count
            }
            Send-Json @{ ok = $true; job = $id }
            break
        }

        '^/api/job$' {
            $job = $S.Jobs[[string]$q['id']]
            if (-not $job) { Send-Json @{ state = 'failed'; error = 'Unknown job.' }; break }

            if ($job.state -eq 'running') {
                # progress
                if (Test-Path -LiteralPath $job.prog) {
                    try {
                        $fs = [IO.File]::Open($job.prog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                        $txt = (New-Object IO.StreamReader($fs)).ReadToEnd()
                        $fs.Dispose()
                        $m = [regex]::Matches($txt, 'out_time=(\d+):(\d+):(\d+(?:\.\d+)?)')
                        if ($m.Count -gt 0) {
                            $g = $m[$m.Count - 1].Groups
                            $done = [double]$g[1].Value * 3600 + [double]$g[2].Value * 60 +
                                    [double]::Parse($g[3].Value, $inv)
                            $job.percent = [math]::Min(99.0, $done / $job.span * 100.0)
                        }
                    } catch { }
                }
                if ($job.proc.HasExited) {
                    $code = $job.proc.ExitCode
                    if ($null -eq $code) { $code = -1 }
                    if ($code -eq 0 -and (Test-Path -LiteralPath $job.out)) {
                        $job.state = 'done'; $job.percent = 100.0
                    } else {
                        $tail = ''
                        try {
                            $lines = Get-Content -LiteralPath $job.log -ErrorAction SilentlyContinue |
                                     Where-Object { $_.Trim() } | Select-Object -Last 3
                            $tail = ($lines -join ' | ')
                        } catch { }
                        if (-not $tail) { $tail = "ffmpeg exited with code $code" }
                        $job.state = 'failed'; $job.error = $tail
                    }
                    Remove-Item -LiteralPath $job.prog -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $job.log  -Force -ErrorAction SilentlyContinue
                    if ($job.filt) { Remove-Item -LiteralPath $job.filt -Force -ErrorAction SilentlyContinue }
                }
            }
            Send-Json @{ state = $job.state; percent = $job.percent; outName = $job.outName
                         error = $job.error; kind = $job.kind }
            break
        }

        '^/api/reveal$' {
            $job = $S.Jobs[[string]$q['id']]
            if ($job -and (Test-Path -LiteralPath $job.out)) {
                Start-Process explorer.exe ('/select,"' + $job.out + '"')
            }
            Send-Json @{ ok = $true }
            break
        }

        '^/api/quit$' {
            Send-Json @{ ok = $true }
            $res.OutputStream.Flush()
            $S.Running = $false
            try { $S.Listener.Stop() } catch { }
            break
        }

        default { Send-Text 'Not found' 'text/plain' 404 }
    }
} catch {
    try { Send-Json @{ ok = $false; error = $_.Exception.Message } 500 } catch { }
} finally {
    try { $res.OutputStream.Close() } catch { }
    try { $res.Close() } catch { }
}
}

# ------------------------------------------------------------------ server --

$listener = New-Object System.Net.HttpListener
$port = 0
foreach ($p in 8731..8780) {
    try {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://127.0.0.1:$p/")
        $l.Start()
        $listener = $l
        $port = $p
        break
    } catch {
        try { $l.Close() } catch { }
    }
}
if ($port -eq 0) { throw 'Could not open a local port between 8731 and 8780.' }
$S.Listener = $listener

$iss  = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$pool = [runspacefactory]::CreateRunspacePool(1, 16, $iss, $Host)
$pool.ApartmentState = 'STA'
$pool.Open()

$url = "http://127.0.0.1:$port/"
Write-Ok "server:  $url"
Write-Host ''
Write-Host '   Opening your browser...' -ForegroundColor Gray
Write-Host ''
Write-Host '   Keep this window open while you work.' -ForegroundColor DarkGray
Write-Host '   Close it (or press Ctrl+C) to shut the app down.' -ForegroundColor DarkGray
Write-Host ''

try { Start-Process $url | Out-Null } catch { Write-Bad "Open this address manually: $url" }

$pending = New-Object System.Collections.ArrayList
try {
    while ($S.Running) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        if (-not $S.Running) { break }

        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($Handler).AddArgument($ctx).AddArgument($S)
        $h = $ps.BeginInvoke()
        $null = $pending.Add(@{ PS = $ps; H = $h })

        for ($i = $pending.Count - 1; $i -ge 0; $i--) {
            if ($pending[$i].H.IsCompleted) {
                try { $pending[$i].PS.EndInvoke($pending[$i].H) } catch { }
                $pending[$i].PS.Dispose()
                $pending.RemoveAt($i)
            }
        }
    }
} finally {
    Write-Host ''
    Write-Step 'Shutting down...'
    foreach ($e in $pending) { try { $e.PS.Dispose() } catch { } }
    try { $listener.Stop(); $listener.Close() } catch { }
    try { $pool.Close(); $pool.Dispose() } catch { }
    Get-ChildItem -LiteralPath $S.CacheDir -Filter 'prog_*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $S.CacheDir -Filter 'log_*.txt'  -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $S.CacheDir -Filter 'filter_*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $S.CacheDir -Filter 'frame_*.jpg' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Ok 'Goodbye.'
    Start-Sleep -Milliseconds 600
}

exit 0
