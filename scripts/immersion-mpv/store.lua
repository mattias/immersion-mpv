-- SPDX-License-Identifier: GPL-3.0-or-later
-- The plugin's files, all in one data folder outside mpv's config:
--
--   stats.jsonl          what played, one row per flush (see the README)
--   seen-<date>.tsv      lines that already count today, per file
--   coverage.json        which parts of each file have played
--   choices.json         the series chosen per folder
--   secrets.json         the AniList token and the Jimaku key
--   subs/<id>/           subtitles from Jimaku

local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

local M = {}

local is_windows = package.config:sub(1, 1) == "\\"

local function data_dir()
    local override = os.getenv("IMMERSION_MPV_DATA")
    if override and override ~= "" then return override end
    if is_windows then return utils.join_path(os.getenv("APPDATA") or ".", "immersion-mpv") end
    local base = os.getenv("XDG_CONFIG_HOME")
    if not base or base == "" then base = utils.join_path(os.getenv("HOME") or ".", ".config") end
    return utils.join_path(base, "immersion-mpv")
end

M.dir = data_dir()

function M.path(...)
    local path = M.dir
    for _, part in ipairs({...}) do path = utils.join_path(path, part) end
    return path
end

function M.ensure_dir(path)
    local info = utils.file_info(path)
    if info and info.is_dir then return true end
    local args = is_windows and {"cmd", "/d", "/c", "mkdir", (path:gsub("/", "\\"))} or {"mkdir", "-p", path}
    mp.command_native({name = "subprocess", args = args, playback_only = false,
        capture_stdout = true, capture_stderr = true})
    info = utils.file_info(path)
    return info ~= nil and info.is_dir
end

function M.read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

function M.append(path, text)
    local file, err = io.open(path, "ab")
    if not file then
        msg.warn("cannot write " .. path .. ": " .. tostring(err))
        return false
    end
    file:write(text)
    file:close()
    return true
end

function M.write(path, text)
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then
        msg.warn("cannot write " .. path .. ": " .. tostring(err))
        return false
    end
    file:write(text)
    file:close()
    os.remove(path)
    return os.rename(temporary, path) ~= nil
end

function M.read_json(path)
    local text = M.read(path)
    if not text or text == "" then return nil end
    return utils.parse_json(text)
end

function M.write_json(path, value)
    local text = utils.format_json(value)
    if text then return M.write(path, text) end
    return false
end

local function seen_path(date)
    return M.path("seen-" .. date .. ".tsv")
end

-- The lines of this file that already count on this date.
function M.load_seen(date, file_id)
    local seen = {}
    local text = M.read(seen_path(date))
    if not text then return seen end
    local prefix = file_id .. "\t"
    for line in text:gmatch("[^\n]+") do
        if line:sub(1, #prefix) == prefix then seen[line:sub(#prefix + 1)] = true end
    end
    return seen
end

function M.add_seen(date, file_id, key)
    M.append(seen_path(date), file_id .. "\t" .. key .. "\n")
end

-- Only today's lines matter; older days are finished.
function M.prune_seen(today)
    for _, name in ipairs(utils.readdir(M.dir, "files") or {}) do
        local date = name:match("^seen%-(.+)%.tsv$")
        if date and date ~= today then os.remove(M.path(name)) end
    end
end

function M.load_coverage(file_id)
    local all = M.read_json(M.path("coverage.json")) or {}
    return all[file_id]
end

function M.save_coverage(file_id, ranges)
    local path = M.path("coverage.json")
    local all = M.read_json(path) or {}
    all[file_id] = ranges
    M.write_json(path, all)
end

function M.forget_coverage(file_id)
    local path = M.path("coverage.json")
    local all = M.read_json(path) or {}
    if all[file_id] == nil then return end
    all[file_id] = nil
    M.write_json(path, next(all) and all or {})
end

-- Keys never go in mpv's options, which verbose logs print.
function M.read_secrets()
    return M.read_json(M.path("secrets.json")) or {}
end

local function folder_key(folder)
    local key = folder:gsub("\\", "/"):gsub("/+$", "")
    if is_windows then key = key:lower() end
    return key
end

-- A folder can hold more than one series, so the choice is per series name
-- within the folder.
function M.load_choice(folder, title_key)
    local all = M.read_json(M.path("choices.json")) or {}
    local entries = all[folder_key(folder)]
    return entries and entries[title_key] or nil
end

function M.save_choice(folder, title_key, choice)
    local path = M.path("choices.json")
    local all = M.read_json(path) or {}
    local key = folder_key(folder)
    all[key] = all[key] or {}
    all[key][title_key] = choice
    M.write_json(path, all)
end

return M
