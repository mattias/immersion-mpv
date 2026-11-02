#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs immersion-mpv into mpv's config folder (default: ~/.config/mpv).
#
#   ./install.sh
#   ./install.sh --mpv-dir ~/.var/app/io.mpv.Mpv/config/mpv
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mpv_dir="${XDG_CONFIG_HOME:-$HOME/.config}/mpv"
while [ $# -gt 0 ]; do
    case "$1" in
        --mpv-dir) mpv_dir=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

source="$here/scripts/immersion-mpv"
target="$mpv_dir/scripts/immersion-mpv"
mkdir -p "$mpv_dir/scripts" "$mpv_dir/script-opts"

if [ "$(cd "$source" && pwd -P)" != "$( [ -d "$target" ] && cd "$target" && pwd -P)" ]; then
    echo "Copying the plugin to $target"
    mkdir -p "$target"
    (cd "$source" && tar --exclude=./settings/node_modules -cf - .) | (cd "$target" && tar -xf -)
fi

conf="$mpv_dir/script-opts/immersion-mpv.conf"
if [ ! -e "$conf" ]; then
    cp "$here/script-opts/immersion-mpv.conf" "$conf"
    echo "Wrote $conf"
else
    echo "Kept your $conf"
fi

# The Settings window runs on Electron. hachidori-mpv's is used when it is there.
if [ -x "$mpv_dir/scripts/hachidori-mpv/overlay/node_modules/electron/dist/electron" ]; then
    echo "Using hachidori-mpv's Electron for the Settings window."
else
    command -v node >/dev/null 2>&1 || { echo "Node.js 18 or newer is needed to install the Settings window (https://nodejs.org)." >&2; exit 1; }
    major=$(node -p 'process.versions.node.split(".")[0]')
    [ "$major" -ge 18 ] || { echo "Node.js 18 or newer is needed; this is $(node --version)." >&2; exit 1; }
    cd "$target/settings"
    echo "Installing the Settings window's packages…"
    npm install --omit=dev --ignore-scripts --no-audit --no-fund
    node fetch-electron.mjs
fi

echo
echo "immersion-mpv is installed. Statistics start with the next video."
echo "Press Alt+i in mpv to enter your AniList token and Jimaku key."
