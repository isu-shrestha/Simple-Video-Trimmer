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

# The last autosave of the PREVIOUS run is what the page offers to restore;
# this run starts writing a fresh one, so opening the app and adding a clip
# can never overwrite the work being offered back.
$autosave = Join-Path $CacheDir 'autosave.svtsession'
if (Test-Path -LiteralPath $autosave) {
    try { Move-Item -LiteralPath $autosave -Destination (Join-Path $CacheDir 'autosave-last.svtsession') -Force } catch { }
}

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
    # one Windows dialog at a time - see Show-Dialog
    DialogLock = (New-Object object)
    DialogHwnd = [IntPtr]::Zero
    MediaBase  = ''
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
  /* both players fill the stage and stack, so swapping them at a loop point
     changes nothing about the layout - only which one is painted */
  .stage video{position:absolute;left:0;top:0;width:100%;height:100%;max-width:none;max-height:none;object-fit:contain}
  #bSel.on{color:#8cc6ff;border-color:#3f6d9e;background:#1b2c3f}
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

  /* The preview and the track list share a row, so adding a tenth clip makes
     the LIST scroll instead of squeezing the picture. */
  .work{flex:1;min-height:0;display:flex;gap:12px}
  .work .stage{flex:1;min-width:0}
  .side{width:248px;flex:none;display:flex;flex-direction:column;gap:8px;
    background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 11px}
  .tkhead{display:flex;align-items:center;gap:8px;flex:none}
  .tkhead .lab{flex:1;min-width:0}
  .tkhead #bAdd{padding:5px 9px;font-size:12.5px;gap:5px}
  .tkhead #bAdd svg{width:13px;height:13px}
  .tkhint{font-size:11.5px;line-height:1.35;color:#6c7986;flex:none}
  .tklist{flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;gap:5px}
  /* two lines per clip: the name, then its size and the controls - a single
     row cannot hold all of that in a column this narrow */
  .tk{display:flex;flex-wrap:wrap;align-items:center;gap:5px;padding:5px 6px;border-radius:7px;
    background:#0b0f14;border:1px solid var(--line)}
  .tk.on{border-color:var(--accent2);background:#111a26}
  /* the whole row is the drag handle for reordering; its controls keep their clicks */
  .tk{cursor:grab;user-select:none}
  .tk button,.tk select{cursor:pointer}
  body.tkdragging,body.tkdragging *{cursor:grabbing!important}
  .tk.drag{opacity:.45}
  .tk.dropBefore{box-shadow:0 -3px 0 -1px var(--accent)}
  .tk.dropAfter{box-shadow:0 3px 0 -1px var(--accent)}
  /* the soundtrack sits under the track list: one file for the whole video */
  .snd{flex:none;display:flex;flex-direction:column;gap:6px;border-top:1px solid var(--line);padding-top:8px}
  .snd #bSnd{padding:5px 9px;font-size:12.5px;gap:5px}
  .snd #bSnd svg{width:13px;height:13px}
  .sndrow{align-items:center;gap:6px;padding:5px 6px;border-radius:7px;background:#0b0f14;border:1px solid #2b5c34}
  .sndrow .nm{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12.5px}
  .sndrow .meta{font:10.5px/1 "Consolas",monospace;color:#6c7986;white-space:nowrap}
  .sndrow button{padding:3px 5px;background:transparent;border-color:transparent}
  .sndrow button svg{width:13px;height:13px}
  .sndrow button:hover:not(:disabled){background:#341d1c;border-color:#96413d;color:#ff9d96}
  .tk .no{font:11px/1 "Consolas",monospace;color:var(--bg);background:var(--dim);
    border-radius:4px;padding:4px 5px;min-width:18px;text-align:center;font-weight:700;flex:none}
  .tk.on .no{background:var(--accent)}
  .tk .nm{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12.5px}
  .tkfoot{display:flex;align-items:center;gap:2px;width:100%}
  .tk .meta{font:10.5px/1 "Consolas",monospace;color:#6c7986;white-space:nowrap;
    flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis}
  .tk .warn{color:var(--warn);flex:none}
  .tk .warn svg{width:13px;height:13px}
  .tk button{padding:3px 5px;background:transparent;border-color:transparent;flex:none}
  .tk button svg{width:13px;height:13px}
  .tk button:hover:not(:disabled){background:#243040;border-color:#3b4a5c}
  .tk button.rm:hover:not(:disabled){background:#341d1c;border-color:#96413d;color:#ff9d96}
  .tk button.mute.on{color:var(--warn);background:#2e2617;border-color:#5c4a24}
  /* line three: how many times the track plays, and whether it bounces */
  .tkloop{display:flex;align-items:center;gap:5px;width:100%;font-size:11px;color:#6c7986}
  .tkloop select{font:11px/1 "Consolas",monospace;color:var(--text);background:#161b22;
    border:1px solid var(--line);border-radius:5px;padding:2px 3px;cursor:pointer}
  .tk button.pong{font-size:11px;gap:4px;padding:2px 6px;color:var(--dim)}
  .tk button.pong.on{color:#8cc6ff;background:#1b2c3f;border-color:#2f4a68}
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
  .labbtn.b{color:#ffb05c}
  .labbtn:hover:not(:disabled){background:#1b2c3f;border-color:#2f4a68}
  .labbtn.b:hover:not(:disabled){background:#33261a;border-color:#69492a}
  .labbtn:hover:not(:disabled) svg{opacity:1}
  .sep{width:1px;height:22px;background:var(--line);margin:0 2px}
  .len{margin-left:auto;display:flex;align-items:center;gap:10px}
  .len .box{font:13px/1 "Consolas",monospace;background:#0b0f14;border:1px solid var(--line);
    border-radius:6px;padding:8px 11px;color:var(--dim);white-space:nowrap}
  .len .box b{color:var(--good)}

  .bar{position:relative;height:6px;border-radius:3px;background:#0b0f14;border:1px solid var(--line);
    overflow:hidden;width:130px;display:none}
  .bar i{position:absolute;left:0;top:0;bottom:0;right:100%;background:var(--accent);transition:right .2s}

  /* ---- crop overlay ----
     Drawn over the OUTPUT frame - track 1's picture - not over whatever clip
     happens to be on screen, because that frame is what every part is fitted
     into and therefore what the crop rectangle actually means. */
  #cropWrap{position:absolute;left:0;top:0;right:0;bottom:0;display:none;z-index:6}
  #cropWrap.on{display:block}
  #cropBox{position:absolute;cursor:move;touch-action:none;
    outline:1px solid rgba(255,255,255,.92);
    box-shadow:0 0 0 9999px rgba(6,9,13,.58)}
  /* rule-of-thirds guides, drawn with the box's own pseudo elements */
  #cropBox::before{content:"";position:absolute;left:33.33%;right:33.33%;top:0;bottom:0;
    border-left:1px solid rgba(255,255,255,.22);border-right:1px solid rgba(255,255,255,.22)}
  #cropBox::after{content:"";position:absolute;top:33.33%;bottom:33.33%;left:0;right:0;
    border-top:1px solid rgba(255,255,255,.22);border-bottom:1px solid rgba(255,255,255,.22)}
  #cropBox .g{position:absolute;width:20px;height:20px;touch-action:none;z-index:2}
  #cropBox .g::after{content:"";position:absolute;width:13px;height:13px;
    border:2px solid #fff;box-shadow:0 0 4px rgba(0,0,0,.85)}
  .g.nw{left:-4px;top:-4px;cursor:nwse-resize}    .g.nw::after{left:0;top:0;border-right:0;border-bottom:0}
  .g.ne{right:-4px;top:-4px;cursor:nesw-resize}   .g.ne::after{right:0;top:0;border-left:0;border-bottom:0}
  .g.sw{left:-4px;bottom:-4px;cursor:nesw-resize} .g.sw::after{left:0;bottom:0;border-right:0;border-top:0}
  .g.se{right:-4px;bottom:-4px;cursor:nwse-resize}.g.se::after{right:0;bottom:0;border-left:0;border-top:0}
  /* clear of the corner grip, which is 20px square and drawn over the top */
  #cropLab{position:absolute;left:20px;top:4px;z-index:3;pointer-events:none;
    font:11px/1 "Consolas",monospace;color:#cfe4ff;background:rgba(6,9,13,.8);
    border-radius:4px;padding:3px 6px;white-space:nowrap}

  /* ---- advanced section: collapsed until asked for ---- */
  .adv{margin-top:11px;padding-top:11px;border-top:1px solid var(--line)}
  .advhead{width:100%;justify-content:flex-start;background:transparent;border-color:transparent;
    padding:5px 6px;font-size:12px;text-transform:uppercase;letter-spacing:.6px;
    font-weight:600;color:var(--dim)}
  .advhead:hover:not(:disabled){background:#1a222c;border-color:var(--line)}
  .advhead .chev{transition:transform .15s;opacity:.7}
  .adv.open .advhead .chev{transform:rotate(90deg)}
  .adv.open .advhead{color:var(--text)}
  .advbody{display:none;padding:10px 2px 2px;flex-direction:column;gap:9px}
  .adv.open .advbody{display:flex}
  .advrow{display:flex;align-items:center;gap:9px;flex-wrap:wrap}
  .pills{display:flex;align-items:center;gap:5px;flex-wrap:wrap}
  button.pill{padding:5px 10px;font:12px/1 "Consolas",monospace;border-radius:6px}
  button.pill.on{background:var(--accent2);border-color:var(--accent2);color:#fff}
  .tog{display:inline-flex;align-items:center;gap:7px;cursor:pointer;user-select:none;font-size:13px}
  .tog input{width:15px;height:15px;accent-color:var(--accent);cursor:pointer}
  #pxSlide{width:190px}
  .advrow .box{font:13px/1 "Consolas",monospace;background:#0b0f14;border:1px solid var(--line);
    border-radius:6px;padding:8px 11px;color:var(--dim);white-space:nowrap}
  .advrow .box b{color:var(--accent)}

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
  <button id="bSessOpen" class="ghost" title="Open a saved session - its tracks and every edit">Open Session</button>
  <button id="bSessSave" class="ghost" disabled title="Save the tracks and every edit to a session file">Save Session</button>
  <button id="bQuit" class="ghost" title="Shut down the local server">Quit</button>
</header>

<main>
  <div class="notice" id="notice">
    <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2 1 21h22L12 2zm1 14h-2v2h2v-2zm0-7h-2v5h2V9z"/></svg>
    <span class="txt" id="noticeText"></span>
  </div>

  <div class="work">
    <div class="stage" id="stage">
      <video id="v" preload="auto"></video>
      <video id="v2" preload="auto"></video>
      <div class="empty" id="empty">
        <svg viewBox="0 0 24 24"><path d="M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V4h-4z"/></svg>
        <h2>No video loaded</h2>
        <p>Add an MP4, M4V, MOV or WebM file to start. Add more to stitch them end to end.</p>
        <button id="bOpen2" class="primary">Add your first video...</button>
      </div>
      <img id="frame" alt="">
      <div id="cropWrap">
        <div id="cropBox" title="Drag to move the crop, or drag a corner to resize it">
          <span id="cropLab"></span>
          <span class="g nw" data-g="nw"></span><span class="g ne" data-g="ne"></span>
          <span class="g sw" data-g="sw"></span><span class="g se" data-g="se"></span>
        </div>
      </div>
    </div>

    <aside class="side">
      <div class="tkhead">
        <span class="lab">Tracks</span>
        <button id="bAdd" class="primary" title="Add another clip to play after this one"><svg viewBox="0 0 24 24"><path d="M13 11V5h-2v6H5v2h6v6h2v-6h6v-2z"/></svg>Add</button>
      </div>
      <div class="tklist" id="tkList"></div>
      <div class="tkhint" id="tkHint">played in order, one after another</div>
      <div class="snd" id="sndBox">
        <div class="tkhead">
          <span class="lab">Soundtrack</span>
          <button id="bSnd" title="Replace the video's sound with an audio file - it repeats to fill the whole video"><svg viewBox="0 0 24 24"><path d="M12 3v10.55A4 4 0 1 0 14 17V7h4V3h-6z"/></svg>Import</button>
        </div>
        <div class="sndrow" id="sndRow" style="display:none">
          <span class="nm" id="sndName"></span><span class="meta" id="sndMeta"></span>
          <button id="bSndOff" title="Remove the soundtrack and go back to the tracks' own sound"><svg viewBox="0 0 24 24"><path d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg></button>
        </div>
        <div class="tkhint" id="sndHint">the tracks' own sound is used</div>
      </div>
      <audio id="snd" preload="auto" loop></audio>
    </aside>
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
      <button id="bSel" disabled title="Play the selected range on a loop - Space stops it"><svg viewBox="0 0 24 24"><path d="M4 5v14l8-7zm9 0v14l8-7z"/></svg>Play Selection</button>
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
        <button id="bGoB" class="labbtn b" disabled title="Jump the scrubber to the end point">END<svg viewBox="0 0 24 24"><path d="M4 11h9V7.5L18 12l-5 4.5V13H4z"/></svg></button>
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

    <div class="adv" id="adv">
      <button id="bAdv" class="advhead" title="Cut a fixed-size piece out of the picture">
        <svg class="chev" viewBox="0 0 24 24"><path d="M9 6l6 6-6 6z"/></svg>
        <span>Advanced - crop size &amp; shape</span>
        <span class="spacer"></span>
        <span class="chip off" id="advChip">off</span>
      </button>
      <div class="advbody" id="advBody">
        <div class="advrow">
          <label class="tog" title="Take a fixed-size piece out of the picture, at the picture's own resolution">
            <input type="checkbox" id="cbCrop"><span>Crop to a fixed size</span>
          </label>
          <span class="tkhint" id="cropHint">drag the box to move it, or a corner to resize it</span>
          <button id="bCropCentre" class="ghost" disabled title="Put the crop back in the middle of the picture">Centre</button>
        </div>
        <div class="advrow">
          <span class="lab">Shape</span>
          <div class="pills" id="arList"></div>
        </div>
        <div class="advrow">
          <span class="lab">Size</span>
          <div class="pills" id="pxList"></div>
          <input type="range" id="pxSlide" min="0" max="1000" step="1" value="500" disabled
                 title="Slide between the sizes - fully left is 256, fully right is the whole frame">
          <div class="box">Output <b id="outDim">-</b></div>
        </div>
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
/* Video, strips and stills come from a second host name for the same server.
   A browser allows only six connections per host, and media elements hold
   theirs open - on one host they could leave a dialog request queued behind
   them, with the Add button disabled and no dialog ever appearing. */
var MEDIA = "__MEDIA__";
if (MEDIA.charAt(0) === "_") MEDIA = "";     /* not substituted: same host it is */
function media(p, q){ return MEDIA + api(p, q); }
function $(id){ return document.getElementById(id); }
var v = $("v");
/* v is whichever player is ACTIVE. Play Selection keeps the other one parked on
   the next loop point and swaps the two there, so a loop never has to seek. */
var vMain = v, vAux = $("v2");
var snd = $("snd");      /* the imported soundtrack, when there is one */
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
  return expandLoops(keptPartsOnce(), function(p){ return trackByTok(p.t); },
                     function(p){ var q = { t: p.t, s: p.s, e: p.e, r: 1 };
                                  if (p.m) q.m = 1;
                                  return q; });
}
function trackByTok(tok){
  for (var i = 0; i < TR.length; i++) if (TR[i].token === tok) return TR[i];
  return null;
}
/* A track's loop count and ping-pong repeat its run of parts in place: n times
   through, and with ping-pong every time through is followed by the same run
   backwards - last part first, each part itself reversed. Only kept parts are
   in the run, so deleted sections stay deleted on every pass. */
function expandLoops(list, trackOf, reversed){
  var out = [], i = 0, j, k, m;
  while (i < list.length){
    var t = trackOf(list[i]);
    for (j = i; j < list.length && trackOf(list[j]) === t; j++);
    var n = (t && t.loops > 1) ? Math.min(Math.floor(t.loops), 10) : 1, pong = !!(t && t.pong);
    for (k = 0; k < n; k++){
      for (m = i; m < j; m++) out.push(list[m]);
      if (pong) for (m = j - 1; m >= i; m--) out.push(reversed(list[m]));
    }
    i = j;
  }
  return out;
}
function keptPartsOnce(){
  var sg = segments(), out = [];
  for (var i = 0; i < sg.length; i++){
    if (sg[i].del) continue;
    var s = Math.max(sg[i].s, A), e = Math.min(sg[i].e, B);
    if (e - s < 0.01) continue;
    var k = trackAt((s + e) / 2);
    if (k < 0) continue;
    var o = trackOff(k);
    var part = { t: TR[k].token,
                 s: +clamp(s - o, 0, TR[k].dur).toFixed(6),
                 e: +clamp(e - o, 0, TR[k].dur).toFixed(6) };
    /* only muted parts carry the flag, so a save that mutes nothing posts
       exactly the same body it always did */
    if (TR[k].mute) part.m = 1;
    out.push(part);
  }
  return out;
}
/* the saved length - loops and ping-pong passes included */
function outLen(){
  /* the play list rather than keptParts: the same passes, but unrounded */
  var p = loopPieces(), t = 0;
  for (var i = 0; i < p.length; i++) t += p[i].e - p[i].s;
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
      return { o: t, cuts: t.cuts.slice(), dels: t.dels.map(function(r){ return r.slice(); }),
               loops: t.loops, pong: t.pong, mute: t.mute };
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

function toast(msg, kind, actionLabel, action, sticky){
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
  if (!sticky) setTimeout(function(){
    d.style.transition = "opacity .3s"; d.style.opacity = 0;
    setTimeout(function(){ d.parentNode && d.parentNode.removeChild(d); }, 320);
  }, actionLabel ? 10000 : 3400);
  return d;
}
function kill(el){ if (el && el.parentNode) el.parentNode.removeChild(el); }

/* ---- trim points: every clamp rule lives here, so nothing can error out ---- */
/* Setting one trim point when the other is in the way.

   An explicit "put it HERE" - the Set Start button, I/O, a typed time - is
   taken at its word: the point lands where it was asked to and the OTHER point
   shifts out of the way. Pinning it to wherever the far point happens to sit
   answers a question the user did not ask.

   A drag is the exception, and passes drag=true. There the handle is under the
   pointer and can be seen stopping against the far point, so shoving that far
   point along on an overshoot would quietly destroy a mark nobody was aiming
   at. Dragging clamps; everything else pushes.

   Either way MIN_LEN has to survive on the far side, so a point set inside
   MIN_LEN of the programme's own end still cannot be honoured exactly. */
function setA(t, drag){
  if (!M) return;
  var x = clamp(t, 0, Math.max(0, D - MIN_LEN));
  if (drag){
    x = Math.min(x, Math.max(0, B - MIN_LEN));
  } else if (B < x + MIN_LEN){
    B = Math.min(D, x + MIN_LEN);
    toast("End point moved to " + fmt(B) + " to make room.", "");
  }
  A = x; render();
}
function setB(t, drag){
  if (!M) return;
  var x = clamp(t, Math.min(D, MIN_LEN), D);
  if (drag){
    x = Math.max(x, Math.min(D, A + MIN_LEN));
  } else if (A > x - MIN_LEN){
    A = Math.max(0, x - MIN_LEN);
    toast("Start point moved to " + fmt(A) + " to make room.", "");
  }
  B = x; render();
}

/* ---- timeline layout ----
   A deleted section is drawn as a narrow placeholder rather than at its full
   length - it only has to be there to be clicked and restored - and the kept
   sections share the rest of the width in proportion to their lengths. So the
   timeline is NOT linear in program time once anything is deleted: every
   position on it goes through tlX (time -> fraction) and tlT (fraction -> time). */
var GAP_PX = 16;
var TLMAP = { c: null, d: null, D: -1, w: -1, spans: [] };
function tlSpans(){
  var r = $("tl").getBoundingClientRect(), w = r.width > 0 ? r.width : 1000;
  if (TLMAP.c === cutsP && TLMAP.d === delsP && TLMAP.D === D && TLMAP.w === w) return TLMAP.spans;
  var sg = segments(), nd = 0, K = 0, i, out = [], x = 0;
  for (i = 0; i < sg.length; i++){ if (sg[i].del) nd++; else K += sg[i].e - sg[i].s; }
  /* never let the placeholders eat more than 30% of the bar */
  var g = nd ? Math.min(GAP_PX / w, 0.3 / nd) : 0;
  var linear = !nd || !(K > 0);
  for (i = 0; i < sg.length; i++){
    var len = sg[i].e - sg[i].s;
    var wd = linear ? len / D : (sg[i].del ? g : len / K * (1 - nd * g));
    out.push({ s: sg[i].s, e: sg[i].e, del: sg[i].del, x0: x, x1: x + wd });
    x += wd;
  }
  if (out.length) out[out.length - 1].x1 = 1;
  TLMAP = { c: cutsP, d: delsP, D: D, w: w, spans: out };
  return out;
}
function tlX(t){
  if (!(D > 0)) return 0;
  var sp = tlSpans(), i;
  if (!sp.length) return clamp(t / D, 0, 1);
  if (t <= sp[0].s) return 0;
  for (i = 0; i < sp.length; i++){
    if (t > sp[i].e) continue;
    var len = sp[i].e - sp[i].s;
    return sp[i].x0 + (len > 0 ? (t - sp[i].s) / len : 0) * (sp[i].x1 - sp[i].x0);
  }
  return 1;
}
function tlT(f){
  if (!(D > 0)) return 0;
  var sp = tlSpans(), i;
  f = clamp(f, 0, 1);
  if (!sp.length) return f * D;
  for (i = 0; i < sp.length; i++){
    if (f > sp[i].x1 && i < sp.length - 1) continue;
    var wd = sp[i].x1 - sp[i].x0;
    return clamp(sp[i].s + (wd > 0 ? (f - sp[i].x0) / wd : 0) * (sp[i].e - sp[i].s), sp[i].s, sp[i].e);
  }
  return D;
}

function render(){
  var pa = D ? tlX(A) * 100 : 0, pb = D ? tlX(B) * 100 : 100;
  /* a split or delete reshapes the bar, so the filmstrip slices follow it */
  if (TR.length && stripSpans !== tlSpans()) renderStrips();
  $("rMid").textContent = (TR.length && D > 0) ? fmtShort(tlT(0.5)) : "--:--";
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
  renderCrop();
  renderSoundtrack();
  scheduleAutosave();
}

function renderSegs(){
  var host = $("segs");
  while (host.firstChild) host.removeChild(host.firstChild);
  if (!TR.length || !(D > 0)) return;
  var sg = segments(), i, j, el;
  var pct = function(t){ return tlX(t) * 100; };

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
    var d = CROP.on ? outDims() : null;
    $("txSave").textContent = d ? "Save Cropped Video"
                                : (many ? "Save Stitched Video" : "Save Trimmed Video");
    $("bSave").title =
      (many ? "Stitch the tracks together and save as MP4"
            : "Trim and save as MP4") +
      (d ? ", cropped to " + d.w + " x " + d.h : "") + " (Ctrl+S)";
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
  $("ph").style.left = (D ? tlX(PH) * 100 : 0) + "%";
  $("tNow").textContent = fmt(PH);
  /* cheap enough to run on every timeupdate; the rest of syncEditButtons
     rewrites innerHTML, so it stays in render() */
  if (M) $("bSplit").disabled = !canSplitAt(PH);
}

/* ------------------------------ tracks -------------------------------- */
var BUSY_MSG = "A file dialog is already open - it has been brought to the front. Finish or close it first.";

/* Every request that puts up a Windows dialog goes through here. The wait is
   never a dead end: the notice stays up with a way out, and giving up hands the
   controls back straight away. A reply that turns up later is still honoured. */
function dialogFetch(path, opts, what, giveUp){
  var w = toast("Waiting for the " + what + " dialog. If you cannot see it, it may be behind this window.",
                "", "Stop waiting", function(){ w = null; if (giveUp) giveUp(); }, true);
  return fetch(api(path), opts)
    .then(function(r){ return r.json(); })
    .then(function(j){ kill(w); return j; }, function(e){ kill(w); throw e; });
}

function addTrack(){
  var enable = function(){ $("bAdd").disabled = false; $("bOpen2").disabled = false; };
  $("bAdd").disabled = true; $("bOpen2").disabled = true;
  dialogFetch("/api/open", { method: "POST" }, "file", enable)
    .then(function(j){
      if (j.cancelled) return;
      if (j.busy){ toast(BUSY_MSG, "warn"); return; }
      if (!j.ok){ toast(j.error || "Could not open that file.", "bad"); return; }
      acceptTrack(j);
    })
    .then(null, function(e){ toast("Could not reach the local server: " + e.message, "bad"); })
    .then(enable);
}

/* quiet: part of opening a session, which reports once for the lot */
function acceptTrack(j, quiet){
  var first = TR.length === 0;
  if (!quiet && restoreToast){ kill(restoreToast); restoreToast = null; }
  /* a selection that ran to the end should grow to cover the new clip */
  var toEnd = first || Math.abs(B - D) < EPS;
  snapshot(true);
  j.dur  = j.duration;
  j.cuts = [];
  j.dels = [];
  j.loops = 1;
  j.pong = false;
  j.mute = false;
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
  var always = ["bPrev","bNext","inA","inB","bSetA","bSetB","bGoA","bGoB","bReset","bSave","bSessSave"];
  for (var i = 0; i < always.length; i++) $(always[i]).disabled = false;

  if (first){ PH = 0; activate(0, 0, false); }
  refreshProgram();
  if (!first && !quiet){
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

function moveTrack(i, dir){ moveTrackTo(i, i + dir); }

/* take track i out and put it back so it ends up at index k */
function moveTrackTo(i, k){
  if (i < 0 || i >= TR.length || k < 0 || k >= TR.length || k === i) return;
  snapshot(true);
  var t = TR.splice(i, 1)[0];
  TR.splice(k, 0, t);
  recalc();
  selSeg = -1;
  cur = TR.indexOf(M);
  refreshProgram();
  goTo(clamp(PH, 0, D), false);
}

function clearProgram(){
  TR = []; cur = -1; M = null; D = 0; A = 0; B = 0; PH = 0;
  cutsP = []; delsP = []; selSeg = -1; selPlay = false;
  skipGuardUntil = 0; restarting = false; pendingSeek = -1;
  /* the undo stack has to go with it: nothing in it refers to anything still
     loaded, and Ctrl+Z has no !!M guard, so leaving it would let a discarded
     file come back on top of whatever the user opens next */
  hist = [];
  if (skipTimer){ clearTimeout(skipTimer); skipTimer = null; }
  loopStop();
  stopStream();
  v.style.display = "none";
  v = vMain;
  $("frame").style.display = "none";
  $("frame").removeAttribute("src");
  $("notice").style.display = "none";
  $("empty").style.display = "block";
  $("fname").textContent = "No video loaded";
  $("tDur").textContent = fmt(0);
  $("rMid").textContent = "--:--"; $("rEnd").textContent = "--:--";
  var off = ["bPrev","bNext","inA","inB","bSetA","bSetB","bGoA","bGoB","bReset","bSessSave","bSave","bPlay","bSel"];
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

/* ---- reordering by drag ----
   Pointer events rather than HTML5 drag and drop: the rows are rebuilt all the
   time and native DnD is fussy about that. A press only becomes a drag after
   the pointer has travelled a few pixels, so a click stays a click, and a press
   on a row's own button or dropdown never starts one. */
var tkDrag = null;       /* { from, y0, on, slot } while a row is held */

function tkPointerDown(i, e){
  if (e.button > 0 || TR.length < 2) return;
  for (var n = e.target; n && n !== document.body; n = n.parentNode){
    if (/^(BUTTON|SELECT|OPTION|INPUT)$/i.test(n.tagName || "")) return;
    if (String(n.className).split(" ")[0] === "tk") break;
  }
  tkDrag = { from: i, y0: e.clientY, on: false, slot: -1 };
}
function tkRows(){
  var host = $("tkList"), out = [];
  for (var k = 0; k < host.childNodes.length; k++) out.push(host.childNodes[k]);
  return out;
}
/* the gap the pointer is over: 0 is above the first row, rows.length below the last */
function dropSlot(y, rows){
  var s = 0;
  for (var k = 0; k < rows.length; k++){
    var r = rows[k].getBoundingClientRect();
    if (r.top + r.height / 2 < y) s = k + 1;
  }
  return s;
}
/* taking the row out first shifts every gap below it up by one */
function slotToIndex(slot, from){ return slot > from ? slot - 1 : slot; }

function markDrop(rows){
  var to = slotToIndex(tkDrag.slot, tkDrag.from);
  for (var k = 0; k < rows.length; k++){
    var c = "tk" + (k === cur ? " on" : "") + (k === tkDrag.from ? " drag" : "");
    if (to !== tkDrag.from){
      if (k === tkDrag.slot) c += " dropBefore";
      else if (tkDrag.slot === rows.length && k === rows.length - 1) c += " dropAfter";
    }
    rows[k].className = c;
  }
}
function endTkDrag(){
  var d = tkDrag;
  tkDrag = null;
  if (!d || !d.on) return;
  document.body.classList.remove("tkdragging");
  var to = slotToIndex(d.slot, d.from);
  if (d.slot >= 0 && to !== d.from) moveTrackTo(d.from, to);
  else renderTracks();                       /* clear the drop marks */
}
document.addEventListener("pointermove", function(e){
  if (!tkDrag) return;
  if (!tkDrag.on){
    if (Math.abs(e.clientY - tkDrag.y0) < 5) return;
    tkDrag.on = true;
    document.body.classList.add("tkdragging");
  }
  var rows = tkRows();
  tkDrag.slot = dropSlot(e.clientY, rows);
  markDrop(rows);
  if (e.preventDefault) e.preventDefault();
});
document.addEventListener("pointerup", endTkDrag);
document.addEventListener("pointercancel", endTkDrag);

function renderTracks(){
  /* a join crossed mid-drag would rebuild the rows out from under the pointer */
  if (tkDrag && tkDrag.on) return;
  /* every change of the current track, and every mute toggle, comes through
     here - so this is the one place the players have to be told about */
  applyMute();
  var host = $("tkList");
  /* The rows are rebuilt from scratch. Emptying the list collapses it, which
     throws its scroll back to the top, and the control just used is thrown away
     with its row - so note both and put them back afterwards. */
  var top = host.scrollTop, spot = focusSpot(host);
  while (host.firstChild) host.removeChild(host.firstChild);
  $("tkHint").textContent = TR.length > 1
    ? "played top to bottom - drag a track to reorder. Track 1 sets the output size"
    : "played in order, one after another";
  for (var i = 0; i < TR.length; i++) host.appendChild(trackRow(i));
  host.scrollTop = top;
  restoreFocus(host, spot);
}

/* a row's buttons and dropdown, in document order - the same in every row */
function focusables(el, out){
  out = out || [];
  for (var k = 0; k < el.childNodes.length; k++){
    var c = el.childNodes[k];
    if (!c.tagName) continue;
    if (/^(BUTTON|SELECT)$/i.test(c.tagName)) out.push(c);
    else if (c.childNodes) focusables(c, out);
  }
  return out;
}
/* which row, and which of its controls, has the focus */
function focusSpot(host){
  var a = document.activeElement;
  if (!a) return null;
  for (var r = 0; r < host.childNodes.length; r++){
    var f = focusables(host.childNodes[r]);
    for (var k = 0; k < f.length; k++) if (f[k] === a) return { row: r, at: k };
  }
  return null;
}
function restoreFocus(host, spot){
  if (!spot || spot.row >= host.childNodes.length) return;
  var f = focusables(host.childNodes[spot.row]);
  if (spot.at >= f.length) return;
  /* preventScroll: focusing must not drag the list to the control either */
  try { f[spot.at].focus({ preventScroll: true }); } catch (e) {}
}

function trackRow(i){
  var t = TR[i];
  var row = document.createElement("div");
  row.className = "tk" + (i === cur ? " on" : "");
  row.addEventListener("pointerdown", function(e){ tkPointerDown(i, e); });

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

  /* line two: the clip's size and the controls that act on it */
  var foot = document.createElement("div");
  foot.className = "tkfoot";

  var meta = document.createElement("span");
  meta.className = "meta";
  /* mm:ss rather than the full clock - the sidebar is too narrow for both this
     and the controls, and the exact length is on the timeline anyway */
  meta.textContent = t.width + "x" + t.height + " " + fmtShort(t.dur);
  meta.title = t.width + "x" + t.height + " - " + fmt(t.dur, false);
  foot.appendChild(meta);

  foot.appendChild(mini("Jump to the start of this track",
    '<path d="M4 11h9V7.5L18 12l-5 4.5V13H4z"/>', "", function(){ playbackPause(); seek(trackOff(i)); }));
  /* A track with no sound of its own has nothing to mute, and a soundtrack has
     already replaced every track's sound, so the button would be a lie. */
  var sndOn = !!SND, quiet = !t.hasAudio;
  foot.appendChild(mini(
    sndOn ? "The soundtrack has replaced this track's sound"
          : quiet ? "This track has no sound"
          : t.mute ? "This track is muted - click to hear it again"
                   : "Mute this track's sound",
    t.mute || sndOn || quiet
      ? '<path d="M3 9v6h4l5 5V4L7 9H3z"/><path d="M21.2 8.2 19.8 6.8 17 9.6l-2.8-2.8-1.4 1.4L15.6 11l-2.8 2.8 1.4 1.4L17 12.4l2.8 2.8 1.4-1.4L18.4 11z"/>'
      : '<path d="M3 9v6h4l5 5V4L7 9H3z"/><path d="M14.5 8.5a4 4 0 0 1 0 7v-7zM16.5 5a7.5 7.5 0 0 1 0 14v-2a5.5 5.5 0 0 0 0-10V5z"/>',
    "mute" + (t.mute && !sndOn && !quiet ? " on" : ""),
    function(){ setMute(i, !TR[i].mute); },
    sndOn || quiet));

  foot.appendChild(mini("Clone this track - splits, deletions and loops included - to use again later",
    '<path d="M16 1H4a2 2 0 0 0-2 2v14h2V3h12V1zm3 4H8a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2zm0 16H8V7h11v14z"/>',
    "", function(){ cloneTrack(i); }));
  foot.appendChild(mini("Remove this track",
    '<path d="M6 19a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/>',
    "rm", function(){ removeTrack(i); }));
  row.appendChild(foot);
  row.appendChild(loopRow(i));
  return row;
}

/* line three: Loop [xN] [Ping-pong] */
function loopRow(i){
  var t = TR[i], line = document.createElement("div");
  line.className = "tkloop";
  var lab = document.createElement("span");
  lab.textContent = "Loop";
  line.appendChild(lab);

  var sel = document.createElement("select");
  sel.title = "How many times this track plays in a row - only the parts that were not deleted";
  for (var n = 1; n <= 10; n++){
    var op = document.createElement("option");
    op.value = String(n);
    op.textContent = "\u00d7" + n;
    if (n === (t.loops || 1)) op.selected = true;
    sel.appendChild(op);
  }
  sel.value = String(t.loops || 1);
  sel.onchange = function(){ setLoops(i, parseInt(this.value, 10)); };
  line.appendChild(sel);

  var pp = document.createElement("button");
  pp.className = "pong" + (t.pong ? " on" : "");
  pp.title = t.pong ? "Ping-pong is on - each loop plays forward, then backward"
                    : "Ping-pong - play each loop forward, then backward";
  pp.innerHTML = '<svg viewBox="0 0 24 24"><path d="M7 7h10V4l4 4-4 4V9H7zm10 10H7v3l-4-4 4-4v3h10z"/></svg>Ping-pong';
  pp.onclick = function(){ setPong(i, !TR[i].pong); };
  line.appendChild(pp);
  return line;
}
function setLoops(i, n){
  if (i < 0 || i >= TR.length || isNaN(n)) return;
  n = clamp(Math.round(n), 1, 10);
  if (n === (TR[i].loops || 1)) return;
  snapshot();
  TR[i].loops = n;
  renderTracks(); render();
}
/* ----------------------------- soundtrack ----------------------------- */
/* One audio file for the whole video. On export it replaces every track's own
   sound outright: it starts with the video, repeats from its beginning when it
   runs out, and is cut off where the video ends. The preview does the same -
   the players are muted and the soundtrack is kept in step with the OUTPUT
   clock, so deleted sections are skipped and loop and ping-pong passes counted,
   and what is heard is what will be saved. */
var SND = null;          /* { token, name, path, dur } */
var userMuted = false;   /* the mute button - under a soundtrack it mutes that */

/* Three things can silence the picture: a soundtrack (which replaces every
   track's own sound), the volume bar's mute, and the track's own mute button.
   Only the second reaches a soundtrack - muting one track must not silence
   music that plays over the whole program. */
function trackMuted(){ return cur >= 0 && cur < TR.length && !!TR[cur].mute; }
function applyMute(){
  vMain.muted = vAux.muted = SND ? true : (userMuted || trackMuted());
  snd.muted = userMuted;
}
function setVolume(x){ vMain.volume = vAux.volume = snd.volume = x; }

function importSoundtrack(){
  var btn = $("bSnd"), enable = function(){ btn.disabled = false; };
  btn.disabled = true;
  dialogFetch("/api/audio/open", { method: "POST" }, "file", enable)
    .then(function(j){
      if (j.cancelled) return;
      if (j.busy){ toast(BUSY_MSG, "warn"); return; }
      if (!j.ok){ toast(j.error || "Could not use that audio file.", "bad"); return; }
      setSoundtrack(j);
      toast("Soundtrack set - it replaces the tracks' own sound" +
            (TR.length && SND.dur + 0.01 < outLen() ? " and repeats to cover the whole video." : "."), "good");
    })
    .then(null, function(e){ toast("Could not reach the local server: " + e.message, "bad"); })
    .then(enable);
}
function setSoundtrack(j){
  if (!j || !j.token || !(+j.duration > 0)){ clearSoundtrack(); return; }
  SND = { token: j.token, name: j.name, path: j.path, dur: +j.duration };
  try { snd.pause(); } catch (e) {}
  snd.src = media("/api/audiofile", "t=" + j.token);
  try { snd.load(); } catch (e) {}
  applyMute();
  renderSoundtrack();
  renderTracks();          /* a soundtrack takes the rows' mute buttons out of play */
  syncPlayButtons();
  sndSync(true);
  scheduleAutosave();
}
function clearSoundtrack(){
  SND = null;
  try { snd.pause(); } catch (e) {}
  snd.removeAttribute("src");
  try { snd.load(); } catch (e) {}
  applyMute();
  renderSoundtrack();
  renderTracks();          /* a soundtrack takes the rows' mute buttons out of play */
  syncPlayButtons();
  scheduleAutosave();
}
function renderSoundtrack(){
  $("sndRow").style.display = SND ? "flex" : "none";
  $("bSnd").title = SND ? "Choose a different audio file"
                        : "Replace the video's sound with an audio file - it repeats to fill the whole video";
  if (!SND){ $("sndHint").textContent = "the tracks' own sound is used"; return; }
  $("sndName").textContent = SND.name;
  $("sndName").title = SND.name;
  $("sndMeta").textContent = fmtShort(SND.dur);
  var total = TR.length ? outLen() : 0;
  $("sndHint").textContent = !(total > 0)
    ? "replaces the tracks' own sound"
    : (SND.dur + 0.01 < total
        ? "replaces the tracks' sound - plays " + Math.ceil(total / SND.dur - 1e-6) +
          " times over to cover " + fmt(total, false)
        : "replaces the tracks' sound - cut off where the video ends");
}

/* how far into the SAVED video the frame on screen is */
function outputTime(){
  if (!TR.length) return 0;
  if (LOOP.on){
    var P = loopPieces(), t = 0, k;
    if (LOOP.into < 0 || LOOP.into >= P.length) return 0;
    for (k = 0; k < LOOP.into; k++) t += P[k].e - P[k].s;
    var p = P[LOOP.into], len = p.e - p.s, into;
    if (LOOP.holding) into = len;
    else if (p.rev) into = revPiece ? v.currentTime : 0;
    else into = PH - p.s;
    return t + clamp(into, 0, len);
  }
  /* plain Play runs the timeline once through: count the kept time before PH */
  var r = keptRanges(), o = 0, i;
  for (i = 0; i < r.length; i++){
    if (PH >= r[i][1]){ o += r[i][1] - r[i][0]; continue; }
    if (PH > r[i][0]) o += PH - r[i][0];
    break;
  }
  return o;
}
/* Keep the soundtrack on the output clock. Small drift is left alone - every
   correction is an audible skip - but a jump (a loop going round, a respin
   across a cut, the tab waking up) puts it back where it belongs. */
function sndSync(force){
  if (!SND) return;
  var on = !!M && (LOOP.holding || playbackIsPlaying());
  if (!on){
    if (!snd.paused){ try { snd.pause(); } catch (e) {} }
    return;
  }
  var want = outputTime() % SND.dur;
  var d = Math.abs((snd.currentTime || 0) - want);
  d = Math.min(d, SND.dur - d);                  /* 0.02 and 2.98 of a 3s file are neighbours */
  if (force || snd.paused || d > 0.25){ try { snd.currentTime = want; } catch (e) {} }
  if (snd.paused){
    var pr = snd.play();
    if (pr && pr.then) pr.then(null, function(){ });
  }
}

/* ------------------------------ cloning ------------------------------- */
/* The server hands out a second token for the same file, so the clone is a
   track in its own right - ordered, edited and exported separately. */
function cloneTrack(i){
  if (i < 0 || i >= TR.length) return;
  var src = TR[i];
  fetch(api("/api/clone", "t=" + src.token), { method: "POST" })
    .then(function(r){ return r.json(); })
    .then(function(j){
      if (!j || !j.ok || !j.token){ toast((j && j.error) || "Could not clone that track.", "bad"); return; }
      insertClone(TR.indexOf(src), j.token);
    }, function(e){ toast("Could not reach the local server: " + e.message, "bad"); });
}
/* the clone goes straight after its original; everything later in the program
   moves along by its length, so the trim points and playhead stay on the same
   footage they were on */
function insertClone(i, token){
  if (i < 0 || i >= TR.length) return;
  var src = TR[i], c = {}, k;
  for (k in src) if (Object.prototype.hasOwnProperty.call(src, k)) c[k] = src[k];
  c.token = token;
  c.cuts = src.cuts.slice();
  c.dels = src.dels.map(function(r){ return r.slice(); });
  c._stripOk = false;
  snapshot(true);
  var at = trackOff(i) + src.dur, toEnd = Math.abs(B - D) < EPS;
  TR.splice(i + 1, 0, c);
  recalc();
  if (A >= at - EPS && A > EPS) A += c.dur;
  if (toEnd) B = D; else if (B > at + EPS) B += c.dur;
  if (PH >= at - EPS && PH > EPS) PH += c.dur;
  recalc();
  selSeg = -1;
  cur = TR.indexOf(M);
  refreshProgram();
  goTo(clamp(PH, 0, D), false);
  toast("Track " + (i + 2) + " is a copy of track " + (i + 1) + " - move it wherever you need it.", "good");
}

/* ------------------------------ sessions ------------------------------ */
/* A session is the tracks by file path plus every edit made to them. The file
   is plain JSON, written and read by the server because only it knows the paths
   and can put up the dialogs. It is also autosaved as work goes on, so a closed
   window or a crash costs nothing: the next start offers it back. */
var restoreToast = null;
var autosaveTimer = null;

function sessionData(){
  return {
    app: "SimpleVideoTrimmer", version: 1, A: A, B: B,
    audio: SND ? { path: SND.path, name: SND.name } : null,
    crop: { on: CROP.on, ar: CROP.ar, px: CROP.px, x: CROP.x, y: CROP.y },
    tracks: TR.map(function(t){
      return { path: t.path, name: t.name, cuts: t.cuts.slice(),
               dels: t.dels.map(function(r){ return r.slice(); }),
               loops: t.loops || 1, pong: !!t.pong, mute: !!t.mute };
    })
  };
}

function cleanCuts(a, dur){
  var out = [], i;
  if (a && a.length) for (i = 0; i < a.length; i++){
    var x = +a[i];
    if (isFinite(x) && x > EPS && x < dur - EPS) out.push(x);
  }
  out.sort(function(x, y){ return x - y; });
  return out;
}
function cleanDels(a, dur){
  var out = [], i;
  if (a && a.length) for (i = 0; i < a.length; i++){
    if (!a[i] || a[i].length !== 2) continue;
    var s = clamp(+a[i][0], 0, dur), e = clamp(+a[i][1], 0, dur);
    if (isFinite(s) && isFinite(e) && e - s > EPS) out.push([s, e]);
  }
  return out;
}

/* s: the session as saved. files: what the server made of each of its tracks,
   in the same order - a loaded track with a fresh token, or null when that
   file is no longer where the session says it is. */
/* audio: the session's soundtrack as the server re-registered it, or null */
function applySession(s, files, audio){
  var tr = (s && s.tracks) || [], missing = [], k;
  if (restoreToast){ kill(restoreToast); restoreToast = null; }
  clearProgram();
  for (k = 0; k < tr.length; k++){
    var f = files && files[k];
    if (!f || !f.token){ missing.push(tr[k].name || tr[k].path || ("track " + (k + 1))); continue; }
    acceptTrack(f, true);
    var t = TR[TR.length - 1];
    t.cuts  = cleanCuts(tr[k].cuts, t.dur);
    t.dels  = cleanDels(tr[k].dels, t.dur);
    normTrackDels(TR.length - 1);
    t.loops = clamp(Math.round(+tr[k].loops) || 1, 1, 10);
    t.pong  = !!tr[k].pong;
    t.mute  = !!tr[k].mute;
  }
  if (!TR.length){
    toast("None of that session's videos could be found" +
          (missing.length ? ": " + missing.join(", ") : "") + ".", "bad");
    return;
  }
  recalc();
  A = isFinite(+s.A) ? clamp(+s.A, 0, D) : 0;
  B = (isFinite(+s.B) && +s.B > A) ? clamp(+s.B, 0, D) : D;
  /* a track that went missing can leave the saved trim points pointing at
     footage that is no longer in the program - select everything instead */
  if (missing.length){ A = 0; B = D; }
  if (s.crop && typeof s.crop === "object"){
    CROP.on = !!s.crop.on;
    CROP.ar = arDef(s.crop.ar).k;
    if (isFinite(+s.crop.px)) CROP.px = +s.crop.px;
    if (isFinite(+s.crop.x))  CROP.x  = +s.crop.x;
    if (isFinite(+s.crop.y))  CROP.y  = +s.crop.y;
    cropSync();
    renderAdv();
  }
  hist = [];
  selSeg = -1;
  if (audio && audio.token) setSoundtrack(audio);
  else {
    clearSoundtrack();
    if (s.audio && s.audio.path)
      toast("The soundtrack " + (s.audio.name || s.audio.path) + " could not be found - the tracks' own sound is used.", "warn");
  }
  refreshProgram();
  seek(0);
  if (missing.length)
    toast("Opened " + TR.length + " of " + tr.length + " tracks - could not find " + missing.join(", ") + ".", "warn");
  else
    toast("Session opened - " + TR.length + (TR.length === 1 ? " track." : " tracks."), "good");
}

function saveSession(){
  if (!TR.length) return;
  var btn = $("bSessSave");
  var enable = function(){ btn.disabled = !TR.length; };
  btn.disabled = true;
  dialogFetch("/api/session/save", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(sessionData())
  }, "save", enable)
    .then(function(j){
      if (j.cancelled) return;
      if (j.busy){ toast(BUSY_MSG, "warn"); return; }
      if (!j.ok){ toast(j.error || "Could not save the session.", "bad"); return; }
      toast("Session saved: " + j.name, "good");
    })
    .then(null, function(e){ toast("Could not reach the local server: " + e.message, "bad"); })
    .then(enable);
}

function openSession(){
  if (TR.length && !confirm("Opening a session replaces the tracks you have now. Continue?")) return;
  var btn = $("bSessOpen");
  var enable = function(){ btn.disabled = false; };
  btn.disabled = true;
  dialogFetch("/api/session/open", { method: "POST" }, "file", enable)
    .then(function(j){
      if (j.cancelled) return;
      if (j.busy){ toast(BUSY_MSG, "warn"); return; }
      if (!j.ok){ toast(j.error || "Could not open that session.", "bad"); return; }
      applySession(JSON.parse(j.raw), j.files, j.audio);
    })
    .then(null, function(e){ toast("Could not open that session: " + e.message, "bad"); })
    .then(enable);
}

function autosaveNow(){
  if (autosaveTimer){ clearTimeout(autosaveTimer); autosaveTimer = null; }
  return fetch(api("/api/autosave"), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(sessionData())
  });
}
/* shortly after the last change, not on every one - a handle drag is dozens */
function scheduleAutosave(){
  if (!TR.length) return;       /* an empty program never overwrites real work */
  if (autosaveTimer) clearTimeout(autosaveTimer);
  autosaveTimer = setTimeout(function(){
    autosaveTimer = null;
    if (TR.length) autosaveNow().then(null, function(){ });
  }, 1500);
}
function restoreAutosave(){
  restoreToast = null;
  fetch(api("/api/autosave/load"), { method: "POST" })
    .then(function(r){ return r.json(); })
    .then(function(j){
      if (!j || !j.ok){ toast((j && j.error) || "The last session could not be restored.", "bad"); return; }
      applySession(JSON.parse(j.raw), j.files, j.audio);
    }, function(e){ toast("Could not reach the local server: " + e.message, "bad"); });
}

function setMute(i, on){
  if (i < 0 || i >= TR.length || !!TR[i].mute === !!on) return;
  snapshot();
  TR[i].mute = !!on;
  renderTracks(); render();
}

function setPong(i, on){
  if (i < 0 || i >= TR.length || !!TR[i].pong === !!on) return;
  snapshot();
  TR[i].pong = !!on;
  renderTracks(); render();
}

function mini(title, path, cls, fn, disabled){
  var b = document.createElement("button");
  b.className = cls; b.title = title; b.disabled = !!disabled;
  b.innerHTML = '<svg viewBox="0 0 24 24">' + path + '</svg>';
  b.onclick = fn;
  return b;
}

/* One filmstrip slice per KEPT section, each showing just its own stretch of
   its track's strip image - deleted sections are placeholders with no picture. */
var stripSpans = null;
function renderStrips(){
  var host = $("strip"), tl = $("tl"), i, k;
  while (host.firstChild) host.removeChild(host.firstChild);
  stripSpans = null;
  if (!TR.length || !(D > 0)){ tl.className = "tl"; return; }
  var sp = tlSpans(), slices = [], waiting = 0;
  stripSpans = sp;
  for (i = 0; i < TR.length; i++) slices.push([]);
  for (k = 0; k < sp.length; k++){
    if (sp[k].del) continue;
    var ti = trackAt((sp[k].s + sp[k].e) / 2);
    if (ti < 0) continue;
    var tk = TR[ti], len = sp[k].e - sp[k].s, sl = sp[k].s - trackOff(ti);
    var el = document.createElement("div");
    el.className = "sv" + (ti > 0 && !slices[ti].length ? " j" : "");
    el.style.left  = (sp[k].x0 * 100) + "%";
    el.style.width = ((sp[k].x1 - sp[k].x0) * 100) + "%";
    /* the image is scaled so the whole track would span dur/len slices, then
       slid so this section's stretch lines up - background-position in % means
       "this fraction of (box - image)", hence the dur - len divisor */
    el.style.backgroundSize = (tk.dur / len * 100) + "% 100%";
    el.style.backgroundPosition = (tk.dur - len > 1e-6 ? sl / (tk.dur - len) * 100 : 0) + "% 0";
    host.appendChild(el);
    slices[ti].push(el);
  }
  var paint = function(els, url){
    for (var j = 0; j < els.length; j++) els[j].style.backgroundImage = "url('" + url + "')";
  };
  var settle = function(){ if (--waiting <= 0) tl.className = "tl"; };
  for (i = 0; i < TR.length; i++){
    if (!slices[i].length) continue;
    var url = media("/api/strip", "t=" + TR[i].token);
    /* already fetched once: repaint straight away, so a delete does not blink */
    if (TR[i]._stripOk){ paint(slices[i], url); continue; }
    waiting++;
    (function(t, els, url){
      var img = new Image();
      img.onload  = function(){ t._stripOk = true; paint(els, url); settle(); };
      img.onerror = settle;
      img.src = url;
    })(TR[i], slices[i], url);
  }
  tl.className = waiting ? "tl busy" : "tl";
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
  var url = media("/api/frame", "t=" + M.token + "&at=" + at.toFixed(6));
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
  v._url = "";
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
  v.src = v._url = media("/api/play", "t=" + M.token + "&start=" + want.toFixed(6));
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
  var haveAudio = on && (!!SND || !M || M.hasAudio);
  $("bMute").disabled = !haveAudio;
  $("vol").disabled   = !haveAudio;
  $("bPlay").title = "Play / Pause (Space)";
  $("bSel").title  = (M && !M.hasAudio && !SND)
    ? "Play the selected range on a loop - this file has no audio track"
    : "Play the selected range on a loop - Space stops it";
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
    v.src = v._url = media("/api/stream", "t=" + M.token);
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
    /* a track that is still loading cannot take a seek yet - and loadedmetadata
       would overwrite one anyway - so re-aim the seek it is waiting to make */
    if (pendingSeek >= 0) pendingSeek = L.t;
    else if (vOk){ try { v.currentTime = L.t; } catch (e) {} }
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
  return tlT(clamp((clientX - r.left) / r.width, 0, 1));
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
  var at = tlT(f);
  var L = toLocal(at);
  if (!L) return;
  var tk = TR[L.i];
  if (!tk.tiles) return;
  /* the thumbnail has to come from whichever track the cursor is over */
  var idx = clamp(Math.floor(L.t / tk.dur * tk.tiles), 0, tk.tiles - 1);
  var pop = $("pop");
  $("popImg").style.backgroundImage = "url('" + media("/api/strip", "t=" + tk.token) + "')";
  $("popImg").style.backgroundSize = (tk.tiles * tk.tileW) + "px " + tk.tileH + "px";
  $("popImg").style.backgroundPosition = (-idx * tk.tileW) + "px 0";
  $("popLab").textContent = fmt(at, false);
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
    h.edits[i].o.loops = h.edits[i].loops;
    h.edits[i].o.pong = h.edits[i].pong;
    h.edits[i].o.mute = h.edits[i].mute;
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

/* ----------------------- looping Play Selection ------------------------ */
/* Play Selection plays the kept parts of the selection in order and then goes
   round again, forever. A seek back to the start would stall - the decoder has
   to restart from a keyframe and the audio flushes - so instead the idle player
   is parked, paused, on the frame where the next part begins. When the active
   one reaches the end of its part the two swap: the parked one starts playing
   and is shown, the other is hidden and paused. Nothing is decoded at the join,
   so there is nothing to wait for. The same swap carries playback over a
   deleted hole or onto the next track.

   The end is watched on every animation frame rather than on timeupdate, which
   only fires about four times a second and would overshoot by up to 250ms.
   Anything the swap cannot cover - a part in a file the browser cannot decode,
   or a player that is not parked yet - falls back to an ordinary jump. */
var LOOP = { on: false, raf: 0, key: "", ready: false, failed: "", into: -1, last: 0, dt: 16,
             holding: false, swapAt: 0, holdTimer: null };
var revPiece = null;   /* {s, e} in program time while the active player runs a part backwards */

function vIdle(){ return v === vMain ? vAux : vMain; }

/* kept parts in program time, merged into runs that stay inside one track */
function loopPieces(){
  var sg = segments(), out = [], i;
  for (i = 0; i < sg.length; i++){
    if (sg[i].del) continue;
    var s = Math.max(sg[i].s, A), e = Math.min(sg[i].e, B);
    if (e - s < 0.01) continue;
    var k = trackAt((s + e) / 2);
    if (k < 0) continue;
    var last = out.length ? out[out.length - 1] : null;
    if (last && last.i === k && Math.abs(s - last.e) < EPS) last.e = e;
    else out.push({ i: k, s: s, e: e });
  }
  /* the preview goes round the same passes the export will contain */
  return expandLoops(out, function(p){ return TR[p.i]; },
                     function(p){ return { i: p.i, s: p.s, e: p.e, rev: true }; });
}
function loopKey(p){ return TR[p.i].token + "@" + p.s.toFixed(4) + (p.rev ? "<" + p.e.toFixed(4) : ""); }
/* browsers cannot play backwards, so a backwards pass is streamed ready-reversed */
function revUrl(p){
  var o = trackOff(p.i);
  return media("/api/play", "t=" + TR[p.i].token + "&start=" + (p.s - o).toFixed(6) +
                          "&end=" + (p.e - o).toFixed(6) + "&rev=1");
}

function loopStart(){
  LOOP.on = true; LOOP.into = 0; LOOP.last = 0;
  skipGuardUntil = 0;
  $("bSel").classList.add("on");
  watchFrames(vMain); watchFrames(vAux);
  if (!LOOP.raf && typeof requestAnimationFrame === "function") LOOP.raf = requestAnimationFrame(loopTick);
}
function loopStop(){
  if (LOOP.raf && typeof cancelAnimationFrame === "function") cancelAnimationFrame(LOOP.raf);
  LOOP.raf = 0; LOOP.on = false; LOOP.into = -1;
  LOOP.holding = false;
  if (LOOP.holdTimer){ clearTimeout(LOOP.holdTimer); LOOP.holdTimer = null; }
  unwatchFrames(vMain); unwatchFrames(vAux);
  loopRelease();
  $("bSel").classList.remove("on");
  /* stopped mid backwards pass: put the track's own source back, at the
     frame the playhead is showing */
  if (revPiece){
    var at = clamp(PH, 0, D);
    revPiece = null; restarting = false;
    if (TR.length){
      var L = toLocal(at);
      activate(L.i, L.t, false);
      PH = at; renderPlayhead();
    }
  }
}
/* unpark the idle player - for a preview stream that also ends its ffmpeg */
function loopRelease(){
  var sb = vIdle();
  LOOP.key = ""; LOOP.ready = false; LOOP.failed = "";
  sb._seekTo = -1; sb._key = "";
  if (sb._url){
    try { sb.pause(); } catch (e) {}
    sb.removeAttribute("src"); sb._url = "";
    try { sb.load(); } catch (e) {}
  }
  sb.style.display = "none"; sb.style.visibility = "";
}

function loopTick(ts){
  LOOP.raf = 0;
  if (!selPlay || !M){ loopStop(); return; }
  if (LOOP.last && ts > LOOP.last) LOOP.dt = clamp(ts - LOOP.last, 4, 50);
  LOOP.last = ts;
  if (LOOP.holding){
    /* parked on the last frame before the end - swap once its time is up */
    if (ts >= LOOP.swapAt) loopStep(true);
  } else if (!v.paused && v.style.display !== "none" && !(mode === "video" && pendingSeek >= 0)){
    PH = playPos();
    loopStep(false);
    renderPlayhead();
  }
  sndSync();
  LOOP.raf = requestAnimationFrame(loopTick);
}

/* ---- landing exactly on the end ----
   Swapping on the clock alone is not frame exact. The browser puts video frames
   on screen from its compositor, without waiting for the page, so by the time a
   swap made on the main thread reaches the screen the old player can already
   have shown a frame or two from PAST the end - a glimpse of footage that was
   trimmed away. Where the browser reports each frame as it is presented
   (requestVideoFrameCallback), the player is instead paused ON the last frame
   before the end, which is a frame that belongs in the loop, and the swap is
   timed for when that frame's own display time runs out. Nothing later is ever
   decoded for the compositor to show. */
function frameDur(){ return 1 / ((M && M.fps > 0) ? M.fps : 25); }
function frameWatched(){ return !!v.requestVideoFrameCallback; }
/* with frame callbacks the clock check is only a backstop, a frame late */
function endSlack(){ return frameWatched() ? -frameDur() : LOOP.dt / 2000; }

function watchFrames(el){
  if (!el.requestVideoFrameCallback || el._rvfc) return;
  var onFrame = function(now, meta){
    el._rvfc = 0;
    if (!LOOP.on) return;
    if (el === v) loopFrame(meta);
    el._rvfc = el.requestVideoFrameCallback(onFrame);
  };
  el._rvfc = el.requestVideoFrameCallback(onFrame);
}
function unwatchFrames(el){
  if (el._rvfc && el.cancelVideoFrameCallback) el.cancelVideoFrameCallback(el._rvfc);
  el._rvfc = 0;
}

function loopFrame(meta){
  if (LOOP.holding || v.paused || !M || !meta) return;
  var P = loopPieces(), ip = (LOOP.into >= 0 && LOOP.into < P.length) ? P[LOOP.into] : null;
  if (!ip || ip.i !== cur || !!ip.rev !== !!revPiece) return;
  /* the part's end on this player's own clock */
  var end = ip.rev ? ip.e - ip.s : ip.e - trackOff(ip.i) - (mode === "frames" ? playStart : 0);
  var fd = frameDur(), t = meta.mediaTime;
  if (t + fd < end - fd * 0.25) return;          /* more frames to come before the end */
  var left = Math.max(0, end - t) * 1000 / (v.playbackRate || 1);
  LOOP.holding = true;
  LOOP.swapAt = meta.expectedDisplayTime + left - LOOP.dt / 2;
  try { v.pause(); } catch (e) {}
  /* animation frames stop in a background tab - never stay parked for good */
  if (LOOP.holdTimer) clearTimeout(LOOP.holdTimer);
  LOOP.holdTimer = setTimeout(function(){
    LOOP.holdTimer = null;
    if (LOOP.holding) loopStep(true);
  }, left + 60);
}

/* atEnd: the active clip has run out, so whatever part it was in is over */
function loopStep(atEnd){
  if (!M) return;
  var P = loopPieces(), n = P.length, i, idx = -1;
  if (!n) return;
  if (revPiece){
    /* a backwards pass is its own stream, so progress is just how far into it
       playback is - the program position runs the other way */
    var rp = (LOOP.into >= 0 && LOOP.into < n) ? P[LOOP.into] : null;
    if (rp && rp.rev && rp.i === cur && Math.abs(rp.s - revPiece.s) < EPS && Math.abs(rp.e - revPiece.e) < EPS){
      var nr = (LOOP.into + 1) % n;
      loopPrime(P[nr]);
      if (atEnd || v.currentTime >= (rp.e - rp.s) - endSlack()) loopJump(P, nr);
    } else {
      loopJump(P, 0);     /* the loop settings changed under a backwards pass */
    }
    return;
  }
  var pos = atEnd ? trackOff(cur) + M.dur - 1e-6 : PH;
  /* the part just jumped into also owns anything before its start: a preview
     stream can only begin on a keyframe, so it replays a moment first */
  var ip = (LOOP.into >= 0 && LOOP.into < n) ? P[LOOP.into] : null;
  /* and it still owns a late report just past its end - running past it is
     exactly when it is time to move on, not a sign playback is lost */
  if (ip && !ip.rev && ip.i === cur && (atEnd || pos < ip.e + 1) && pos >= ip.s - (mode === "frames" ? 1e9 : 0.05)) idx = LOOP.into;
  for (i = 0; idx < 0 && i < n; i++) if (!P[i].rev && P[i].i === cur && pos >= P[i].s - 0.05 && pos < P[i].e) idx = i;
  if (idx < 0){
    /* outside every part - the selection moved under the playhead. Carry on
       with the next part along, or go round. */
    for (i = 0; i < n; i++) if (!P[i].rev && P[i].s > pos - EPS) break;
    loopJump(P, i < n ? i : 0);
    return;
  }
  var nx = (idx + 1) % n;
  loopPrime(P[nx]);
  /* swap on the animation frame nearest the end, not the first one after it */
  var lead = (LOOP.dt / 2000) * (v.playbackRate || 1);
  if (atEnd || pos >= P[idx].e - (frameWatched() ? endSlack() : lead)) loopJump(P, nx);
}

/* park the idle player on the first frame of part p */
function loopPrime(p){
  var tk = TR[p.i], key = loopKey(p);
  if ((!tk.playable && !p.rev) || key === LOOP.key || key === LOOP.failed) return;
  var sb = vIdle(), url = media("/api/stream", "t=" + tk.token);
  var at = clamp(p.s - trackOff(p.i), 0, tk.dur);
  LOOP.key = key; LOOP.ready = false;
  sb._key = key; sb._rev = !!p.rev;
  sb.style.visibility = "hidden"; sb.style.display = "block";
  try { sb.pause(); } catch (e) {}
  if (p.rev){
    /* a fresh server stream every time - it is used up as it plays - and it
       begins on its own first frame, so there is nothing to seek */
    sb._seekTo = -1;
    sb.src = sb._url = revUrl(p);
    sb.load();
    return;
  }
  if (sb._url !== url){
    sb._seekTo = at; sb._url = url;
    sb.src = url; sb.load();
  } else if (!(sb.readyState >= 1)){
    sb._seekTo = at;                 /* loadedmetadata will place it */
  } else {
    sb._seekTo = -1;
    try { sb.currentTime = at; } catch (e) { LOOP.failed = key; LOOP.key = ""; }
  }
}
function idleVideoEvent(el, name){
  if (name === "loadedmetadata" && el._seekTo >= 0){
    var t = el._seekTo; el._seekTo = -1;
    try { el.currentTime = t; } catch (e) {}
  } else if (name === "seeked" && !el._rev && el._key && el._key === LOOP.key && !(el._seekTo >= 0)){
    LOOP.ready = true;
  } else if (name === "loadeddata" && el._rev && el._key && el._key === LOOP.key){
    LOOP.ready = true;                /* the reversed stream's first frame is in */
  } else if (name === "error" && el._key && el._key === LOOP.key){
    /* never retry a broken park every frame - the plain jump still works */
    LOOP.failed = LOOP.key; LOOP.key = ""; LOOP.ready = false; el._url = "";
  }
}

function loopJump(P, k){
  var p = P[k], sb = vIdle(), old = v;
  LOOP.into = k;
  LOOP.holding = false;
  if (LOOP.holdTimer){ clearTimeout(LOOP.holdTimer); LOOP.holdTimer = null; }
  skipGuardUntil = 0;
  if (LOOP.ready && LOOP.key === loopKey(p) && (p.rev || TR[p.i].playable)){
    var moved = cur !== p.i;
    sb.muted = old.muted; sb.volume = old.volume;
    v = sb;
    cur = p.i; M = TR[p.i]; mode = "video"; vOk = true; playStart = 0; pendingSeek = -1;
    revPiece = p.rev ? { s: p.s, e: p.e } : null;
    /* start the parked player first, then hide the old one in the same task,
       so the browser never paints a frame with neither on screen */
    sb.style.visibility = ""; sb.style.display = "block";
    guardPlay();
    old.style.display = "none"; old.style.visibility = "";
    old._key = "";
    try { old.pause(); } catch (e) {}
    $("frame").style.display = "none";
    $("notice").style.display = "none";
    LOOP.key = ""; LOOP.ready = false;
    PH = p.rev ? p.e : p.s;
    if (moved){ syncPlayButtons(); renderTracks(); }
    return;
  }
  if (p.rev){ loopStreamReverse(p); return; }
  if (revPiece){
    /* coming out of a backwards stream: the track's real source has to go back in */
    revPiece = null;
    restarting = true;
    activate(p.i, p.s - trackOff(p.i), true);
    PH = p.s;
    return;
  }
  skipTo(p.s, true);
}
/* nothing parked for a backwards pass - start its stream on the active player */
function loopStreamReverse(p){
  restarting = true;
  stopStream();
  cur = p.i; M = TR[p.i]; mode = "video"; vOk = true; playStart = 0; pendingSeek = -1;
  revPiece = { s: p.s, e: p.e };
  $("frame").style.display = "none";
  v.style.display = "block"; v.style.visibility = "";
  v.src = v._url = revUrl(p);
  v.load();
  guardPlay();
  setPlayIcon(true);
  PH = p.e;
  syncPlayButtons(); renderTracks();
}
onVideo("loadeddata", function(){ });   /* only the parked player cares - see idleVideoEvent */

/* ----------------------------- transport ------------------------------ */
function togglePlay(){
  if (!M || !canPlayNow()) return;
  if (playbackIsPlaying()){
    /* the user's own pause always ends Play Selection - even mid respin, when
       the pause handler has to assume a pause is the app's own doing */
    selPlay = false;
    playbackPause();
    if (LOOP.on) loopStop();
  } else playbackPlay();
}
function setPlayIcon(on){
  $("icPlay").innerHTML = on ? '<path d="M6 5h4v14H6zm8 0h4v14h-4z"/>'
                             : '<path d="M8 5v14l11-7z"/>';
  $("txPlay").textContent = on ? "Pause" : "Play";
}
/* Both players carry every listener, but only the ACTIVE one's events drive the
   app. The idle one is being parked on the next loop point, and its events
   only report how that is going. */
function onVideo(name, fn){
  var els = [vMain, vAux];
  for (var i = 0; i < els.length; i++) (function(el){
    el.addEventListener(name, function(e){
      if (el === v) fn.call(el, e); else idleVideoEvent(el, name);
    });
  })(els[i]);
}
function playPos(){
  if (revPiece) return trackOff(cur) + revPiece.e - v.currentTime;
  return trackOff(cur) + ((mode === "video") ? v.currentTime : (playStart + v.currentTime));
}

onVideo("play",  function(){ setPlayIcon(true); restarting = false; sndSync(); });
onVideo("pause", function(){
  setPlayIcon(false);
  /* a respin across a cut tears the stream down first - that pause is ours,
     not the user's, so it must not cancel Play Selection. Nor does running
     off the end of a clip: ended takes the loop round from there. */
  if (!restarting && !this.ended && !LOOP.holding) selPlay = false;
  if (!selPlay && LOOP.on) loopStop();
  sndSync();
});
onVideo("timeupdate", function(){
  if (mode === "frames" && !playbackIsPlaying()) return;
  /* a freshly loaded track reports 0 until its pending seek lands - acting on
     that would "skip" a deleted head that playback is not even in */
  if (mode === "video" && pendingSeek >= 0) return;
  PH = playPos();
  sndSync();
  /* the animation-frame loop normally gets there first; this keeps the loop
     going in a background tab, where animation frames stop */
  if (selPlay){ loopStep(false); renderPlayhead(); return; }
  if (skipIfDeleted()) return;
  renderPlayhead();
});
onVideo("seeked", function(){
  if (mode === "video" && !revPiece){ PH = trackOff(cur) + v.currentTime; renderPlayhead(); }
});
onVideo("loadedmetadata", function(){
  /* a freshly swapped-in track cannot be positioned until its metadata lands */
  if (pendingSeek >= 0){
    try { v.currentTime = pendingSeek; } catch (e) {}
    pendingSeek = -1;
  }
});
onVideo("error", function(){
  if (!M) return;
  if (revPiece){
    selPlay = false; loopStop();
    toast("Could not play that part backwards - the saved video is not affected.", "warn");
    return;
  }
  if (mode === "video"){ enterFramesMode(M, clamp(PH - trackOff(cur), 0, M.dur), false); }
  else if (playbackIsPlaying()) { playbackPause(); toast("Preview stream stopped.", "warn"); }
});
/* the end of one clip is the start of the next - that is the whole stitch */
onVideo("ended", function(){
  if (!M) return;
  if (selPlay){ loopStep(true); return; }
  if (cur < TR.length - 1){
    /* land past a deleted head on the next track rather than playing into it */
    var nt = trackOff(cur + 1), edge = delEndAt(nt);
    if (edge >= D - 0.02){ playbackPause(); seek(D); return; }
    restarting = true;
    goTo(edge >= 0 ? edge : nt, true);
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
  if (LOOP.on){ selPlay = false; loopStop(); }   /* start over from the top */
  var r = keptRanges();
  if (!r.length){ toast("Nothing is selected to play.", "warn"); return; }
  seek(r[0][0]); selPlay = true;
  playbackPlay();
  loopStart();
};
$("bMute").onclick = function(){
  userMuted = !userMuted;
  applyMute();
  $("icVol").innerHTML = userMuted
    ? '<path d="M3 9v6h4l5 5V4L7 9H3zm18.6 1.4L20.2 9l-2.1 2.1L16 9l-1.4 1.4 2.1 2.1-2.1 2.1L16 16l2.1-2.1L20.2 16l1.4-1.4-2.1-2.1z"/>'
    : '<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z"/>';
};
$("vol").oninput = function(e){ setVolume(+e.target.value); userMuted = false; applyMute(); };
$("bSetA").onclick = function(){ setA(PH); };
$("bSetB").onclick = function(){ setB(PH); };
$("bGoA").onclick  = function(){ playbackPause(); seek(A); };
$("bGoB").onclick  = function(){ playbackPause(); seek(B); };
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

/* ------------------- crop and output size (the Advanced panel) -------------
   The size control is a pixel BUDGET, and the box takes exactly that many
   pixels out of the source at 1:1 - 512 means a 512x512 chunk of the actual
   picture, saved as 512x512. Nothing is resampled in either direction, so
   picking a bigger budget makes the box cover MORE of the frame rather than
   re-encoding the same region larger. A budget the source cannot fill is
   capped to the largest box of that shape which fits, because upscaling would
   invent detail that was never there.

   The rectangle itself is stored NORMALISED: x and y as fractions of the
   OUTPUT frame, which is track 1's picture. Not source pixels, for two
   reasons. Track 1 can be swapped for a clip of a different size without the
   rectangle silently coming to mean something else. And normalised is what the
   server needs anyway, because it has to resolve the same rectangle against a
   different frame on each of its two export paths - the source itself when one
   file is involved, track 1's canvas once several are stitched into it. */

var PX_MIN = 256, PX_MAX = 4096;
var PX_PRESETS = [256, 512, 768, 1024, 1536, 2048];
var ARS = [
  { k: "src",  w: 0,  h: 0,  lab: "Original", grp: "free" },
  { k: "1x1",  w: 1,  h: 1,  lab: "1:1",      grp: "sq"   },
  { k: "16x9", w: 16, h: 9,  lab: "16:9",     grp: "land" },
  { k: "3x2",  w: 3,  h: 2,  lab: "3:2",      grp: "land" },
  { k: "4x3",  w: 4,  h: 3,  lab: "4:3",      grp: "land" },
  { k: "5x4",  w: 5,  h: 4,  lab: "5:4",      grp: "land" },
  { k: "9x16", w: 9,  h: 16, lab: "9:16",     grp: "port" },
  { k: "2x3",  w: 2,  h: 3,  lab: "2:3",      grp: "port" },
  { k: "3x4",  w: 3,  h: 4,  lab: "3:4",      grp: "port" },
  { k: "4x5",  w: 4,  h: 5,  lab: "4:5",      grp: "port" }
];
/* w and h are derived from px - cropSync owns them - but they are kept on the
   object because every layout and drag calculation wants them normalised. */
var CROP  = { on: false, ar: "src", px: 512, x: 0, y: 0, w: 1, h: 1, capped: false };
var cdrag = null;        /* an in-flight move or corner resize */

function arDef(k){
  for (var i = 0; i < ARS.length; i++) if (ARS[i].k === k) return ARS[i];
  return ARS[0];
}
/* The frame the rectangle is measured against. The server settles this the
   same way, and it is not simply track 1: a lone contributing clip keeps its
   own frame, and only once several files are stitched does track 1's canvas
   become the one they are all fitted into. So trimming track 1 away entirely
   really does change the shape of the output, and the box follows it. */
function frameTrack(){
  if (!TR.length) return null;
  var parts = keptParts(), tok = null, i, k;
  for (i = 0; i < parts.length; i++){
    if (tok === null) tok = parts[i].t;
    else if (parts[i].t !== tok) return TR[0];      /* several files: track 1 */
  }
  if (tok === null) return TR[0];                   /* nothing kept yet */
  for (k = 0; k < TR.length; k++) if (TR[k].token === tok) return TR[k];
  return TR[0];
}
function frameDims(){
  var t = frameTrack();
  if (!t || !(t.width > 0) || !(t.height > 0)) return { w: 1920, h: 1080 };
  return { w: t.width, h: t.height };
}
function frameAR(){ var f = frameDims(); return f.w / f.h; }
function cropAR(){
  var a = arDef(CROP.ar);
  return (a.w > 0 && a.h > 0) ? a.w / a.h : frameAR();
}

/* The box in SOURCE pixels: the budget spread across the chosen shape, then
   shrunk to fit if the picture is smaller than that. Both sides shrink by the
   same factor, so the shape survives the cap. */
function cropSize(){
  var f = frameDims(), r = Math.sqrt(cropAR());
  var px = clamp(CROP.px, PX_MIN, PX_MAX);
  var cw = px * r, ch = px / r;
  var k = Math.min(1, f.w / cw, f.h / ch);
  return { w: cw * k, h: ch * k, fw: f.w, fh: f.h,
           capped: px > pxCeilingExact() + 0.5 };
}
/* Re-derive the normalised box from the budget and keep it on the picture.
   Everything that changes the budget, the shape or the frame ends with this. */
function cropSync(){
  /* A shape change can lower the ceiling under the budget - a 9:16 slice of
     1080p reaches only 810 where 16:9 reached 1440. Bring the budget down with
     it, so the lit preset is always one that could actually be picked rather
     than a greyed-out button claiming to be selected. */
  CROP.px = clamp(CROP.px, PX_MIN, pxCeiling());
  var s = cropSize();
  CROP.w = s.w / s.fw;
  CROP.h = s.h / s.fh;
  CROP.capped = s.capped;
  CROP.x = clamp(CROP.x, 0, Math.max(0, 1 - CROP.w));
  CROP.y = clamp(CROP.y, 0, Math.max(0, 1 - CROP.h));
}
function cropCentre(){
  cropSync();
  CROP.x = (1 - CROP.w) / 2;
  CROP.y = (1 - CROP.h) / 2;
  cropSync();
}
/* x264 at yuv420p refuses an odd dimension. Floor rather than round, so the
   box can never claim a pixel the source does not have. */
function even(x){ return Math.max(2, Math.floor(x / 2 + 1e-6) * 2); }
function outDims(){
  var s = cropSize();
  return { w: even(s.w), h: even(s.h) };
}
/* the budget a box of this pixel width stands for - the inverse of cropSize */
function pxForWidth(cw){ return cw / Math.sqrt(cropAR()); }

/* The largest budget this clip can actually supply at this shape - the whole
   frame, in other words. It is the real limit, so it is the one the slider
   uses: PX_MAX is only a backstop for a source too big to be plausible. A 16:9
   crop of 1080p reaches 1440 here, and of 4K, 2880. */
function pxCeilingExact(){
  var f = frameDims(), r = Math.sqrt(cropAR());
  return Math.min(f.w / r, f.h * r);
}
function pxCeiling(){ return clamp(Math.round(pxCeilingExact()), PX_MIN, PX_MAX); }
/* The slider is logarithmic. Its range spans a factor of five or more once a
   big source raises the ceiling, and a linear track would crush 256-to-512
   into a few pixels of travel - which is exactly the end that needs the fine
   control. On a log track every doubling gets the same room. */
function pxToPos(px){
  var hi = pxCeiling();
  if (hi <= PX_MIN) return 0;
  return Math.round(1000 * Math.log(clamp(px, PX_MIN, hi) / PX_MIN) / Math.log(hi / PX_MIN));
}
function posToPx(pos){
  var hi = pxCeiling();
  if (hi <= PX_MIN) return PX_MIN;
  return Math.round(PX_MIN * Math.exp(clamp(pos, 0, 1000) / 1000 * Math.log(hi / PX_MIN)));
}

/* Where the output frame lands inside the stage: the same letterbox
   object-fit:contain gives the picture, worked out rather than measured so the
   box is right before the first frame has even decoded - and so it still means
   track 1's frame while a differently-shaped track is on screen. */
function frameRect(){
  var st = $("stage").getBoundingClientRect();
  var fa = frameAR(), w = st.width, h = st.height;
  if (!(w > 0) || !(h > 0)) return { left: 0, top: 0, w: 0, h: 0 };
  if (w / h > fa) w = h * fa; else h = w / fa;
  return { left: (st.width - w) / 2, top: (st.height - h) / 2, w: w, h: h };
}

function renderCrop(){
  var live = CROP.on && TR.length > 0;
  $("cropWrap").classList[live ? "add" : "remove"]("on");
  if (!live) return;
  cropSync();
  var f = frameRect(), b = $("cropBox"), d = outDims();
  b.style.left   = (f.left + CROP.x * f.w) + "px";
  b.style.top    = (f.top  + CROP.y * f.h) + "px";
  b.style.width  = (CROP.w * f.w) + "px";
  b.style.height = (CROP.h * f.h) + "px";
  $("cropLab").textContent = d.w + " x " + d.h;
}

function renderAdv(){
  var on = CROP.on, d = outDims(), i, kids, key;
  $("cbCrop").checked   = on;
  $("pxSlide").disabled = !on;
  $("pxSlide").value    = String(pxToPos(CROP.px));
  $("bCropCentre").disabled = !on;

  kids = $("arList").childNodes;
  for (i = 0; i < kids.length; i++){
    if (!kids[i].getAttribute) continue;
    key = kids[i].getAttribute("data-ar");
    if (key === null) continue;                 /* a group separator */
    kids[i].disabled  = !on;
    kids[i].className = "pill" + (on && key === CROP.ar ? " on" : "");
  }
  var ceil = pxCeiling(), pv;
  kids = $("pxList").childNodes;
  for (i = 0; i < kids.length; i++){
    if (!kids[i].getAttribute) continue;
    key = kids[i].getAttribute("data-px");
    if (key === null) continue;
    if (key === "max"){
      kids[i].disabled  = !on;
      kids[i].className = "pill" + (on && CROP.px >= ceil ? " on" : "");
      kids[i].title     = "Take the whole frame at this shape - " + ceil + " here";
      continue;
    }
    pv = parseInt(key, 10);
    /* a budget bigger than the clip holds is shown greyed rather than hidden,
       so the reason it is unavailable is on the button itself */
    kids[i].disabled  = !on || pv > ceil;
    kids[i].className = "pill" + (on && pv === CROP.px ? " on" : "");
    kids[i].title     = pv > ceil
      ? (pv + " is more than this clip holds at this shape - the most is " + ceil)
      : ("Take as many pixels as " + pv + " x " + pv + ", straight out of the picture");
  }

  $("outDim").textContent  = on ? (d.w + " x " + d.h) : "-";
  $("advChip").textContent = on ? (d.w + " x " + d.h) : "off";
  $("advChip").className   = "chip " + (on ? (CROP.capped ? "work" : "done") : "off");
  $("cropHint").textContent = !on
    ? "cut a fixed-size piece out of the picture, at its own resolution"
    : CROP.capped
      ? ("this clip only reaches " + pxCeiling() + " at this shape - taking " +
         d.w + " x " + d.h + " rather than blowing it up")
      : (TR.length > 1
          ? "measured on track 1's frame, which the other tracks are fitted into"
          : "drag the box to move it, or a corner to resize it");
}
function renderCropAll(){ renderAdv(); renderCrop(); syncEditButtons(); }

/* Growing or restyling the box keeps its middle where the user left it, so the
   subject they framed stays framed. */
function reshape(fn){
  var cx = CROP.x + CROP.w / 2, cy = CROP.y + CROP.h / 2;
  fn();
  cropSync();
  CROP.x = cx - CROP.w / 2;
  CROP.y = cy - CROP.h / 2;
  cropSync();
  renderCropAll();
}
function setAR(k){ if (CROP.on) reshape(function(){ CROP.ar = arDef(k).k; }); }
function setPX(n){
  if (!CROP.on || isNaN(n)) return;
  reshape(function(){ CROP.px = clamp(Math.round(n), PX_MIN, pxCeiling()); });
}

/* What /api/save is told. Null while the panel is off, and a save with no crop
   means "the whole frame at its own size" - exactly what it meant before.
   The size goes over as whole pixels rather than as another fraction: the
   server has to land on the same integers, and a round trip through a fraction
   is exactly where it would fail to. */
function cropPayload(){
  if (!CROP.on) return null;
  cropSync();
  var d = outDims();
  return { x: CROP.x, y: CROP.y, ow: d.w, oh: d.h };
}

function buildAdv(){
  var host = $("arList"), i, b, s, prev = null;
  for (i = 0; i < ARS.length; i++){
    if (prev !== null && ARS[i].grp !== prev){
      s = document.createElement("span"); s.className = "sep"; host.appendChild(s);
    }
    prev = ARS[i].grp;
    b = document.createElement("button");
    b.className   = "pill";
    b.textContent = ARS[i].lab;
    b.title       = ARS[i].k === "src" ? "Keep the shape of the source picture"
                                       : "Crop to " + ARS[i].lab;
    b.setAttribute("data-ar", ARS[i].k);
    b.onclick = onPickAR;
    host.appendChild(b);
  }
  host = $("pxList");
  for (i = 0; i < PX_PRESETS.length; i++){
    b = document.createElement("button");
    b.className   = "pill";
    b.textContent = String(PX_PRESETS[i]);
    b.title       = "Take as many pixels as " + PX_PRESETS[i] + " x " + PX_PRESETS[i] +
                    ", straight out of the picture";
    b.setAttribute("data-px", String(PX_PRESETS[i]));
    b.onclick = onPickPX;
    host.appendChild(b);
  }
  s = document.createElement("span"); s.className = "sep"; host.appendChild(s);
  b = document.createElement("button");
  b.className   = "pill";
  b.textContent = "Max";
  b.setAttribute("data-px", "max");
  b.onclick = onPickPX;
  host.appendChild(b);
}
function onPickAR(){ setAR(this.getAttribute("data-ar")); }
function onPickPX(){
  var v = this.getAttribute("data-px");
  setPX(v === "max" ? pxCeiling() : parseInt(v, 10));
}

$("bAdv").onclick = function(){
  var a = $("adv");
  a.classList[a.classList.contains("open") ? "remove" : "add"]("open");
  renderCrop();
};
$("cbCrop").addEventListener("change", function(e){
  CROP.on = !!(e && e.target ? e.target.checked : $("cbCrop").checked);
  if (CROP.on) cropCentre(); else cropSync();
  renderCropAll();
});
$("pxSlide").addEventListener("input", function(e){
  setPX(posToPx(parseInt((e && e.target ? e.target.value : $("pxSlide").value), 10)));
});
$("bCropCentre").onclick = function(){ if (CROP.on){ cropCentre(); renderCropAll(); } };

$("cropBox").addEventListener("pointerdown", function(e){
  if (!CROP.on || !TR.length) return;
  var g = (e.target && e.target.getAttribute) ? e.target.getAttribute("data-g") : null;
  cdrag = { mode: g || "move", px: e.clientX, py: e.clientY,
            x: CROP.x, y: CROP.y, w: CROP.w, h: CROP.h, f: frameRect() };
  try { $("cropBox").setPointerCapture(e.pointerId); } catch (err) {}
  if (e.preventDefault)  e.preventDefault();
  if (e.stopPropagation) e.stopPropagation();
});
$("cropBox").addEventListener("pointermove", function(e){
  if (!cdrag || !(cdrag.f.w > 0)) return;
  var dx = (e.clientX - cdrag.px) / cdrag.f.w;
  var dy = (e.clientY - cdrag.py) / cdrag.f.h;
  if (cdrag.mode === "move"){
    CROP.x = clamp(cdrag.x + dx, 0, 1 - cdrag.w);
    CROP.y = clamp(cdrag.y + dy, 0, 1 - cdrag.h);
    renderCrop();
    return;
  }
  /* A corner drag is the same control as the slider, reached by hand: the
     opposite corner is pinned and the shape is locked, so the width the
     pointer asks for becomes a budget. Both pinned edges cap how far it can
     grow before the box would leave the frame. */
  var east  = cdrag.mode === "ne" || cdrag.mode === "se";
  var south = cdrag.mode === "se" || cdrag.mode === "sw";
  var ax = east  ? cdrag.x : cdrag.x + cdrag.w;   /* pinned vertical edge */
  var ay = south ? cdrag.y : cdrag.y + cdrag.h;   /* pinned horizontal edge */
  var maxW = Math.min(east ? (1 - ax) : ax,
                      (south ? (1 - ay) : ay) * cropAR() / frameAR());
  var want = Math.min(east ? (cdrag.w + dx) : (cdrag.w - dx), maxW);
  CROP.px = clamp(Math.round(pxForWidth(want * frameDims().w)), PX_MIN, pxCeiling());
  cropSync();
  CROP.x = east  ? ax : ax - CROP.w;
  CROP.y = south ? ay : ay - CROP.h;
  cropSync();
  renderAdv();
  renderCrop();
});
function endCropDrag(){ cdrag = null; }
$("cropBox").addEventListener("pointerup", endCropDrag);
$("cropBox").addEventListener("pointercancel", endCropDrag);

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
  /* tokens carries the track order - the server takes the output format from
     the first of them, and the parts are already in the order they play. crop
     is left off the wire entirely unless the Advanced panel is on, so a save
     that does not use it posts exactly what it always did. */
  var body = { tokens: TR.map(function(t){ return t.token; }), parts: parts };
  var cp = cropPayload();
  if (cp) body.crop = cp;
  if (SND) body.audio = SND.token;     /* replaces every part's own sound */
  dialogFetch("/api/save", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  }, "save", finishSave)
  .then(function(j){
    if (j.cancelled || j.busy){ finishSave(); if (j.busy) toast(BUSY_MSG, "warn"); return; }
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
$("bSessSave").onclick = saveSession;
$("bSessOpen").onclick = openSession;
$("bSnd").onclick = importSoundtrack;
$("bSndOff").onclick = clearSoundtrack;
snd.addEventListener("error", function(){
  if (SND && snd.getAttribute("src"))
    toast("This browser cannot play " + SND.name + " for the preview - the saved video will still use it.", "warn");
});

$("bQuit").onclick = function(){
  if (!confirm("Shut down Simple Video Trimmer?")) return;
  /* the last few seconds of edits may not have autosaved yet */
  var quit = function(){ fetch(api("/api/quit"), { method: "POST" }).then(null, function(){}); };
  if (TR.length) autosaveNow().then(quit, quit); else quit();
  setTimeout(function(){
    document.body.innerHTML =
      '<div style="margin:auto;text-align:center;color:#8b98a5;font:15px Segoe UI,sans-serif">' +
      'Simple Video Trimmer has shut down.<br><br>You can close this tab.</div>';
  }, 200);
};

window.addEventListener("resize", render);
buildAdv();
renderAdv();
render();

/* offer back whatever was open when the app last closed */
fetch(api("/api/autosave/peek"))
  .then(function(r){ return r.json(); })
  .then(function(j){
    if (!j || !j.ok || !(j.count > 0) || TR.length) return;
    restoreToast = toast("Last time you had " + j.count + (j.count === 1 ? " track" : " tracks") +
                         " open - pick up where you left off?", "", "Restore", restoreAutosave, true);
  }, function(){ });
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

# ------------------------------------------------------------------- crop --
# The Advanced panel cuts a fixed-size piece out of the picture at 1:1 - it
# never rescales, so there is no scale filter here and the output size IS the
# crop size. The offset arrives normalised so it means the same thing on both
# export paths; the size arrives as whole pixels, because the client has
# already shown the user those exact numbers and a fraction would not survive
# the round trip back to them.

function Read-Crop($c) {
    if (-not $c) { return $null }
    $vals = @{}
    foreach ($f in @('x', 'y', 'ow', 'oh')) {
        $d = 0.0
        # a client that omits a field, or sends "left", NaN or infinity, gets no
        # crop rather than a filter string ffmpeg would refuse
        if (-not [double]::TryParse([string]$c.$f, [Globalization.NumberStyles]::Float,
                                    $inv, [ref]$d)) { return $null }
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
        $vals[$f] = $d
    }
    $x = [math]::Max(0.0, [math]::Min($vals['x'], 1.0))
    $y = [math]::Max(0.0, [math]::Min($vals['y'], 1.0))

    # x264 at yuv420p needs both sides even; the ceiling keeps a hostile or
    # garbled request from asking for a frame that would never finish
    $ow = [int][math]::Floor([math]::Round($vals['ow']) / 2) * 2
    $oh = [int][math]::Floor([math]::Round($vals['oh']) / 2) * 2
    if ($ow -lt 16 -or $oh -lt 16 -or $ow -gt 8192 -or $oh -gt 8192) { return $null }

    @{ x = $x; y = $y; ow = $ow; oh = $oh }
}

# $fw x $fh is the frame the rectangle is resolved against: the source itself
# while one file is involved, track 1's canvas once several are stitched into
# it. The window is only ever shrunk to fit, never grown, and the offset is
# nudged back inside the frame - so crop can never be handed a window that runs
# off the picture, whatever the client believed the frame size to be.
function Get-CropFilter($c, [int]$fw, [int]$fh) {
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

    # an odd offset falls between chroma samples on yuv420p
    $cx = [int][math]::Floor($c.x * $fw / 2) * 2
    $cy = [int][math]::Floor($c.y * $fh / 2) * 2
    if ($cx + $cw -gt $mw) { $cx = $mw - $cw }
    if ($cy + $ch -gt $mh) { $cy = $mh - $ch }
    if ($cx -lt 0) { $cx = 0 }; if ($cy -lt 0) { $cy = 0 }

    "crop=${cw}:${ch}:${cx}:${cy}"
}

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
        '\.mp3$'       { 'audio/mpeg' ; break }
        '\.m4a$'       { 'audio/mp4' ; break }
        '\.aac$'       { 'audio/aac' ; break }
        '\.wav$'       { 'audio/wav' ; break }
        '\.flac$'      { 'audio/flac' ; break }
        '\.(ogg|opus)$' { 'audio/ogg' ; break }
        default        { 'application/octet-stream' }
    }
}

# Run a WinForms dialog on top of everything else.
# Only one at a time: a second request would stack another dialog somewhere
# the user cannot see it. It gets 'Busy' back, and the dialog that IS open is
# pulled to the front so the user can find it.
function Show-Dialog($dlg) {
    if (-not [System.Threading.Monitor]::TryEnter($S.DialogLock)) {
        $h = $S.DialogHwnd
        if ($h -and $h -ne [IntPtr]::Zero) { try { [void][Svt.User32]::SetForegroundWindow($h) } catch { } }
        return 'Busy'
    }
    $owner = New-Object System.Windows.Forms.Form
    $owner.Opacity = 0; $owner.ShowInTaskbar = $false; $owner.TopMost = $true
    $owner.FormBorderStyle = 'None'; $owner.Size = New-Object System.Drawing.Size -ArgumentList 1, 1
    $owner.StartPosition = 'CenterScreen'
    try {
        $owner.Show(); $owner.Activate()
        $S.DialogHwnd = $owner.Handle
        try { [void][Svt.User32]::SetForegroundWindow($owner.Handle) } catch { }
        return $dlg.ShowDialog($owner)
    } finally {
        $S.DialogHwnd = [IntPtr]::Zero
        $owner.Close(); $owner.Dispose()
        [System.Threading.Monitor]::Exit($S.DialogLock)
    }
}

# A session file, opened: every track whose file is still there is loaded
# under a fresh token. files[] lines up with the session's tracks, null where
# a file has gone; the raw text goes back untouched and the page reads the
# edits out of it itself.
function Read-Session([string]$text) {
    $p = $text | ConvertFrom-Json
    if (-not $p -or -not $p.PSObject.Properties['tracks']) { throw 'that file is not a Simple Video Trimmer session' }
    $files = New-Object System.Collections.ArrayList
    $seen  = @{}
    foreach ($t in @($p.tracks)) {
        $entry = $null
        $path  = [string]$t.path
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            try {
                # a clone is the same file twice - probe it once
                if (-not $seen.ContainsKey($path)) { $seen[$path] = Get-MediaInfo $path }
                $info = $seen[$path]
                if ($info.duration -gt 0) {
                    $token = [Guid]::NewGuid().ToString('N')
                    $S.Files[$token] = $info
                    $entry = $info | Select-Object *
                    $entry | Add-Member -NotePropertyName token -NotePropertyValue $token -Force
                    $S.LastDir = [IO.Path]::GetDirectoryName($info.path)
                }
            } catch { $entry = $null }
        }
        [void]$files.Add($entry)
    }
    $audio = $null
    if ($p.PSObject.Properties['audio'] -and $p.audio -and $p.audio.path -and
        (Test-Path -LiteralPath ([string]$p.audio.path) -PathType Leaf)) {
        try { $audio = Register-Audio ([string]$p.audio.path) } catch { $audio = $null }
    }
    @{ ok = $true; raw = $text; files = $files.ToArray(); audio = $audio }
}

function Read-Body { (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() }
function Test-SessionBody([string]$body) {
    try { $p = $body | ConvertFrom-Json; return [bool]($p -and @($p.tracks).Count -gt 0) } catch { return $false }
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

# An imported soundtrack: its first audio stream and how long it runs.
function Get-AudioInfo([string]$path) {
    $raw = & $S.FFprobe -v error -print_format json -show_format -show_streams $path 2>$null
    if (-not $raw) { throw 'ffprobe returned nothing for that file.' }
    $j = ($raw -join "`n") | ConvertFrom-Json
    $as = $j.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
    if (-not $as) { throw 'that file does not contain any audio.' }
    $dur = 0.0
    foreach ($cand in @($j.format.duration, $as.duration)) {
        if ($cand -and [double]::TryParse([string]$cand, [Globalization.NumberStyles]::Float, $inv, [ref]$dur) -and $dur -gt 0) { break }
    }
    if ($dur -le 0) { throw 'that audio file has no readable length.' }
    $fi = Get-Item -LiteralPath $path
    [pscustomobject]@{
        ok       = $true
        path     = $fi.FullName
        name     = $fi.Name
        duration = [math]::Round($dur, 3)
        codec    = [string]$as.codec_name
        sizeText = Human $fi.Length
    }
}
# kept in $S.Audio, apart from the video tracks, so no audio file can ever be
# mistaken for a track or a track for a soundtrack
function Register-Audio([string]$path) {
    $info  = Get-AudioInfo $path
    $token = [Guid]::NewGuid().ToString('N')
    $S.Audio[$token] = $info
    $o = $info | Select-Object *
    $o | Add-Member -NotePropertyName token -NotePropertyValue $token -Force
    $o
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
            if ($r -eq 'Busy') { Send-Json @{ busy = $true }; break }
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

        '^/api/clone$' {
            $info = $S.Files[[string]$q['t']]
            if (-not $info) { Send-Json @{ ok = $false; error = 'That track is no longer loaded.' }; break }
            # the same file under a second token, so the clone is a track of its own
            $token = [Guid]::NewGuid().ToString('N')
            $S.Files[$token] = $info
            Send-Json @{ ok = $true; token = $token }
            break
        }

        '^/api/session/save$' {
            $body = Read-Body
            if (-not (Test-SessionBody $body)) { Send-Json @{ ok = $false; error = 'There is nothing to save yet.' }; break }
            $first = @(($body | ConvertFrom-Json).tracks)[0]
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Title           = 'Save session as'
            $dlg.Filter          = 'Simple Video Trimmer session (*.svtsession)|*.svtsession'
            $dlg.DefaultExt      = 'svtsession'
            $dlg.AddExtension    = $true
            $dlg.OverwritePrompt = $true
            $dlg.FileName        = [IO.Path]::GetFileNameWithoutExtension([string]$first.name) + '.svtsession'
            if ($S.LastDir -and (Test-Path -LiteralPath $S.LastDir)) { $dlg.InitialDirectory = $S.LastDir }
            $r = Show-Dialog $dlg
            if ($r -eq 'Busy') { Send-Json @{ busy = $true }; break }
            if ($r -ne [System.Windows.Forms.DialogResult]::OK) { Send-Json @{ cancelled = $true }; break }
            try {
                [IO.File]::WriteAllText($dlg.FileName, $body, (New-Object Text.UTF8Encoding $false))
                Send-Json @{ ok = $true; name = [IO.Path]::GetFileName($dlg.FileName) }
            } catch {
                Send-Json @{ ok = $false; error = "Could not write the session: $($_.Exception.Message)" }
            }
            break
        }

        '^/api/session/open$' {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title  = 'Open a session'
            $dlg.Filter = 'Simple Video Trimmer session (*.svtsession)|*.svtsession|All files (*.*)|*.*'
            $dlg.CheckFileExists = $true
            if ($S.LastDir -and (Test-Path -LiteralPath $S.LastDir)) { $dlg.InitialDirectory = $S.LastDir }
            $r = Show-Dialog $dlg
            if ($r -eq 'Busy') { Send-Json @{ busy = $true }; break }
            if ($r -ne [System.Windows.Forms.DialogResult]::OK) { Send-Json @{ cancelled = $true }; break }
            try   { Send-Json (Read-Session ([IO.File]::ReadAllText($dlg.FileName))) }
            catch { Send-Json @{ ok = $false; error = "Could not open that session: $($_.Exception.Message)" } }
            break
        }

        '^/api/autosave$' {
            $body = Read-Body
            $ok = Test-SessionBody $body
            if ($ok) {
                $f = Join-Path $S.CacheDir 'autosave.svtsession'
                try {
                    [IO.File]::WriteAllText("$f.tmp", $body, (New-Object Text.UTF8Encoding $false))
                    Move-Item -LiteralPath "$f.tmp" -Destination $f -Force
                } catch { $ok = $false }
            }
            Send-Json @{ ok = $ok }
            break
        }

        '^/api/autosave/peek$' {
            $f = Join-Path $S.CacheDir 'autosave-last.svtsession'
            $n = 0
            if (Test-Path -LiteralPath $f) {
                try { $n = @(([IO.File]::ReadAllText($f) | ConvertFrom-Json).tracks).Count } catch { $n = 0 }
            }
            Send-Json @{ ok = ($n -gt 0); count = $n }
            break
        }

        '^/api/autosave/load$' {
            $f = Join-Path $S.CacheDir 'autosave-last.svtsession'
            if (-not (Test-Path -LiteralPath $f)) { Send-Json @{ ok = $false; error = 'There is no earlier session to restore.' }; break }
            try   { Send-Json (Read-Session ([IO.File]::ReadAllText($f))) }
            catch { Send-Json @{ ok = $false; error = "The last session could not be restored: $($_.Exception.Message)" } }
            break
        }

        '^/api/audio/open$' {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title  = 'Choose a soundtrack'
            $dlg.Filter = 'Audio files (*.mp3;*.m4a;*.aac;*.wav;*.flac;*.ogg;*.opus)|*.mp3;*.m4a;*.aac;*.wav;*.flac;*.ogg;*.opus|All files (*.*)|*.*'
            $dlg.CheckFileExists = $true
            if ($S.LastDir -and (Test-Path -LiteralPath $S.LastDir)) { $dlg.InitialDirectory = $S.LastDir }
            $r = Show-Dialog $dlg
            if ($r -eq 'Busy') { Send-Json @{ busy = $true }; break }
            if ($r -ne [System.Windows.Forms.DialogResult]::OK) { Send-Json @{ cancelled = $true }; break }
            try   { Send-Json (Register-Audio $dlg.FileName) }
            catch { Send-Json @{ ok = $false; error = "Could not use that audio file: $($_.Exception.Message)" } }
            break
        }

        '^/api/audiofile$' {
            $info = $S.Audio[[string]$q['t']]
            if (-not $info) { Send-Text 'Unknown token' 'text/plain' 404; break }
            Send-FileRange $info.path
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
            if ([string]$q['rev'] -eq '1') {
                # A backwards pass for ping-pong - browsers cannot play in reverse.
                # The reverse filter holds the whole part in memory before it emits a
                # frame, so the picture comes down to 540 lines. Preview only: the
                # export reverses the original at full size.
                $end = $at
                [void][double]::TryParse([string]$q['end'], [Globalization.NumberStyles]::Float, $inv, [ref]$end)
                $end = [math]::Max($at, [math]::Min([double]$info.duration, $end))
                $len = [math]::Max(0.05, $end - $at)
                # The end is cut with trim, on presentation time - exactly as the export
                # cuts it. An input -t stops by packet DECODE order instead, which with
                # B-frames lets a frame or two from past the end slip in, and reversed
                # those are the very first frames shown. -t now only bounds the read.
                $lenS = Num $len '0.######'
                $ffArgs = @('-hide_banner', '-v', 'error', '-ss', (Num $at '0.######'),
                            '-t', (Num ($len + 1.0) '0.######'), '-i', $info.path,
                            '-vf', "trim=end=${lenS},setpts=PTS-STARTPTS,scale=-2:'trunc(min(540,ih)/2)*2',reverse",
                            '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p') +
                          $(if ($info.hasAudio) { @('-af', "atrim=end=${lenS},asetpts=PTS-STARTPTS,areverse", '-c:a', 'aac', '-b:a', '128k') }
                            else { @('-an') }) +
                          @('-movflags', 'frag_keyframe+empty_moov+default_base_moof', '-f', 'mp4', 'pipe:1')
            } else {
                $ffArgs = @('-hide_banner', '-v', 'error', '-ss', (Num $at '0.######'), '-i', $info.path) +
                          $vArgs + $aArgs +
                          @('-movflags', 'frag_keyframe+empty_moov+default_base_moof', '-f', 'mp4', 'pipe:1')
            }

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
                    # r marks a ping-pong pass that plays this part backwards
                    $rv = ([string]$sg.r) -in @('1', 'True', 'true')
                    # m marks a part whose track is muted - it goes out silent
                    $mu = ([string]$sg.m) -in @('1', 'True', 'true')
                    [void]$segs.Add(@{ tok = [string]$sg.t; info = $ti; s = $s0; e = $e0; r = $rv; m = $mu })
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
            if ($span -lt 0.05) { Send-Json @{ ok = $false; error = 'The selected clip is too short.' }; break }

            # An unreadable or absurd crop is dropped rather than refused: the
            # trim itself is still exactly what the user asked for, and failing
            # the whole export over the Advanced panel would be a poor trade.
            $crop = $(if ($p.PSObject.Properties['crop']) { Read-Crop $p.crop } else { $null })
            # a soundtrack replaces every part's own sound; an unknown token is just no soundtrack
            $snd = $(if ($p.PSObject.Properties['audio'] -and $p.audio) { $S.Audio[[string]$p.audio] } else { $null })

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
            $word = $(if ($crop) { 'crop' }
                      elseif ($multi) { 'stitched' }
                      elseif ($segs.Count -gt 1) { 'edit' } else { 'trim' })
            $dim  = $(if ($crop) { '_{0}x{1}' -f $crop.ow, $crop.oh } else { '' })
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Title            = $(if ($crop) { 'Save cropped video as' }
                                      elseif ($multi) { 'Save stitched video as' }
                                      elseif ($segs.Count -gt 1) { 'Save edited video as' }
                                      else { 'Save trimmed video as' })
            $dlg.Filter           = 'MP4 video (*.mp4)|*.mp4'
            $dlg.DefaultExt       = 'mp4'
            $dlg.AddExtension     = $true
            $dlg.OverwritePrompt  = $true
            $dlg.FileName         = "${base}_${word}_${tag}${dim}.mp4"
            $dlg.InitialDirectory = [IO.Path]::GetDirectoryName($info.path)
            $r = Show-Dialog $dlg
            if ($r -eq 'Busy') { Send-Json @{ busy = $true }; break }
            if ($r -ne [System.Windows.Forms.DialogResult]::OK) { Send-Json @{ cancelled = $true }; break }

            $outPath = $dlg.FileName
            # ffmpeg would read and rewrite the same file at once - check every
            # source, not just track 1's
            $clash = $false
            foreach ($tk in $used) { if ([IO.Path]::GetFullPath($outPath) -eq $S.Files[$tk].path) { $clash = $true } }
            if ($snd -and [IO.Path]::GetFullPath($outPath) -eq $snd.path) { $clash = $true }
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

            if ($segs.Count -eq 1 -and -not $segs[0].r) {
                # One range from one file: seek to it and copy forward. Unchanged
                # from before splitting existed, and far cheaper on a long file
                # than decoding from frame zero the way the filter paths have to.
                # A crop lands on even numbers by construction, so it stands in
                # for the even-up on the frames it covers.
                $vf = ''
                if ($crop) {
                    $vf = Get-CropFilter $crop ([int]$segs[0].info.width) ([int]$segs[0].info.height)
                } elseif ($oddSrc) {
                    $vf = $evenFix
                }
                # A soundtrack is looped from its own start and cut off by -t with the
                # picture, and it is the only sound mapped - the clip's is dropped.
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
                } elseif ($oddSrc -and -not $crop) {
                    # with a crop the trailing scale evens the picture up anyway
                    $vfit = ",$evenFix"
                }
                $afit = $(if ($multi) { ',aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo' } else { '' })

                # Audio only survives the concat if EVERY part offers a pin, so a
                # clip with no sound needs silence generated to stand in for it.
                # Each silent part gets its own lavfi input - a filter input pad
                # cannot be consumed twice.
                $anyAudio = $false
                foreach ($sg in $segs) { if ($sg.info.hasAudio -and -not $sg.m) { $anyAudio = $true } }
                # the soundtrack stands in for every part's sound, so the graph is picture only
                if ($snd) { $anyAudio = $false }

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
                # One crop on the finished picture, not one per part: the parts
                # have already been fitted to a common frame by here, so N copies
                # of the same filter would only cost N times as much to build.
                $vend = $(if ($crop) { '[vcat]' } else { '[vout]' })
                if ($anyAudio) {
                    [void]$sb.Append($chain + "concat=n=$($segs.Count):v=1:a=1${vend}[aout]")
                } else {
                    [void]$sb.Append($chain + "concat=n=$($segs.Count):v=1:a=0${vend}")
                }
                if ($crop) {
                    # a single file keeps its own frame; several have been scaled
                    # and padded into track 1's, so that is what gets cropped
                    $cfw = $(if ($multi) { $tw } else { [int]$S.Files[$used[0]].width })
                    $cfh = $(if ($multi) { $th } else { [int]$S.Files[$used[0]].height })
                    [void]$sb.Append(";`n[vcat]" + (Get-CropFilter $crop $cfw $cfh) + "[vout]")
                }
                [IO.File]::WriteAllText($filt, $sb.ToString(), (New-Object Text.UTF8Encoding $false))

                if ($snd) {
                    # after every file input (no silent lavfi inputs exist without audio in the graph)
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
    # The page is served from 127.0.0.1 and its video from localhost - the same
    # server, but two hosts as far as the browser's six-connections-per-host
    # limit goes, so open video streams can never queue the API behind them.
    # If localhost cannot be registered, everything shares 127.0.0.1 as before.
    foreach ($both in @($true, $false)) {
        try {
            $l = New-Object System.Net.HttpListener
            $l.Prefixes.Add("http://127.0.0.1:$p/")
            if ($both) { $l.Prefixes.Add("http://localhost:$p/") }
            $l.Start()
            $listener = $l
            $port = $p
            $S.MediaBase = $(if ($both) { "http://localhost:$p" } else { '' })
            break
        } catch {
            try { $l.Close() } catch { }
        }
    }
    if ($port) { break }
}
if ($port -eq 0) { throw 'Could not open a local port between 8731 and 8780.' }
$S.Listener = $listener
$S.Html = $S.Html.Replace('__MEDIA__', $S.MediaBase)

# lets a second dialog request pull the open one to the front
try {
    Add-Type -Namespace Svt -Name User32 -ErrorAction Stop -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
} catch { }

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
