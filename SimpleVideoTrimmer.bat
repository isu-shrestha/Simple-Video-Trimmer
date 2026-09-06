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

function Install-FFmpeg {
    $dest = Join-Path $AppDir 'ffmpeg\bin'
    $tmp  = Join-Path $env:TEMP ('svt_ffmpeg_' + [Guid]::NewGuid().ToString('N'))
    $zip  = Join-Path $env:TEMP 'svt_ffmpeg.zip'
    $urls = @(
        'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
        'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
    )

    Write-Host ''
    Write-Step 'ffmpeg was not found on this PC.'
    Write-Step 'Downloading a portable copy - about 90 MB - into the folder beside this app.'
    Write-Step 'This happens once. No admin rights, nothing installed system-wide.'
    Write-Host ''

    $got = $false
    foreach ($url in $urls) {
        try {
            Write-Step "Fetching $url"
            if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
            try   { Start-BitsTransfer -Source $url -Destination $zip -Description 'ffmpeg' -ErrorAction Stop }
            catch { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing }
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
Write-Ok "ffmpeg:  $FFmpeg"

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
  .jump{color:var(--dim);background:transparent}
  .jump:hover:not(:disabled){color:var(--text)}
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
    <span class="chip" id="audioChip"></span>
  </div>

  <div class="stage">
    <video id="v" preload="auto"></video>
    <audio id="au" preload="auto"></audio>
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
      <button id="bPlay" disabled title="Play / Pause (Space)"><svg id="icPlay" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg><span id="txPlay">Play</span></button>
      <button id="bPrev" class="iconbtn" disabled title="Previous frame (Left arrow)"><svg viewBox="0 0 24 24"><path d="M6 6h2v12H6zm12 0v12l-9-6z"/></svg></button>
      <button id="bNext" class="iconbtn" disabled title="Next frame (Right arrow)"><svg viewBox="0 0 24 24"><path d="M16 6h2v12h-2zM6 6l9 6-9 6z"/></svg></button>
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
        <div class="h" id="hA" title="Drag to move the start point"></div>
        <div class="h" id="hB" title="Drag to move the end point"></div>
        <div class="ph" id="ph"></div>
      </div>
      <div class="pop" id="pop"><div class="img" id="popImg"></div><div class="lab" id="popLab">00:00</div></div>
    </div>
    <div class="ruler"><span>00:00</span><span id="rMid">--:--</span><span id="rEnd">--:--</span></div>

    <div class="trim">
      <div class="grp">
        <span class="lab a">Start</span>
        <input type="text" id="inA" value="00:00:00.000" disabled title="Type a time, e.g. 1:23.500">
        <button id="bSetA" class="mark a" disabled title="Move the START point to the scrubber  (shortcut: I)"><svg viewBox="0 0 24 24"><path d="M11 4h2v9h3.5L12 18l-4.5-5H11z" /><path d="M5 20h14v2H5z"/></svg>Set</button>
        <button id="bGoA" class="jump" disabled title="Move the scrubber to the START point"><svg viewBox="0 0 24 24"><path d="M4 11h9V7.5L18 12l-5 4.5V13H4z"/></svg>Go</button>
      </div>
      <div class="grp">
        <span class="lab b">End</span>
        <input type="text" id="inB" value="00:00:00.000" disabled title="Type a time, e.g. 1:23.500">
        <button id="bSetB" class="mark b" disabled title="Move the END point to the scrubber  (shortcut: O)"><svg viewBox="0 0 24 24"><path d="M11 4h2v9h3.5L12 18l-4.5-5H11z" /><path d="M5 20h14v2H5z"/></svg>Set</button>
        <button id="bGoB" class="jump" disabled title="Move the scrubber to the END point"><svg viewBox="0 0 24 24"><path d="M4 11h9V7.5L18 12l-5 4.5V13H4z"/></svg>Go</button>
      </div>
      <button id="bReset" class="ghost" disabled title="Select the whole video again">Reset</button>
      <div class="len">
        <div class="box">Clip length <b id="tLen">00:00:00.000</b></div>
        <div class="bar" id="bar"><i id="barFill"></i></div>
        <button id="bSave" class="primary" disabled title="Trim and save as MP4 (Ctrl+S)"><svg viewBox="0 0 24 24"><path d="M17 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V7l-4-4zm-5 16a3 3 0 1 1 0-6 3 3 0 0 1 0 6zm3-10H6V5h9v4z"/></svg><span id="txSave">Save Trimmed Video</span></button>
      </div>
    </div>
  </div>

  <div class="hint">
    <kbd>Space</kbd> play/pause &nbsp; <kbd>&larr;</kbd> <kbd>&rarr;</kbd> step frame (hold <kbd>Shift</kbd> for 1s)
    &nbsp; <kbd>I</kbd> set start &nbsp; <kbd>O</kbd> set end &nbsp; <kbd>Ctrl</kbd>+<kbd>S</kbd> save
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
var mode = "video";      // "video" = browser decodes it | "frames" = server-rendered stills
var audioState = "none"; // none | preparing | ready | failed
var au = $("au");
var dragging = null;     // "A" | "B" | "scrub"
var resumeAfterScrub = false;
var selPlay = false;
var pollTimer = null;

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
  $("tLen").textContent = fmt(Math.max(0, B - A));
  renderPlayhead();
}
function renderPlayhead(){
  $("ph").style.left = (D ? clamp(PH / D, 0, 1) * 100 : 0) + "%";
  $("tNow").textContent = fmt(PH);
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
  var fn = $("fname");
  while (fn.firstChild) fn.removeChild(fn.firstChild);
  var b = document.createElement("b"); b.textContent = j.name;
  fn.appendChild(b);
  fn.appendChild(document.createTextNode(
    "  -  " + j.width + "x" + j.height + " - " + j.fps.toFixed(2) + " fps - " +
    j.sizeText + " - " + fmt(D, false)));

  $("empty").style.display = "none";
  PH = 0;
  try { au.pause(); } catch (e) {}
  au.removeAttribute("src");
  audioState = "none";
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
  var always = ["bPrev","bNext","inA","inB","bSetA","bSetB","bGoA","bGoB","bReset","bSave"];
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
  if (Math.abs(at - lastFrameAt) < 0.01 && lastFrameAt >= 0) return;
  if (frameBusy){ framePending = at; return; }
  frameBusy = true;
  var url = api("/api/frame", "t=" + M.token + "&at=" + at.toFixed(2));
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

function setChip(text, cls, spinning){
  var c = $("audioChip");
  c.className = "chip " + (cls || "");
  c.innerHTML = (spinning ? '<span class="spin"></span>' : "") + "";
  c.appendChild(document.createTextNode(text));
}

function canPlayNow(){
  return mode === "video" ? vOk : (audioState === "ready");
}
function syncPlayButtons(){
  var on = canPlayNow();
  $("bPlay").disabled = !on;
  $("bSel").disabled  = !on;
  $("bMute").disabled = !on;
  $("vol").disabled   = !on;
  if (!on && mode === "frames"){
    var tip = audioState === "preparing" ? "Audio is still being prepared"
            : audioState === "none"      ? "This file has no audio track, so there is nothing to play"
            : "Audio could not be prepared";
    $("bPlay").title = tip;
    $("bSel").title  = tip;
  } else {
    $("bPlay").title = "Play / Pause (Space)";
    $("bSel").title  = "Play only the selected range";
  }
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
    "Preview mode - your browser cannot decode this file because " + (j.why || "of an unsupported codec") +
    ". Frames are rendered on demand as you scrub; trimming and saving always read the original file.";
  lastFrameAt = -1;
  showFrame(0);

  if (j.audioMode === "none"){
    audioState = "none";
    setChip("No audio track", "off", false);
  } else {
    audioState = "preparing";
    setChip("Preparing audio...", "work", true);
    startAudioPrep();
  }
  syncPlayButtons();
}

/* Runs by itself in the background - nothing here blocks scrubbing or trimming. */
function startAudioPrep(){
  fetch(api("/api/prep", "t=" + M.token), { method: "POST" })
    .then(function(r){ return r.json(); })
    .then(function(j){
      if (!j.ok){ audioFailed(j.error); return; }
      if (j.silent){ audioState = "none"; setChip("No audio track", "off", false); syncPlayButtons(); return; }
      if (j.ready){ audioReady(); return; }
      pollAudio(j.job, j.mode);
    })
    .catch(function(e){ audioFailed(e.message); });
}

function pollAudio(id, howMode){
  var token = M.token;
  var t = setInterval(function(){
    if (!M || M.token !== token){ clearInterval(t); return; }   /* user opened another file */
    fetch(api("/api/job", "id=" + id))
      .then(function(r){ return r.json(); })
      .then(function(j){
        if (j.state === "running"){
          setChip("Preparing audio " + Math.round(j.percent) + "%", "work", true);
          return;
        }
        clearInterval(t);
        if (j.state === "done") audioReady();
        else audioFailed(j.error);
      })
      .catch(function(){ });
  }, 700);
}

function audioReady(){
  audioState = "ready";
  au.src = api("/api/audio", "t=" + M.token);
  au.load();
  au.volume = +$("vol").value;
  try { au.currentTime = PH; } catch (e) {}
  setChip("Audio ready", "done", false);
  syncPlayButtons();
  toast("Audio is ready - you can play this video now.", "good");
}

function audioFailed(msg){
  audioState = "failed";
  setChip("Audio unavailable", "off", false);
  syncPlayButtons();
  if (msg) toast("Could not prepare audio: " + msg, "warn");
}

/* audio is the clock in frames mode */
au.addEventListener("timeupdate", function(){
  if (mode !== "frames") return;
  PH = au.currentTime;
  if (selPlay && PH >= B){ au.pause(); seek(B); selPlay = false; }
  renderPlayhead();
  showFrame(PH);
});
au.addEventListener("play",  function(){
  $("icPlay").innerHTML = '<path d="M6 5h4v14H6zm8 0h4v14h-4z"/>';
  $("txPlay").textContent = "Pause";
});
au.addEventListener("pause", function(){
  $("icPlay").innerHTML = '<path d="M8 5v14l11-7z"/>';
  $("txPlay").textContent = "Play";
  selPlay = false;
});

/* --------------------------- timeline input --------------------------- */
function posToTime(clientX){
  var r = $("tl").getBoundingClientRect();
  return clamp((clientX - r.left) / r.width, 0, 1) * D;
}
function seek(t){
  if (!M) return;
  PH = clamp(t, 0, D);
  if (mode === "video"){
    if (vOk) { try { v.currentTime = PH; } catch (e) {} }
  } else {
    if (audioState === "ready") { try { au.currentTime = PH; } catch (e) {} }
    showFrame(PH);
  }
  renderPlayhead();
}

$("tl").addEventListener("pointerdown", function(e){
  if (!M) return;
  dragging = (e.target === $("hA")) ? "A" : (e.target === $("hB")) ? "B" : "scrub";
  try { $("tl").setPointerCapture(e.pointerId); } catch (err) {}
  if (dragging === "scrub"){
    var el = (mode === "video") ? v : au;
    resumeAfterScrub = canPlayNow() && !el.paused;
    try { el.pause(); } catch (err) {}
    selPlay = false;
    seek(posToTime(e.clientX));
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
  if (dragging === "scrub" && resumeAfterScrub && canPlayNow()){
    (mode === "video" ? v : au).play();
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

/* ----------------------------- transport ------------------------------ */
function togglePlay(){
  if (!M || !canPlayNow()) return;
  var el = (mode === "video") ? v : au;
  if (el.paused){ if (PH >= D - 0.02) seek(0); el.play(); }
  else el.pause();
}
v.addEventListener("play", function(){
  $("icPlay").innerHTML = '<path d="M6 5h4v14H6zm8 0h4v14h-4z"/>';
  $("txPlay").textContent = "Pause";
});
v.addEventListener("pause", function(){
  $("icPlay").innerHTML = '<path d="M8 5v14l11-7z"/>';
  $("txPlay").textContent = "Play";
  selPlay = false;
});
v.addEventListener("timeupdate", function(){
  PH = v.currentTime;
  if (selPlay && PH >= B){ v.pause(); seek(B); selPlay = false; }
  renderPlayhead();
});
v.addEventListener("seeked", function(){ PH = v.currentTime; renderPlayhead(); });
v.addEventListener("loadedmetadata", function(){
  if (M && (!D || !isFinite(D)) && isFinite(v.duration)){ D = v.duration; B = D; render(); }
});
v.addEventListener("error", function(){
  if (M && mode === "video"){ enterFramesMode(M); }
});

function step(dir, big){
  if (!M) return;
  try { v.pause(); au.pause(); } catch (e) {}
  seek(PH + dir * (big ? 1 : 1 / (M.fps || 25)));
}

/* ------------------------------- wiring ------------------------------- */
$("bOpen").onclick = openVideo;
$("bOpen2").onclick = openVideo;
$("bPlay").onclick = togglePlay;
$("bPrev").onclick = function(e){ step(-1, e.shiftKey); };
$("bNext").onclick = function(e){ step(1, e.shiftKey); };
$("bSel").onclick = function(){
  if (!M || !canPlayNow()) return;
  seek(A); selPlay = true;
  (mode === "video" ? v : au).play();
};
$("bMute").onclick = function(){
  v.muted = !v.muted;
  au.muted = v.muted;
  $("icVol").innerHTML = v.muted
    ? '<path d="M3 9v6h4l5 5V4L7 9H3zm18.6 1.4L20.2 9l-2.1 2.1L16 9l-1.4 1.4 2.1 2.1-2.1 2.1L16 16l2.1-2.1L20.2 16l1.4-1.4-2.1-2.1z"/>'
    : '<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z"/>';
};
$("vol").oninput = function(e){
  v.volume = +e.target.value; au.volume = +e.target.value;
  v.muted = false; au.muted = false;
};
$("bSetA").onclick = function(){ setA(PH); };
$("bSetB").onclick = function(){ setB(PH); };
$("bGoA").onclick  = function(){ try { v.pause(); au.pause(); } catch (e) {} seek(A); };
$("bGoB").onclick  = function(){ try { v.pause(); au.pause(); } catch (e) {} seek(B); };
$("bReset").onclick = function(){ A = 0; B = D; render(); toast("Selection reset to the whole video."); };

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
  if (e.ctrlKey || e.altKey || e.metaKey) return;
  switch (e.key){
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
  if (B - A < MIN_LEN){ toast("The selected clip is too short to save.", "warn"); return; }
  $("bSave").disabled = true;
  $("txSave").textContent = "Choose location...";
  fetch(api("/api/save"), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ token: M.token, start: A, end: B })
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

function Get-AudioPath([string]$path) {
    $fi  = Get-Item -LiteralPath $path
    $sig = 'aud|{0}|{1}|{2}' -f $fi.FullName, $fi.Length, $fi.LastWriteTimeUtc.Ticks
    $md5 = [Security.Cryptography.MD5]::Create()
    try   { $h = ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($sig)) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $md5.Dispose() }
    Join-Path $S.CacheDir "aud_$h.m4a"
}

# One still frame taken straight from the source. Roughly 100 ms even on a 4 GB
# file, which is what lets an undecodable video be scrubbed without copying any
# video data at all.
function Get-Frame([object]$info, [double]$at) {
    $fw = [math]::Min(960, [int]$info.width)
    if ($fw -lt 16) { $fw = 960 }
    $dst = Join-Path $S.CacheDir ('frame_' + [Guid]::NewGuid().ToString('N') + '.jpg')
    $t   = [math]::Max(0, [math]::Min(([double]$info.duration - 0.04), $at))
    & $S.FFmpeg -y -v error -ss (Num $t '0.###') -i $info.path -frames:v 1 -vf "scale=${fw}:-2" -an -sn -q:v 4 $dst 2>&1 | Out-Null
    return $dst
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
            $t   = [math]::Max(0, [math]::Min($dur - 0.05, ($i + 0.5) * $dur / $n))
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

        '^/api/audio$' {
            $ap = $S.Audio[[string]$q['t']]
            if (-not $ap -or -not (Test-Path -LiteralPath $ap)) { Send-Text 'No audio prepared' 'text/plain' 404; break }
            Send-FileRange $ap
            break
        }

        '^/api/prep$' {
            $tok  = [string]$q['t']
            $info = $S.Files[$tok]
            if (-not $info) { Send-Json @{ ok = $false; error = 'That video is no longer loaded.' }; break }
            if ($info.audioMode -eq 'none') { Send-Json @{ ok = $true; ready = $true; silent = $true }; break }

            # Audio only - the video is never copied, so this costs tens of MB
            # instead of the gigabytes a full remux would have needed.
            $dest = Get-AudioPath $info.path
            if (Test-Path -LiteralPath $dest) {
                $S.Audio[$tok] = $dest
                Send-Json @{ ok = $true; ready = $true }
                break
            }

            $id   = [Guid]::NewGuid().ToString('N')
            $prog = Join-Path $S.CacheDir "prog_$id.txt"
            $log  = Join-Path $S.CacheDir "log_$id.txt"
            $aArgs = $(if ($info.audioMode -eq 'copy') { @('-c:a', 'copy') } else { @('-c:a', 'aac', '-b:a', '160k') })
            $ffArgs = @(
                '-y', '-hide_banner', '-nostats',
                '-progress', ('"' + $prog + '"'),
                '-i', ('"' + $info.path + '"'),
                '-vn', '-sn', '-map', '0:a:0'
            ) + $aArgs + @('-movflags', '+faststart', ('"' + $dest + '"'))

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
                out = $dest; outName = [IO.Path]::GetFileName($dest); span = [double]$info.duration
                error = ''; kind = 'prep'; token = $tok
            }
            Send-Json @{ ok = $true; job = $id; mode = $info.audioMode }
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
            $span = $b - $a
            if ($span -lt 0.05) { Send-Json @{ ok = $false; error = 'The selected clip is too short.' }; break }

            $base = [IO.Path]::GetFileNameWithoutExtension($info.name)
            $tag  = '{0}-{1}' -f ([timespan]::FromSeconds($a).ToString('hhmmss')),
                                 ([timespan]::FromSeconds($b).ToString('hhmmss'))
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Title            = 'Save trimmed video as'
            $dlg.Filter           = 'MP4 video (*.mp4)|*.mp4'
            $dlg.DefaultExt       = 'mp4'
            $dlg.AddExtension     = $true
            $dlg.OverwritePrompt  = $true
            $dlg.FileName         = "${base}_trim_${tag}.mp4"
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
            $ffArgs = @(
                '-y', '-hide_banner', '-nostats',
                '-progress', ('"' + $prog + '"'),
                '-ss', (Num $a '0.###'),
                '-i',  ('"' + $info.path + '"'),
                '-t',  (Num $span '0.###'),
                '-map', '0:v:0', '-map', '0:a:0?',
                '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                '-pix_fmt', 'yuv420p',
                '-c:a', 'aac', '-b:a', '192k',
                '-movflags', '+faststart',
                ('"' + $outPath + '"')
            )
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
                kind = 'save'; token = [string]$p.token
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
                        if ($job.kind -eq 'prep') { $S.Audio[$job.token] = $job.out }
                    } else {
                        if ($job.kind -eq 'prep') { Remove-Item -LiteralPath $job.out -Force -ErrorAction SilentlyContinue }
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
$pool = [runspacefactory]::CreateRunspacePool(1, 8, $iss, $Host)
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
    Get-ChildItem -LiteralPath $S.CacheDir -Filter 'aud_*.m4a'   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $S.CacheDir -Filter 'frame_*.jpg' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Ok 'Goodbye.'
    Start-Sleep -Milliseconds 600
}

exit 0
