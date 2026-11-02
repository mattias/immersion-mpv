-- SPDX-License-Identifier: GPL-3.0-or-later
-- What the video itself says about timing: its own subtitle tracks, read with
-- ffmpeg, or the speech in its audio, heard by Whisper.

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"
local parse = require "parse"
local store = require "store"

local M = {}

local is_windows = package.config:sub(1, 1) == "\\"
local TEXT_CODECS = {subrip = true, srt = true, ass = true, ssa = true, webvtt = true, mov_text = true, text = true}
local SNIFF_SECONDS = 300

local function exists(path)
    local info = path and path ~= "" and utils.file_info(path)
    return info and info.is_file or false
end

-- opts: the plugin's options (ffmpeg_path, whisper_python, whisper_model).
function M.ffmpeg(opts)
    if opts.ffmpeg_path ~= "" then return opts.ffmpeg_path end
    if is_windows then
        local beside = mp.command_native({"expand-path", "~~exe_dir/ffmpeg.exe"})
        if exists(beside) then return beside end
    end
    return "ffmpeg"
end

local function run(args, done, env)
    mp.command_native_async({
        name = "subprocess",
        args = args,
        env = env,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(_, result)
        done(result and result.status == 0, result and result.stdout or "", result and result.stderr or "")
    end)
end

function M.is_text(track)
    return track.type == "sub" and TEXT_CODECS[(track.codec or ""):lower()] == true
end

local function is_tagged(track)
    local lang = (track.lang or ""):lower()
    return lang ~= "" and lang ~= "und" and lang ~= "unk"
end

-- The input and stream for one track, as ffmpeg names them.
local function source(media, track)
    if track.external then return track["external-filename"], "0:s:0" end
    if track["ff-index"] then return media, "0:" .. track["ff-index"] end
    return nil
end

-- Reads a track's first minutes: done(text) or done(nil).
local function sniff(opts, media, track, done)
    local input, stream = source(media, track)
    if not input then
        done(nil)
        return
    end
    run({M.ffmpeg(opts), "-v", "error", "-nostdin", "-i", input, "-map", stream, "-t", tostring(SNIFF_SECONDS),
        "-f", "srt", "-"}, function(ok, out)
        done(ok and out or nil)
    end)
end

-- Sorts the text tracks the file has: is any of them Japanese, and which
-- other one can a subtitle be timed against? Tracks without a language tag are
-- read to find out. done(japanese, reference_track).
function M.survey(opts, media, tracks, japanese_tag, done)
    local untagged, reference = {}, nil
    for _, track in ipairs(tracks) do
        if track.type == "sub" then
            if japanese_tag(track) then
                done(true, nil)
                return
            end
            if M.is_text(track) then
                if is_tagged(track) then
                    reference = reference or track
                else
                    table.insert(untagged, track)
                end
            end
        end
    end
    local index = 0
    local function next_track()
        index = index + 1
        local track = untagged[index]
        if not track then
            done(false, reference)
            return
        end
        sniff(opts, media, track, function(text)
            if text and parse.is_japanese(text) then
                msg.info("track " .. tostring(track.id) .. " has no language tag but is Japanese")
                done(true, nil)
                return
            end
            if text and text:find("%-%->") then reference = reference or track end
            next_track()
        end)
    end
    next_track()
end

-- A whole track as SRT text: done(text) or done(nil, reason).
function M.extract(opts, media, track, done)
    local input, stream = source(media, track)
    if not input then
        done(nil, "the track cannot be read")
        return
    end
    run({M.ffmpeg(opts), "-v", "error", "-nostdin", "-i", input, "-map", stream, "-f", "srt", "-"},
        function(ok, out, err)
            if ok and out ~= "" then done(out) else done(nil, "ffmpeg could not read the track: " .. err) end
        end)
end

-- Whisper: where the Python with faster-whisper, its model and CUDA live.
-- Defaults: install-whisper.ps1's environment, and the model and CUDA
-- libraries Anki Miner keeps, when they are there.
local function home(...)
    local base = os.getenv(is_windows and "USERPROFILE" or "HOME") or ""
    local path = base
    for _, part in ipairs({...}) do path = utils.join_path(path, part) end
    return path
end

function M.whisper_python(opts)
    if opts.whisper_python ~= "" then return opts.whisper_python end
    local default
    if is_windows then
        default = utils.join_path(os.getenv("LOCALAPPDATA") or "", "immersion-mpv/whisper/Scripts/python.exe")
    else
        default = home(".local/share/immersion-mpv/whisper/bin/python")
    end
    return exists(default) and default or nil
end

local function anki_miner_model()
    local snapshots = home(".anki_miner/asr_models/models--Systran--faster-whisper-large-v3/snapshots")
    for _, name in ipairs(utils.readdir(snapshots, "dirs") or {}) do
        local dir = utils.join_path(snapshots, name)
        if exists(utils.join_path(dir, "model.bin")) then return dir end
    end
    return nil
end

local function cuda_dirs()
    local root = home(".anki_miner/cuda_libs")
    local dirs = {}
    for _, name in ipairs(utils.readdir(root, "dirs") or {}) do
        table.insert(dirs, utils.join_path(root, name))
    end
    return dirs
end

local function environment(extra_path)
    if #extra_path == 0 then return nil end
    local list, found = {}, false
    local separator = is_windows and ";" or ":"
    for _, entry in ipairs(utils.get_env_list()) do
        local name = entry:match("^([^=]+)=")
        if name and name:upper() == "PATH" then
            entry = name .. "=" .. table.concat(extra_path, separator) .. separator .. entry:sub(#name + 2)
            found = true
        end
        table.insert(list, entry)
    end
    if not found then table.insert(list, "PATH=" .. table.concat(extra_path, separator)) end
    return list
end

local busy = false

-- Speech times as SRT text: done(text) or done(nil, reason).
function M.whisper(opts, media, script_dir, done)
    local python = M.whisper_python(opts)
    if not python then
        done(nil, "Whisper is not installed (install-whisper.ps1)")
        return
    end
    if busy then
        done(nil, "Whisper is busy with another file")
        return
    end
    busy = true
    local function finish(text, reason)
        busy = false
        done(text, reason)
    end
    local work = store.path("tmp")
    store.ensure_dir(work)
    local stem = utils.join_path(work, "whisper-" .. mp.get_property("pid", "0"))
    run({M.ffmpeg(opts), "-v", "error", "-nostdin", "-y", "-i", media, "-map", "0:a:0", "-ac", "1", "-ar", "16000",
        "-c:a", "pcm_s16le", stem .. ".wav"}, function(ok, _, err)
        if not ok then
            os.remove(stem .. ".wav")
            finish(nil, "ffmpeg could not read the audio: " .. err)
            return
        end
        local model = opts.whisper_model ~= "" and opts.whisper_model or anki_miner_model() or "large-v3-turbo"
        local args = {python, utils.join_path(script_dir, "whisper_ref.py"), stem .. ".wav", stem .. ".srt", "--model", model}
        msg.info("Whisper: listening for speech times")
        run(args, function(done_ok, _, whisper_err)
            os.remove(stem .. ".wav")
            local text = done_ok and store.read(stem .. ".srt") or nil
            os.remove(stem .. ".srt")
            if text and text ~= "" then
                finish(text)
            else
                finish(nil, "Whisper failed: " .. (whisper_err:match("([^\n]+)\n*$") or "no output"))
            end
        end, environment(cuda_dirs()))
    end)
end

return M
