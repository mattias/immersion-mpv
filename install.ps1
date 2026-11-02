# SPDX-License-Identifier: GPL-3.0-or-later
# Installs immersion-mpv into mpv's config folder (default: %APPDATA%\mpv).
#
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -MpvDir D:\mpv\portable_config
param(
    [string]$MpvDir = (Join-Path $env:APPDATA "mpv")
)
$ErrorActionPreference = "Stop"

$source = Join-Path $PSScriptRoot "scripts\immersion-mpv"
$scripts = Join-Path $MpvDir "scripts"
$target = Join-Path $scripts "immersion-mpv"
$opts = Join-Path $MpvDir "script-opts"
New-Item -ItemType Directory -Force $scripts, $opts | Out-Null

$sameFolder = (Test-Path $target) -and ((Resolve-Path $target).Path -eq (Resolve-Path $source).Path -or
    (Get-Item $target).LinkType -eq "Junction")
if (-not $sameFolder) {
    Write-Host "Copying the plugin to $target"
    New-Item -ItemType Directory -Force $target | Out-Null
    robocopy $source $target /E /XD node_modules /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying failed (robocopy $LASTEXITCODE)." }
}

$conf = Join-Path $opts "immersion-mpv.conf"
if (-not (Test-Path $conf)) {
    Copy-Item (Join-Path $PSScriptRoot "script-opts\immersion-mpv.conf") $conf
    Write-Host "Wrote $conf"
} else {
    Write-Host "Kept your $conf"
}

# The Settings window runs on Electron. hachidori-mpv's is used when it is there.
$shared = Join-Path $scripts "hachidori-mpv\overlay\node_modules\electron\dist\electron.exe"
if (Test-Path $shared) {
    Write-Host "Using hachidori-mpv's Electron for the Settings window."
} else {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { throw "Node.js 18 or newer is needed to install the Settings window (https://nodejs.org). mpv does not need it afterwards." }
    $major = [int]((& node --version).TrimStart("v").Split(".")[0])
    if ($major -lt 18) { throw "Node.js 18 or newer is needed; this is $(& node --version)." }
    Push-Location (Join-Path $target "settings")
    try {
        Write-Host "Installing the Settings window's packages..."
        & npm install --omit=dev --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
        & node fetch-electron.mjs
        if ($LASTEXITCODE -ne 0) { throw "Downloading Electron failed." }
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "immersion-mpv is installed. Statistics start with the next video."
Write-Host "Press Alt+i in mpv to enter your AniList token and Jimaku key."
