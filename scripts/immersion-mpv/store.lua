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

-- For tests.
function M.use_dir(path)
    M.dir = path
end

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

-- Compaction: stats.jsonl's rows are increments, so all rows of one file on
-- one day can become a single row with the sums, at any time, without
-- changing any total. Other mpvs may be appending meanwhile, and nothing may
-- be lost or counted twice, even if mpv stops halfway:
--
--   1. stats.jsonl is renamed to stats.raw-<run>; new rows start a new one.
--   2. Every stats.raw-* (with any a stopped run left) is merged into
--      stats.tmp-<run>.
--   3. stats.commit-<run> names the raw files merged. From here the run is
--      finished by whoever finds it, never redone.
--   4. stats.tmp-<run> becomes stats.jsonl; a stats.jsonl that appeared
--      meanwhile is set aside as one more raw file first.
--   5. The raw files and the commit are removed.

local function merge_rows(text)
    local order, rows, other = {}, {}, {}
    for line in text:gmatch("[^\r\n]+") do
        local row = utils.parse_json(line)
        if type(row) == "table" and row.date and row.file then
            local key = tostring(row.date) .. "\0" .. tostring(row.file)
            local sum = rows[key]
            if not sum then
                rows[key] = row
                table.insert(order, key)
            else
                for _, field in ipairs({"seconds", "lines", "chars"}) do
                    sum[field] = (tonumber(sum[field]) or 0) + (tonumber(row[field]) or 0)
                end
                sum.ended = math.max(tonumber(sum.ended) or 0, tonumber(row.ended) or 0)
                sum.title = row.title or sum.title
                sum.anilist_id = row.anilist_id or sum.anilist_id
                sum.episode = row.episode or sum.episode
            end
        elseif line:find("%S") then
            table.insert(other, line)
        end
    end
    local out = {}
    for _, key in ipairs(order) do
        local row = rows[key]
        row.seconds = math.floor((tonumber(row.seconds) or 0) * 10 + 0.5) / 10
        table.insert(out, utils.format_json(row))
    end
    for _, line in ipairs(other) do table.insert(out, line) end
    return #out > 0 and table.concat(out, "\n") .. "\n" or ""
end

M.merge_rows = merge_rows

local run_count = 0

local function finish_run(run)
    local live = M.path("stats.jsonl")
    local commit = M.read_json(M.path("stats.commit-" .. run))
    if type(commit) ~= "table" then return end
    local tmp = M.path("stats.tmp-" .. run)
    if utils.file_info(tmp) then
        for _ = 1, 20 do
            if utils.file_info(live) then
                run_count = run_count + 1
                os.rename(live, M.path(("stats.raw-%s-late%d"):format(run, run_count)))
            end
            if os.rename(tmp, live) then break end
        end
        if utils.file_info(tmp) then return end
    end
    for _, name in ipairs(commit) do os.remove(M.path(name)) end
    os.remove(M.path("stats.commit-" .. run))
end

-- One compaction at a time across every mpv: creating a folder either
-- succeeds or finds it there. A lock left by a stopped mpv expires.
local LOCK_STALE = 600

local function shell(args)
    local result = mp.command_native({name = "subprocess", args = args, playback_only = false,
        capture_stdout = true, capture_stderr = true})
    return result and result.status == 0
end

local function lock()
    local path = M.path("stats.lock")
    local native = is_windows and path:gsub("/", "\\") or path
    local make = is_windows and {"cmd", "/d", "/c", "mkdir", native} or {"mkdir", native}
    if shell(make) then return true end
    local info = utils.file_info(path)
    if info and os.time() - info.mtime > LOCK_STALE then
        shell(is_windows and {"cmd", "/d", "/c", "rmdir", native} or {"rmdir", native})
        return shell(make)
    end
    return false
end

local function unlock()
    local native = is_windows and M.path("stats.lock"):gsub("/", "\\") or M.path("stats.lock")
    shell(is_windows and {"cmd", "/d", "/c", "rmdir", native} or {"rmdir", native})
end

local compact_once

function M.compact_stats()
    if not lock() then return false end
    local ok, result = pcall(compact_once)
    -- Rows that arrived while it ran are merged too, once.
    if ok and result then
        for _, name in ipairs(utils.readdir(M.dir, "files") or {}) do
            if name:find("^stats%.raw%-") then
                pcall(compact_once)
                break
            end
        end
    end
    unlock()
    if not ok then msg.warn("compacting stats.jsonl: " .. tostring(result)) end
    return ok and result
end

compact_once = function()
    -- A run that got as far as its commit is finished, not redone.
    for _, name in ipairs(utils.readdir(M.dir, "files") or {}) do
        local run = name:match("^stats%.commit%-(.+)$")
        if run and not run:find("%.tmp$") then finish_run(run) end
    end
    for _, name in ipairs(utils.readdir(M.dir, "files") or {}) do
        local run = name:match("^stats%.tmp%-(.+)$")
        if run and not utils.file_info(M.path("stats.commit-" .. run)) then os.remove(M.path(name)) end
    end

    run_count = run_count + 1
    local run = ("%s-%d-%d"):format(mp.get_property("pid", "0"), os.time(), run_count)
    local live = M.path("stats.jsonl")
    if utils.file_info(live) and not os.rename(live, M.path("stats.raw-" .. run)) then return false end
    local raw, parts = {}, {}
    for _, name in ipairs(utils.readdir(M.dir, "files") or {}) do
        if name:find("^stats%.raw%-") then
            local text = M.read(M.path(name))
            if text then
                table.insert(raw, name)
                table.insert(parts, text)
            end
        end
    end
    if #raw == 0 then return true end
    if not M.write(M.path("stats.tmp-" .. run), merge_rows(table.concat(parts, "\n"))) then return false end
    if not M.write_json(M.path("stats.commit-" .. run), raw) then
        os.remove(M.path("stats.tmp-" .. run))
        return false
    end
    finish_run(run)
    return true
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

-- Answers from AniList and Jimaku, so the same question is not asked again
-- while the answer is fresh: {key = {until = time, value = ...}}. Stale
-- entries are dropped whenever the cache is written.
function M.cache_get(key)
    local cache = M.read_json(M.path("cache.json")) or {}
    local entry = cache[key]
    if type(entry) ~= "table" or (tonumber(entry["until"]) or 0) <= os.time() then return nil end
    return entry.value
end

function M.cache_put(key, value, days)
    local path = M.path("cache.json")
    local cache = M.read_json(path) or {}
    local now = os.time()
    for old, entry in pairs(cache) do
        if type(entry) ~= "table" or (tonumber(entry["until"]) or 0) <= now then cache[old] = nil end
    end
    cache[key] = {["until"] = now + math.floor(days * 86400), value = value}
    M.write_json(path, cache)
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
