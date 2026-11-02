-- SPDX-License-Identifier: GPL-3.0-or-later
-- Finds an episode's Japanese subtitle on jimaku.cc and saves it locally.

local msg = require "mp.msg"
local utils = require "mp.utils"
local http = require "http"
local parse = require "parse"
local store = require "store"

local M = {}

local EXTENSIONS = {srt = true, ass = true, ssa = true}
local MAX_SIZE = 5 * 1024 * 1024
local MAX_ENTRIES = 3

local function extension(name)
    local found = name:match("%.(%w+)$")
    return found and found:lower() or nil
end

local function has_japanese_mark(text)
    local lower = text:lower()
    return lower:find("japanese", 1, true) ~= nil or text:find("日本語", 1, true) ~= nil
end

-- Whether a track says it is Japanese: by its language, title or file name.
-- (Tracks that say nothing are read: see reference.survey.)
function M.is_japanese_track(track)
    if track.type ~= "sub" then return false end
    local lang = (track.lang or ""):lower()
    if lang == "ja" or lang == "jp" or lang == "jpn" or lang:find("^ja%-") then return true end
    if track.title and has_japanese_mark(track.title) then return true end
    local name = track["external-filename"]
    return name ~= nil and (has_japanese_mark(name) or name:lower():find("[.%-_]jpn?[.%-_]") ~= nil
        or name:lower():find("[.%-_]ja[.%-_]") ~= nil)
end

function M.has_japanese_track(tracks)
    for _, track in ipairs(tracks) do
        if M.is_japanese_track(track) then return true end
    end
    return false
end

-- Jimaku's episode filter is a best effort from the file name, so each name
-- is read again here: the wrong episode is worse than none. Among the right
-- ones: the same release group (its timing fits), then SRT (plain text, no
-- signs), then the newest.
function M.pick_file(files, episode, group)
    local best, best_score
    for _, file in ipairs(files) do
        local kind = type(file.name) == "string" and extension(file.name)
        if kind and EXTENSIONS[kind] and type(file.url) == "string" then
            local parsed = parse.parse_name(file.name)
            if not episode or parsed.episode == episode then
                local score = (kind == "srt") and 2 or 1
                if group and parsed.group and parsed.group:lower() == group:lower() then score = score + 4 end
                local stamp = tostring(file.last_modified or "")
                if not best or score > best_score or (score == best_score and stamp > tostring(best.last_modified or "")) then
                    best, best_score = file, score
                end
            end
        end
    end
    return best
end

local function cache_stem(media_id, episode)
    return store.path("subs", tostring(media_id), episode and string.format("ep%03d", episode) or "movie")
end

function M.cached(media_id, episode)
    local stem = cache_stem(media_id, episode)
    for kind in pairs(EXTENSIONS) do
        local info = utils.file_info(stem .. "." .. kind)
        if info and info.is_file and info.size > 0 then return stem .. "." .. kind end
    end
    return nil
end

-- A subtitle timed to one video fits that video only, so the timed copy is
-- kept per video: its file name, hashed into the cache's own ASCII names.
local function hash(text)
    local value = 5381
    for index = 1, #text do value = (value * 33 + text:byte(index)) % 4294967296 end
    return string.format("%08x", value)
end

function M.place(media_id, episode, video_name)
    return cache_stem(media_id, episode) .. "-" .. hash(video_name)
end

function M.timed(place)
    for kind in pairs(EXTENSIONS) do
        local info = utils.file_info(place .. "." .. kind)
        if info and info.is_file and info.size > 0 then return place .. "." .. kind end
    end
    return nil
end

function M.timed_path(place, raw)
    return place .. "." .. extension(raw)
end

function M.refused(place)
    return utils.file_info(place .. ".refused") ~= nil
end

-- Timing is not tried again for a video it failed on; the reason is kept.
function M.mark_refused(place, reason)
    store.write(place .. ".refused", tostring(reason) .. "\n")
end

local function download(file, media_id, episode, done)
    local target = cache_stem(media_id, episode) .. "." .. extension(file.name)
    if not store.ensure_dir(store.path("subs", tostring(media_id))) then
        done(nil, "cannot create the subtitle folder")
        return
    end
    http.request({url = file.url, output = target .. ".part", follow = true, max_size = MAX_SIZE, timeout = 30,
        service = "jimaku"},
        function(status)
            if status ~= 200 then
                os.remove(target .. ".part")
                done(nil, "download answered " .. tostring(status))
                return
            end
            os.remove(target)
            os.rename(target .. ".part", target)
            done(target)
        end)
end

-- done(path, reason): the saved subtitle, or nil and why there is none.
function M.fetch(base_url, key, media_id, episode, group, done)
    local headers = {"Authorization: " .. key}
    local function get(path, cache, callback)
        http.get_json({url = base_url .. path, headers = headers, service = "jimaku", cache = cache}, callback)
    end
    local function failed(status)
        if status == 401 then return "Jimaku refused the key" end
        if status == http.LIMITED then return "Jimaku's rate limit was hit; trying again later" end
        return "Jimaku answered " .. tostring(status)
    end
    -- Which entries a series has rarely changes; an episode's files do while
    -- it airs, and "nothing yet" is asked again after a few hours.
    local entries_cache = {key = "jimaku-entries:" .. tostring(media_id), days = 7, empty_days = 0.25}
    get("/api/entries/search?anilist_id=" .. http.escape(media_id), entries_cache, function(entries, status)
        if not entries then
            done(nil, failed(status))
            return
        end
        local index = 0
        local function next_entry()
            index = index + 1
            local entry = entries[index]
            if not entry or index > MAX_ENTRIES then
                done(nil, "no subtitle for this episode on Jimaku")
                return
            end
            local path = "/api/entries/" .. http.escape(entry.id) .. "/files"
            if episode then path = path .. "?episode=" .. episode end
            local files_cache = {key = "jimaku-files:" .. tostring(entry.id) .. ":" .. tostring(episode or "movie"),
                days = 1, empty_days = 0.25}
            get(path, files_cache, function(files, file_status)
                if not files then
                    done(nil, failed(file_status))
                    return
                end
                local file = M.pick_file(files, episode, group)
                if not file then
                    -- A list without this episode counts as nothing yet.
                    store.cache_put(files_cache.key, {}, files_cache.empty_days)
                    next_entry()
                    return
                end
                msg.info("Jimaku: " .. file.name)
                download(file, media_id, episode, done)
            end)
        end
        next_entry()
    end)
end

return M
