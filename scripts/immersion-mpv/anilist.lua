-- SPDX-License-Identifier: GPL-3.0-or-later
-- AniList's GraphQL API: searching a series and moving your list forward.

local utils = require "mp.utils"
local http = require "http"

local M = {}

local MEDIA_FIELDS = "id title { romaji english native } synonyms format episodes seasonYear"

local SEARCH = "query ($search: String) { Page(perPage: 10) { media(search: $search, type: ANIME, sort: SEARCH_MATCH) { "
    .. MEDIA_FIELDS .. " } } }"
local BY_ID = "query ($id: Int) { Media(id: $id, type: ANIME) { " .. MEDIA_FIELDS .. " } }"
local ENTRY = "query ($id: Int) { Media(id: $id, type: ANIME) { episodes mediaListEntry { id status progress } } }"
local SAVE = "mutation ($mediaId: Int, $progress: Int, $status: MediaListStatus) { "
    .. "SaveMediaListEntry(mediaId: $mediaId, progress: $progress, status: $status) { id status progress } }"

local function post(url, token, query, variables, done)
    local headers = {"Content-Type: application/json", "Accept: application/json"}
    if token and token ~= "" then table.insert(headers, "Authorization: Bearer " .. token) end
    http.request({
        url = url,
        headers = headers,
        body = utils.format_json({query = query, variables = variables}),
    }, function(status, text)
        if not status then
            done(nil, "no answer from AniList")
            return
        end
        local reply = utils.parse_json(text)
        if status ~= 200 or not reply or not reply.data then
            if status == 401 or status == 400 and text:find("Invalid token", 1, true) then
                done(nil, "AniList refused the token")
            else
                done(nil, "AniList answered " .. status)
            end
            return
        end
        done(reply.data)
    end)
end

function M.search(url, text, done)
    post(url, nil, SEARCH, {search = text}, function(data, err)
        if not data then
            done(nil, err)
            return
        end
        done(data.Page and data.Page.media or {})
    end)
end

function M.by_id(url, id, done)
    post(url, nil, BY_ID, {id = id}, function(data, err)
        done(data and data.Media or nil, err)
    end)
end

-- What to send to reach this episode, or nil and why not. Decided from the
-- list as it is right now: progress only ever moves forward, a finished entry
-- is left alone, and a rewatch stays a rewatch.
function M.plan_update(media, episode)
    local entry = media.mediaListEntry
    if type(entry) ~= "table" then entry = nil end
    local progress = entry and tonumber(entry.progress) or 0
    local episodes = tonumber(media.episodes)
    if episodes and episode > episodes then
        return nil, "episode " .. episode .. " is past the series' " .. episodes
    end
    if entry and entry.status == "COMPLETED" then return nil, "already completed" end
    if episode <= progress then return nil, "already at episode " .. progress end
    local update = {progress = episode}
    if not entry or entry.status ~= "REPEATING" then
        update.status = episodes and episode == episodes and "COMPLETED" or "CURRENT"
    end
    return update
end

-- done(update, reason): update is what was sent, nil when nothing needed
-- sending; failed is true when the attempt itself went wrong.
function M.mark(url, token, media_id, episode, dry_run, done)
    post(url, token, ENTRY, {id = media_id}, function(data, err)
        if not data or type(data.Media) ~= "table" then
            done(nil, err or "AniList does not know this series", true)
            return
        end
        local update, reason = M.plan_update(data.Media, episode)
        if not update then
            done(nil, reason)
            return
        end
        if dry_run then
            done(update, "test mode")
            return
        end
        post(url, token, SAVE, {mediaId = media_id, progress = update.progress, status = update.status},
            function(saved, save_err)
                if not saved then
                    done(nil, save_err, true)
                    return
                end
                done(update)
            end)
    end)
end

return M
