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

function M.has_japanese_track(tracks)
    for _, track in ipairs(tracks) do
        if track.type == "sub" then
            local lang = (track.lang or ""):lower()
            if lang == "ja" or lang == "jp" or lang == "jpn" or lang:find("^ja%-") then return true end
            if track.title and has_japanese_mark(track.title) then return true end
            local name = track["external-filename"]
            if name and (has_japanese_mark(name) or name:lower():find("[.%-_]jpn?[.%-_]")
                or name:lower():find("[.%-_]ja[.%-_]")) then return true end
        end
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

local function download(file, media_id, episode, done)
    local target = cache_stem(media_id, episode) .. "." .. extension(file.name)
    if not store.ensure_dir(store.path("subs", tostring(media_id))) then
        done(nil, "cannot create the subtitle folder")
        return
    end
    http.request({url = file.url, output = target .. ".part", follow = true, max_size = MAX_SIZE, timeout = 30},
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
    local function get(path, callback)
        http.get_json({url = base_url .. path, headers = headers}, callback)
    end
    local function failed(status)
        if status == 401 then return "Jimaku refused the key" end
        if status == 429 then return "Jimaku's rate limit was hit" end
        return "Jimaku answered " .. tostring(status)
    end
    get("/api/entries/search?anilist_id=" .. http.escape(media_id), function(entries, status)
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
            get(path, function(files, file_status)
                if not files then
                    done(nil, failed(file_status))
                    return
                end
                local file = M.pick_file(files, episode, group)
                if not file then
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
