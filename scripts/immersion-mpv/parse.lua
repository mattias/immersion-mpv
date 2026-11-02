-- SPDX-License-Identifier: GPL-3.0-or-later
-- Reads a series, season and episode out of a file name and its folders, and
-- decides whether an AniList search result is that series. Nothing here
-- guesses: anything less than one exact match is left for the user to choose.

local M = {}

local GENERIC_FOLDERS = {
    anime = true, video = true, videos = true, downloads = true, download = true,
    movies = true, series = true, tv = true, media = true, torrents = true,
    ["completed"] = true, ["new folder"] = true, ["nytt mapp"] = true,
}

local EXTRA_FOLDERS = {
    extras = true, extra = true, specials = true, special = true, sps = true,
    sp = true, nc = true, ncop = true, nced = true, bonus = true, ost = true,
    menus = true, menu = true, scans = true, ova = true, ovas = true,
}

local TAGS = {
    ["2160p"] = true, ["1080p"] = true, ["720p"] = true, ["576p"] = true, ["480p"] = true,
    ["4k"] = true, ["x264"] = true, ["x265"] = true, ["h264"] = true, ["h265"] = true,
    ["hevc"] = true, ["avc"] = true, ["av1"] = true, ["10bit"] = true, ["8bit"] = true,
    ["web"] = true, ["webrip"] = true, ["web-dl"] = true, ["webdl"] = true, ["bluray"] = true,
    ["blu-ray"] = true, ["bdrip"] = true, ["bd"] = true, ["dvdrip"] = true, ["dvd"] = true,
    ["hdtv"] = true, ["aac"] = true, ["flac"] = true, ["opus"] = true, ["dual"] = true,
    ["multi"] = true, ["uncensored"] = true, ["remux"] = true, ["nf"] = true, ["cr"] = true,
    ["amzn"] = true, ["dsnp"] = true, ["hidive"] = true, ["adn"] = true, ["batch"] = true,
}

local ROMAN = {ii = 2, iii = 3, iv = 4, v = 5, vi = 6}
local ROMAN_OF = {[2] = "ii", [3] = "iii", [4] = "iv", [5] = "v", [6] = "vi"}

local function trim(text)
    return (text:gsub("^[%s%-_.~:]+", ""):gsub("[%s%-_.~:]+$", ""))
end

-- ０-９ to 0-9, so 第０３話 reads like 第03話.
local function ascii_digits(text)
    return (text:gsub("\239\188([\144-\153])", function(byte)
        return string.char(byte:byte() - 144 + 48)
    end))
end

-- Cuts at the first release tag: everything after it is not the title.
local function cut_tags(text)
    local position = 1
    while true do
        local first, last = text:find("[^%s]+", position)
        if not first then return text end
        local word = text:sub(first, last):lower():gsub("%-.*$", function(rest)
            return rest == "-dl" and rest or ""
        end)
        if TAGS[word] then return text:sub(1, first - 1) end
        position = last + 1
    end
end

local function looks_extra(text)
    local upper = text:upper()
    if upper:find("%f[%w]NC ?OP%d*%f[%W]") or upper:find("%f[%w]NC ?ED%d*%f[%W]") then return true end
    if upper:find("%f[%w]CREDITLESS%f[%W]") or upper:find("%f[%w]TRAILER%f[%W]") then return true end
    if upper:find("%f[%w]PREVIEW%f[%W]") or upper:find("%f[%w]OVA%f[%W]") then return true end
    if upper:find("%f[%w]OAD%f[%W]") or upper:find("%f[%w]SPECIAL%f[%W]") then return true end
    for _, word in ipairs({"OP%d+", "ED%d+", "SP%d*", "PV%d*", "CM%d*"}) do
        if text:find("%f[%w]" .. word .. "%f[%W]") then return true end
    end
    return false
end

local function take_season(title)
    local lower = title:lower()
    local number = lower:match("season%s*(%d+)")
    if not number then number = lower:match("(%d+)[nrst][dht]%s+season") end
    if number then
        local cut = lower:find("%d+[nrst][dht]%s+season") or lower:find("season%s*%d+")
        return trim(title:sub(1, cut - 1)), tonumber(number)
    end
    local before, short = title:match("^(.-)%s+[Ss](%d+)$")
    if before and before ~= "" then return trim(before), tonumber(short) end
    local stem, roman = title:match("^(.-)%s+([IiVv]+)$")
    if stem and stem ~= "" and ROMAN[roman:lower()] and roman == roman:upper() then
        return trim(stem), ROMAN[roman:lower()]
    end
    return title, nil
end

-- Parses one file (or folder) name. episode is set only when one whole number
-- is certain; ambiguous is set for a range, a part episode like 13.5 or a
-- trailing number that may belong to the title.
function M.parse_name(name)
    local base = ascii_digits(name):gsub("%.[%w]+$", "")
    local info = {}
    info.group = base:match("^%[([^%]]+)%]")
    info.year = tonumber(base:match("[%(%[]((19%d%d))[%)%]]") or base:match("[%(%[]((20%d%d))[%)%]]"))
    local text = base:gsub("%b[]", " "):gsub("%b()", " "):gsub("【.-】", " ")
    if not text:find(" ") then text = text:gsub("[._]", " ") end
    text = text:gsub("_", " "):gsub("%s+", " ")
    text = trim(cut_tags(text))
    if not info.year then
        local before, year = text:match("^(.+)%s([12][09]%d%d)$")
        if before then text, info.year = before, tonumber(year) end
    end
    info.extra = looks_extra(text)

    local function found(title, number)
        info.title = trim(title)
        info.episode = tonumber(number)
    end

    local title, season, number = text:match("^(.-)[Ss](%d+)[%s._-]*[Ee][Pp]?(%d+)")
    if title and (title == "" or title:find("[%s._-]$")) then
        found(title, number)
        info.season = tonumber(season)
        local tail = text:sub(#text:match("^.-[Ss]%d+[%s._-]*[Ee][Pp]?%d+") + 1)
        if tail:find("^%s*[-~]%s*[Ee]?%d") or tail:find("^[Ee]%d") then
            info.episode, info.ambiguous = nil, true
        end
    end

    if not info.title then
        local before, kai = text:match("^(.-)第%s*(%d+)%s*[話回]")
        if not kai then before, kai = text:match("^(.-)第%s*(%d+)%s*话") end
        if kai then found(before, kai) end
    end

    if not info.title then
        -- The last " - 03" wins: a title may hold dashes of its own.
        local position, last_first, last_number, last_tail = 1, nil, nil, nil
        while true do
            local first, stop, digits = text:find("%s%-%s*(%d+)", position)
            if not first then break end
            last_first, last_number, last_tail = first, digits, text:sub(stop + 1)
            position = stop
        end
        if last_first then
            local tail = last_tail:gsub("^[vV]%d+", "")
            if tail:find("^%.%d") or tail:find("^%s*[-~]%s*%d") then
                info.title, info.ambiguous = trim(text:sub(1, last_first)), true
            elseif tail == "" or tail:find("^%s") then
                found(text:sub(1, last_first), last_number)
            end
        end
    end

    if not info.title then
        local before, digits = text:match("^(.-)%f[%a][Ee][Pp]?%.?%s*(%d+)%f[%D]")
        if not digits then before, digits = text:lower():match("^(.-)episode%s*(%d+)%f[%D]") end
        if digits then found(text:sub(1, #before), digits) end
    end

    if not info.title then
        if text:find("^%d+$") then
            found("", text)
        else
            local before, digits = text:match("^(.+)%s(%d+)[vV]?%d*$")
            if digits and digits:sub(1, 1) == "0" and #digits >= 2 then
                found(before, digits)
            elseif digits then
                info.ambiguous = true
                info.title = trim(text)
            else
                info.title = trim(text)
            end
        end
    end

    local bare, part_season = take_season(info.title)
    info.title = bare
    info.season = info.season or part_season
    return info
end

-- directories: the folders above the file, nearest first.
function M.parse_path(path)
    local parts = {}
    for part in path:gmatch("[^/\\]+") do table.insert(parts, part) end
    local info = M.parse_name(table.remove(parts) or "")
    local names = {}
    if info.title ~= "" then table.insert(names, info.title) end
    for depth = 0, 1 do
        local folder = parts[#parts - depth]
        if not folder or folder:find(":$") then break end
        local lower = folder:lower()
        if EXTRA_FOLDERS[lower] then
            info.extra = true
        else
            local season = lower:match("^season%s*(%d+)$") or lower:match("^s(%d+)$")
            if season then
                info.season = info.season or tonumber(season)
            elseif not GENERIC_FOLDERS[lower] then
                local parsed = M.parse_name(folder .. ".dir")
                if parsed.title ~= "" and not parsed.title:find("^%d*$") then
                    if parsed.title ~= names[1] then table.insert(names, parsed.title) end
                    info.season = info.season or parsed.season
                    info.year = info.year or parsed.year
                end
                break
            end
        end
    end
    info.names = names
    return info
end

function M.norm(text)
    local lower = text:lower():gsub("×", "x")
    return (lower:gsub("[%c%s%p]", ""))
end

local function ordinal(number)
    local suffix = ({"st", "nd", "rd"})[number] or "th"
    return number .. suffix
end

local function wanted_names(names, season)
    local wanted = {}
    for _, name in ipairs(names) do
        if season and season > 1 then
            wanted[M.norm(name .. " season " .. season)] = true
            wanted[M.norm(name .. " " .. ordinal(season) .. " season")] = true
            wanted[M.norm(name .. " " .. season)] = true
            if ROMAN_OF[season] then wanted[M.norm(name .. " " .. ROMAN_OF[season])] = true end
        else
            wanted[M.norm(name)] = true
        end
    end
    return wanted
end

local function names_of(media)
    local list = {}
    local title = media.title or {}
    for _, key in ipairs({"romaji", "english", "native"}) do
        if type(title[key]) == "string" then table.insert(list, title[key]) end
    end
    for _, synonym in ipairs(media.synonyms or {}) do
        if type(synonym) == "string" then table.insert(list, synonym) end
    end
    -- "Show (2011)" is also "Show": a remake must tie with the original, not lose.
    for index = 1, #list do
        local bare = list[index]:gsub("%s*%(%d%d%d%d%)%s*$", "")
        if bare ~= list[index] then table.insert(list, bare) end
    end
    return list
end

-- Returns the one media that is certainly this file, or nil.
function M.certain_match(results, info)
    local wanted = wanted_names(info.names or {}, info.season)
    local exact = {}
    for _, media in ipairs(results) do
        for _, name in ipairs(names_of(media)) do
            if wanted[M.norm(name)] then
                table.insert(exact, media)
                break
            end
        end
    end
    if info.year then
        local same_year = {}
        for _, media in ipairs(exact) do
            if media.seasonYear == info.year then table.insert(same_year, media) end
        end
        exact = same_year
    end
    if #exact ~= 1 then return nil end
    local media = exact[1]
    local episodes = tonumber(media.episodes)
    if info.episode then
        if episodes and info.episode > episodes then return nil end
    elseif media.format ~= "MOVIE" then
        return nil
    end
    return media
end

function M.is_japanese(text)
    return text:find("\227[\129\130\131]") ~= nil or text:find("[\228-\233][\128-\191][\128-\191]") ~= nil
end

-- Characters, without white space (the ideographic space included).
function M.count_chars(text)
    local bare = text:gsub("\227\128\128", ""):gsub("%s", "")
    local _, continuation = bare:gsub("[\128-\191]", "")
    return #bare - continuation
end

return M
