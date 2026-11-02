-- SPDX-License-Identifier: GPL-3.0-or-later
-- Retimes a subtitle to a reference by when lines start, never by what they
-- say: the reference can be another subtitle track in any language, or the
-- speech Whisper heard. Tsubasa-sync's idea, in a few pages of Lua.
--
-- Every reference start votes for the offsets it would agree with. The
-- offsets with most votes become candidates, and a walk through the cues in
-- order picks one offset per cue, paying a price for every change of offset.
-- A broadcast cut (an ad break the other release did not have) is two
-- offsets with a change between them. Too little agreement and nothing
-- changes: a confidently wrong subtitle is worse than one that is off.

local M = {}

local MAX_OFFSET = 600     -- seconds either way
local BIN = 0.2            -- vote resolution
local CANDIDATES = 12
local SWITCH_COST = 8      -- matched cues a new segment must win back
local MIN_MATCHED = 20
local MIN_SEGMENT = 8

-- Times as written in SRT/VTT (00:01:02,345) and ASS (0:01:02.34).
local function seconds(h, m, s, fraction)
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber("0." .. fraction)
end

local function srt_stamp(value)
    value = math.max(0, value)
    local millis = math.floor(value * 1000 + 0.5)
    return string.format("%02d:%02d:%02d,%03d", math.floor(millis / 3600000), math.floor(millis / 60000) % 60,
        math.floor(millis / 1000) % 60, millis % 1000)
end

local function ass_stamp(value)
    value = math.max(0, value)
    local centis = math.floor(value * 100 + 0.5)
    return string.format("%d:%02d:%02d.%02d", math.floor(centis / 360000), math.floor(centis / 6000) % 60,
        math.floor(centis / 100) % 60, centis % 100)
end

local SRT_TIME = "(%d+):(%d%d):(%d%d)[,.](%d+)%s*%-%->%s*(%d+):(%d%d):(%d%d)[,.](%d+)"
local ASS_DIALOGUE = "^(Dialogue:%s*[^,]*,)(%d+):(%d%d):(%d%d)%.(%d+),(%d+):(%d%d):(%d%d)%.(%d+)(,.*)$"

function M.is_ass(text)
    return text:find("%[Events%]") ~= nil
end

-- Start times of the cues, sorted.
function M.starts(text)
    local list = {}
    if M.is_ass(text) then
        for line in text:gmatch("[^\r\n]+") do
            local _, h, m, s, f = line:match(ASS_DIALOGUE)
            if h then table.insert(list, seconds(h, m, s, f)) end
        end
    else
        for h, m, s, f in text:gmatch(SRT_TIME) do
            table.insert(list, seconds(h, m, s, f))
        end
    end
    table.sort(list)
    return list
end

-- The first index in a sorted list whose value is at least value.
local function lower_bound(list, value)
    local low, high = 1, #list + 1
    while low < high do
        local middle = math.floor((low + high) / 2)
        if list[middle] < value then low = middle + 1 else high = middle end
    end
    return low
end

-- The reference start nearest to time, and how far away it is.
local function nearest(reference, time)
    local index = lower_bound(reference, time)
    local best, distance = nil, math.huge
    for _, at in ipairs({index - 1, index}) do
        local value = reference[at]
        if value and math.abs(value - time) < distance then best, distance = value, math.abs(value - time) end
    end
    return best, distance
end

local function median(list)
    table.sort(list)
    local count = #list
    if count == 0 then return nil end
    if count % 2 == 1 then return list[(count + 1) / 2] end
    return (list[count / 2] + list[count / 2 + 1]) / 2
end

local function candidates(target, reference)
    local votes = {}
    for _, start in ipairs(target) do
        local voted = {}
        local first = lower_bound(reference, start - MAX_OFFSET)
        for index = first, #reference do
            local difference = reference[index] - start
            if difference > MAX_OFFSET then break end
            local bin = math.floor(difference / BIN + 0.5)
            -- A cue votes once per bin, and a little for its neighbours, so
            -- a peak split across two bins is not lost.
            for spread = -1, 1 do
                local key = bin + spread
                if not voted[key] then
                    voted[key] = true
                    votes[key] = (votes[key] or 0) + (spread == 0 and 2 or 1)
                end
            end
        end
    end
    local ranked = {}
    for bin, count in pairs(votes) do table.insert(ranked, {bin = bin, count = count}) end
    table.sort(ranked, function(a, b) return a.count > b.count end)
    local chosen = {}
    for _, entry in ipairs(ranked) do
        local offset = entry.bin * BIN
        local distinct = true
        for _, other in ipairs(chosen) do
            if math.abs(other - offset) < 1.0 then distinct = false break end
        end
        if distinct then table.insert(chosen, offset) end
        if #chosen >= CANDIDATES then break end
    end
    return chosen
end

-- How often a start lands near a reference start by chance: the share of the
-- reference's span within tolerance of one of its starts.
local function chance(reference, tolerance)
    local covered, reach = 0, -math.huge
    for _, start in ipairs(reference) do
        local from, to = math.max(start - tolerance, reach), start + tolerance
        if to > from then covered = covered + to - from end
        reach = math.max(reach, to)
    end
    local span = reference[#reference] - reference[1] + 2 * tolerance
    return span > 0 and covered / span or 1
end

local walk

-- options.tolerance: how close a shifted start must come to a reference start
-- (wider for Whisper, whose starts are rougher).
-- Returns {segments = {{from, offset, matched, cues}}, matched, rate} or nil, reason.
function M.align(target, reference, options)
    options = options or {}
    local tolerance = options.tolerance or 0.4
    if #target < MIN_MATCHED or #reference < MIN_MATCHED then
        return nil, "too few lines to time against"
    end
    local offsets = candidates(target, reference)
    if #offsets == 0 then return nil, "no common timing" end
    -- A segment must beat chance clearly, or it is chance.
    local floor = math.max(options.min_rate or 0.5, chance(reference, tolerance) + 0.3)
    while #offsets > 0 do
        local segments, matched = walk(target, reference, offsets, tolerance)
        local weakest
        for _, segment in ipairs(segments) do
            local rate = segment.matched / segment.cues
            if segment.matched < MIN_SEGMENT or rate < floor then
                if not weakest or rate < weakest.matched / weakest.cues then weakest = segment end
            end
        end
        if not weakest then
            local rate = matched / #target
            if matched < MIN_MATCHED then break end
            return {segments = segments, matched = matched, rate = rate}
        end
        -- Its cues go to the offsets that are left.
        table.remove(offsets, weakest.candidate)
    end
    return nil, "too few lines line up with the reference"
end

walk = function(target, reference, offsets, tolerance)
    -- hits[c][i]: cue i lands on a reference line with offset c.
    local hits = {}
    for c, offset in ipairs(offsets) do
        hits[c] = {}
        for i, start in ipairs(target) do
            local _, distance = nearest(reference, start + offset)
            hits[c][i] = distance <= tolerance and 1 or 0
        end
    end

    -- The walk: best score of cues 1..i ending with offset c.
    local score, from = {}, {}
    for c = 1, #offsets do score[c] = hits[c][1] end
    for i = 2, #target do
        local best_c, best = 1, -math.huge
        for c = 1, #offsets do
            if score[c] > best then best_c, best = c, score[c] end
        end
        from[i] = {}
        local next_score = {}
        for c = 1, #offsets do
            local stay, switch = score[c], best - SWITCH_COST
            if stay >= switch then
                next_score[c], from[i][c] = stay + hits[c][i], c
            else
                next_score[c], from[i][c] = switch + hits[c][i], best_c
            end
        end
        score = next_score
    end
    local last, top = 1, -math.huge
    for c = 1, #offsets do
        if score[c] > top then last, top = c, score[c] end
    end
    local chosen = {}
    chosen[#target] = last
    for i = #target, 2, -1 do chosen[i - 1] = from[i][chosen[i]] end

    -- Segments, each with its offset refined to the median of its matches.
    local segments, matched = {}, 0
    local i = 1
    while i <= #target do
        local c = chosen[i]
        local j = i
        while j < #target and chosen[j + 1] == c do j = j + 1 end
        local differences = {}
        for k = i, j do
            if hits[c][k] == 1 then
                local value = nearest(reference, target[k] + offsets[c])
                table.insert(differences, value - target[k])
            end
        end
        table.insert(segments, {from = target[i], offset = median(differences) or offsets[c],
            matched = #differences, cues = j - i + 1, candidate = c})
        matched = matched + #differences
        i = j + 1
    end
    return segments, matched
end

local function offset_at(segments, time)
    local offset = segments[1].offset
    for _, segment in ipairs(segments) do
        if time >= segment.from - 0.001 then offset = segment.offset end
    end
    return offset
end

-- The same text with every cue moved by its segment's offset.
function M.retime(text, segments)
    if M.is_ass(text) then
        return (text:gsub("[^\r\n]+", function(line)
            local head, h1, m1, s1, f1, h2, m2, s2, f2, tail = line:match(ASS_DIALOGUE)
            if not head then return line end
            local start, stop = seconds(h1, m1, s1, f1), seconds(h2, m2, s2, f2)
            local offset = offset_at(segments, start)
            return head .. ass_stamp(start + offset) .. "," .. ass_stamp(stop + offset) .. tail
        end))
    end
    return (text:gsub(SRT_TIME, function(h1, m1, s1, f1, h2, m2, s2, f2)
        local start, stop = seconds(h1, m1, s1, f1), seconds(h2, m2, s2, f2)
        local offset = offset_at(segments, start)
        return srt_stamp(start + offset) .. " --> " .. srt_stamp(stop + offset)
    end))
end

function M.describe(result)
    local parts = {}
    for _, segment in ipairs(result.segments) do
        table.insert(parts, string.format("%+.2f s", segment.offset))
    end
    return table.concat(parts, " / ") .. string.format(", %d%% of lines agree", math.floor(result.rate * 100))
end

return M
