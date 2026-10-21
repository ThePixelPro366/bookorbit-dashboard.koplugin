--[[--
The reader's library as the dashboard sees it, built from KOReader alone.

Books are the files under KOReader's home folder (plus anything in the
reading history that lives elsewhere). What is known about each one comes
from places KOReader already keeps: the book's sidecar (progress, status,
rating, highlights, metadata), the reading history (when it was last opened),
CoverBrowser's book info cache (metadata and covers of books never opened),
collections, and statistics.sqlite3. A book none of those know yet is opened
once by the extractor, one book at a time between paints, for its metadata
and its cover; both are cached under cache/bookorbitdashboard.

body() returns the dashboard body the board widgets read: continue reading,
the shelves, counts, the reading goal and streak, a highlight of the day and
what was being read a year ago.
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local util = require("util")

local StatsReader = require("dashboard_stats_reader")

local Library = {}

local DAY = 86400
-- A walk of the home folder is kept this long unless something invalidates
-- it first (a book closing, a file operation in the file browser).
local SCAN_TTL = 15 * 60
Library.SCAN_MAX = 5000
local SCAN_DEPTH = 10
local SHELF_MAX = 12

-- ------------------------------------------------------------------ files
function Library.homeDir()
    local home = G_reader_settings:readSetting("home_dir")
    if home and lfs.attributes(home, "mode") == "directory" then return home end
    local Device = require("device")
    home = Device.home_dir
    if home and lfs.attributes(home, "mode") == "directory" then return home end
    return lfs.currentdir()
end

local scan = { at = 0, home = nil, files = {}, generation = 0 }

local function walk(dir, depth, out)
    if depth > SCAN_DEPTH or #out >= Library.SCAN_MAX then return end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then return end
    local subdirs = {}
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr then
                if attr.mode == "directory" then
                    table.insert(subdirs, path)
                elseif attr.mode == "file" and DocumentRegistry:hasProvider(path) then
                    table.insert(out, { path = path, mtime = attr.modification or 0, size = attr.size or 0 })
                    if #out >= Library.SCAN_MAX then return end
                end
            end
        end
    end
    for _i, sub in ipairs(subdirs) do walk(sub, depth + 1, out) end
end

-- Every book file under the home folder, newest file first.
function Library.files(now)
    now = now or os.time()
    local home = Library.homeDir()
    if scan.home == home and now - scan.at < SCAN_TTL then return scan.files, scan.generation end
    local files = {}
    walk(home, 1, files)
    table.sort(files, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return a.path < b.path
    end)
    scan = { at = now, home = home, files = files, generation = scan.generation + 1 }
    return files, scan.generation
end

function Library.invalidate()
    scan.at = 0
    Library.invalidateBooks()
end

-- ---------------------------------------------------------------- history
local function history()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or type(ReadHistory) ~= "table" then return {} end
    if ReadHistory.reload then pcall(ReadHistory.reload, ReadHistory) end
    return type(ReadHistory.hist) == "table" and ReadHistory.hist or {}
end

-- ------------------------------------------------------------------ books
local book_cache = {}
-- Covers already found on disk, by path: { file, added }.
local cover_found = {}

function Library.invalidateBooks(path)
    if path then
        book_cache[path] = nil
    else
        book_cache = {}
    end
    -- A custom cover set or cleared in Book information is seen next time.
    if path then cover_found[path] = nil else cover_found = {} end
end

local bim_loaded, bim = false, nil
local function bookInfoManager()
    if not bim_loaded then
        bim_loaded = true
        local ok, mod = pcall(require, "bookinfomanager")
        bim = ok and mod or nil
    end
    return bim
end

local function splitAuthors(authors)
    local out = {}
    if type(authors) ~= "string" then return out end
    for a in authors:gmatch("[^\n]+") do
        a = util.trim(a)
        if a ~= "" then table.insert(out, a) end
    end
    return out
end

local function titleFromPath(path)
    local name = path:gsub(".*/", ""):gsub("%.[^%.]+$", "")
    return (name:gsub("_", " "))
end

local function iso(t)
    return t and os.date("!%Y-%m-%dT%H:%M:%SZ", t) or nil
end
Library.iso = iso

local STATUS = { reading = "reading", complete = "finished", abandoned = "abandoned" }

-- One book, as the board widgets expect it. last_open is the reading
-- history's time for the file, when it has one.
function Library.book(path, last_open, attr)
    local cached = book_cache[path]
    if cached and cached.last_open == last_open then return cached.book end
    attr = attr or lfs.attributes(path) or {}
    local props
    local sidecar = DocSettings:hasSidecarFile(path)
    local doc_settings = sidecar and DocSettings:open(path) or nil
    if doc_settings then
        props = doc_settings:readSetting("doc_props")
        local custom = DocSettings:findCustomMetadataFile(path)
        if custom then
            local custom_props = DocSettings.openSettingsFile(custom):readSetting("custom_props")
            if type(custom_props) == "table" then
                props = props and util.tableDeepCopy(props) or {}
                for k, v in pairs(custom_props) do props[k] = v end
            end
        end
    end
    if not props then
        local manager = bookInfoManager()
        if manager then
            local ok, info = pcall(manager.getDocProps, manager, path)
            if ok and info and (info.title or info.authors) then props = info end
        end
    end
    if not props then
        local known = Library.meta(path, attr.modification)
        if known then
            props = known
        else
            Library.queue(path, false)
        end
    end
    props = props or {}
    local book = {
        id = path,
        path = path,
        title = (type(props.title) == "string" and props.title ~= "") and props.title or titleFromPath(path),
        authors = splitAuthors(props.authors),
        seriesName = type(props.series) == "string" and props.series ~= "" and props.series or nil,
        seriesIndex = tonumber(props.series_index),
        addedAt = iso(attr.modification),
        added = attr.modification or 0,
        size = attr.size or 0,
        opened = sidecar,
        readStatus = sidecar and "reading" or "unread",
    }
    if book.seriesName then
        -- KOReader may keep "Name #3" in the series field.
        local name, index = book.seriesName:match("^(.-)%s*#%s*([%d%.]+)%s*$")
        if name and name ~= "" then
            book.seriesName = name
            book.seriesIndex = book.seriesIndex or tonumber(index)
        end
    end
    if doc_settings then
        local pct = tonumber(doc_settings:readSetting("percent_finished"))
        if pct then book.progressPercentage = math.max(0, math.min(100, pct * 100)) end
        local summary = doc_settings:readSetting("summary") or {}
        book.readStatus = STATUS[summary.status] or "reading"
        book.rating = tonumber(summary.rating)
        if book.readStatus == "finished" then
            book.finishedOn = type(summary.modified) == "string" and summary.modified or nil
            book.progressPercentage = 100
        end
        book.partial_md5 = doc_settings:readSetting("partial_md5_checksum")
        local annotations = doc_settings:readSetting("annotations")
        book.annotation_count = type(annotations) == "table" and #annotations or 0
    end
    if last_open then
        book.last_open = last_open
        book.lastReadAt = iso(last_open)
    end
    book_cache[path] = { last_open = last_open, book = book }
    return book
end

-- The partial md5 KOReader's statistics key a book by.
function Library.md5(book)
    if not book then return nil end
    if book.partial_md5 then return book.partial_md5 end
    if book.md5_checked then return book.md5 end
    book.md5_checked = true
    book.md5 = util.partialMD5(book.path)
    return book.md5
end

-- --------------------------------------------------- metadata and covers
local cache_dir
local function cacheDir()
    if not cache_dir then
        cache_dir = DataStorage:getDataDir() .. "/cache/bookorbitdashboard"
        util.makePath(cache_dir .. "/covers")
    end
    return cache_dir
end

local COVER_MAX_H = 480
local COVER_MIN_H = 300

local function coverFile(path)
    return cacheDir() .. "/covers/" .. md5(path) .. ".png"
end

-- What the extractor learnt about books nobody else knows yet, by path:
-- title, authors, series, series_index, the file's mtime then, and whether
-- it has a cover. Kept in one file, written a moment after the last change.
local meta_store = nil
local meta_dirty = false

local function metaFile()
    return cacheDir() .. "/books.lua"
end

local function metaStore()
    if meta_store then return meta_store end
    local ok, data = pcall(dofile, metaFile())
    meta_store = ok and type(data) == "table" and data or {}
    return meta_store
end

local function saveMeta()
    if not meta_dirty then return end
    meta_dirty = false
    local tmp = metaFile() .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write("return " .. require("dump")(metaStore()))
    f:close()
    os.rename(tmp, metaFile())
end

function Library.meta(path, mtime)
    local entry = metaStore()[path]
    if entry and (not mtime or entry.mtime == mtime) then return entry end
end

local function writeCover(bb, file)
    if not bb then return false end
    local w, h = bb:getWidth(), bb:getHeight()
    if w <= 0 or h <= 0 then return false end
    local out = bb
    if h > COVER_MAX_H then
        local RenderImage = require("ui/renderimage")
        out = RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(w * COVER_MAX_H / h + 0.5)), COVER_MAX_H, false)
    end
    local ok = pcall(out.writePNG, out, file)
    if out ~= bb then out:free() end
    return ok and lfs.attributes(file, "mode") == "file"
end

-- Opens one book for its metadata and its cover. CoverBrowser's cache is
-- asked first for the cover, so a book it already indexed with a cover big
-- enough for a tile is not opened just for that (its mosaic thumbnails are
-- far too small).
function Library.extract(path, want_cover)
    local attr = lfs.attributes(path)
    if not attr then return end
    local file = coverFile(path)
    local entry = { mtime = attr.modification }
    local have_cover = false
    local manager = bookInfoManager()
    if want_cover and manager then
        local ok, info = pcall(manager.getBookInfo, manager, path, true)
        if ok and info and info.cover_bb then
            if info.cover_bb:getHeight() >= COVER_MIN_H then
                have_cover = writeCover(info.cover_bb, file)
            end
            info.cover_bb:free()
        end
    end
    local doc = DocumentRegistry:openDocument(path)
    if doc then
        local loaded = true
        if doc.loadDocument then loaded = doc:loadDocument(false) end
        if loaded then
            local ok, props = pcall(doc.getProps, doc)
            if ok and type(props) == "table" then
                entry.title = props.title
                entry.authors = props.authors
                entry.series = props.series
                entry.series_index = props.series_index
            end
            if want_cover and not have_cover then
                local got, bb = pcall(doc.getCoverPageImage, doc)
                if got and bb then
                    have_cover = writeCover(bb, file)
                    bb:free()
                end
            end
        end
        doc:close()
    end
    entry.nocover = want_cover and not have_cover or nil
    metaStore()[path] = entry
    meta_dirty = true
    Library.invalidateBooks(path)
end

-- The extractor's queue: covers first (something on screen waits for
-- them), then books whose metadata is unknown. One book per step. Opening a
-- book takes a while on an e-reader, so metadata-only work waits until the
-- reader has left the screen alone for a few seconds, and goes slowly.
local queue, queued = {}, {}
local running = false
local IDLE_DELAY = 4
local quiet_until = 0
-- Called (debounced) when the extractor learnt something new: with
-- "covers" when only covers arrived, "books" when metadata did (which can
-- change shelves and counts).
Library.on_update = nil
-- Bumped with each new cover, so cached pages drawn without it are redrawn.
Library.cover_version = 0

-- The reader touched the screen: background metadata work holds off.
function Library.busy()
    quiet_until = os.time() + IDLE_DELAY
end

local pending = { covers = false, books = false, task = nil }
local function notify(kind)
    pending[kind] = true
    if pending.task then return end
    pending.task = function()
        pending.task = nil
        saveMeta()
        local what = pending.books and "books" or "covers"
        pending.covers, pending.books = false, false
        if Library.on_update then Library.on_update(what) end
    end
    UIManager:scheduleIn(kind == "covers" and 1.5 or 2, pending.task)
end

local function runQueue()
    if running then return end
    running = true
    local function step()
        local job = queue[1]
        if not job then
            running = false
            if meta_dirty then notify("books") end
            return
        end
        if not job.cover and os.time() < quiet_until then
            return UIManager:scheduleIn(IDLE_DELAY, step)
        end
        table.remove(queue, 1)
        queued[job.path] = nil
        local ok, err = pcall(Library.extract, job.path, job.cover)
        if not ok then
            logger.dbg("Dashboard: could not read", job.path, err)
            metaStore()[job.path] = { mtime = lfs.attributes(job.path, "modification"), nocover = true, failed = true }
            meta_dirty = true
        end
        if job.cover then
            Library.cover_version = Library.cover_version + 1
            notify("covers")
        end
        -- Metadata-only books are told about once the queue is empty, in one
        -- reload rather than one per book.
        UIManager:scheduleIn(job.cover and 0.05 or 0.5, step)
    end
    UIManager:scheduleIn(0.3, step)
end

function Library.queue(path, cover)
    local job = queued[path]
    if job then
        if cover and not job.cover then
            job.cover = true
            for i, j in ipairs(queue) do
                if j == job then table.remove(queue, i); break end
            end
            table.insert(queue, 1, job)
        end
        return
    end
    job = { path = path, cover = cover }
    queued[path] = job
    if cover then table.insert(queue, 1, job) else table.insert(queue, job) end
    runQueue()
end

-- The cover image to draw for a book, and its state: a path when the cover
-- is cached, "loading" while it waits its turn, nil when the book has none.
-- A found cover is remembered, so a redraw does not look for it again.
function Library.cover(book)
    local path = book and book.path
    if not path then return nil, nil end
    local found = cover_found[path]
    if found and found.added == book.added then return found.file, "ready" end
    local custom = DocSettings:findCustomCoverFile(path)
    local file = custom
    if not file then
        file = coverFile(path)
        local mtime = lfs.attributes(file, "modification")
        if not (mtime and mtime >= (book.added or 0)) then file = nil end
    end
    if file then
        cover_found[path] = { file = file, added = book.added }
        return file, "ready"
    end
    local known = Library.meta(path, book.added)
    if known and known.nocover then return nil, nil end
    Library.queue(path, true)
    return nil, "loading"
end

-- -------------------------------------------------------------- the body
local function dayStart(t)
    local d = os.date("*t", t)
    d.hour, d.min, d.sec = 0, 0, 0
    return os.time(d)
end

local function dateKey(t)
    return os.date("%Y-%m-%d", t)
end

-- A list in a fixed order for the day: the same picks all day, new ones
-- tomorrow, more with each shuffle.
local function dailyShuffle(list, seed)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    local x = seed % 2147483647
    if x <= 0 then x = x + 2147483646 end
    for i = #out, 2, -1 do
        x = (x * 16807) % 2147483647
        local j = x % i + 1
        out[i], out[j] = out[j], out[i]
    end
    return out
end

local function take(list, n)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

local function collections()
    local ok, ReadCollection = pcall(require, "readcollection")
    if not ok or type(ReadCollection) ~= "table" then return {}, nil end
    pcall(ReadCollection._read, ReadCollection)
    return ReadCollection.coll or {}, ReadCollection
end

-- Collection names in the reader's own order.
function Library.collectionNames()
    local coll, ReadCollection = collections()
    local names = {}
    for name in pairs(coll) do table.insert(names, name) end
    local settings = ReadCollection and ReadCollection.coll_settings or {}
    table.sort(names, function(a, b)
        local oa = settings[a] and settings[a].order or math.huge
        local ob = settings[b] and settings[b].order or math.huge
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    return names
end

function Library.collectionDisplayName(name)
    local ok, ReadCollection = pcall(require, "readcollection")
    if ok and name == ReadCollection.default_collection_name then
        return require("gettext")("Favorites")
    end
    return name
end

-- Every book the dashboard knows: the home folder plus history entries that
-- live elsewhere. Returns the list, a path index and the history times.
function Library.all(now)
    local files, generation = Library.files(now)
    local hist = history()
    local last_open = {}
    for _i, item in ipairs(hist) do
        if type(item) == "table" and item.file and not last_open[item.file] then
            last_open[item.file] = tonumber(item.time)
        end
    end
    local books, by_path = {}, {}
    for _i, f in ipairs(files) do
        local book = Library.book(f.path, last_open[f.path], { modification = f.mtime, size = f.size })
        table.insert(books, book)
        by_path[f.path] = book
    end
    for _i, item in ipairs(hist) do
        local path = type(item) == "table" and item.file
        if path and not by_path[path] and lfs.attributes(path, "mode") == "file" then
            local book = Library.book(path, last_open[path])
            table.insert(books, book)
            by_path[path] = book
        end
    end
    return books, by_path, hist, generation
end

local streak_cache = { day = nil, at = 0 }

-- Streaks from this device's statistics: days in a row with any reading
-- (still counting when today has none yet), the longest run in the last
-- year, and which of the last seven days had reading. Kept two minutes.
function Library.streak(now)
    now = now or os.time()
    local today = dayStart(now)
    if streak_cache.day == today and now - streak_cache.at < 120 then return streak_cache.value end
    local daily = StatsReader.getDailySeconds(today - 400 * DAY) or {}
    local function read(t) return (daily[dateKey(t + 12 * 3600)] or 0) >= 60 end
    local current = 0
    local cursor = today
    if not read(cursor) then cursor = cursor - DAY end
    while read(cursor) do
        current = current + 1
        cursor = cursor - DAY
    end
    local longest, run = 0, 0
    for i = 400, 0, -1 do
        if read(today - i * DAY) then
            run = run + 1
            if run > longest then longest = run end
        else
            run = 0
        end
    end
    local last_seven = {}
    for i = 1, 7 do last_seven[i] = read(today - (7 - i) * DAY) end
    local value = { currentStreak = current, longestStreak = math.max(longest, current), lastSevenDays = last_seven }
    streak_cache = { day = today, at = now, value = value }
    return value
end

-- One highlight a day from the books in the history: every highlight with
-- text, in a fixed order, walked one step per local day.
local highlight_cache = { day = nil }
function Library.highlightOfTheDay(books, now)
    local today = dateKey(now)
    if highlight_cache.day == today then return highlight_cache.value end
    local pool = {}
    for _i, book in ipairs(books) do
        if book.opened and (book.annotation_count or 0) > 0 then
            local ok, doc_settings = pcall(DocSettings.open, DocSettings, book.path)
            local annotations = ok and doc_settings and doc_settings:readSetting("annotations") or {}
            for _j, a in ipairs(annotations) do
                if type(a) == "table" and type(a.text) == "string" and #a.text > 20 and #a.text < 600 then
                    table.insert(pool, { text = util.trim(a.text:gsub("%s+", " ")), bookTitle = book.title,
                        chapterTitle = a.chapter, book = book, key = book.path .. "|" .. tostring(a.datetime) })
                end
            end
        end
    end
    table.sort(pool, function(a, b) return a.key < b.key end)
    local value = nil
    if #pool > 0 then
        local day = math.floor((dayStart(now) + 12 * 3600) / DAY)
        value = pool[day % #pool + 1]
    end
    highlight_cache = { day = today, value = value }
    return value
end

-- What was being read a year ago, give or take a week.
local year_ago_cache = { day = nil }
function Library.yearAgo(by_md5, now)
    local today = dateKey(now)
    if year_ago_cache.day == today then return year_ago_cache.value end
    local centre = dayStart(now) - 365 * DAY
    local r = StatsReader.getMostReadBetween(centre - 7 * DAY, centre + 8 * DAY)
    local value = nil
    if r and r.seconds >= 300 then
        local book = by_md5[r.md5] or {
            id = "stats:" .. r.md5, title = r.title or "", authors = splitAuthors(r.authors),
        }
        value = {
            book = book,
            minutes = math.floor(r.seconds / 60 + 0.5),
            days = r.days,
            endProgress = r.end_pct,
            firstDay = r.first and dateKey(r.first) or nil,
        }
    end
    year_ago_cache = { day = today, value = value }
    return value
end

-- The next unread book of each series the reader has started.
local function upNext(books)
    local series = {}
    for _i, b in ipairs(books) do
        if b.seriesName then
            local key = b.seriesName:lower()
            local s = series[key]
            if not s then
                s = { books = {}, read_to = nil, last = 0 }
                series[key] = s
            end
            table.insert(s.books, b)
            if b.readStatus == "finished" or b.readStatus == "reading" then
                local idx = b.seriesIndex or 0
                if not s.read_to or idx > s.read_to then s.read_to = idx end
                s.last = math.max(s.last, b.last_open or 0)
            end
        end
    end
    local out = {}
    for _key, s in pairs(series) do
        if s.read_to then
            local best
            for _i, b in ipairs(s.books) do
                if b.readStatus == "unread" and (b.seriesIndex or math.huge) > s.read_to then
                    if not best or (b.seriesIndex or math.huge) < (best.seriesIndex or math.huge) then best = b end
                end
            end
            if best then table.insert(out, { book = best, last = s.last }) end
        end
    end
    table.sort(out, function(a, b) return a.last > b.last end)
    local list = {}
    for _i, e in ipairs(out) do table.insert(list, e.book) end
    return list
end

local function sortedBy(list, key, desc)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    table.sort(out, function(a, b)
        local x, y = a[key] or 0, b[key] or 0
        if x ~= y then
            if desc then return x > y end
            return x < y
        end
        return a.path < b.path
    end)
    return out
end

-- The books of one shelf, for a "See all" list and for the board.
-- source is a shelf source; params narrows a picked shelf (a collection,
-- an author or a series).
function Library.shelfBooks(source, params, books, now, opts)
    opts = opts or {}
    now = now or os.time()
    params = params or {}
    if source == "collection" then
        local coll = collections()[params.name] or {}
        local list = {}
        local by_path = opts.by_path or {}
        for path, item in pairs(coll) do
            local b = by_path[path] or (lfs.attributes(path, "mode") == "file" and Library.book(path)) or nil
            if b then table.insert(list, { book = b, order = item.order or 0 }) end
        end
        table.sort(list, function(a, b) return a.order < b.order end)
        local out = {}
        for _i, e in ipairs(list) do table.insert(out, e.book) end
        return out
    elseif source == "author" then
        local out = {}
        for _i, b in ipairs(books) do
            for _j, a in ipairs(b.authors) do
                if a == params.name then table.insert(out, b); break end
            end
        end
        table.sort(out, function(a, b) return a.title < b.title end)
        return out
    elseif source == "series" then
        local out = {}
        for _i, b in ipairs(books) do
            if b.seriesName == params.name then table.insert(out, b) end
        end
        table.sort(out, function(a, b) return (a.seriesIndex or math.huge) < (b.seriesIndex or math.huge) end)
        return out
    elseif source == "recently-added" then
        return sortedBy(books, "added", true)
    elseif source == "in-progress" then
        local out = {}
        for _i, b in ipairs(sortedBy(books, "last_open", true)) do
            if b.readStatus == "reading" and b.last_open then table.insert(out, b) end
        end
        return out
    elseif source == "pick-back-up" then
        -- Started, then left alone for more than a week (or put on hold).
        local out = {}
        for _i, b in ipairs(sortedBy(books, "last_open", true)) do
            if b.last_open and ((b.readStatus == "reading" and now - b.last_open > 7 * DAY) or b.readStatus == "abandoned") then
                table.insert(out, b)
            end
        end
        return out
    elseif source == "finished" then
        local year = os.date("%Y", now)
        local out = {}
        for _i, b in ipairs(books) do
            if b.readStatus == "finished" and b.finishedOn and b.finishedOn:sub(1, 4) == year then table.insert(out, b) end
        end
        table.sort(out, function(a, b) return a.finishedOn > b.finishedOn end)
        return out
    elseif source == "want-to-read" then
        -- KOReader's Favorites collection, minus what is finished.
        local ok, ReadCollection = pcall(require, "readcollection")
        local name = ok and ReadCollection.default_collection_name or "favorites"
        local out = {}
        for _i, b in ipairs(Library.shelfBooks("collection", { name = name }, books, now, opts)) do
            if b.readStatus ~= "finished" then table.insert(out, b) end
        end
        return out
    elseif source == "up-next-in-series" then
        return upNext(books)
    elseif source == "unopened" then
        local out = {}
        for _i, b in ipairs(books) do
            if not b.opened and not b.last_open then table.insert(out, b) end
        end
        return out
    elseif source == "all" then
        local out = {}
        for i, b in ipairs(books) do out[i] = b end
        table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
        return out
    end
    -- "random": a daily shuffle of the books not finished, unread first.
    local unread, rest = {}, {}
    for _i, b in ipairs(books) do
        if b.readStatus == "unread" then table.insert(unread, b)
        elseif b.readStatus ~= "finished" then table.insert(rest, b) end
    end
    local seed = math.floor(dayStart(now) / DAY) * 7919 + (opts.shuffle or 0) * 104729 + 1
    local out = dailyShuffle(unread, seed)
    for _i, b in ipairs(dailyShuffle(rest, seed + 1)) do table.insert(out, b) end
    return out
end

local function shelfKey(props)
    return require("dashboard_board_store").shelfKey(props)
end

-- The dashboard body. opts.sources are the shelves some widget on the board
-- draws (key -> props); opts.goal the yearly goal in books; opts.shuffle how
-- many times Discover was shuffled today.
function Library.body(now, opts)
    now = now or os.time()
    opts = opts or {}
    local books, by_path = Library.all(now)
    local body = { generatedAt = iso(now), totalBooks = #books }

    -- Continue reading: the history, newest first, while the book is being read.
    local continue = {}
    for _i, b in ipairs(sortedBy(books, "last_open", true)) do
        if b.last_open and b.readStatus == "reading" then
            table.insert(continue, b)
            if #continue >= 10 then break end
        end
    end
    body.continueReading = continue

    local shelves = {}
    local wanted = opts.sources or {}
    wanted["random"] = wanted["random"] or { source = "random" }
    wanted["recently-added"] = wanted["recently-added"] or { source = "recently-added" }
    wanted["unopened"] = wanted["unopened"] or { source = "unopened" }
    wanted["finished"] = wanted["finished"] or { source = "finished" }
    wanted["up-next-in-series"] = wanted["up-next-in-series"] or { source = "up-next-in-series" }
    for key, props in pairs(wanted) do
        local list = Library.shelfBooks(props.source, props.params, books, now, { by_path = by_path, shuffle = opts.shuffle })
        shelves[key] = key == "unopened" and list or take(list, SHELF_MAX)
    end
    body.boardShelves = shelves
    body.finishedThisYear = Library.shelfBooks("finished", nil, books, now)
    body.discover = shelves["random"]

    local authors, series, in_progress = {}, {}, 0
    local n_authors, n_series = 0, 0
    for _i, b in ipairs(books) do
        for _j, a in ipairs(b.authors) do
            if not authors[a] then authors[a] = true; n_authors = n_authors + 1 end
        end
        if b.seriesName and not series[b.seriesName] then series[b.seriesName] = true; n_series = n_series + 1 end
        if b.readStatus == "reading" and b.last_open then in_progress = in_progress + 1 end
    end
    local coll_names = Library.collectionNames()
    local display = {}
    for _i, name in ipairs(coll_names) do table.insert(display, Library.collectionDisplayName(name)) end
    body.browseCounts = {
        authors = n_authors,
        series = n_series,
        collections = #coll_names,
        inProgress = in_progress,
    }
    body.boardNames = { collections = take(display, 4) }

    body.readingGoal = {
        goalBooks = tonumber(opts.goal),
        completedBooks = #body.finishedThisYear,
        year = tonumber(os.date("%Y", now)),
    }
    body.readingStreak = Library.streak(now)
    body.highlightOfTheDay = Library.highlightOfTheDay(books, now)

    local by_md5 = {}
    for _i, b in ipairs(books) do
        if b.partial_md5 then by_md5[b.partial_md5] = b end
    end
    body.yearAgo = Library.yearAgo(by_md5, now)
    body._books = books
    body._by_path = by_path
    return body
end

return Library
