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

-- request: url, headers (list of "Name: value"), body, output (a file to save
-- to), follow (redirects), timeout, max_size.
-- done(status, text): status is nil when no answer came, and text then says why.
function M.request(request, done)
    local config = {
        "url = " .. quoted(request.url),
        "user-agent = " .. quoted(USER_AGENT),
        "max-time = " .. tostring(request.timeout or 20),
        "write-out = " .. quoted("\n%{http_code}"),
    }
    for _, header in ipairs(request.headers or {}) do
        table.insert(config, "header = " .. quoted(header))
    end
    if request.body then table.insert(config, "data-raw = " .. quoted(request.body)) end
    if request.output then table.insert(config, "output = " .. quoted(request.output)) end
    if request.follow then table.insert(config, "location") end
    if request.max_size then table.insert(config, "max-filesize = " .. tostring(request.max_size)) end
    sequence = sequence + 1
    local config_file = store.path(("curl-%s-%d.conf"):format(mp.get_property("pid", "0"), sequence))
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
        local body, status = result.stdout:match("^(.*)\n(%d+)$")
        done(tonumber(status), body or "")
    end)
end

function M.get_json(request, done)
    M.request(request, function(status, text)
        if status ~= 200 then
            done(nil, status, text)
            return
        end
        done(utils.parse_json(text), status)
    end)
end

function M.escape(value)
    return (tostring(value):gsub("[^%w%-_.~]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

return M
