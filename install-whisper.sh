#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Optional: installs faster-whisper for timing subtitles on files that have no
# subtitle track to time against. Goes into ~/.local/share/immersion-mpv/whisper.
#
#   ./install-whisper.sh [--target DIR]
#
# Needs uv (https://docs.astral.sh/uv/). An NVIDIA GPU with CUDA 12 and cuDNN 9
# makes it fast; without one it runs on the CPU, several times slower.
set -euo pipefail

target="$HOME/.local/share/immersion-mpv/whisper"
if [ "${1:-}" = "--target" ] && [ -n "${2:-}" ]; then target="$2"; fi

if ! command -v uv >/dev/null 2>&1; then
    echo "uv was not found. Install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
    exit 1
fi

echo "Creating $target"
uv venv --python 3.12 "$target"
uv pip install --python "$target/bin/python" "faster-whisper==1.2.1"

echo
echo "faster-whisper is installed. The plugin finds it by itself; the model is"
echo "downloaded on first use unless whisper_model in immersion-mpv.conf names one."
if [ "$target" != "$HOME/.local/share/immersion-mpv/whisper" ]; then
    echo "Set whisper_python=$target/bin/python in immersion-mpv.conf."
fi
