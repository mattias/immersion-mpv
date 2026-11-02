-- SPDX-License-Identifier: GPL-3.0-or-later
-- Requests through curl. The request goes in a short-lived curl config beside
-- secrets.json, so a key is never on a command line, where mpv's logs and the
-- process list would show it. (mpv on Windows gives subprocesses no stdin.)

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"
local store = require "store"

local M = {}

local USER_AGENT = "immersion-mpv/0.1"
local sequence = 0

-- A killed mpv can leave its last request behind.
function M.clean_up()
    for _, name in ipairs(utils.readdir(store.dir, "files") or {}) do
        if name:find("^curl%-.*%.conf$") then os.remove(store.path(name)) end
    end
end

local function quoted(value)
    return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"')
        :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

-- A service that said "too many requests" (or that none are left) is not
-- asked again until it said to come back: one block per service, shared by
-- every mpv through the data folder.
local MIN_WAIT = 60

local function blocked_until(service)
    local blocks = store.read_json(store.path("blocked.json")) or {}
    return tonumber(blocks[service]) or 0
end

local function block(service, seconds)
    local path = store.path("blocked.json")
    local blocks = store.read_json(path) or {}
    blocks[service] = os.time() + math.max(MIN_WAIT, math.ceil(seconds or 0))
    store.write_json(path, blocks)
    msg.warn(service .. " asked to wait; no requests to it for " .. (blocks[service] - os.time()) .. " s")
end

M.LIMITED = 429

-- request: url, headers (list of "Name: value"), body, output (a file to save
-- to), follow (redirects), timeout, max_size, service (a name for rate limits).
-- done(status, text): status is nil when no answer came, and text then says why.
-- A blocked service answers 429 without being asked.
function M.request(request, done)
    if request.service and blocked_until(request.service) > os.time() then
        done(M.LIMITED, "")
        return
    end
    local config = {
        "url = " .. quoted(request.url),
        "user-agent = " .. quoted(USER_AGENT),
        "max-time = " .. tostring(request.timeout or 20),
        "write-out = " .. quoted("\n%{http_code}\n%header{retry-after}|%header{x-ratelimit-remaining}|%header{x-ratelimit-reset-after}"),
    }
    for _, header in ipairs(request.headers or {}) do
        table.insert(config, "header = " .. quoted(header))
    end
    if request.body then table.insert(config, "data-raw = " .. quoted(request.body)) end
    if request.output then table.insert(config, "output = " .. quoted(request.output)) end
    if request.follow then table.insert(config, "location") end
    if request.max_size then table.insert(config, "max-filesize = " .. tostring(request.max_size)) end
    sequence = sequence + 1
    local config_file = store.path(("curl-%s-%s-%d.conf"):format(mp.get_property("pid", "0"),
        mp.get_script_name(), sequence))
    if not store.write(config_file, table.concat(config, "\n") .. "\n") then
        done(nil, "cannot write to the data folder")
        return
    end
    mp.command_native_async({
        name = "subprocess",
        args = {"curl", "--silent", "--show-error", "--config", config_file},
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(_, result)
        os.remove(config_file)
        if not result or result.status ~= 0 then
            local reason = result and result.stderr or "curl did not run"
            msg.warn("request failed: " .. reason)
            done(nil, reason)
            return
        end
        -- With the body in a file, curl on Windows writes these lines in text
        -- mode, with CR LF; the body itself is left as it came.
        local stdout = request.output and result.stdout:gsub("\r", "") or result.stdout
        local body, status, retry, remaining, reset = stdout:match("^(.*)\n(%d+)\n([^|\n]*)|([^|\n]*)|([^|\n]*)$")
        status = tonumber(status)
        if request.service and (status == M.LIMITED or remaining == "0") then
            block(request.service, tonumber(retry) or tonumber(reset))
        end
        done(status, body or "")
    end)
end

-- request.cache: {key, days, empty_days}. A good answer is kept for days, an
-- empty list (nothing there yet) for empty_days; errors are never kept.
function M.get_json(request, done)
    local cache = request.cache
    if cache then
        local hit = store.cache_get(cache.key)
        if hit ~= nil then
            done(hit, 200)
            return
        end
    end
    M.request(request, function(status, text)
        if status ~= 200 then
            done(nil, status, text)
            return
        end
        local value = utils.parse_json(text)
        if cache and value ~= nil then
            local empty = type(value) == "table" and next(value) == nil
            store.cache_put(cache.key, value, empty and (cache.empty_days or cache.days) or cache.days)
        end
        done(value, status)
    end)
end

function M.escape(value)
    return (tostring(value):gsub("[^%w%-_.~]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

return M
