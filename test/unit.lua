-- SPDX-License-Identifier: GPL-3.0-or-later
-- Unit tests, run by mpv's own Lua (see test/run.mjs).

local mp = require "mp"
local dir = mp.get_opt("immersion-test-dir")
package.path = dir .. "/?.lua;" .. package.path

local parse = require "parse"
local stats = require "stats"
local anilist = require "anilist"
local jimaku = require "jimaku"

local failures, checks = 0, 0

local function same(actual, expected, label)
    checks = checks + 1
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL %s: got %s, wanted %s"):format(label, tostring(actual), tostring(expected)))
    end
end

-- title, episode, season for file names.
local names = {
    {"[SubsPlease] Sousou no Frieren - 03 (1080p) [ABCD1234].mkv", "Sousou no Frieren", 3, nil},
    {"[Erai-raws] Kimetsu no Yaiba - Katanakaji no Sato-hen - 05 [1080p][Multiple Subtitle].mkv", "Kimetsu no Yaiba - Katanakaji no Sato-hen", 5, nil},
    {"Mushoku.Tensei.S02E04.1080p.WEB.x264-GROUP.mkv", "Mushoku Tensei", 4, 2},
    {"Steins;Gate - 12v2.mkv", "Steins;Gate", 12, nil},
    {"Re Zero 2nd Season - 03.mkv", "Re Zero", 3, 2},
    {"86 - 05.mkv", "86", 5, nil},
    {"Mob Psycho 100 III - 07.mkv", "Mob Psycho 100", 7, 3},
    {"Spy x Family Season 2 - 03 [1080p].mkv", "Spy x Family", 3, 2},
    {"葬送のフリーレン 第０３話.mkv", "葬送のフリーレン", 3, nil},
    {"03.mkv", "", 3, nil},
    {"E03.mkv", "", 3, nil},
    {"Title Name 05.mkv", "Title Name", 5, nil},
    {"Mob Psycho 100.mkv", "Mob Psycho 100", nil, nil},
    {"Show - 13.5 [1080p].mkv", "Show", nil, nil},
    {"Show - 01-12 [Batch].mkv", "Show", nil, nil},
}
for _, case in ipairs(names) do
    local info = parse.parse_name(case[1])
    same(info.title, case[2], case[1] .. " title")
    same(info.episode, case[3], case[1] .. " episode")
    same(info.season, case[4], case[1] .. " season")
end
same(parse.parse_name("Show - 13.5.mkv").ambiguous, true, "part episode is ambiguous")
same(parse.parse_name("[Group] Show - 01 [1080p].mkv").group, "Group", "group")
same(parse.parse_name("[G] Show - NCOP1 [1080p].mkv").extra, true, "NCOP is an extra")
same(parse.parse_name("[G] Show - OP2.mkv").extra, true, "OP2 is an extra")
same(parse.parse_name("[G] Show - 03.mkv").extra, false, "an episode is not an extra")

local info = parse.parse_path("D:/Anime/Sousou no Frieren/Season 2/E03.mkv")
same(info.names[1], "Sousou no Frieren", "title from the folder above Season 2")
same(info.season, 2, "season from the folder")
same(info.episode, 3, "episode with folder title")
same(parse.parse_path("D:/Anime/Show/Extras/Show - 01.mkv").extra, true, "extras folder")
same(parse.parse_path("D:/Downloads/Show - 01.mkv").names[2], nil, "generic folder is no title")
same(#parse.parse_path("D:/Frieren/Sousou no Frieren - 01.mkv").names, 2, "file and folder titles")

local function media(id, romaji, format, episodes, year, synonyms)
    return {id = id, title = {romaji = romaji}, format = format, episodes = episodes, seasonYear = year, synonyms = synonyms}
end
local function certain(results, values)
    local found = parse.certain_match(results, values)
    return found and found.id or nil
end

same(certain({media(1, "Show", "TV", 12), media(2, "Show Season 2", "TV", 12)}, {names = {"Show"}, episode = 3}), 1, "one exact title")
same(certain({media(1, "Show", "TV", 12), media(2, "Show Season 2", "TV", 12)}, {names = {"Show"}, season = 2, episode = 3}), 2, "season title")
same(certain({media(1, "Show", "TV", 12), media(2, "Show 2nd Season", "TV", 12)}, {names = {"Show"}, season = 2, episode = 3}), 2, "ordinal season title")
same(certain({media(1, "Show", "TV", 12)}, {names = {"Show"}, season = 2, episode = 3}), nil, "season 2 of a series without one")
same(certain({media(1, "Show", "TV", 12, 2001), media(2, "Show", "TV", 25, 2019)}, {names = {"Show"}, episode = 3}), nil, "a remake is not guessed")
same(certain({media(1, "Show", "TV", 12, 2001), media(2, "Show", "TV", 25, 2019)}, {names = {"Show"}, episode = 3, year = 2019}), 2, "the year settles a remake")
same(certain({media(1, "Show", "TV", 62), media(2, "Show (2011)", "TV", 148)}, {names = {"Show"}, episode = 5}), nil, "a year in the title does not hide a remake")
same(certain({media(1, "Show Something", "TV", 12)}, {names = {"Show"}, episode = 3}), nil, "a similar title is not a match")
same(certain({media(1, "Show", "TV", 12)}, {names = {"Show"}, episode = 13}), nil, "an episode past the end")
same(certain({media(1, "Show", "TV", 12)}, {names = {"Show"}}), nil, "no episode")
same(certain({media(1, "Show", "MOVIE", 1)}, {names = {"Show"}}), 1, "a movie needs no episode")
same(certain({media(1, "Other", "TV", 12, nil, {"Sh-ow!"})}, {names = {"Show"}, episode = 1}), 1, "synonym, punctuation aside")

same(parse.is_japanese("こんにちは"), true, "kana")
same(parse.is_japanese("漢字"), true, "kanji")
same(parse.is_japanese("Hello there"), false, "English")
same(parse.is_japanese("Café ♪"), false, "accents and music notes")
same(parse.count_chars("こんにちは 世界\n"), 7, "characters without spaces")
same(parse.count_chars("a　b"), 2, "ideographic space")

-- A simulated player: each step moves position by itself or not.
local function player(tracker)
    local self = {now = 0, position = 0}
    function self.play(seconds, line)
        for _ = 1, math.floor(seconds * 10 + 0.5) do
            self.now = self.now + 0.1
            self.position = self.position + 0.1
            tracker:tick({now = self.now, playing = true, position = self.position, speed = 1,
                text = line and line.text or "", start = line and line.start, stop = line and line.stop})
        end
    end
    function self.pause(seconds, line)
        for _ = 1, math.floor(seconds * 10 + 0.5) do
            self.now = self.now + 0.1
            tracker:tick({now = self.now, playing = false, position = self.position, speed = 1,
                text = line and line.text or "", start = line and line.start, stop = line and line.stop})
        end
    end
    function self.seek(position) self.position = position end
    return self
end

local line_a = {text = "はじめまして", start = 0, stop = 2}
local line_b = {text = "よろしく", start = 2, stop = 4}

do
    local counted = {}
    local tracker = stats.new({}, function(key) table.insert(counted, key) end, true)
    local run = player(tracker)
    run.play(2, line_a)
    same(tracker.lines, 1, "a played line counts")
    same(tracker.chars, 6, "its characters count")
    run.pause(5, line_b)
    same(tracker.lines, 1, "a line under pause does not count")
    same(math.floor(tracker.seconds + 0.5), 2, "pause adds no time")
    run.seek(0)
    run.play(2, line_a)
    same(tracker.lines, 1, "a replayed line counts once")
    same(math.floor(tracker.seconds + 0.5), 4, "a replay is still listening time")
    same(math.floor(tracker:covered_seconds() + 0.5), 2, "a replay adds no coverage")
    run.play(0.5, line_b)
    same(tracker.lines, 1, "too little of a line does not count")
    run.play(1, line_b)
    same(tracker.lines, 2, "half of a line counts")
    same(#counted, 2, "each new line is reported once")
end

do
    local tracker = stats.new({}, nil, true)
    local run = player(tracker)
    for index = 1, 5 do
        run.seek(index * 10)
        run.play(0.1, {text = "線" .. index, start = index * 10, stop = index * 10 + 4})
    end
    same(tracker.lines, 0, "sub-seek through lines counts none")
end

do
    local tracker = stats.new({}, nil, true)
    player(tracker).play(3, {text = "Hello", start = 0, stop = 3})
    same(tracker.lines, 0, "English lines do not count")
    same(math.floor(tracker.seconds + 0.5), 3, "their time does")
end

do
    local seen = {[stats.line_key(line_a.text, line_a.start)] = true}
    local tracker = stats.new(seen, nil, true)
    player(tracker).play(2, line_a)
    same(tracker.lines, 0, "a line from earlier today counts once")
    tracker:new_day()
    tracker.last_position = 0
    player(tracker).play(2, line_a)
    same(tracker.lines, 1, "a new day counts it again")
end

do
    local tracker = stats.new({}, nil, true)
    tracker:tick({now = 0, playing = true, position = 0})
    tracker:tick({now = 7200, playing = true, position = 0.1})
    same(tracker.seconds, 0, "sleep is no playback")
end

do
    local key_before = stats.line_key("あ", 10.0, 0)
    local key_after = stats.line_key("あ", 10.5, 0.5)
    same(key_before, key_after, "sub-delay does not make a line new")
end

local function plan(status, progress, episodes, episode)
    local entry = status and {status = status, progress = progress} or nil
    return anilist.plan_update({episodes = episodes, mediaListEntry = entry}, episode)
end

same(plan(nil, nil, 12, 3).progress, 3, "no entry yet")
same(plan(nil, nil, 12, 3).status, "CURRENT", "no entry becomes CURRENT")
same(plan("CURRENT", 2, 12, 3).progress, 3, "forward")
same(plan("CURRENT", 5, 12, 3), nil, "never backward")
same(plan("CURRENT", 3, 12, 3), nil, "not the same episode again")
same(plan("CURRENT", 11, 12, 12).status, "COMPLETED", "the last episode completes")
same(plan("COMPLETED", 12, 12, 3), nil, "a finished entry stays")
same(plan("REPEATING", 2, 12, 3).status, nil, "a rewatch stays a rewatch")
same(plan("PLANNING", 0, 12, 1).status, "CURRENT", "planning starts")
same(plan("CURRENT", 2, 12, 13), nil, "past the series' end")
same(plan("CURRENT", 2, nil, 13).progress, 13, "unknown length is no limit")

local files = {
    {name = "[A] Show - 03.ass", url = "u1", last_modified = "2024"},
    {name = "[B] Show - 03.srt", url = "u2", last_modified = "2023"},
    {name = "[B] Show - 04.srt", url = "u3", last_modified = "2025"},
    {name = "Show batch.zip", url = "u4", last_modified = "2026"},
}
same(jimaku.pick_file(files, 3).url, "u2", "SRT first")
same(jimaku.pick_file(files, 3, "A").url, "u1", "same group first")
same(jimaku.pick_file(files, 5), nil, "no wrong episode")
same(jimaku.pick_file({{name = "Movie.srt", url = "m"}}, nil).url, "m", "a movie takes any subtitle")

same(jimaku.has_japanese_track({{type = "sub", lang = "jpn"}}), true, "jpn track")
same(jimaku.has_japanese_track({{type = "sub", lang = "eng"}}), false, "English track")
same(jimaku.has_japanese_track({{type = "audio", lang = "jpn"}}), false, "Japanese audio is no subtitle")
same(jimaku.has_japanese_track({{type = "sub", title = "日本語"}}), true, "title")
same(jimaku.has_japanese_track({{type = "sub", ["external-filename"] = "D:/x/Show.ja.srt"}}), true, "external")

print(("%d checks, %d failed"):format(checks, failures))
mp.commandv("quit", failures == 0 and 0 or 1)
