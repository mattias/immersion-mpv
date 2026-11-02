-- SPDX-License-Identifier: GPL-3.0-or-later
-- immersion-mpv: listening statistics, Jimaku subtitles and AniList progress.
--
-- This script only reads subtitles (sub-text, sub-start, sub-end). It runs
-- beside hachidori-mpv, which owns how subtitles are shown: nothing here sets
-- subtitle visibility, and every message and binding has its own name.

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"
local options = require "mp.options"

local anilist = require "anilist"
local http = require "http"
local jimaku = require "jimaku"
local parse = require "parse"
local reference = require "reference"
local stats = require "stats"
local store = require "store"
local sync = require "sync"

local opts = {
    -- Count listening time, subtitle lines and characters.
    stats_enabled = true,
    -- Count only lines with Japanese in them. Time always counts.
    stats_japanese_only = true,
    -- Fetch a Japanese subtitle from Jimaku when the file has none.
    jimaku_enabled = true,
    -- Time a Jimaku subtitle to the video: by another subtitle track of the
    -- file, or else by the speech (Whisper, when installed).
    sync_enabled = true,
    sync_whisper = true,
    -- Empty means: install-whisper.ps1's Python; Anki Miner's large-v3, or
    -- large-v3-turbo (downloaded on first use).
    whisper_python = "",
    whisper_model = "",
    -- Empty means: the ffmpeg next to mpv, then ffmpeg on PATH.
    ffmpeg_path = "",
    -- Mark watched episodes on AniList.
    anilist_enabled = true,
    -- How much of an episode must have played, in percent.
    anilist_threshold = 85,
    -- Only say what would be sent to AniList; send nothing.
    anilist_dry_run = true,
    -- Your AniList API client, used only to open the page that shows a token.
    anilist_client_id = "",
    anilist_url = "https://graphql.anilist.co",
    jimaku_url = "https://jimaku.cc",
    -- Empty means: the Electron next to this plugin or hachidori-mpv's.
    electron_path = "",
}
local defaults = {}
for key, value in pairs(opts) do defaults[key] = value end

local script_dir = mp.get_script_directory()
local settings_dir = utils.join_path(script_dir, "settings")
local is_windows = package.config:sub(1, 1) == "\\"

local TICK = 0.1
local FLUSH_EVERY = 30
local MARK_RETRIES = 3

local secrets = {}
local current = nil      -- what is known about the playing file
local skipped_now = {}   -- series already asked about, until mpv quits

local function osd(text, seconds)
    mp.osd_message("immersion: " .. text, seconds or 3)
end

local function today()
    return os.date("%Y-%m-%d")
end

local function round(value)
    return math.floor(value * 10 + 0.5) / 10
end

-- Statistics.

local function flush()
    if not current or not current.tracker then return end
    if #current.tracker.covered > 0 then
        store.save_coverage(current.file_id, current.tracker.covered)
    end
    local row = current.tracker:take()
    if row.seconds < 0.5 and row.lines == 0 then
        current.tracker.seconds = row.seconds
        return
    end
    local identity = current.identity
    store.append(store.path("stats.jsonl"), utils.format_json({
        v = 1,
        date = current.date,
        ended = os.time(),
        file = current.file_id,
        title = identity and identity.title or mp.get_property("media-title", current.file_id),
        anilist_id = identity and identity.id or nil,
        episode = current.info and current.info.episode or nil,
        seconds = round(row.seconds),
        lines = row.lines,
        chars = row.chars,
    }) .. "\n")
end

local function start_stats()
    if not opts.stats_enabled or not current or current.tracker then return end
    local date = today()
    current.date = date
    current.tracker = stats.new(store.load_seen(date, current.file_id), function(key)
        store.add_seen(current.date, current.file_id, key)
    end, opts.stats_japanese_only)
    current.tracker:restore_covered(store.load_coverage(current.file_id))
end

-- AniList progress.

local function mark_watched()
    local identity, info = current.identity, current.info
    current.marking = true
    local this_file = current
    anilist.mark(opts.anilist_url, secrets.anilist_token, identity.id, info.episode, opts.anilist_dry_run,
        function(update, reason, failed)
            this_file.marking = false
            if failed then
                this_file.mark_tries = (this_file.mark_tries or 0) + 1
                msg.warn("AniList: " .. tostring(reason))
                if this_file.mark_tries >= MARK_RETRIES then
                    this_file.marked = true
                    if this_file == current then osd("AniList: " .. tostring(reason), 5) end
                end
                return
            end
            this_file.marked = true
            store.forget_coverage(this_file.file_id)
            if not update then
                msg.info("AniList: nothing to do, " .. tostring(reason))
                return
            end
            local text = identity.title .. " episode " .. update.progress
            if reason == "test mode" then
                msg.info("AniList test mode: would set " .. text .. " (" .. tostring(update.status) .. ")")
                osd("test mode, AniList not changed: " .. text, 5)
            else
                msg.info("AniList: set " .. text)
                osd("AniList: " .. text, 4)
            end
        end)
end

local function check_watched()
    if not current or current.marked or current.marking or not current.tracker then return end
    if not opts.anilist_enabled or not secrets.anilist_token then return end
    if not current.identity or not current.info.episode then return end
    if current.retry_at and mp.get_time() < current.retry_at then return end
    local duration = mp.get_property_number("duration")
    if not duration or duration <= 0 then return end
    if current.tracker:covered_seconds() / duration * 100 < tonumber(opts.anilist_threshold) then return end
    current.retry_at = mp.get_time() + 60
    mark_watched()
end

local function tick()
    if not current or not current.tracker then return end
    local date = today()
    if date ~= current.date then
        flush()
        current.date = date
        current.tracker:new_day()
    end
    current.tracker:tick({
        now = mp.get_time(),
        playing = mp.get_property_bool("core-idle") == false and mp.get_property_bool("seeking") == false,
        position = mp.get_property_number("time-pos"),
        speed = mp.get_property_number("speed"),
        text = mp.get_property("sub-text", ""),
        start = mp.get_property_number("sub-start"),
        stop = mp.get_property_number("sub-end"),
        delay = mp.get_property_number("sub-delay"),
    })
    check_watched()
end

-- Jimaku.

-- hachidori-mpv looks for a subtitle track when the file loads, which was
-- before this one arrived. Only start it if it is set to start by itself and
-- has not tried yet (it makes its IPC socket when it first starts); toggling
-- it any other time would turn it off.
local function wake_hachidori()
    local published = mp.get_property_native("user-data/hachidori-mpv/options")
    if type(published) ~= "string" then return end
    local hachidori = utils.parse_json(published)
    if not hachidori or not hachidori.autostart then return end
    if mp.get_property("input-ipc-server", "") ~= "" then return end
    mp.commandv("script-binding", "hachidori_mpv/toggle")
end

local function add_subtitle(path, title)
    mp.commandv("sub-add", path, "select", title, "ja")
    wake_hachidori()
end

-- mpv may write a path with other slashes than it was given.
local function same_path(a, b)
    local function plain(path)
        path = path:gsub("\\", "/")
        return is_windows and path:lower() or path
    end
    return a ~= nil and b ~= nil and plain(a) == plain(b)
end

local function track_of(path)
    for _, track in ipairs(mp.get_property_native("track-list", {})) do
        if track.type == "sub" and same_path(track["external-filename"], path) then return track end
    end
    return nil
end

-- The timed subtitle takes the untimed one's place, and its selection.
local function replace_subtitle(old_path, new_path)
    local old = track_of(old_path)
    if old then mp.commandv("sub-remove", tostring(old.id)) end
    mp.commandv("sub-add", new_path, (not old or old.selected) and "select" or "auto", "Jimaku (timed)", "ja")
end

-- Whisper's starts are rougher than a subtitle's, so they may be further off.
local TOLERANCE = {track = 0.4, whisper = 0.6}
-- Less than this is not worth a change.
local DEADBAND = 0.15

local function time_subtitle(this_file, raw, reference_track, place)
    local text = store.read(raw)
    if not text then return end
    local function settle(reference_text, kind, reason)
        if not reference_text then
            msg.info("not timed: " .. tostring(reason))
            jimaku.mark_refused(place, reason)
            if this_file == current then osd("Jimaku subtitle kept as it is: " .. tostring(reason), 5) end
            return
        end
        local result, why = sync.align(sync.starts(text), sync.starts(reference_text), {tolerance = TOLERANCE[kind]})
        if not result then
            settle(nil, kind, why)
            return
        end
        local first = result.segments[1].offset
        local unchanged = #result.segments == 1 and math.abs(first) < DEADBAND
        local timed = jimaku.timed_path(place, raw)
        store.write(timed, unchanged and text or sync.retime(text, result.segments))
        local summary = (unchanged and "already in time" or sync.describe(result))
            .. (kind == "whisper" and " (by the speech)" or " (by the video's subtitles)")
        msg.info("timed: " .. summary)
        if this_file ~= current then return end
        replace_subtitle(raw, timed)
        osd("Jimaku subtitle timed: " .. summary, 5)
    end
    local function by_speech(reason)
        if not opts.sync_whisper then
            settle(nil, "whisper", reason or "the video has no subtitle to time against")
            return
        end
        if this_file == current then osd("timing the Jimaku subtitle by the speech (about a minute)", 3) end
        reference.whisper(opts, this_file.media, script_dir, function(reference_text, err)
            settle(reference_text, "whisper", err)
        end)
    end
    if reference_track then
        reference.extract(opts, this_file.media, reference_track, function(reference_text, err)
            if reference_text then settle(reference_text, "track") else by_speech(err) end
        end)
    else
        by_speech()
    end
end

local function fetch_subtitle()
    if not current or current.subtitle_started or not current.identity then return end
    if not opts.jimaku_enabled then return end
    local identity, info = current.identity, current.info
    local movie = identity.format == "MOVIE"
    if not movie and not info.episode then return end
    local episode = (not movie) and info.episode or nil
    current.subtitle_started = true
    local this_file = current
    local tracks = mp.get_property_native("track-list", {})
    reference.survey(opts, current.media, tracks, jimaku.is_japanese_track, function(japanese, reference_track)
        if this_file ~= current or japanese then return end
        local place = jimaku.place(identity.id, episode, this_file.file_id)
        local timed = jimaku.timed(place)
        if timed then
            add_subtitle(timed, "Jimaku (timed)")
            return
        end
        local function have(raw)
            add_subtitle(raw, "Jimaku")
            if opts.sync_enabled and not jimaku.refused(place) and this_file.is_local then
                time_subtitle(this_file, raw, reference_track, place)
            end
        end
        local cached = jimaku.cached(identity.id, episode)
        if cached then
            have(cached)
            return
        end
        if not secrets.jimaku_key then return end
        jimaku.fetch(opts.jimaku_url, secrets.jimaku_key, identity.id, episode, info.group, function(path, reason)
            if this_file ~= current then return end
            if path then
                osd("Japanese subtitle from Jimaku", 3)
                have(path)
            else
                msg.info("Jimaku: " .. tostring(reason))
                osd(reason, 4)
            end
        end)
    end)
end

-- Which series is this?

local function title_of(media)
    local title = media.title or {}
    if type(title.romaji) == "string" then return title.romaji end
    if type(title.english) == "string" then return title.english end
    return "AniList " .. tostring(media.id)
end

local function describe(media)
    local details = {}
    if type(media.seasonYear) == "number" then table.insert(details, tostring(media.seasonYear)) end
    if type(media.format) == "string" then table.insert(details, media.format) end
    if type(media.episodes) == "number" then table.insert(details, media.episodes .. " ep") end
    return title_of(media) .. " (" .. table.concat(details, ", ") .. ")"
end

local function use_identity(this_file, media, source)
    local identity = {id = media.id, title = title_of(media),
        episodes = type(media.episodes) == "number" and media.episodes or nil,
        format = type(media.format) == "string" and media.format or nil, source = source}
    if identity.format == "MOVIE" and not this_file.info.episode then this_file.info.episode = 1 end
    store.save_choice(this_file.folder, this_file.title_key, identity)
    if this_file ~= current then return end
    this_file.identity = identity
    msg.info("identified: " .. identity.title .. " episode " .. tostring(this_file.info.episode))
    fetch_subtitle()
end

local ask

local function ask_text(this_file, prompt, submit)
    local input = require "mp.input"
    input.get({
        prompt = prompt,
        submit = function(text)
            input.terminate()
            submit(text)
        end,
    })
end

ask = function(this_file, results)
    local ok, input = pcall(require, "mp.input")
    if not ok then
        osd("this series needs choosing, which takes mpv 0.39 or newer", 6)
        return
    end
    if this_file ~= current then return end
    local items, shown = {}, {}
    for index, media in ipairs(results) do
        if index > 8 then break end
        table.insert(shown, media)
        table.insert(items, describe(media))
    end
    local search_item = #items + 1
    local id_item = #items + 2
    local skip_item = #items + 3
    table.insert(items, "Search for another title…")
    table.insert(items, "Enter an AniList ID…")
    table.insert(items, "Not on AniList: never ask for this folder")
    input.select({
        prompt = "Which series is " .. mp.get_property("filename", "this") .. "?",
        items = items,
        submit = function(index)
            if index == skip_item then
                store.save_choice(this_file.folder, this_file.title_key, {skip = true})
            elseif index == search_item then
                mp.add_timeout(0.05, function()
                    ask_text(this_file, "AniList search: ", function(text)
                        anilist.search(opts.anilist_url, text, function(found)
                            ask(this_file, found or {})
                        end)
                    end)
                end)
            elseif index == id_item then
                mp.add_timeout(0.05, function()
                    ask_text(this_file, "AniList ID: ", function(text)
                        anilist.by_id(opts.anilist_url, tonumber(text), function(media, err)
                            if media then
                                use_identity(this_file, media, "chosen")
                                osd(title_of(media), 3)
                            else
                                osd("no such series" .. (err and ": " .. err or ""), 4)
                            end
                        end)
                    end)
                end)
            elseif shown[index] then
                use_identity(this_file, shown[index], "chosen")
                osd(title_of(shown[index]), 3)
            end
        end,
    })
end

local function identify(this_file, name_index, gathered)
    local name = this_file.info.names[name_index]
    if not name then
        if this_file ~= current then return end
        if #gathered == 0 then
            msg.info("AniList found nothing for this file")
            return
        end
        local asked = this_file.folder .. "|" .. this_file.title_key
        if skipped_now[asked] then return end
        skipped_now[asked] = true
        ask(this_file, gathered)
        return
    end
    anilist.search(opts.anilist_url, name, function(results, err)
        if not results then
            msg.warn("AniList search: " .. tostring(err))
            osd(err, 4)
            return
        end
        local media = parse.certain_match(results, this_file.info)
        if media then
            use_identity(this_file, media, "exact")
            return
        end
        local known = {}
        for _, item in ipairs(gathered) do known[item.id] = true end
        for _, item in ipairs(results) do
            if not known[item.id] then table.insert(gathered, item) end
        end
        identify(this_file, name_index + 1, gathered)
    end)
end

local function start_identity()
    if not current or current.identity_started or not current.is_local then return end
    local wanted = (opts.anilist_enabled and secrets.anilist_token) or (opts.jimaku_enabled and secrets.jimaku_key)
    if not wanted then return end
    if current.info.extra or current.info.ambiguous or #current.info.names == 0 then return end
    current.identity_started = true
    local choice = store.load_choice(current.folder, current.title_key)
    if choice and choice.skip then return end
    if choice and choice.id then
        current.identity = choice
        if choice.format == "MOVIE" and not current.info.episode then current.info.episode = 1 end
        fetch_subtitle()
        return
    end
    identify(current, 1, {})
end

-- The user can always correct a remembered choice.
local function rematch()
    if not current or not current.is_local or #current.info.names == 0 then
        osd("this file has no series to match", 3)
        return
    end
    local this_file = current
    anilist.search(opts.anilist_url, current.info.names[1], function(results, err)
        if not results then
            osd(err, 4)
            return
        end
        ask(this_file, results)
    end)
end

local function start_features()
    start_stats()
    start_identity()
end

-- Settings live in two files that the Settings window writes; a look at them
-- every few seconds applies a change to every open mpv.

local function load_secrets()
    local raw = store.read_secrets()
    secrets = {}
    if type(raw.anilist_token) == "string" and raw.anilist_token ~= "" then secrets.anilist_token = raw.anilist_token end
    if type(raw.jimaku_key) == "string" and raw.jimaku_key ~= "" then secrets.jimaku_key = raw.jimaku_key end
end

local function conf_path()
    return mp.command_native({"expand-path", "~~/script-opts/immersion-mpv.conf"})
end

local function stamp(path)
    local info = utils.file_info(path)
    return info and (info.mtime .. ":" .. info.size) or ""
end

local settings_stamp

local function watch_settings()
    local now = stamp(conf_path()) .. "|" .. stamp(store.path("secrets.json"))
    if now == settings_stamp then return end
    local first = settings_stamp == nil
    settings_stamp = now
    if first then return end
    for key, value in pairs(defaults) do opts[key] = value end
    options.read_options(opts, "immersion-mpv")
    load_secrets()
    if opts.stats_enabled == false and current and current.tracker then
        flush()
        current.tracker = nil
    end
    start_features()
    fetch_subtitle()
end

local function electron_executable()
    local function binary(dist)
        return utils.join_path(dist, is_windows and "electron.exe" or "electron")
    end
    local candidates = {
        opts.electron_path,
        binary(utils.join_path(settings_dir, "node_modules/electron/dist")),
        binary(utils.join_path(script_dir, "../hachidori-mpv/overlay/node_modules/electron/dist")),
    }
    for _, path in ipairs(candidates) do
        local info = path ~= "" and utils.file_info(path)
        if info and info.is_file then return path end
    end
    return nil
end

local function open_settings()
    local electron = electron_executable()
    if not electron then
        osd("Electron was not found. Run install.ps1 / install.sh from immersion-mpv.", 6)
        return
    end
    mp.command_native_async({
        name = "subprocess",
        args = {electron, settings_dir,
            "--immersion-config-dir=" .. mp.command_native({"expand-path", "~~/"}),
            "--immersion-data-dir=" .. store.dir},
        detach = true,
        playback_only = false,
        capture_stdout = false,
        capture_stderr = false,
    }, function() end)
end

local function show_status()
    if not current then
        osd("no file", 2)
        return
    end
    local lines = {}
    if current.tracker then
        local duration = mp.get_property_number("duration") or 0
        local percent = duration > 0 and current.tracker:covered_seconds() / duration * 100 or 0
        table.insert(lines, string.format("%d%% of this file has played", percent))
    end
    if current.identity then
        table.insert(lines, current.identity.title .. " episode " .. tostring(current.info.episode))
    end
    mp.osd_message("immersion: " .. table.concat(lines, "\n"), 4)
end

-- One file at a time.

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", "")
    local filename = mp.get_property("filename", "")
    local is_local = not path:find("^%a[%w+.-]*://")
    local info
    if is_local then
        info = parse.parse_path(utils.join_path(mp.get_property("working-directory", ""), path))
    else
        info = {names = {}}
    end
    current = {
        file_id = filename,
        is_local = is_local,
        media = is_local and utils.join_path(mp.get_property("working-directory", ""), path) or path,
        info = info,
        folder = is_local and (utils.split_path(utils.join_path(mp.get_property("working-directory", ""), path))) or "",
        title_key = parse.norm(info.names[1] or ""),
    }
    start_features()
end)

mp.register_event("end-file", function()
    flush()
    current = nil
    store.compact_stats()
end)

mp.register_event("shutdown", flush)

options.read_options(opts, "immersion-mpv")
store.ensure_dir(store.dir)
store.prune_seen(today())
store.compact_stats()
load_secrets()
mp.register_event("shutdown", http.clean_up)
watch_settings()

mp.add_periodic_timer(TICK, tick)
mp.add_periodic_timer(FLUSH_EVERY, flush)
mp.add_periodic_timer(3, watch_settings)

mp.add_key_binding("alt+i", "settings", open_settings)
mp.add_key_binding("alt+I", "status", show_status)
mp.add_key_binding("alt+a", "rematch", rematch)
