-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plays a scenario in a real mpv beside the plugin, the way a viewer would,
-- and reports what it saw as "E2E key=value" lines. See test/run.mjs.

local mp = require "mp"
local utils = require "mp.utils"

local mode = mp.get_opt("e2e-mode") or "play"

local function report(key, value)
    print(("E2E %s=%s"):format(key, tostring(value)))
end

local function at_time(position, action)
    local timer
    timer = mp.add_periodic_timer(0.02, function()
        if (mp.get_property_number("time-pos") or 0) >= position then
            timer:kill()
            action()
        end
    end)
end

local function later(seconds, action)
    mp.add_timeout(seconds, action)
end

local function finish(seconds)
    later(seconds or 0.5, function()
        report("sub-visibility", mp.get_property("sub-visibility"))
        report("sid", mp.get_property("sid"))
        for _, track in ipairs(mp.get_property_native("track-list", {})) do
            if track.type == "sub" then
                report("sub-track", (track.title or "") .. "|" .. (track.lang or "") .. "|" .. tostring(track.selected))
            end
        end
        report("input-ipc-server", mp.get_property("input-ipc-server"))
        local bound = {}
        for _, binding in ipairs(mp.get_property_native("input-bindings", {})) do
            if binding.owner == "immersion_mpv" or binding.owner == "hachidori_mpv" then
                table.insert(bound, binding.owner .. ":" .. binding.key)
            end
        end
        report("bindings", table.concat(bound, ","))
        mp.commandv("quit")
    end)
end

local scenarios = {}

-- Lines are 2 s apart: line n runs from 2(n-1) to 2n-0.2.
function scenarios.stats()
    at_time(3.2, function()
        -- Lines 1 and 2 have played. Paused, nothing moves.
        mp.set_property_bool("pause", true)
        mp.commandv("seek", "6.5", "absolute+exact")
        later(1, function()
            mp.commandv("sub-seek", "1")
            later(1, function()
                -- Play the same two lines again, from the top.
                mp.commandv("seek", "0", "absolute+exact")
                mp.set_property_bool("pause", false)
                later(0.3, function()
                    at_time(3.2, function()
                        -- sub-seek through five lines without hearing them:
                        -- the next hop comes as soon as the last one landed.
                        local left = 5
                        local function hop()
                            if left == 0 then
                                mp.unregister_event(hop)
                                mp.commandv("seek", "20", "absolute+exact")
                                later(0.3, function()
                                    at_time(23.5, function() finish(0.2) end)
                                end)
                                return
                            end
                            left = left - 1
                            later(0.1, function() mp.commandv("sub-seek", "1") end)
                        end
                        mp.register_event("playback-restart", hop)
                        hop()
                    end)
                end)
            end)
        end)
    end)
end

function scenarios.again()
    at_time(3.2, function() finish(0.1) end)
end

-- Plays the whole file.
function scenarios.play()
    mp.register_event("end-file", function() end)
    local duration
    local timer
    timer = mp.add_periodic_timer(0.1, function()
        duration = duration or mp.get_property_number("duration")
        if duration and (mp.get_property_number("time-pos") or 0) >= duration - 0.5 then
            timer:kill()
            finish(1.5)
        end
    end)
end

-- Jumps past the 85 % without watching.
function scenarios.skip()
    later(1, function()
        mp.commandv("seek", "95", "absolute-percent+exact")
        later(1.5, function() finish(0.5) end)
    end)
end

-- The question comes up; the first choice is taken, then the file plays out.
function scenarios.ask()
    later(2, function()
        mp.commandv("keypress", "ENTER")
        scenarios.play()
    end)
end

-- Closing the question with Esc.
function scenarios.escape()
    later(2, function()
        mp.commandv("keypress", "ESC")
        later(1, function() finish(0.2) end)
    end)
end

-- One episode in two sittings.
function scenarios.first()
    at_time(5.5, function() finish(0.1) end)
end

function scenarios.second()
    mp.commandv("seek", "5", "absolute+exact")
    scenarios.play()
end

-- With hachidori-mpv: watch what it does to sub-visibility.
function scenarios.both()
    mp.observe_property("sub-visibility", "bool", function(_, value)
        report("visibility-change", value)
    end)
    later(mp.get_opt("e2e-wait") and tonumber(mp.get_opt("e2e-wait")) or 12, function() finish(0.2) end)
end

mp.register_event("file-loaded", function()
    scenarios[mode]()
end)
