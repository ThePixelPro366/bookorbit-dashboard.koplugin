--[[--
Read-only access to KOReader's statistics.sqlite3, for the dashboard.

Each helper opens a short-lived connection, runs its queries in autocommit
and closes it again, so the statistics plugin's writes and WAL checkpointing
are never blocked. The statistics plugin owns all writes to this database.
]]

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local unpack = table.unpack or unpack

local StatsReader = {}

local BUSY_TIMEOUT_MS = 1000
-- One cached statement per shape, bounded.
local MAX_CACHED_STATEMENTS = 16

local BOOK_IDS_SQL = "SELECT id FROM book WHERE md5 = ?;"

local function dbPath()
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

local function openConn()
    local ok, conn = pcall(SQ3.open, dbPath(), "ro")
    if not ok or not conn then
        logger.dbg("Dashboard: cannot open statistics.sqlite3:", conn)
        return nil
    end
    pcall(conn.set_busy_timeout, conn, BUSY_TIMEOUT_MS)
    return conn
end

local Session = {}
Session.__index = Session

-- Opens the shared read-only connection. A busy database is the expected
-- transient failure here, so one reopen is attempted before giving up.
function StatsReader.openSession()
    local conn = openConn() or openConn()
    if not conn then return nil, "open_failed" end
    return setmetatable({ conn = conn, statements = {}, statement_count = 0 }, Session)
end

function Session:close()
    for _, stmt in pairs(self.statements) do
        pcall(stmt.close, stmt)
    end
    self.statements = {}
    self.statement_count = 0
    if self.conn then
        pcall(self.conn.close, self.conn)
        self.conn = nil
    end
end

function Session:_reopen()
    self:close()
    self.conn = openConn()
    return self.conn ~= nil
end

function Session:_select(sql, params)
    local stmt = self.statements[sql]
    local transient = false
    if stmt then
        stmt:reset()
    else
        stmt = self.conn:prepare(sql)
        if self.statement_count < MAX_CACHED_STATEMENTS then
            self.statements[sql] = stmt
            self.statement_count = self.statement_count + 1
        else
            transient = true
        end
    end
    if params then
        stmt:bind(unpack(params))
    end
    local res = stmt:resultset("i")
    if transient then pcall(stmt.close, stmt) end
    return res
end

-- Returns the column-major result set, nil when the query matched no rows, or
-- nil plus an error when it failed after one reopen and retry.
function Session:select(sql, params)
    if not self.conn then return nil, "closed" end
    local ok, res = pcall(self._select, self, sql, params)
    if ok then return res end
    logger.dbg("Dashboard: statistics query failed, reopening:", res)
    if not self:_reopen() then return nil, "open_failed" end
    local retried, retry_res = pcall(self._select, self, sql, params)
    if retried then return retry_res end
    logger.dbg("Dashboard: statistics query failed:", retry_res)
    return nil, "query_failed"
end

function Session:bookIds(md5)
    if type(md5) ~= "string" or not md5:match("^%x+$") then return {} end
    local ids = {}
    local res = self:select(BOOK_IDS_SQL, { md5 })
    if res then
        for i = 1, #res[1] do
            table.insert(ids, tonumber(res[1][i]))
        end
    end
    return ids
end

-- Seconds read per local day since `since`, in one grouped query. Each event
-- is capped at a day so a reader left open overnight does not count as hours.
function Session:dailySeconds(since)
    local by_day = {}
    local res = self:select(
        "SELECT date(start_time, 'unixepoch', 'localtime'), COALESCE(SUM(MIN(duration, 86400)), 0)"
            .. " FROM page_stat_data WHERE start_time >= ? GROUP BY 1;",
        { since })
    if res then
        for i = 1, #res[1] do
            by_day[res[1][i]] = tonumber(res[2][i]) or 0
        end
    end
    return by_day
end

-- Minutes read in each local hour of the day since `since`, as 24 values for
-- hours 0 to 23. Each event is capped at ten minutes, as for pace.
function Session:hourMinutes(since)
    local minutes = {}
    for i = 1, 24 do minutes[i] = 0 end
    local res = self:select(
        "SELECT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER), COALESCE(SUM(MIN(duration, 600)), 0)"
            .. " FROM page_stat_data WHERE start_time >= ? GROUP BY 1;",
        { since })
    if res then
        for i = 1, #res[1] do
            local hour = tonumber(res[1][i])
            if hour and hour >= 0 and hour < 24 then
                minutes[hour + 1] = math.floor((tonumber(res[2][i]) or 0) / 60 + 0.5)
            end
        end
    end
    return minutes
end

-- Every page turn this device has recorded: the total, the turns since
-- `today_start`, and when the first was. One pass over the table.
function Session:pageTurns(today_start)
    local res = self:select(
        "SELECT COUNT(*), COALESCE(SUM(CASE WHEN start_time >= ? THEN 1 ELSE 0 END), 0), MIN(start_time) FROM page_stat_data;",
        { today_start })
    if not res then return { total = 0, today = 0 } end
    return {
        total = tonumber(res[1][1]) or 0,
        today = tonumber(res[2][1]) or 0,
        first = tonumber(res[3][1]),
    }
end

-- Reading sessions since `since`: page events grouped into a session until a
-- gap of more than ten minutes. Returns the session count, the longest and
-- average session in seconds and the pages turned per hour, or nil when
-- there is no reading. One pass over the period's events.
function Session:sessionRecords(since)
    local res = self:select([[
        WITH ev AS (
            SELECT start_time AS s, MIN(duration, 600) AS d,
                CASE WHEN start_time - LAG(start_time + MIN(duration, 600)) OVER (ORDER BY start_time) <= 600 THEN 0 ELSE 1 END AS brk
            FROM page_stat_data WHERE start_time >= ?
        ), grouped AS (
            SELECT d, SUM(brk) OVER (ORDER BY s ROWS UNBOUNDED PRECEDING) AS g FROM ev
        ), sessions AS (
            SELECT SUM(d) AS secs, COUNT(*) AS pages FROM grouped GROUP BY g
        )
        SELECT COUNT(*), COALESCE(MAX(secs), 0), COALESCE(AVG(secs), 0), COALESCE(SUM(pages), 0), COALESCE(SUM(secs), 0)
        FROM sessions WHERE secs >= 60;]], { since })
    if not res then return nil end
    local count = tonumber(res[1][1]) or 0
    if count == 0 then return nil end
    local total = tonumber(res[5][1]) or 0
    return {
        sessions = count,
        longest_seconds = tonumber(res[2][1]) or 0,
        average_seconds = tonumber(res[3][1]) or 0,
        pages_per_hour = total > 0 and (tonumber(res[4][1]) or 0) * 3600 / total or 0,
    }
end

-- How fast one book is being read: seconds per page from its own events, the
-- page count it was last read at, and seconds read over the last `days` days.
function Session:bookPace(ids, days)
    if not ids or #ids == 0 then return nil end
    local marks = {}
    for _ = 1, #ids do table.insert(marks, "?") end
    local id_list = table.concat(marks, ",")
    local totals = self:select(
        "SELECT COALESCE(SUM(MIN(duration, 600)), 0), COUNT(DISTINCT page), MAX(total_pages)"
            .. " FROM page_stat_data WHERE id_book IN (" .. id_list .. ");", ids)
    if not totals then return nil end
    local seconds = tonumber(totals[1][1]) or 0
    local pages = tonumber(totals[2][1]) or 0
    local total_pages = tonumber(totals[3][1]) or 0
    local params = {}
    for _, id in ipairs(ids) do table.insert(params, id) end
    table.insert(params, os.time() - (days or 14) * 86400)
    local recent = self:select(
        "SELECT COALESCE(SUM(MIN(duration, 600)), 0) FROM page_stat_data WHERE id_book IN ("
            .. id_list .. ") AND start_time >= ?;", params)
    return {
        seconds_per_page = pages > 0 and seconds / pages or nil,
        total_pages = total_pages,
        recent_seconds = recent and tonumber(recent[1][1]) or 0,
    }
end

-- The book read most in a window (a year ago, give or take a week): its
-- md5, title and authors, minutes and days read then, and how far it got.
function Session:mostReadBetween(from, to)
    local res = self:select([[
        SELECT b.md5, b.title, b.authors, COALESCE(SUM(MIN(p.duration, 600)), 0),
            COUNT(DISTINCT date(p.start_time, 'unixepoch', 'localtime')), MIN(p.start_time),
            MAX(p.page * 100.0 / p.total_pages)
        FROM page_stat_data p JOIN book b ON b.id = p.id_book
        WHERE p.start_time >= ? AND p.start_time < ? AND p.total_pages > 0
        GROUP BY b.md5 ORDER BY 4 DESC LIMIT 1;]], { from, to })
    if not res or not res[1][1] then return nil end
    return {
        md5 = res[1][1],
        title = res[2][1],
        authors = res[3][1],
        seconds = tonumber(res[4][1]) or 0,
        days = tonumber(res[5][1]) or 0,
        first = tonumber(res[6][1]),
        end_pct = tonumber(res[7][1]),
    }
end

local function withSession(fn)
    local session = StatsReader.openSession()
    if not session then return nil, "open_failed" end
    local ok, result = pcall(fn, session)
    session:close()
    if not ok then
        logger.dbg("Dashboard: statistics query failed:", result)
        return nil, "query_failed"
    end
    return result
end

function StatsReader.getDailySeconds(since)
    return withSession(function(session)
        return session:dailySeconds(since)
    end)
end

function StatsReader.getHourMinutes(since)
    return withSession(function(session)
        return session:hourMinutes(since)
    end)
end

function StatsReader.getPageTurns(today_start)
    return withSession(function(session)
        return session:pageTurns(today_start)
    end)
end

function StatsReader.getSessionRecords(since)
    return withSession(function(session)
        return session:sessionRecords(since)
    end)
end

function StatsReader.getBookPace(md5, days)
    return withSession(function(session)
        return session:bookPace(session:bookIds(md5), days)
    end)
end

function StatsReader.getMostReadBetween(from, to)
    return withSession(function(session)
        return session:mostReadBetween(from, to)
    end)
end

return StatsReader
