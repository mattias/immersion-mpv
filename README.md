# immersion-mpv

An mpv plugin for watching Japanese: it records what you really listened to,
fetches a Japanese subtitle from [Jimaku](https://jimaku.cc) when a file has
none, and marks watched episodes on [AniList](https://anilist.co). It runs on
its own or beside [hachidori-mpv](../hachidori-mpv), and each part can be
turned off.

- **Statistics**: per file and day, the time really played, unique subtitle
  lines and their characters. Written as JSON lines for your own scripts.
- **Jimaku**: finds the right episode by AniList ID and episode number, saves
  it locally and adds it with `sub-add`.
- **AniList**: recognises the series and episode from the file name and
  folder, and sets your progress once 85 % has really played.

## Requirements

- **mpv** 0.39 or newer (0.35 works, but cannot ask which series a file is)
- **curl**, which Windows 10 and 11 include
- For the Settings window: hachidori-mpv's Electron, or **Node.js 18+** to
  install one (not to run)

## Install

**Windows** (installs into `%APPDATA%\mpv`):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

**Linux** (installs into `~/.config/mpv`):

```bash
./install.sh
```

Use `-MpvDir` / `--mpv-dir` for another mpv config folder (for example a
`portable_config`). An existing conf is kept. Run it again to update.

## Keys

**Alt+i** opens the Settings window. Paste a key, press Save, then Test. Keys
are shown masked from then on, are kept in `secrets.json` in the data folder
(below), never in mpv's conf or this repository, and are never written to a
log. Requests read them from a short-lived file, not from a command line.

- **Jimaku**: generate an API key on your [account page](https://jimaku.cc/account).
- **AniList** ([its docs](https://docs.anilist.co/guide/auth/)): the Settings
  window walks you through it.
  1. On [Settings → Apps → Developer](https://anilist.co/settings/developer),
     press *Create New Application*: any name, Redirect URL
     `https://anilist.co/api/v2/oauth/pin`.
  2. Put the client's ID (the number, not the secret) in the Settings window and
     press *Open AniList*. It opens
     `https://anilist.co/api/v2/oauth/authorize?client_id=ID&response_type=token`.
  3. Approve. AniList shows the token; paste it, Save, Test. It lasts a year.

**AniList starts in test mode**: the plugin says what it would send, and sends
nothing. Turn *Test mode* off in the Settings window when you trust it.

## Use

Statistics start by themselves. The other parts need their key.

| Key | Binding | |
| --- | --- | --- |
| `Alt+i` | `immersion_mpv/settings` | The Settings window |
| `Alt+I` | `immersion_mpv/status` | This file's series, episode and how much has played |
| `Alt+a` | `immersion_mpv/rematch` | Choose this file's series again |

Rebind them in `input.conf`, e.g. `Ctrl+i script-binding immersion_mpv/settings`.

### Which series is it?

A series is only taken without asking when exactly one AniList title or
synonym equals the file's title, its season fits and the episode exists. Two
versions of a title, a similar title, or an episode past the end of the series
are never guessed: the plugin asks once, in mpv, and remembers the choice for
that folder and series name. You can search another title, enter an AniList
ID, or say the folder is not on AniList. Closing the question with Esc stores
nothing and asks again the next time mpv starts.

Extras (NCOP, NCED, previews, OVAs, `Extras` folders), part episodes like 13.5,
batches and files that show no clear episode number leave AniList and Jimaku
alone. Network streams only count statistics.

Absolute numbering is not converted: episode 28 of a second season numbered
from 1 is refused, not moved onto the right season.

### AniList progress

The plugin counts the parts of the file that played by themselves, over all
sessions, so skipping to the end marks nothing and finishing tomorrow does.
At the threshold it reads your list and:

- moves progress forward only; rewatching an earlier episode changes nothing;
- leaves a completed entry alone, and keeps a rewatch a rewatch;
- adds the series as *Watching* if it is not on your list, sets *Completed* on
  the last episode, and moves *Planning*, *Paused* or *Dropped* to *Watching*.

## Statistics

Rows are appended to `stats.jsonl` in the data folder every 30 seconds and when
a file ends:

```json
{"v":1,"date":"2026-11-01","ended":1793569915,"file":"[SubsPlease] Sousou no Frieren - 03 (1080p).mkv","title":"Sousou no Frieren","anilist_id":154587,"episode":3,"seconds":312.4,"lines":58,"chars":701}
```

| Field | |
| --- | --- |
| `v` | Row format |
| `date` | Local date the row belongs to, `YYYY-MM-DD` |
| `ended` | When the row was written, Unix seconds |
| `file` | File name; the key for a file |
| `title` | The series, or mpv's title until it is known |
| `anilist_id`, `episode` | Left out when unknown |
| `seconds` | Time really playing, in clock time; a line heard again is still listening |
| `lines`, `chars` | New lines and their characters, without white space |

**Rows are increments: sum them.** The total per file and day is the sum of
all rows with the same `date` and `file`; weeks, months and years follow from
`date`. Group on `file`, not `title`, which can change within a file's rows.

```python
from collections import defaultdict
from pathlib import Path
import json, os

days = defaultdict(lambda: {"seconds": 0, "lines": 0, "chars": 0})
for row in Path(os.environ["APPDATA"], "immersion-mpv", "stats.jsonl").read_text("utf-8").splitlines():
    row = json.loads(row)
    for key in ("seconds", "lines", "chars"):
        days[row["date"], row["file"]][key] += row[key]
```

What counts:

- Time counts while the player is really running: not paused, not buffering,
  not seeking.
- A line counts once half of it has played, or a full second of a long one.
  A pause, `sub-seek` or a skip over a line does not.
- A line is its start time and text. Within a day it counts once per file,
  however often you replay it, loop it or reopen the file; `sub-delay` does not
  make it new. Another day counts it again.
- Only lines with Japanese count (*Count Japanese lines only*), so English
  subtitles add time but no lines.

## Data folder

`%APPDATA%\immersion-mpv` / `~/.config/immersion-mpv`: `stats.jsonl`,
`choices.json` (remembered series), `coverage.json` (how much of each file has
played), `seen-<date>.tsv` (today's lines), `secrets.json`, `subs/` (Jimaku).

## Beside hachidori-mpv

hachidori-mpv owns how subtitles are shown. This plugin only reads them and
never sets `sub-visibility`; `sub-text` also works while hachidori-mpv hides
mpv's subtitles. It uses its own keys and has no script messages at all: the
Settings window writes files and every open mpv picks them up within seconds.

hachidori-mpv looks for a subtitle when a file loads. When a Jimaku subtitle
arrives later, this plugin starts hachidori-mpv's overlay, only if hachidori-mpv
is set to start by itself and has not started yet in this mpv.

## Development

```bash
node --test scripts/immersion-mpv/settings/test/
mpv --no-config --idle=yes --no-video --script=test/unit.lua --script-opts=immersion-test-dir=$PWD/scripts/immersion-mpv
node test/run.mjs --mpv mpv --ffmpeg ffmpeg          # real mpv, local stand-ins for AniList and Jimaku
node test/run.mjs --both --mpv mpv --ffmpeg ffmpeg   # also beside your hachidori-mpv
node --experimental-websocket test/settings-window.mjs path/to/electron out.png
```

`IMMERSION_MPV_DATA` moves the data folder. The tests use a temporary one and
never reach a real AniList or Jimaku.

## License

GPL-3.0-or-later, like hachidori-mpv, whose Settings window this one builds on.
