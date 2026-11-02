# SPDX-License-Identifier: GPL-3.0-or-later
# Optional: installs faster-whisper for timing subtitles on files that have no
# subtitle track to time against. Goes into %LOCALAPPDATA%\immersion-mpv\whisper.
#
#   powershell -ExecutionPolicy Bypass -File install-whisper.ps1
#
# Needs uv (https://docs.astral.sh/uv/). An NVIDIA GPU makes it fast; without
# one it runs on the CPU, several times slower.
param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA "immersion-mpv\whisper")
)
$ErrorActionPreference = "Stop"

$uv = Get-Command uv -ErrorAction SilentlyContinue
$uvPath = if ($uv) { $uv.Source } else { Join-Path $env:USERPROFILE ".anki_miner\bin\uv.exe" }
if (-not (Test-Path $uvPath)) { throw "uv was not found. Install it: https://docs.astral.sh/uv/getting-started/installation/" }

Write-Host "Creating $Target"
& $uvPath venv --python 3.12 $Target
if ($LASTEXITCODE -ne 0) { throw "uv venv failed." }
& $uvPath pip install --python (Join-Path $Target "Scripts\python.exe") "faster-whisper==1.2.1"
if ($LASTEXITCODE -ne 0) { throw "Installing faster-whisper failed." }

Write-Host ""
Write-Host "faster-whisper is installed. The plugin finds it by itself; the model is"
Write-Host "downloaded on first use unless whisper_model in immersion-mpv.conf names one."
