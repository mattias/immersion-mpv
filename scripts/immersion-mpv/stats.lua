-- SPDX-License-Identifier: GPL-3.0-or-later
-- Follows playback, one snapshot at a time, and counts only what actually
-- played: position that moved forward by itself. A pause, a seek or a sub-seek
-- moves nothing, so it adds nothing, and a line heard twice counts once.

local parse = require "parse"

local M = {}

-- A line counts once half of it has played, or a full second of a long one.
local MIN_HEARD = 1.0
-- Longer gaps between snapshots than this are not playback (the computer slept).
local MAX_STEP = 2.0

local Tracker = {}
Tracker.__index = Tracker

-- seen: keys of lines that already count. on_line(key) is told of each new one.
function M.new(seen, on_line, japanese_only)
    return setmetatable({
        seen = seen or {},
        on_line = on_line,
        japanese_only = japanese_only,
        seconds = 0,
        lines = 0,
        chars = 0,
        covered = {},
    }, Tracker)
end

local function add_interval(list, from, to)
    local merged = {}
    for _, range in ipairs(list) do
        if range[2] < from or range[1] > to then
            table.insert(merged, range)
        else
            from = math.min(from, range[1])
            to = math.max(to, range[2])
        end
    end
    table.insert(merged, {from, to})
    table.sort(merged, function(a, b) return a[1] < b[1] end)
    return merged
end

function Tracker:covered_seconds()
    local total = 0
    for _, range in ipairs(self.covered) do total = total + range[2] - range[1] end
    return total
end

-- The ranges saved from an earlier session of this file.
function Tracker:restore_covered(ranges)
    for _, range in ipairs(ranges or {}) do
        if tonumber(range[1]) and tonumber(range[2]) then
            self.covered = add_interval(self.covered, range[1], range[2])
        end
    end
end

function M.line_key(text, start, delay)
    return string.format("%.1f|%s", start - (delay or 0), text:gsub("[\r\n]+", " "))
end

function Tracker:hear(snapshot, moved)
    local text, start, stop = snapshot.text, snapshot.start, snapshot.stop
    if not text or text == "" or not start or not stop or stop <= start then
        self.line = nil
        return
    end
    local key = M.line_key(text, start, snapshot.delay)
    if self.line ~= key then
        self.line = key
        self.heard = 0
    end
    self.heard = self.heard + moved
    if self.seen[key] or self.heard < math.min(MIN_HEARD, (stop - start) * 0.5) then return end
    if self.japanese_only and not parse.is_japanese(text) then return end
    self.seen[key] = true
    self.lines = self.lines + 1
    self.chars = self.chars + parse.count_chars(text)
    if self.on_line then self.on_line(key) end
end

-- snapshot: now (monotonic seconds), playing, position, speed, text, start,
-- stop, delay.
function Tracker:tick(snapshot)
    local wall = self.last_wall and snapshot.now - self.last_wall or 0
    self.last_wall = snapshot.now
    local position = snapshot.position
    if not snapshot.playing or not position or wall > MAX_STEP then
        self.last_position = position
        self.line = nil
        return
    end
    self.seconds = self.seconds + wall
    local last = self.last_position
    self.last_position = position
    local moved = last and position - last or 0
    local limit = math.max(1, wall * (snapshot.speed or 1) * 3)
    if moved <= 0 or moved > limit then
        self:hear(snapshot, 0)
        return
    end
    self.covered = add_interval(self.covered, last, position)
    self:hear(snapshot, moved)
end

-- What has played since the last call. Time and counts go into one row.
function Tracker:take()
    local row = {seconds = self.seconds, lines = self.lines, chars = self.chars}
    self.seconds, self.lines, self.chars = 0, 0, 0
    return row
end

-- A new day counts its lines anew; the file's coverage goes on.
function Tracker:new_day()
    self.seen = {}
    self.line = nil
end

return M
