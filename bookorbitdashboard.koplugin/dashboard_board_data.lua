--[[--
The data every dashboard widget reads, assembled once per render.

Library data comes from the dashboard body dashboard_library builds from
KOReader (continue reading, goal, streak, highlight, counts, shelves and a
year ago). The rest comes from KOReader directly: statistics.sqlite3 for
today, the week and the finish forecast, the Vocabulary Builder for the word
of the day, and the power device for the frontlight. Local reads are cached
for a couple of minutes.
]]

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local datetime = require("datetime")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local StatsReader = require("dashboard_stats_reader")
local ChapterMap = require("dashboard_chapter_map")
local Library = require("dashboard_library")

local BoardData = {}

local DAY = 86400
local LOCAL_TTL = 120
-- The heatmap shows 52 whole weeks, Sunday to Saturday, ending with the week
-- that holds today.
BoardData.HEATMAP_DAYS = 364

local function dayStart(t)
    local d = os.date("*t", t)
    d.hour, d.min, d.sec = 0, 0, 0
    return os.time(d)
end
BoardData.dayStart = dayStart

local function dateKey(t)
    return os.date("%Y-%m-%d", t)
end

-- ---------------------------------------------------------------- words
function BoardData.longWeekday(t)
    local short = os.date("%a", t)
    return datetime.shortDayOfWeekToLongTranslation[short] or short
end

function BoardData.shortWeekday(t)
    local short = os.date("%a", t)
    return datetime.shortDayOfWeekTranslation[short] or short
end

function BoardData.longMonth(t)
    local long = os.date("%B", t)
    return datetime.longMonthTranslation[long] or long
end

function BoardData.shortMonth(t)
    local short = os.date("%b", t)
    return datetime.shortMonthTranslation[short] or short
end

function BoardData.longDate(t)
    return T(_("%1, %2 %3"), BoardData.longWeekday(t), tonumber(os.date("%d", t)), BoardData.longMonth(t))
end

function BoardData.greeting(name, t)
    local hour = tonumber(os.date("%H", t)) or 12
    if type(name) ~= "string" or name == "" then
        if hour >= 5 and hour < 12 then return _("Good morning") end
        if hour >= 12 and hour < 18 then return _("Good afternoon") end
        return _("Good evening")
    end
    if hour >= 5 and hour < 12 then return T(_("Good morning, %1"), name) end
    if hour >= 12 and hour < 18 then return T(_("Good afternoon, %1"), name) end
    return T(_("Good evening, %1"), name)
end

function BoardData.formatDuration(min)
    min = math.floor((min or 0) + 0.5)
    if min < 60 then return T(_("%1 min"), min) end
    local h, m = math.floor(min / 60), min % 60
    if m == 0 then return T(_("%1 h"), h) end
    return T(_("%1 h %2 min"), h, m)
end

function BoardData.formatShortDuration(min)
    min = math.floor((min or 0) + 0.5)
    if min < 60 then return T(_("%1m"), min) end
    local h, m = math.floor(min / 60), min % 60
    if m == 0 then return T(_("%1h"), h) end
    return T(_("%1h %2m"), h, m)
end

-- Hours today, "yesterday", a weekday inside a week, then a short date.
function BoardData.relativeDay(iso, now)
    if type(iso) ~= "string" then return nil end
    local t = datetime.stringISO8601ToSeconds and datetime.stringISO8601ToSeconds(iso)
    if not t then return nil end
    now = now or os.time()
    local delta = now - t
    if delta < 60 then return _("just now") end
    if delta < 3600 then return T(_("%1 min ago"), math.floor(delta / 60)) end
    if delta < DAY then return T(_("%1 h ago"), math.floor(delta / 3600)) end
    local days = math.floor((dayStart(now) - dayStart(t)) / DAY + 0.5)
    if days <= 1 then return _("yesterday") end
    if days < 7 then return BoardData.longWeekday(t) end
    return T(_("%1 %2"), BoardData.shortMonth(t), tonumber(os.date("%d", t)))
end

-- "Late September 2025" for a YYYY-MM-DD date.
function BoardData.partOfMonth(date_key)
    if type(date_key) ~= "string" then return nil end
    local y, m, d = date_key:match("^(%d+)-(%d+)-(%d+)")
    if not y then return nil end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    local month, year = BoardData.longMonth(t), tonumber(y)
    local day = tonumber(d)
    if day <= 10 then return T(_("Early %1 %2"), month, year) end
    if day <= 20 then return T(_("Mid %1 %2"), month, year) end
    return T(_("Late %1 %2"), month, year)
end

-- "Aug 2025": when a book was last read, for books set aside a while.
function BoardData.monthYear(iso)
    if type(iso) ~= "string" then return nil end
    local t = datetime.stringISO8601ToSeconds and datetime.stringISO8601ToSeconds(iso)
    if not t then return nil end
    return T(_("%1 %2"), BoardData.shortMonth(t), tonumber(os.date("%Y", t)))
end

-- Rounded, except that a started book never reads 0% and an unfinished one
-- never reads 100%.
function BoardData.pctLabel(book)
    local p = book and tonumber(book.progressPercentage)
    if not p then return nil end
    if p > 0 and p < 0.5 then return _("<1%") end
    if p < 100 and p >= 99.5 then return "99%" end
    return tostring(math.floor(p + 0.5)) .. "%"
end

-- ------------------------------------------------------- local statistics
local local_cache = { at = 0, day = nil, daily = {} }

function BoardData.localDaily(now)
    now = now or os.time()
    local today = dateKey(now)
    if local_cache.day == today and now - local_cache.at < LOCAL_TTL then
        return local_cache.daily
    end
    local since = dayStart(now) - (BoardData.HEATMAP_DAYS + 7) * DAY
    local daily = StatsReader.getDailySeconds(since) or {}
    local_cache = { at = now, day = today, daily = daily }
    return daily
end

function BoardData.invalidateLocal()
    local_cache = { at = 0, day = nil, daily = {} }
end

-- Minutes per day for the heatmap's 52 weeks, oldest first, from this
-- device's statistics. Days after today are nil. Kept while the statistics
-- read and the day stay the same.
local year_cache = {}
function BoardData.yearMinutes(now)
    now = now or os.time()
    local today = dayStart(now)
    local dow = tonumber(os.date("%w", now)) -- 0 = Sunday
    local last_saturday = today + (6 - dow) * DAY
    local start = last_saturday - (BoardData.HEATMAP_DAYS - 1) * DAY
    local daily = BoardData.localDaily(now)
    if year_cache.daily == daily and year_cache.today == today then
        return year_cache.values, start + 12 * 3600, today
    end
    local values = {}
    for i = 1, BoardData.HEATMAP_DAYS do
        local t = start + (i - 1) * DAY + 12 * 3600
        if t > today + DAY then
            values[i] = nil
        else
            local key = dateKey(t)
            local local_min = (daily[key] or 0) / 60
            values[i] = math.floor(local_min + 0.5)
        end
    end
    year_cache = { daily = daily, today = today, values = values }
    return values, start + 12 * 3600, today
end

-- When the current book ends at this reader's pace, from its own statistics.
local pace_cache = {}
function BoardData.forecast(book, md5, now)
    if not book or not md5 then return nil end
    now = now or os.time()
    local key = md5 .. ":" .. dateKey(now)
    local pace = pace_cache[key]
    if pace == nil then
        pace = StatsReader.getBookPace(md5, 14) or false
        pace_cache[key] = pace
    end
    if not pace or not pace.seconds_per_page or not pace.total_pages or pace.total_pages <= 0 then return nil end
    local progress = (tonumber(book.progressPercentage) or 0) / 100
    local pages_left = math.max(0, pace.total_pages * (1 - progress))
    local minutes_left = pages_left * pace.seconds_per_page / 60
    -- Average over the last two weeks, at least five minutes a day, so a book
    -- read in one sitting does not forecast as finishing today forever.
    local per_day = math.max(5, pace.recent_seconds / 60 / 14)
    local days_out = math.max(0, math.ceil(minutes_left / per_day) - 1)
    local finish = dayStart(now) + days_out * DAY + 12 * 3600
    return {
        book = book,
        minutes_left = minutes_left,
        per_day = per_day,
        days_out = days_out,
        finish = finish,
        day = days_out == 0 and _("Today") or (days_out == 1 and _("Tomorrow") or BoardData.longWeekday(finish)),
        short = BoardData.shortWeekday(finish),
        date = T(_("%1 %2"), tonumber(os.date("%d", finish)), BoardData.shortMonth(finish)),
    }
end

-- When in the day and how long this device reads. Both read the whole recent
-- history, so they are computed only when a widget on screen asks (see
-- BoardData.build) and kept for the day.
local habits_cache = { day = nil }
local function habits(now)
    local today = dateKey(now)
    if habits_cache.day ~= today then habits_cache = { day = today } end
    return habits_cache
end

function BoardData.hours(now)
    now = now or os.time()
    local cache = habits(now)
    if cache.hours == nil then
        cache.hours = StatsReader.getHourMinutes(dayStart(now) - 90 * DAY) or false
    end
    return cache.hours or nil
end

function BoardData.records(now)
    now = now or os.time()
    local cache = habits(now)
    if cache.records == nil then
        local r = StatsReader.getSessionRecords(dayStart(now) - 365 * DAY)
        cache.records = r and {
            sessions = r.sessions,
            longest_min = math.floor(r.longest_seconds / 60 + 0.5),
            avg_min = math.floor(r.average_seconds / 60 + 0.5),
            pages_per_hour = math.floor(r.pages_per_hour + 0.5),
        } or false
    end
    return cache.records or nil
end

function BoardData.invalidateHabits()
    habits_cache = { day = nil }
end

-- ---------------------------------------------------------- vocabulary
local word_cache = { day = nil, word = false }
function BoardData.wordOfTheDay(now)
    now = now or os.time()
    local today = dateKey(now)
    if word_cache.day == today then return word_cache.word or nil end
    local word = false
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    local path = require("datastorage"):getSettingsDir() .. "/vocabulary_builder.sqlite3"
    if ok_sq and require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then
        local ok, conn = pcall(SQ3.open, path, "ro")
        if ok and conn then
            pcall(function()
                local count = tonumber(conn:rowexec("SELECT COUNT(*) FROM vocabulary;")) or 0
                if count > 0 then
                    -- Counted in local days, so the word changes at the
                    -- reader's midnight rather than at UTC midnight.
                    local offset = math.floor((dayStart(now) + 12 * 3600) / DAY) % count
                    local stmt = conn:prepare("SELECT v.word, v.prev_context, v.next_context, t.name FROM vocabulary v"
                        .. " LEFT JOIN title t ON t.id = v.title_id ORDER BY v.create_time LIMIT 1 OFFSET ?;")
                    local row = stmt:reset():bind(offset):step()
                    if row then
                        word = {
                            word = row[1],
                            before = row[2] or "",
                            after = row[3] or "",
                            book = row[4],
                        }
                    end
                    stmt:close()
                end
            end)
            pcall(conn.close, conn)
        end
    end
    word_cache = { day = today, word = word }
    return word or nil
end

-- ----------------------------------------------------------------- light
function BoardData.light()
    if not Device:hasFrontlight() then return nil end
    local powerd = Device:getPowerDevice()
    local light = { brightness = math.floor((powerd:frontlightIntensity() or 0) + 0.5) }
    if Device:hasNaturalLight() then
        light.warmth = math.floor((powerd:frontlightWarmth() or 0) + 0.5)
    end
    return light
end

-- --------------------------------------------------------------- storage
-- Cached like the local statistics: older KOReader releases measure the disk
-- by running df, and the board is rebuilt on every stepper tap.
local storage_cache = { at = 0 }
function BoardData.storage(dir, now)
    if not dir then return nil end
    now = now or os.time()
    if storage_cache.dir == dir and now - storage_cache.at < LOCAL_TTL then return storage_cache.value end
    local ok, usage = pcall(util.diskUsage, dir)
    local value = nil
    if ok and usage and usage.total and usage.total > 0 then
        value = { free_gb = usage.available / 1024 / 1024 / 1024, total_gb = usage.total / 1024 / 1024 / 1024 }
    end
    storage_cache = { at = now, dir = dir, value = value }
    return value
end

-- ------------------------------------------------------------------ decor
-- Every page this device has turned, how many today, and since when.
local turns_cache = { at = 0 }
function BoardData.pageTurns(now)
    now = now or os.time()
    local today = dateKey(now)
    if turns_cache.day == today and now - turns_cache.at < LOCAL_TTL then return turns_cache.value end
    local r = StatsReader.getPageTurns(dayStart(now))
    local value = nil
    if r then
        value = { total = r.total or 0, today = r.today or 0 }
        if r.first then value.since = T(_("%1 %2"), BoardData.shortMonth(r.first), tonumber(os.date("%Y", r.first))) end
    end
    turns_cache = { at = now, day = today, value = value }
    return value
end

-- Minutes read in each of the last twelve calendar months, oldest first,
-- from the year of reading the heatmap draws.
function BoardData.monthTotals(heatmap, heatmap_start, now)
    local sums = {}
    for i = 1, BoardData.HEATMAP_DAYS do
        local v = heatmap and heatmap[i]
        if v and v > 0 then
            local t = os.date("*t", heatmap_start + (i - 1) * DAY)
            local key = t.year * 12 + t.month - 1
            sums[key] = (sums[key] or 0) + v
        end
    end
    local nt = os.date("*t", now)
    local last = nt.year * 12 + nt.month - 1
    local out = {}
    for key = last - 11, last do
        table.insert(out, { month = key % 12 + 1, year = math.floor(key / 12), min = sums[key] or 0 })
    end
    return out
end

-- The month name for a month number, as BoardData.longMonth gives it.
function BoardData.monthName(month, long)
    local t = os.time({ year = 2001, month = month, day = 15, hour = 12 })
    return long and BoardData.longMonth(t) or BoardData.shortMonth(t)
end

-- The moon tonight, from the mean synodic month counted from a known new
-- moon (2000-01-06 18:14 UTC). Good to within about half a day, which is
-- plenty for a picture of it. Drawn as seen from the northern hemisphere.
local SYNODIC = 29.530588853
local NEW_MOON_REF = 947182440
local MOON_PHASES = {
    new = function() return _("New moon") end,
    waxing_crescent = function() return _("Waxing crescent") end,
    first_quarter = function() return _("First quarter") end,
    waxing_gibbous = function() return _("Waxing gibbous") end,
    full = function() return _("Full moon") end,
    waning_gibbous = function() return _("Waning gibbous") end,
    last_quarter = function() return _("Last quarter") end,
    waning_crescent = function() return _("Waning crescent") end,
}
function BoardData.moon(now)
    now = now or os.time()
    local age = ((now - NEW_MOON_REF) / DAY) % SYNODIC
    local p = age / SYNODIC
    local lit = (1 - math.cos(2 * math.pi * p)) / 2
    local phase
    if age < 1.0 or age > 28.5 then phase = "new"
    elseif age < 6.4 then phase = "waxing_crescent"
    elseif age < 8.4 then phase = "first_quarter"
    elseif age < 13.8 then phase = "waxing_gibbous"
    elseif age < 15.8 then phase = "full"
    elseif age < 21.1 then phase = "waning_gibbous"
    elseif age < 23.1 then phase = "last_quarter"
    else phase = "waning_crescent" end
    local to_full = (SYNODIC / 2 - age) % SYNODIC
    local to_new = SYNODIC - age
    local next_full
    if phase == "new" then next_full = true
    elseif phase == "full" then next_full = false
    else next_full = to_full < to_new end
    local when = now + (next_full and to_full or to_new) * DAY
    local day = tonumber(os.date("%d", when))
    return {
        age = age, p = p, lit = lit, phase = phase, name = MOON_PHASES[phase](),
        next = next_full and T(_("Full moon %1 %2 %3"), BoardData.shortWeekday(when), day, BoardData.shortMonth(when))
            or T(_("New moon %1 %2 %3"), BoardData.shortWeekday(when), day, BoardData.shortMonth(when)),
    }
end

-- Characters for the Glyph of the day, each in a font KOReader ships. A
-- device without the font skips that day's glyph for the next one.
BoardData.GLYPHS = {
    { cp = 0x26, name = function() return _("Ampersand") end, font = "NotoSerif-BoldItalic.ttf", label = "Noto Serif Bold Italic", sample = "Aa Bb Cc Dd" },
    { cp = 0x66F8, name = function() return _("Book, to write") end, font = "NotoSansCJKsc-Regular.otf", label = "Noto Sans CJK SC" },
    { cp = 0xB6, name = function() return _("Pilcrow") end, font = "FreeSerif.ttf", label = "FreeSerif", sample = "Aa Bb Cc Dd" },
    { cp = 0x0639, name = function() return _("Ain") end, font = "NotoNaskhArabic-Regular.ttf", label = "Noto Naskh Arabic" },
    { cp = 0xDF, name = function() return _("Sharp s") end, font = "NotoSerif-Italic.ttf", label = "Noto Serif Italic", sample = "Aa Bb Cc Dd" },
    { cp = 0x0915, name = function() return _("Ka") end, font = "NotoSansDevanagariUI-Bold.ttf", label = "Noto Sans Devanagari" },
    { cp = 0xA7, name = function() return _("Section sign") end, font = "NotoSerif-Regular.ttf", label = "Noto Serif", sample = "Aa Bb Cc Dd" },
    { cp = 0x8AAD, name = function() return _("To read") end, font = "NotoSansCJKsc-Regular.otf", label = "Noto Sans CJK SC" },
    { cp = 0x0985, name = function() return _("A, in Bengali") end, font = "NotoSansBengaliUI-Bold.ttf", label = "Noto Sans Bengali" },
    { cp = 0x40, name = function() return _("At sign") end, font = "NotoSans-Bold.ttf", label = "Noto Sans Bold", sample = "Aa Bb Cc Dd" },
    { cp = 0x05D0, name = function() return _("Alef") end, font = "FreeSerif.ttf", label = "FreeSerif" },
    { cp = 0xF0, name = function() return _("Eth") end, font = "NotoSerif-BoldItalic.ttf", label = "Noto Serif Bold Italic", sample = "Aa Bb Cc Dd" },
    { cp = 0x6587, name = function() return _("Writing") end, font = "NotoSansCJKsc-Regular.otf", label = "Noto Sans CJK SC" },
    { cp = 0x03A9, name = function() return _("Omega") end, font = "NotoSerif-Regular.ttf", label = "Noto Serif", sample = "Aa Bb Cc Dd" },
    { cp = 0x0416, name = function() return _("Zhe") end, font = "NotoSans-Bold.ttf", label = "Noto Sans Bold" },
    { cp = 0x017F, name = function() return _("Long s") end, font = "NotoSerif-Italic.ttf", label = "Noto Serif Italic", sample = "Aa Bb Cc Dd" },
}

-- Today's glyph: one a day, in order, counted in the reader's local days.
-- has(font) says whether this device has a font.
function BoardData.glyphOfTheDay(now, has)
    local day = math.floor((dayStart(now or os.time()) + 12 * 3600) / DAY)
    local n = #BoardData.GLYPHS
    for step = 0, n - 1 do
        local g = BoardData.GLYPHS[(day + step) % n + 1]
        if not has or has(g.font) then return g end
    end
    return nil
end

-- The Chapter line for a book: its stops, where the reader is, and how
-- long to each stop at the pace the finish forecast uses.
function BoardData.chapterLine(book, md5)
    if not book or not md5 then return nil end
    local stops = ChapterMap.stations(ChapterMap.load(md5))
    if not stops then return nil end
    local pos = math.max(0, math.min(100, tonumber(book.progressPercentage) or 0))
    local cur = 1
    for i, stop in ipairs(stops) do
        if stop.pct <= pos then cur = i end
    end
    local per_pct = book.minutes_left and book.minutes_left / math.max(0.1, 100 - pos) or nil
    return {
        book = book,
        stops = stops,
        pos = pos,
        cur = cur,
        next = math.min(cur + 1, #stops),
        per_pct = per_pct,
        end_min = book.minutes_left,
        minutes = function(i)
            if not per_pct then return nil end
            return math.max(1, math.floor((stops[i].pct - pos) * per_pct + 0.5))
        end,
    }
end

-- "About 3 weeks to go" for a number of days, or nil when it is too far
-- off to be worth saying.
function BoardData.etaLabel(days)
    if not days or days ~= days or days <= 0 then return nil end
    if days < 1.5 then return _("About a day to go") end
    if days < 10 then return T(_("About %1 days to go"), math.floor(days + 0.5)) end
    if days < 60 then return T(_("About %1 weeks to go"), math.floor(days / 7 + 0.5)) end
    if days < 730 then return T(_("About %1 months to go"), math.floor(days / 30 + 0.5)) end
    return nil
end

-- A small stable number for a book id (a path), to vary its pictures.
function BoardData.seed(id)
    local n = tonumber(id)
    if n then return n end
    n = 0
    for i = 1, #tostring(id or "") do n = (n * 31 + tostring(id):byte(i)) % 1000003 end
    return n + 1
end

-- Books in the home folder that were never opened: not in KOReader's
-- history and without a sidecar, oldest file first. Kept for the day; the
-- list is checked again before a book is shown.
BoardData.UNOPENED_KEEP = 30
local unopened_cache = { key = nil, list = {} }

local function openedFiles()
    local files = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and type(ReadHistory) == "table" and type(ReadHistory.hist) == "table" then
        for _i, item in ipairs(ReadHistory.hist) do
            if type(item) == "table" and item.file then files[item.file] = true end
        end
    end
    return files
end

local function hasSidecar(path)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings then return false end
    local found, has = pcall(DocSettings.hasSidecarFile, DocSettings, path)
    return found and has == true
end
BoardData._hasSidecar = hasSidecar

function BoardData.unopened(books, now)
    now = now or os.time()
    local key = tostring(books) .. "|" .. dateKey(now)
    if unopened_cache.key == key then return unopened_cache.list end
    local list = {}
    for _i, book in ipairs(books or {}) do
        if book.path and book.added then
            table.insert(list, { book = book, path = book.path, at = book.added, size = book.size or 0 })
        end
    end
    table.sort(list, function(a, b) return a.at < b.at end)
    while #list > BoardData.UNOPENED_KEEP do table.remove(list) end
    unopened_cache = { key = key, list = list }
    return list
end

function BoardData.invalidateUnopened()
    unopened_cache = { key = nil, list = {} }
end

-- The Gathering dust widget's book: one unopened book a day, walking the
-- whole list before any repeats; skip steps past books the reader asked to
-- see past today. A book opened since the list was made is passed over.
function BoardData.dust(books, now, skip)
    local pool = BoardData.unopened(books, now)
    if #pool == 0 then return { count = 0 } end
    local bytes = 0
    for _i, entry in ipairs(pool) do bytes = bytes + (entry.size or 0) end
    local day = math.floor((dayStart(now) + 12 * 3600) / DAY)
    local opened = openedFiles()
    for step = 0, #pool - 1 do
        local entry = pool[(day + (skip or 0) + step) % #pool + 1]
        if not opened[entry.path] and not hasSidecar(entry.path) then
            local days = math.max(0, math.floor((now - entry.at) / DAY))
            return { count = #pool, book = entry.book, days = days, months = math.floor(days / 30),
                total_mb = math.max(1, math.floor(bytes / 1024 / 1024 + 0.5)) }
        end
    end
    return { count = 0 }
end

-- ------------------------------------------------------------------ build
local decorated_cache = {}

-- view: the dashboard view (for its settings).
-- context: the dashboard context (the body from dashboard_library).
function BoardData.build(view, context, now)
    now = now or os.time()
    context = context or {}
    local body = context.dashboard or {}
    local settings = view and view.settings or {}
    local d = {}
    d.now = now
    d.loading = context.dashboard == nil
    d.unavailable = false
    -- Everything the board shows is on this device, so it is never offline.
    d.online = true
    d.wifi = NetworkMgr:isWifiOn()
    d.stale = false
    d.display_name = settings.name
    d.greeting = BoardData.greeting(d.display_name, now)
    d.date_long = BoardData.longDate(now)
    d.clock = datetime.secondsToHour(now, G_reader_settings:isTrue("twelve_hour_clock"))
    d.weekday = BoardData.longWeekday(now)
    d.day_month = T(_("%1 %2"), tonumber(os.date("%d", now)), BoardData.longMonth(now))

    local function decorate(book)
        if type(book) ~= "table" then return nil end
        local b = {}
        for k, v in pairs(book) do b[k] = v end
        b.on_device = book.path ~= nil
        b.last_read = BoardData.relativeDay(book.lastReadAt, now)
        local path, state = Library.cover(book)
        b.cover_path, b.cover_state = path, state
        return b
    end
    local function decorateAll(list)
        local out = {}
        for _i, book in ipairs(type(list) == "table" and list or {}) do
            local b = decorate(book)
            if b then table.insert(out, b) end
        end
        return out
    end

    -- The decorated lists stay the same while the body, what is known about
    -- the books, their covers and the minute ("5 min ago") do. A page flip
    -- builds this data only to check the cached pages are current, so it
    -- reuses them.
    local lists_key = table.concat({ tostring(body), Library.books_version or 0, Library.cover_version or 0,
        math.floor(now / 60) }, "|")
    local lists = decorated_cache.key == lists_key and decorated_cache.lists or nil
    if not lists then
        lists = { continue_reading = decorateAll(body.continueReading), shelves = {} }
        local shelves = type(body.boardShelves) == "table" and body.boardShelves or {}
        for source, books in pairs(shelves) do
            -- The never-opened list is the dust widget's pool: no covers needed.
            lists.shelves[source] = source == "unopened" and books or decorateAll(books)
        end
        lists.shelves["random"] = lists.shelves["random"] or decorateAll(body.discover)
        lists.shelves["in-progress"] = lists.shelves["in-progress"] or decorateAll(body.continueReading)
        lists.shelves["finished"] = decorateAll(body.finishedThisYear)
        decorated_cache = { key = lists_key, lists = lists }
    end
    d.continue_reading = lists.continue_reading
    d.shelves = {}
    for source, books in pairs(lists.shelves) do d.shelves[source] = books end

    local counts = type(body.browseCounts) == "table" and body.browseCounts or {}
    d.counts = {
        library = tonumber(body.totalBooks),
        series = tonumber(counts.series),
        authors = tonumber(counts.authors),
        collections = tonumber(counts.collections),
        in_progress = tonumber(counts.inProgress),
        history = #d.continue_reading,
        device = tonumber(body.totalBooks),
    }
    d.names = type(body.boardNames) == "table" and body.boardNames or {}
    d.recent_searches = {}

    local goal = type(body.readingGoal) == "table" and body.readingGoal or {}
    d.goal = {
        books = tonumber(goal.goalBooks),
        done = tonumber(goal.completedBooks) or 0,
        year = tonumber(goal.year) or tonumber(os.date("%Y", now)),
    }
    d.day_of_year = tonumber(os.date("%j", now)) or 1

    local streak = type(body.readingStreak) == "table" and body.readingStreak or {}
    d.streak = {
        current = tonumber(streak.currentStreak) or 0,
        longest = tonumber(streak.longestStreak) or 0,
        last_seven = type(streak.lastSevenDays) == "table" and streak.lastSevenDays or {},
    }
    d.highlight = type(body.highlightOfTheDay) == "table" and body.highlightOfTheDay or nil

    d.heatmap, d.heatmap_start, d.today_start = BoardData.yearMinutes(now)
    local week = {}
    local today_index = nil
    for i = 1, BoardData.HEATMAP_DAYS do
        if d.heatmap[i] ~= nil then today_index = i end
    end
    today_index = today_index or BoardData.HEATMAP_DAYS
    for i = 1, 7 do week[i] = d.heatmap[today_index - 7 + i] or 0 end
    d.week = week
    d.week_initials = {}
    for i = 1, 7 do
        local t = now - (7 - i) * DAY
        d.week_initials[i] = BoardData.shortWeekday(t):sub(1, 1)
    end
    d.today_min = week[7]
    d.week_min = 0
    for _i, v in ipairs(week) do d.week_min = d.week_min + v end
    if d.streak.current == 0 and d.today_min > 0 then d.streak.current = 1 end
    d.streak_week = {}
    for i = 1, 7 do d.streak_week[i] = (week[i] or 0) > 0 or d.streak.last_seven[i] == true end

    local year_ago = type(body.yearAgo) == "table" and body.yearAgo or nil
    if year_ago and type(year_ago.book) == "table" then
        d.year_ago = {
            book = decorate(year_ago.book),
            minutes = tonumber(year_ago.minutes) or 0,
            days = tonumber(year_ago.days) or 0,
            stopped_at = tonumber(year_ago.endProgress) and math.floor(tonumber(year_ago.endProgress) + 0.5) or nil,
            when = BoardData.partOfMonth(year_ago.firstDay),
        }
    end

    d.word = BoardData.wordOfTheDay(now)
    d.light = BoardData.light()
    d.storage = BoardData.storage(Library.homeDir(), now)

    local lead = d.continue_reading[1]
    local lead_md5 = nil
    if lead and lead.on_device then
        lead_md5 = Library.md5(lead)
        d.forecast = BoardData.forecast(lead, lead_md5, now)
        -- Set every build: the decorated lead is shared while its lists are.
        lead.minutes_left = d.forecast and d.forecast.minutes_left or nil
    end
    -- Everything a widget's layout choice can depend on. Widgets remember
    -- their choice per fingerprint (see BoardUI.pick).
    local covers = {}
    for _i, b in ipairs(d.continue_reading) do table.insert(covers, (b.cover_state or "") .. (b.on_device and "d" or "")) end
    d.fingerprint = table.concat({
        tostring(body.generatedAt), tostring(body), tostring(d.wifi), dateKey(now),
        d.light and (d.light.brightness .. "/" .. tostring(d.light.warmth)) or "-",
        d.today_min, d.week_min, d.streak.current, d.counts.device or 0,
        d.word and d.word.word or "-", d.forecast and math.floor(d.forecast.minutes_left) or "-",
        table.concat(covers, ","), tostring(G_reader_settings:isTrue("night_mode")), d.loading and "l" or "",
    }, "|")
    -- Hours, records and the decor widgets' data cost a pass over the
    -- device's statistics or its files, so they are read only by a widget
    -- that draws them.
    local lazy = {
        hours = function() return BoardData.hours(now) end,
        records = function() return BoardData.records(now) end,
        pages = function() return BoardData.pageTurns(now) end,
        months = function() return BoardData.monthTotals(d.heatmap, d.heatmap_start, now) end,
        moon = function() return BoardData.moon(now) end,
        glyph = function()
            return BoardData.glyphOfTheDay(now, function(font) return require("dashboard_board_art").hasFont(font) end)
        end,
        chapters = function() return BoardData.chapterLine(lead, lead_md5) end,
        dust = function()
            local state = settings.board_dust
            local skip = type(state) == "table" and state.day == dateKey(now) and tonumber(state.skip) or 0
            return BoardData.dust(d.shelves["unopened"], now, skip)
        end,
        -- The day a book was marked finished, never when it was last opened:
        -- a reread opens a finished book.
        finished_today = function()
            local today = dateKey(now)
            for _i, book in ipairs(d.shelves["finished"] or {}) do
                if book.finishedOn == today then return book end
            end
            return false
        end,
    }
    return setmetatable(d, { __index = function(t, k)
        local fn = lazy[k]
        if fn then
            local ok, v = pcall(fn)
            if not ok then
                require("logger").warn("Dashboard: board data", k, "failed:", v)
                v = nil
            end
            v = v or false
            rawset(t, k, v)
            return v
        end
    end })
end

return BoardData
