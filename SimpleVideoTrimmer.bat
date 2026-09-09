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

  /* track list - the clips in the order they play */
  .tracks{margin-bottom:11px;padding-bottom:11px;border-bottom:1px solid var(--line)}
  .tkhead{display:flex;align-items:center;gap:10px;margin-bottom:8px}
  .tkhint{font-size:12px;color:#6c7986;flex:1;min-width:0}
  .tklist{display:flex;flex-direction:column;gap:5px;max-height:132px;overflow-y:auto}
  .tklist:empty{display:none}
  .tk{display:flex;align-items:center;gap:9px;padding:5px 8px;border-radius:7px;
    background:#0b0f14;border:1px solid var(--line)}
  .tk.on{border-color:var(--accent2);background:#111a26}
  .tk .no{font:12px/1 "Consolas",monospace;color:var(--bg);background:var(--dim);
    border-radius:4px;padding:4px 6px;min-width:20px;text-align:center;font-weight:700;flex:none}
  .tk.on .no{background:var(--accent)}
  .tk .nm{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px}
  .tk .meta{font:11px/1 "Consolas",monospace;color:#6c7986;white-space:nowrap;flex:none}
  .tk .warn{color:var(--warn);flex:none}
  .tk .warn svg{width:13px;height:13px}
  .tk button{padding:4px 6px;background:transparent;border-color:transparent}
  .tk button svg{width:13px;height:13px}
  .tk button:hover:not(:disabled){background:#243040;border-color:#3b4a5c}
  .tk button.rm:hover:not(:disabled){background:#341d1c;border-color:#96413d;color:#ff9d96}
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
  /* one filmstrip slice per track, widths proportional to their durations */
  #strip{position:absolute;left:0;right:0;top:0;bottom:0;opacity:.85}
  #strip .sv{position:absolute;top:0;bottom:0;background-repeat:no-repeat;background-size:100% 100%}
  #strip .sv.j{border-left:2px solid #7dc0ff;box-shadow:-2px 0 6px rgba(0,0,0,.7)}
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
      <p>Add an MP4, M4V, MOV or WebM file to start. Add more to stitch them end to end.</p>
      <button id="bOpen2" class="primary">Add your first video...</button>
    </div>
    <img id="frame" alt="">
  </div>

  <div class="panel">
    <div class="tracks" id="tracks">
      <div class="tkhead">
        <span class="lab">Tracks</span>
        <span class="tkhint" id="tkHint">played in order, one after another</span>
        <button id="bAdd" class="primary"><svg viewBox="0 0 24 24"><path d="M13 11V5h-2v6H5v2h6v6h2v-6h6v-2z"/></svg>Add Track</button>
      </div>
      <div class="tklist" id="tkList"></div>
    </div>

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

/* ---- tracks ----
   TR holds the clips in the order they play: track 2 starts where track 1 ends.
   Everything the user touches - the playhead, the trim points, the timeline - is
   in PROGRAM time, the clips laid end to end. Each track keeps its own cuts and
   deletions in its OWN source time, so removing or reordering a track carries
   its edits with it instead of smearing them across the timeline. */
var TR  = [];            // tracks, in play order
var cur = -1;            // index of the track the playhead is sitting in
var M = null;            // TR[cur] - the clip currently loaded in the <video>
var A = 0, B = 0, D = 0; // trim start, trim end, total program length
var PH = 0;              // playhead in program time, kept independent of <video>
                         // so the timeline still works on undecodable files
var vOk = false;         // is the <video> element actually usable?
var mode = "video";      // "video" = browser decodes it | "frames" = live-remuxed stream
var playStart = 0;       // offset the preview stream was started at
var dragging = null;     // "A" | "B" | "scrub"
var resumeAfterScrub = false;
var selPlay = false;
var pollTimer = null;
var saving = false;   // an export is in flight and owns the Save button label

/* ---- cuts and deleted sections ----
   The timeline always shows the program as it stands - it has to, because the
   filmstrips behind it are fixed renders of whole files. So a deleted section
   stays where it is and is drawn struck through; the closing-up happens in the
   output, whose length is what the "Clip length" box reports.

   Deletions are stored as time RANGES rather than segment indices on purpose:
   adding a new split then never has to remap which segments were deleted. */
var selSeg = -1;         // index into segments() of the highlighted section
var hist = [];           // undo snapshots
var skipGuardUntil = 0;  // suppress skip checks until the playhead passes this
var restarting = false;  // the <video> is being respun across a cut or a join
var skipTimer = null;    // handle for the restarting-flag timeout, so a second skip can cancel it

var EPS = 0.0005;
function frameEps(){ return Math.max(0.02, 0.5 / ((M && M.fps) || 25)); }

/* ---- program time <-> track-local time ---- */
function trackOff(i){
  var o = 0;
  for (var k = 0; k < i && k < TR.length; k++) o += TR[k].dur;
  return o;
}
function trackAt(t){
  var o = 0;
  for (var i = 0; i < TR.length; i++){
    if (t < o + TR[i].dur - 1e-9) return i;
    o += TR[i].dur;
  }
  return TR.length ? TR.length - 1 : -1;
}
function toLocal(t){
  var i = trackAt(t);
  if (i < 0) return null;
  return { i: i, t: clamp(t - trackOff(i), 0, TR[i].dur) };
}

/* Program-time views of every track's edits, rebuilt whenever anything moves.
   A track boundary counts as a cut, so no section ever spans two clips - which
   is what lets a section be mapped back to exactly one track on export. */
var cutsP = [], delsP = [];
function recalc(){
  var i, j, o = 0;
  D = 0;
  for (i = 0; i < TR.length; i++) D += TR[i].dur;
  cutsP = []; delsP = [];
  for (i = 0; i < TR.length; i++){
    if (i > 0) cutsP.push(o);
    for (j = 0; j < TR[i].cuts.length; j++) cutsP.push(o + TR[i].cuts[j]);
    for (j = 0; j < TR[i].dels.length; j++) delsP.push([o + TR[i].dels[j][0], o + TR[i].dels[j][1]]);
    o += TR[i].dur;
  }
  cutsP.sort(function(x, y){ return x - y; });
  delsP.sort(function(x, y){ return x[0] - y[0]; });
  var m = [];
  for (i = 0; i < delsP.length; i++){
    if (m.length && delsP[i][0] <= m[m.length - 1][1] + EPS){
      if (delsP[i][1] > m[m.length - 1][1]) m[m.length - 1][1] = delsP[i][1];
    } else m.push([delsP[i][0], delsP[i][1]]);
  }
  delsP = m;
  A = clamp(A, 0, D);
  B = clamp(B, 0, D);
  if (B < A) B = D;
}

/* [0, ...cuts, D] -> the sections the user sees and clicks */
function segments(){
  if (!TR.length || !(D > 0)) return [];
  var b = [0], i;
  for (i = 0; i < cutsP.length; i++) b.push(cutsP[i]);
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
  for (var i = 0; i < delsP.length; i++) if (t > delsP[i][0] && t < delsP[i][1]) return true;
  return false;
}
/* the far edge of the deleted range containing t, or -1 */
function delEndAt(t){
  for (var i = 0; i < delsP.length; i++) if (t >= delsP[i][0] && t < delsP[i][1] - EPS) return delsP[i][1];
  return -1;
}
function segAt(t){
  var sg = segments();
  if (!sg.length) return -1;
  if (t <= sg[0].s) return 0;          /* below zero is the FIRST section, not the last */
  for (var i = 0; i < sg.length; i++) if (t >= sg[i].s && t <= sg[i].e) return i;
  return sg.length - 1;
}
function normTrackDels(i){
  var d = TR[i].dels;
  d.sort(function(x, y){ return x[0] - y[0]; });
  var out = [];
  for (var k = 0; k < d.length; k++){
    if (out.length && d[k][0] <= out[out.length - 1][1] + EPS){
      if (d[k][1] > out[out.length - 1][1]) out[out.length - 1][1] = d[k][1];
    } else out.push([d[k][0], d[k][1]]);
  }
  TR[i].dels = out;
}
/* both take PROGRAM time and write back to whichever track owns it */
function addDel(s, e){
  var i = trackAt((s + e) / 2);
  if (i < 0) return;
  var o = trackOff(i);
  TR[i].dels.push([clamp(s - o, 0, TR[i].dur), clamp(e - o, 0, TR[i].dur)]);
  normTrackDels(i);
  recalc();
}
function subDel(s, e){
  var i = trackAt((s + e) / 2);
  if (i < 0) return;
  var o = trackOff(i), s0 = s - o, e0 = e - o, out = [], k;
  for (k = 0; k < TR[i].dels.length; k++){
    var r = TR[i].dels[k];
    if (r[1] <= s0 + EPS || r[0] >= e0 - EPS){ out.push(r); continue; }
    if (r[0] < s0 - EPS) out.push([r[0], s0]);
    if (r[1] > e0 + EPS) out.push([e0, r[1]]);
  }
  TR[i].dels = out;
  recalc();
}

/* kept sections in program time - what the length box and Play Selection use */
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
/* the same sections for export, each mapped back to its own track's source
   time and kept separate across joins so the encoder concatenates them in order */
function keptParts(){
  var sg = segments(), out = [];
  for (var i = 0; i < sg.length; i++){
    if (sg[i].del) continue;
    var s = Math.max(sg[i].s, A), e = Math.min(sg[i].e, B);
    if (e - s < 0.01) continue;
    var k = trackAt((s + e) / 2);
    if (k < 0) continue;
    var o = trackOff(k);
    out.push({ t: TR[k].token,
               s: +clamp(s - o, 0, TR[k].dur).toFixed(6),
               e: +clamp(e - o, 0, TR[k].dur).toFixed(6) });
  }
  return out;
}
function outLen(){
  var r = keptRanges(), t = 0;
  for (var i = 0; i < r.length; i++) t += r[i][1] - r[i][0];
  return t;
}
function hasEdits(){
  for (var i = 0; i < TR.length; i++) if (TR[i].cuts.length || TR[i].dels.length) return true;
  return false;
}

/* An undo entry keeps the track ORDER and each track's edits, so adding,
   removing and reordering are undoable alongside splits and deletes. Only the
   track-list operations restore A/B as well - reverting a split should not also
   throw away trim handles the user has moved since. */
function snapshot(withTrim){
  hist.push({
    order: TR.slice(),
    edits: TR.map(function(t){
      return { o: t, cuts: t.cuts.slice(), dels: t.dels.map(function(r){ return r.slice(); }) };
    }),
    sel: selSeg, A: A, B: B, ab: !!withTrim
  });
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
  if (!TR.length || !(D > 0)) return;
  var sg = segments(), i, j, el;
  var pct = function(t){ return clamp(t / D, 0, 1) * 100; };

  for (i = 0; i < sg.length; i++){
    if (!sg[i].del) continue;
    el = document.createElement("div");
    el.className = "gone";
    el.style.left  = pct(sg[i].s) + "%";
    el.style.width = Math.max(0, pct(sg[i].e) - pct(sg[i].s)) + "%";
    host.appendChild(el);
  }
  /* only the user's own splits get a marker - the joins between tracks are
     already drawn as dividers on the filmstrip itself */
  var o = 0;
  for (i = 0; i < TR.length; i++){
    for (j = 0; j < TR[i].cuts.length; j++){
      el = document.createElement("div");
      el.className = "cut";
      el.style.left = pct(o + TR[i].cuts[j]) + "%";
      host.appendChild(el);
    }
    o += TR[i].dur;
  }
  if (selSeg >= 0 && selSeg < sg.length && sg.length > 1){
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
  var sec = (selSeg >= 0 && selSeg < sg.length) ? sg[selSeg] : null;
  var restore = !!(sec && sec.del);
  $("txDel").textContent = restore ? "Restore Section" : "Delete Section";
  $("icDel").innerHTML = restore
    ? '<path d="M13 3a9 9 0 0 0-9 9H1l4 4 4-4H6a7 7 0 1 1 7 7v2a9 9 0 0 0 0-18z"/>'
    : '<path d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/>';
  $("bDel").title = restore
    ? "Put the highlighted section back into the video (shortcut: Delete)"
    : "Remove the highlighted section - what is left closes up (shortcut: Delete)";
  /* nothing to delete until there is more than one section to choose between */
  $("bDel").disabled = !sec || (!restore && sg.length < 2);

  /* an export in flight owns this label - do not stomp on its progress text */
  if (!saving){
    var many = TR.length > 1;
    $("txSave").textContent = many ? "Save Stitched Video" : "Save Trimmed Video";
    $("bSave").title = many
      ? "Stitch the tracks together and save as MP4 (Ctrl+S)"
      : "Trim and save as MP4 (Ctrl+S)";
  }
}

/* A split is pointless on top of an existing boundary, and a zero-length
   section would only confuse the export. */
function canSplitAt(t){
  if (!TR.length || !(D > 0)) return false;
  var eps = frameEps(), i;
  if (t <= eps || t >= D - eps) return false;
  /* cutsP carries the track joins too, so a join never gets split again */
  for (i = 0; i < cutsP.length; i++) if (Math.abs(cutsP[i] - t) < eps) return false;
  return true;
}
function renderPlayhead(){
  $("ph").style.left = (D ? clamp(PH / D, 0, 1) * 100 : 0) + "%";
  $("tNow").textContent = fmt(PH);
  /* cheap enough to run on every timeupdate; the rest of syncEditButtons
     rewrites innerHTML, so it stays in render() */
  if (M) $("bSplit").disabled = !canSplitAt(PH);
}

/* ------------------------------ tracks -------------------------------- */
function addTrack(){
  $("bAdd").disabled = true; $("bOpen2").disabled = true;
  var waiting = toast("Waiting for the file dialog...", "");
  fetch(api("/api/open"), { method: "POST" })
    .then(function(r){ return r.json(); })
    .then(function(j){
      kill(waiting);
      if (j.cancelled) return;
      if (!j.ok){ toast(j.error || "Could not open that file.", "bad"); return; }
      acceptTrack(j);
    })
    .catch(function(e){ kill(waiting); toast("Could not reach the local server: " + e.message, "bad"); })
    .then(function(){ $("bAdd").disabled = false; $("bOpen2").disabled = false; });
}

function acceptTrack(j){
  var first = TR.length === 0;
  /* a selection that ran to the end should grow to cover the new clip */
  var toEnd = first || Math.abs(B - D) < EPS;
  snapshot(true);
  j.dur  = j.duration;
  j.cuts = [];
  j.dels = [];
  TR.push(j);
  recalc();
  if (first){ A = 0; B = D; }
  else if (toEnd) B = D;
  selPlay = false;
  selSeg = -1;

  $("empty").style.display = "none";
  $("tDur").textContent = fmt(D);
  $("rMid").textContent = fmtShort(D / 2);
  $("rEnd").textContent = fmtShort(D);
  /* trimming never needs a decoder, so those controls are always live */
  var always = ["bPrev","bNext","inA","inB","bSetA","bSetB","bGoA","bReset","bSave"];
  for (var i = 0; i < always.length; i++) $(always[i]).disabled = false;

  if (first){ PH = 0; activate(0, 0, false); }
  refreshProgram();
  if (!first){
    toast("Track " + TR.length + " added - " + j.name + " plays after track " + (TR.length - 1) + ".", "good");
    if (mismatch(j)) noteMismatch(j);
  }
}

function removeTrack(i){
  if (i < 0 || i >= TR.length) return;
  var wasName = TR[i].name;
  snapshot(true);
  var toEnd = Math.abs(B - D) < EPS;
  TR.splice(i, 1);
  recalc();
  if (toEnd || B > D) B = D;
  selSeg = -1;
  if (!TR.length){ clearProgram(); toast("Removed " + wasName + " - no tracks left.", ""); return; }
  if (cur >= TR.length) cur = TR.length - 1;
  refreshProgram();
  goTo(clamp(PH, 0, D), false);
  activate(trackAt(PH), toLocal(PH).t, false);
  toast("Removed " + wasName + ".", "");
}

function moveTrack(i, dir){
  var k = i + dir;
  if (i < 0 || i >= TR.length || k < 0 || k >= TR.length) return;
  snapshot(true);
  var t = TR[i]; TR[i] = TR[k]; TR[k] = t;
  recalc();
  selSeg = -1;
  cur = TR.indexOf(M);
  refreshProgram();
  goTo(clamp(PH, 0, D), false);
}

function clearProgram(){
  TR = []; cur = -1; M = null; D = 0; A = 0; B = 0; PH = 0;
  cutsP = []; delsP = []; selSeg = -1; selPlay = false;
  skipGuardUntil = 0; restarting = false;
  /* the undo stack has to go with it: nothing in it refers to anything still
     loaded, and Ctrl+Z has no !!M guard, so leaving it would let a discarded
     file come back on top of whatever the user opens next */
  hist = [];
  if (skipTimer){ clearTimeout(skipTimer); skipTimer = null; }
  stopStream();
  v.style.display = "none";
  $("frame").style.display = "none";
  $("frame").removeAttribute("src");
  $("notice").style.display = "none";
  $("empty").style.display = "block";
  $("fname").textContent = "No video loaded";
  $("tDur").textContent = fmt(0);
  $("rMid").textContent = "--:--"; $("rEnd").textContent = "--:--";
  var off = ["bPrev","bNext","inA","inB","bSetA","bSetB","bGoA","bReset","bSave","bPlay","bSel"];
  for (var i = 0; i < off.length; i++) $(off[i]).disabled = true;
  renderTracks(); renderStrips(); render();
}

/* everything that has to be redrawn when the track list itself changes */
function refreshProgram(){
  $("tDur").textContent = fmt(D);
  $("rMid").textContent = fmtShort(D / 2);
  $("rEnd").textContent = fmtShort(D);
  renderHeader();
  renderTracks();
  renderStrips();
  syncPlayButtons();
  render();
}

function renderHeader(){
  var fn = $("fname");
  while (fn.firstChild) fn.removeChild(fn.firstChild);
  if (!TR.length){ fn.textContent = "No video loaded"; return; }
  var b = document.createElement("b");
  if (TR.length === 1){
    b.textContent = TR[0].name;
    fn.appendChild(b);
    fn.appendChild(document.createTextNode(
      "  -  " + TR[0].width + "x" + TR[0].height + " - " + TR[0].fps.toFixed(2) + " fps - " +
      TR[0].sizeText + " - " + fmt(D, false)));
  } else {
    b.textContent = TR.length + " tracks";
    fn.appendChild(b);
    fn.appendChild(document.createTextNode(
      "  -  stitched end to end - output " + TR[0].width + "x" + TR[0].height + " at " +
      TR[0].fps.toFixed(2) + " fps (from track 1) - " + fmt(D, false)));
  }
}

/* Track 1 sets the output format, so anything that differs gets scaled and
   letterboxed into it. Say so once, when the track is added. */
function mismatch(j){
  if (!TR.length) return false;
  var t0 = TR[0];
  return j.width !== t0.width || j.height !== t0.height ||
         Math.abs(j.fps - t0.fps) > 0.01 || (!!j.hasAudio !== !!t0.hasAudio);
}
function noteMismatch(j){
  var t0 = TR[0], bits = [];
  if (j.width !== t0.width || j.height !== t0.height)
    bits.push(j.width + "x" + j.height + " will be fitted into " + t0.width + "x" + t0.height);
  if (Math.abs(j.fps - t0.fps) > 0.01)
    bits.push(j.fps.toFixed(2) + " fps will be resampled to " + t0.fps.toFixed(2));
  if (!j.hasAudio && t0.hasAudio) bits.push("it has no audio, so that stretch will be silent");
  if (j.hasAudio && !t0.hasAudio) bits.push("its audio will be kept");
  if (bits.length) toast("Track " + TR.length + ": " + bits.join("; ") + ".", "warn");
}

function renderTracks(){
  var host = $("tkList");
  while (host.firstChild) host.removeChild(host.firstChild);
  $("tkHint").textContent = TR.length > 1
    ? "played in order, one after another - track 1 sets the output size"
    : "played in order, one after another";
  for (var i = 0; i < TR.length; i++) host.appendChild(trackRow(i));
}

function trackRow(i){
  var t = TR[i];
  var row = document.createElement("div");
  row.className = "tk" + (i === cur ? " on" : "");

  var no = document.createElement("span");
  no.className = "no"; no.textContent = String(i + 1);
  row.appendChild(no);

  var nm = document.createElement("span");
  nm.className = "nm"; nm.textContent = t.name; nm.title = t.name;
  row.appendChild(nm);

  if (!t.playable){
    var w = document.createElement("span");
    w.className = "warn"; w.title = "Preview only - " + (t.why || "unsupported codec");
    w.innerHTML = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2 1 21h22L12 2zm1 14h-2v2h2v-2zm0-7h-2v5h2V9z"/></svg>';
    row.appendChild(w);
  }

  var meta = document.createElement("span");
  meta.className = "meta";
  meta.textContent = t.width + "x" + t.height + "  " + fmt(t.dur, false);
  row.appendChild(meta);

  row.appendChild(mini("Jump to the start of this track",
    '<path d="M4 11h9V7.5L18 12l-5 4.5V13H4z"/>', "", function(){ playbackPause(); seek(trackOff(i)); }));
  row.appendChild(mini("Move earlier", '<path d="M12 8l-6 6h12z"/>', "",
    function(){ moveTrack(i, -1); }, i === 0));
  row.appendChild(mini("Move later", '<path d="M12 16l6-6H6z"/>', "",
    function(){ moveTrack(i, 1); }, i === TR.length - 1));
  row.appendChild(mini("Remove this track",
    '<path d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/>',
    "rm", function(){ removeTrack(i); }));
  return row;
}

function mini(title, path, cls, fn, disabled){
  var b = document.createElement("button");
  b.className = cls; b.title = title; b.disabled = !!disabled;
  b.innerHTML = '<svg viewBox="0 0 24 24">' + path + '</svg>';
  b.onclick = fn;
  return b;
}

/* one filmstrip per track, each sized to its share of the program */
function renderStrips(){
  var host = $("strip"), tl = $("tl");
  while (host.firstChild) host.removeChild(host.firstChild);
  if (!TR.length || !(D > 0)){ tl.className = "tl"; return; }
  tl.className = "tl busy";
  var left = TR.length, o = 0;
  var settle = function(){ if (--left <= 0) tl.className = "tl"; };
  for (var i = 0; i < TR.length; i++){
    var url = api("/api/strip", "t=" + TR[i].token);
    var el = document.createElement("div");
    el.className = "sv" + (i ? " j" : "");
    el.style.left  = (o / D * 100) + "%";
    el.style.width = (TR[i].dur / D * 100) + "%";
    host.appendChild(el);
    (function(el, url){
      var img = new Image();
      img.onload  = function(){ el.style.backgroundImage = "url('" + url + "')"; settle(); };
      img.onerror = settle;
      img.src = url;
    })(el, url);
    o += TR[i].dur;
  }
}

/* ---------- files the browser cannot decode: stills + sidecar audio ---------- */
/* One frame is ~100ms server-side, so requests are coalesced rather than queued. */
var frameBusy = false, framePending = null, lastFrameAt = -1;

/* takes time LOCAL to the active track, since the frame comes from its file */
function showFrame(t){
  if (mode !== "frames" || !M) return;
  var at = clamp(t, 0, M.dur);
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

/* starts the live-remuxed preview stream at a track-LOCAL offset */
function streamFrom(want){
  if (!M) return;
  playStart = want;                /* corrected below once the real start is known */
  $("frame").style.display = "none";
  v.style.display = "block";
  v.src = api("/api/play", "t=" + M.token + "&start=" + want.toFixed(6));
  v.load();
  guardPlay();
  setPlayIcon(true);

  /* a stream copy can only begin on a keyframe, so ask where it really starts;
     runs alongside the stream so play is not held up waiting for it */
  var tok = M.token;
  fetch(api("/api/playinfo", "t=" + tok + "&at=" + want.toFixed(6)))
    .then(function(r){ return r.json(); })
    .then(function(j){ if (j && j.ok && isFinite(j.start) && M && M.token === tok) playStart = j.start; })
    .catch(function(){ });
}

function playbackPlay(){
  if (!canPlayNow()) return;
  if (PH >= D - 0.05) seek(0);
  if (mode === "video"){ guardPlay(); return; }
  streamFrom(clamp(PH - trackOff(cur), 0, M.dur));
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
  showFrame(at - trackOff(cur));
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

function enterFramesMode(j, localT, keepPlaying){
  mode = "frames";
  vOk = false;
  v.style.display = "none";
  v.removeAttribute("src");
  try { v.load(); } catch (e) {}
  $("frame").style.display = "block";
  $("notice").style.display = "flex";
  $("noticeText").textContent =
    "Preview mode - your browser cannot decode " + j.name + " directly because " +
    (j.why || "of an unsupported codec") +
    ", so it is converted on the fly as you play. This affects preview only - the video you " +
    "save is built from the original files, at full quality.";
  lastFrameAt = -1;
  if (keepPlaying) streamFrom(localT || 0); else showFrame(localT || 0);
  syncPlayButtons();
}

/* ------------------- moving between tracks at a join ------------------- */
/* Only one clip is ever loaded in the <video> element, so crossing a join means
   swapping its source. That costs a short stall - unavoidable without a second
   element, and the same stall the preview stream already pays across a cut. */
var pendingSeek = -1;

function activate(i, localT, keepPlaying){
  if (i < 0 || i >= TR.length) return;
  cur = i; M = TR[i];
  playStart = 0;
  lastFrameAt = -1;
  framePending = null;
  stopStream();
  if (M.playable){
    mode = "video";
    vOk = true;
    $("notice").style.display = "none";
    $("frame").style.display = "none";
    $("frame").removeAttribute("src");
    v.style.display = "block";
    pendingSeek = clamp(localT || 0, 0, M.dur);
    v.src = api("/api/stream", "t=" + M.token);
    v.load();
    if (keepPlaying){ restarting = true; guardPlay(); }
  } else {
    enterFramesMode(M, clamp(localT || 0, 0, M.dur), keepPlaying);
  }
  syncPlayButtons();
  renderTracks();
}

/* the single way the playhead moves in program time */
function goTo(t, keepPlaying){
  if (!TR.length) return;
  PH = clamp(t, 0, D);
  var L = toLocal(PH);
  if (!L) return;
  if (L.i !== cur){
    if (keepPlaying) restarting = true;
    activate(L.i, L.t, keepPlaying);
    renderPlayhead();
    return;
  }
  if (mode === "video"){
    if (vOk){ try { v.currentTime = L.t; } catch (e) {} }
    if (keepPlaying && v.paused) guardPlay();
  } else if (keepPlaying){
    streamFrom(L.t);
  } else {
    if (playbackIsPlaying()) exitStreamToStill(); else showFrame(L.t);
  }
  renderPlayhead();
}

/* --------------------------- timeline input --------------------------- */
function posToTime(clientX){
  var r = $("tl").getBoundingClientRect();
  return clamp((clientX - r.left) / r.width, 0, 1) * D;
}
function seek(t){
  if (!M) return;
  skipGuardUntil = 0;   /* an explicit move always beats a pending skip */
  goTo(t, false);
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
  if (!TR.length || !(D > 0)) return;
  var r = $("tl").getBoundingClientRect();
  var f = clamp((clientX - r.left) / r.width, 0, 1);
  var L = toLocal(f * D);
  if (!L) return;
  var tk = TR[L.i];
  if (!tk.tiles) return;
  /* the thumbnail has to come from whichever track the cursor is over */
  var idx = clamp(Math.floor(L.t / tk.dur * tk.tiles), 0, tk.tiles - 1);
  var pop = $("pop");
  $("popImg").style.backgroundImage = "url('" + api("/api/strip", "t=" + tk.token) + "')";
  $("popImg").style.backgroundSize = (tk.tiles * tk.tileW) + "px " + tk.tileH + "px";
  $("popImg").style.backgroundPosition = (-idx * tk.tileW) + "px 0";
  $("popLab").textContent = fmt(f * D, false);
  pop.style.display = "block";
  pop.style.left = clamp(clientX - r.left - 80, 2, Math.max(2, r.width - 162)) + "px";
}

/* --------------------------- split and delete -------------------------- */
function doSplit(){
  if (!M) return;
  if (!canSplitAt(PH)){
    toast(Math.abs(PH - trackOff(trackAt(PH))) < frameEps() && trackAt(PH) > 0
      ? "That is already a join between two tracks."
      : "There is already a cut here - move the scrubber first.", "warn");
    return;
  }
  snapshot();
  var L = toLocal(PH);
  TR[L.i].cuts.push(L.t);
  TR[L.i].cuts.sort(function(x, y){ return x - y; });
  recalc();
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
  var sec = sg[selSeg];
  if (sec.del){
    snapshot();
    subDel(sec.s, sec.e);
    render();
    toast("Section restored.", "good");
    return;
  }
  if (sg.length < 2){
    toast("Split the video first - there is only one section.", "warn");
    return;
  }
  /* section boundaries are always cut boundaries, so deleting one removes
     exactly its clipped length - no need to try it and roll back */
  var lose = Math.max(0, Math.min(sec.e, B) - Math.max(sec.s, A));
  if (outLen() - lose < MIN_LEN){
    toast("That would leave nothing to save.", "warn");
    return;
  }
  snapshot();
  addDel(sec.s, sec.e);
  render();
  /* if the playhead is now inside the hole, walk it out to the join */
  var edge = delEndAt(PH);
  if (edge >= 0) seek(Math.min(edge, D));
  toast("Section removed - the ends will close up on save. New length " +
        fmt(outLen(), false) + ".", "good");
}

function doUndo(){
  if (!hist.length){ toast("Nothing to undo.", "warn"); return; }
  var h = hist.pop(), i;
  var hadTracks = TR.length;
  TR = h.order.slice();
  for (i = 0; i < h.edits.length; i++){
    h.edits[i].o.cuts = h.edits[i].cuts;
    h.edits[i].o.dels = h.edits[i].dels;
  }
  selSeg = h.sel;
  if (h.ab){ A = h.A; B = h.B; }
  recalc();
  if (!TR.length){ clearProgram(); return; }
  if (!hadTracks) $("empty").style.display = "none";
  cur = TR.indexOf(M);
  refreshProgram();
  /* the clip under the playhead may be a different one now */
  var L = toLocal(clamp(PH, 0, D));
  if (cur < 0 || (L && L.i !== cur)) activate(L ? L.i : 0, L ? L.t : 0, false);
  else goTo(clamp(PH, 0, D), false);
}

/* ------------------------- skipping deleted parts ---------------------- */
/* Playback jumps the holes in both modes. In native mode that is a plain
   currentTime move. In preview mode the stream has to be respun, which stalls
   briefly - and because a stream copy can only begin on a keyframe, ffmpeg may
   hand back a moment of footage from BEFORE the join. skipGuardUntil stops that
   replayed audio from re-triggering the same jump forever. */
function skipTo(edge, wasPlaying){
  skipGuardUntil = edge;
  if (wasPlaying){
    restarting = true;
    /* a second skip must cancel the first one's timer - otherwise the stale one
       fires mid-respin and clears a flag this skip still owns (and which
       activate/goTo/ended also set, with no timer of their own) */
    if (skipTimer) clearTimeout(skipTimer);
    skipTimer = setTimeout(function(){ restarting = false; skipTimer = null; }, 3000);
  }
  goTo(edge, wasPlaying);
}

/* Returns true when playback was diverted, so callers stop what they were doing. */
function skipIfDeleted(){
  if (!M || !delsP.length) return false;
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
  PH = trackOff(cur) + ((mode === "video") ? v.currentTime : (playStart + v.currentTime));
  if (skipIfDeleted()) return;
  if (selPlay && PH >= B){ playbackPause(); selPlay = false; seek(B); }
  renderPlayhead();
});
v.addEventListener("seeked", function(){
  if (mode === "video"){ PH = trackOff(cur) + v.currentTime; renderPlayhead(); }
});
v.addEventListener("loadedmetadata", function(){
  /* a freshly swapped-in track cannot be positioned until its metadata lands */
  if (pendingSeek >= 0){
    try { v.currentTime = pendingSeek; } catch (e) {}
    pendingSeek = -1;
  }
});
v.addEventListener("error", function(){
  if (!M) return;
  if (mode === "video"){ enterFramesMode(M, clamp(PH - trackOff(cur), 0, M.dur), false); }
  else if (playbackIsPlaying()) { playbackPause(); toast("Preview stream stopped.", "warn"); }
});
/* the end of one clip is the start of the next - that is the whole stitch */
v.addEventListener("ended", function(){
  if (!M) return;
  if (cur < TR.length - 1){
    restarting = true;
    goTo(trackOff(cur + 1), true);
    return;
  }
  if (mode === "frames") playbackPause();
});

function step(dir, big){
  if (!M) return;
  playbackPause();
  if (big){ seek(PH + dir); return; }
  /* ask for the real timestamp of the neighbouring frame rather than
     assuming frames sit on exact 1/fps boundaries */
  var o = trackOff(cur), from = clamp(PH - o, 0, M.dur), tok = M.token;
  var fallback = function(){ seek(o + from + dir / (M.fps || 25)); };
  fetch(api("/api/step", "t=" + tok + "&at=" + from.toFixed(6) + "&dir=" + dir))
    .then(function(r){ return r.json(); })
    .then(function(j){ if (j && j.ok && isFinite(j.t)) seek(o + j.t); else fallback(); })
    .catch(fallback);
}

/* ------------------------------- wiring ------------------------------- */
$("bAdd").onclick = addTrack;
$("bOpen2").onclick = addTrack;
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
  snapshot(true);
  for (var i = 0; i < TR.length; i++){ TR[i].cuts = []; TR[i].dels = []; }
  recalc();
  A = 0; B = D; selSeg = -1; skipGuardUntil = 0;
  render();
  toast(TR.length > 1
    ? "Every cut cleared - all " + TR.length + " tracks selected again."
    : "Every cut cleared - the whole video is selected again.");
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
  var parts = keptParts();
  if (!parts.length || outLen() < MIN_LEN){
    toast("The selected clip is too short to save.", "warn"); return;
  }
  saving = true;
  $("bSave").disabled = true;
  $("txSave").textContent = "Choose location...";
  fetch(api("/api/save"), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    /* tokens carries the track order - the server takes the output format from
       the first of them, and the parts are already in the order they play */
    body: JSON.stringify({
      tokens: TR.map(function(t){ return t.token; }),
      parts: parts
    })
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
  saving = false;
  $("bSave").disabled = false;
  $("bar").style.display = "none";
  syncEditButtons();          /* restores Trimmed vs Stitched wording */
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

# ProcessStartInfo takes one string, which the child re-splits with
# CommandLineToArgvW rules. A Windows file name cannot contain a double quote, so
# wrapping is enough - except that a trailing backslash would escape the closing
# quote, so any run of them at the end is doubled.
function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $tail = [regex]::Match($a, '\*$').Value
    return '"' + $a.Substring(0, $a.Length - $tail.Length) + ($tail * 2) + '"'
}

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

            # tokens carries the track order; the FIRST track sets the output
            # format, which is what everything else gets fitted into.
            $order = @()
            if ($p.PSObject.Properties['tokens'] -and $p.tokens) {
                foreach ($tk in $p.tokens) { if ($S.Files[[string]$tk]) { $order += [string]$tk } }
            }
            if ($order.Count -eq 0) { Send-Json @{ ok = $false; error = 'Those videos are no longer loaded.' }; break }
            $first = $S.Files[$order[0]]

            # Never trust the client: rebuild the part list here, clamping every
            # edge to its own track's duration and dropping slivers. Order is
            # preserved exactly as sent - it IS the order the clips play in.
            $segs = New-Object System.Collections.ArrayList
            if ($p.PSObject.Properties['parts'] -and $p.parts) {
                foreach ($sg in $p.parts) {
                    if ($null -eq $sg) { continue }
                    # must be a loaded file AND one of the tracks we were given
                    if ($order -notcontains [string]$sg.t) { continue }
                    $ti = $S.Files[[string]$sg.t]
                    if (-not $ti) { continue }
                    $s0 = 0.0; $e0 = 0.0
                    if (-not [double]::TryParse([string]$sg.s, [Globalization.NumberStyles]::Float, $inv, [ref]$s0)) { continue }
                    if (-not [double]::TryParse([string]$sg.e, [Globalization.NumberStyles]::Float, $inv, [ref]$e0)) { continue }
                    # TryParse says yes to "NaN", and every later comparison against
                    # NaN is false - the reversal test, both clamps, the sliver test
                    # and the span test - so it would sail all the way through and
                    # only blow up in [timespan]::FromSeconds. (Infinity is fine: the
                    # clamps absorb it into [0, duration] like any other overshoot.)
                    if ([double]::IsNaN($s0) -or [double]::IsNaN($e0)) { continue }
                    if ($e0 -lt $s0) { $t = $s0; $s0 = $e0; $e0 = $t }
                    $s0 = [math]::Max(0.0, [math]::Min($s0, $ti.duration))
                    $e0 = [math]::Max(0.0, [math]::Min($e0, $ti.duration))
                    if (($e0 - $s0) -lt 0.01) { continue }
                    [void]$segs.Add(@{ tok = [string]$sg.t; info = $ti; s = $s0; e = $e0 })
                }
            }
            if ($segs.Count -eq 0) { Send-Json @{ ok = $false; error = 'Nothing is selected to save.' }; break }

            # Runs of the same clip that touch end to end are one encode, not two.
            $merged = New-Object System.Collections.ArrayList
            foreach ($sg in $segs) {
                $prev = $(if ($merged.Count) { $merged[$merged.Count - 1] } else { $null })
                # Only genuinely contiguous runs merge. Parts are a SEQUENCE, not a
                # set: one that overlaps or rewinds still contributes its own
                # length, and folding it into its neighbour would silently drop it.
                if ($prev -and $prev.tok -eq $sg.tok -and
                    [math]::Abs($sg.s - $prev.e) -le 0.0005 -and $sg.e -gt $prev.e) {
                    $prev.e = $sg.e
                } else {
                    [void]$merged.Add(@{ tok = $sg.tok; info = $sg.info; s = $sg.s; e = $sg.e })
                }
            }
            $segs = @($merged)

            $span = 0.0
            foreach ($sg in $segs) { $span += ($sg.e - $sg.s) }
            if ($span -lt 0.05) { Send-Json @{ ok = $false; error = 'The selected clip is too short.' }; break }

            # how many distinct source files actually contribute
            $used = @()
            foreach ($sg in $segs) { if ($used -notcontains $sg.tok) { $used += $sg.tok } }
            $info = $first
            $multi = $used.Count -gt 1

            $base = [IO.Path]::GetFileNameWithoutExtension($first.name)
            # a start-end tag means nothing once the parts come from different
            # files, so a stitched export is named by its total length instead
            $tag  = $(if ($multi) { [timespan]::FromSeconds($span).ToString('hhmmss') }
                      else { '{0}-{1}' -f ([timespan]::FromSeconds($segs[0].s).ToString('hhmmss')),
                                          ([timespan]::FromSeconds($segs[$segs.Count - 1].e).ToString('hhmmss')) })
            $word = $(if ($multi) { 'stitched' } elseif ($segs.Count -gt 1) { 'edit' } else { 'trim' })
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Title            = $(if ($multi) { 'Save stitched video as' }
                                      elseif ($segs.Count -gt 1) { 'Save edited video as' }
                                      else { 'Save trimmed video as' })
            $dlg.Filter           = 'MP4 video (*.mp4)|*.mp4'
            $dlg.DefaultExt       = 'mp4'
            $dlg.AddExtension     = $true
            $dlg.OverwritePrompt  = $true
            $dlg.FileName         = "${base}_${word}_${tag}.mp4"
            $dlg.InitialDirectory = [IO.Path]::GetDirectoryName($info.path)
            $r = Show-Dialog $dlg
            if ($r -ne [System.Windows.Forms.DialogResult]::OK) { Send-Json @{ cancelled = $true }; break }

            $outPath = $dlg.FileName
            # ffmpeg would read and rewrite the same file at once - check every
            # source, not just track 1's
            $clash = $false
            foreach ($tk in $used) { if ([IO.Path]::GetFullPath($outPath) -eq $S.Files[$tk].path) { $clash = $true } }
            if ($clash) {
                Send-Json @{ ok = $false; error = 'Please save to a different file than the source videos.' }
                break
            }

            $id   = [Guid]::NewGuid().ToString('N')
            $prog = Join-Path $S.CacheDir "prog_$id.txt"
            $log  = Join-Path $S.CacheDir "log_$id.txt"
            $filt = ''

            # Encode to a sidecar and move it into place only once ffmpeg has
            # succeeded. -y truncates the target the moment the muxer opens, so
            # writing straight to $outPath meant any failure - a bad codec, a
            # cancelled job - destroyed whatever the user chose to overwrite.
            $tmpOut = $outPath + '.svtpart'

            # Some legal sources have an odd width or height (yuv422p/yuv444p
            # H.264, VP8/VP9, MJPEG). libx264 at yuv420p refuses those outright,
            # so round down to even whenever the source needs it.
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

            if ($segs.Count -eq 1) {
                # One range from one file: seek to it and copy forward. Unchanged
                # from before splitting existed, and far cheaper on a long file
                # than decoding from frame zero the way the filter paths have to.
                $ffArgs = @(
                    '-y', '-hide_banner', '-nostats',
                    '-progress', $prog,
                    '-ss', (Num $segs[0].s '0.###'),
                    '-i',  $segs[0].info.path,
                    '-t',  (Num $span '0.###'),
                    '-map', '0:v:0', '-map', '0:a:0?'
                ) + $(if ($oddSrc) { @('-vf', $evenFix) } else { @() }) + $encArgs
            } else {
                # Several parts: trim each one, rebase its timestamps to zero and
                # concat, all in a single pass. The graph goes in a file because a
                # dozen parts would otherwise overrun the command line that
                # cmd.exe accepts - see the stderr redirect below.
                $filt = Join-Path $S.CacheDir "filter_$id.txt"

                # The concat filter refuses parts that disagree on size, aspect or
                # pixel format, and on sample rate and layout for audio. Clips from
                # different files essentially never agree, so when more than one
                # file is involved every part is fitted into track 1's format:
                # scaled to fit, letterboxed, and resampled. A single file needs
                # none of that, so it skips the whole normalisation.
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
                } elseif ($oddSrc) {
                    $vfit = ",$evenFix"
                }
                $afit = $(if ($multi) { ',aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo' } else { '' })

                # Audio only survives the concat if EVERY part offers a pin, so a
                # clip with no sound needs silence generated to stand in for it.
                # Each silent part gets its own lavfi input - a filter input pad
                # cannot be consumed twice.
                $anyAudio = $false
                foreach ($sg in $segs) { if ($sg.info.hasAudio) { $anyAudio = $true } }

                $inArgs = @()
                $slot   = @{}          # token -> input index
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
                    [void]$sb.Append("[${ix}:v]trim=start=${s0}:end=${e0},setpts=PTS-STARTPTS${vfit}[v$i];`n")
                    $chain += "[v$i]"
                    if ($anyAudio) {
                        if ($sg.info.hasAudio) {
                            [void]$sb.Append("[${ix}:a]atrim=start=${s0}:end=${e0},asetpts=PTS-STARTPTS${afit}[a$i];`n")
                        } else {
                            $len = Num ($sg.e - $sg.s) '0.###'
                            $inArgs += @('-f', 'lavfi', '-t', $len, '-i', 'anullsrc=r=48000:cl=stereo')
                            [void]$sb.Append("[${n}:a]atrim=start=0:end=${len},asetpts=PTS-STARTPTS${afit}[a$i];`n")
                            $n++
                        }
                        $chain += "[a$i]"
                    }
                }
                if ($anyAudio) {
                    [void]$sb.Append($chain + "concat=n=$($segs.Count):v=1:a=1[vout][aout]")
                } else {
                    [void]$sb.Append($chain + "concat=n=$($segs.Count):v=1:a=0[vout]")
                }
                [IO.File]::WriteAllText($filt, $sb.ToString(), (New-Object Text.UTF8Encoding $false))

                $mapArgs = $(if ($anyAudio) { @('-map', '[vout]', '-map', '[aout]') }
                             else { @('-map', '[vout]', '-an') })
                $ffArgs = @(
                    '-y', '-hide_banner', '-nostats',
                    '-progress', $prog
                ) + $inArgs + @(
                    '-filter_complex_script', $filt
                ) + $mapArgs + $encArgs
            }
            # Start-Process -PassThru never populates ExitCode, so drive the process
            # directly. This used to go through cmd.exe purely to get the "2>" stderr
            # redirect - but cmd expands %VAR% even inside a quoted argument, so a
            # perfectly ordinary file like "100% done.mp4" or one sitting in a folder
            # named %TEMP% had its path rewritten before ffmpeg ever saw it. ffmpeg is
            # now launched directly and its stderr drained to the log ourselves, which
            # also removes the last shell between us and the file names.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $S.FFmpeg
            $psi.Arguments              = (($ffArgs | ForEach-Object { Quote-Arg $_ }) -join ' ')
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi
            [void]$proc.Start()
            # copied asynchronously so a full stderr pipe can never stall ffmpeg
            $logFs = [IO.File]::Create($log)
            $null = $proc.StandardError.BaseStream.CopyToAsync($logFs)
            $S.Jobs[$id] = @{
                state = 'running'; percent = 0.0; proc = $proc; prog = $prog; log = $log
                out = $outPath; outName = [IO.Path]::GetFileName($outPath); span = $span; error = ''
                kind = 'save'; token = $order[0]; filt = $filt; parts = $segs.Count
                tmp = $tmpOut; logFs = $logFs
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
                    # the async stderr copy has to be closed before the log is read
                    if ($job.logFs) {
                        try { $job.logFs.Dispose() } catch { }
                        $job.logFs = $null
                    }
                    $made = $(if ($job.tmp) { $job.tmp } else { $job.out })
                    if ($code -eq 0 -and (Test-Path -LiteralPath $made)) {
                        # only now does the user's chosen file get replaced
                        $moved = $true
                        if ($job.tmp) {
                            try { Move-Item -LiteralPath $job.tmp -Destination $job.out -Force }
                            catch { $moved = $false; $job.state = 'failed'
                                    $job.error = "Could not write $($job.outName): $($_.Exception.Message)" }
                        }
                        if ($moved) { $job.state = 'done'; $job.percent = 100.0 }
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
                    # a half-written sidecar must never be left lying next to the target
                    if ($job.tmp) { Remove-Item -LiteralPath $job.tmp -Force -ErrorAction SilentlyContinue }
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
