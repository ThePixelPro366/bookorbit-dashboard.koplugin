--[[--
Updates the plugin from its GitHub releases.

A check asks GitHub for the repository's latest release and compares its tag
(v1.2.3) with the installed version. Installing downloads the release's zip
asset, extracts it next to the plugin, swaps the folders (the old one is kept
until the new one is in place) and offers to restart KOReader.

Network work runs in a subprocess (Trapper), so the screen never waits on it.
The daily check runs at most once a day, only while Wi-Fi is already on, and
asks about a given version once; Check for update in About always asks.

The unpack and swap are derived from BookOrbit's KOReader plugin updater.
]]

local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Updater = {}

Updater.REPO = "ThePixelPro366/bookorbit-dashboard.koplugin"
Updater.ASSET = "bookorbitdashboard.koplugin.zip"
Updater.CHECK_INTERVAL = 24 * 60 * 60
local USER_AGENT = "KOReader-BookorbitDashboard"

-- True when `candidate` is strictly newer than `current` (x.y.z, optional "v").
function Updater.isNewer(candidate, current)
    local function parse(v)
        if type(v) ~= "string" then return nil end
        local a, b, c = v:match("^v?(%d+)%.(%d+)%.(%d+)")
        if not a then return nil end
        return { tonumber(a), tonumber(b), tonumber(c) }
    end
    local c, cur = parse(candidate), parse(current)
    if not c or not cur then return false end
    if c[1] ~= cur[1] then return c[1] > cur[1] end
    if c[2] ~= cur[2] then return c[2] > cur[2] end
    return c[3] > cur[3]
end

-- ----------------------------------------------------------------- network
-- One GET, following redirects (GitHub serves assets from another host).
-- make_sink: returns a fresh ltn12 sink for each request, since a redirect
-- has a body of its own and a file sink closes its file when a body ends; or
-- nil to collect the body. Returns the body (when collected) or true, or
-- nil + error.
local function get(url, make_sink, block_timeout, total_timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local chunks = {}
    for _hop = 1, 5 do
        local sink
        if make_sink then
            sink = make_sink()
            if not sink then return nil, "cannot write the download" end
        end
        socketutil:set_timeout(block_timeout or socketutil.LARGE_BLOCK_TIMEOUT, total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
        local code, headers, status = socket.skip(1, http.request{
            url = url,
            method = "GET",
            redirect = false,
            headers = {
                ["User-Agent"] = USER_AGENT,
                ["Accept"] = sink and "application/octet-stream" or "application/vnd.github+json",
                ["Accept-Encoding"] = "identity",
            },
            sink = sink or ltn12.sink.table(chunks),
        })
        socketutil:reset_timeout()
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local location = headers and (headers.location or headers.Location)
            if not location or not location:match("^https://") then return nil, "bad redirect" end
            url = location
            chunks = {}
        elseif code == 200 then
            return sink and true or table.concat(chunks)
        else
            return nil, tostring(status or code or "network unreachable")
        end
    end
    return nil, "too many redirects"
end

-- Without the API: github.com answers /releases/latest with a redirect to
-- the release's tag, and assets live at a fixed address under that tag. No
-- API rate limit applies, which matters on shared connections.
function Updater.latestFromRedirect()
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request{
        url = "https://github.com/" .. Updater.REPO .. "/releases/latest",
        method = "HEAD",
        redirect = false,
        headers = { ["User-Agent"] = USER_AGENT },
    })
    socketutil:reset_timeout()
    local location = headers and (headers.location or headers.Location)
    local tag = location and location:match("/releases/tag/([^/?#]+)")
    if not tag then return nil, tostring(status or code or "network unreachable") end
    return {
        version = tag:gsub("^v", ""),
        url = "https://github.com/" .. Updater.REPO .. "/releases/download/" .. tag .. "/" .. Updater.ASSET,
        notes = "",
    }
end

-- The latest release: { version = "1.2.3", url = asset url, notes = text },
-- or nil + error. Asks the API first (for the release notes), then falls
-- back to the redirect.
function Updater.fetchLatest()
    local body, err = get("https://api.github.com/repos/" .. Updater.REPO .. "/releases/latest")
    if not body then
        logger.dbg("Dashboard: release API failed, trying the redirect:", err)
        return Updater.latestFromRedirect()
    end
    local ok, json = pcall(require, "rapidjson")
    if not ok then json = require("json") end
    local parsed, data = pcall(json.decode, body)
    if not parsed or type(data) ~= "table" then return nil, "unreadable answer from GitHub" end
    local version = type(data.tag_name) == "string" and data.tag_name:gsub("^v", "") or nil
    if not version then return nil, "release has no version tag" end
    local url
    for _i, asset in ipairs(type(data.assets) == "table" and data.assets or {}) do
        if type(asset) == "table" and asset.name == Updater.ASSET then url = asset.browser_download_url end
    end
    if not url then
        for _i, asset in ipairs(type(data.assets) == "table" and data.assets or {}) do
            if type(asset) == "table" and type(asset.name) == "string" and asset.name:match("%.zip$") then
                url = asset.browser_download_url
                break
            end
        end
    end
    return { version = version, url = url, notes = type(data.body) == "string" and data.body or "" }
end

function Updater.download(url, path)
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    -- Each request starts the file over, so a redirect's body never ends up
    -- in the zip.
    local function fileSink()
        local f = io.open(path, "wb")
        return f and ltn12.sink.file(f)
    end
    local ok, err = get(url, fileSink, socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT * 3)
    if not ok then os.remove(path) end
    return ok, err
end

-- ----------------------------------------------------------------- install
local function sq(path)
    return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function childNames(dir)
    local names = {}
    local ok, iterator, dir_obj = pcall(lfs.dir, dir)
    if not ok or not iterator then return names end
    for name in iterator, dir_obj do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    return names
end

-- Extracts the zip into `staging`, dropping its single top-level folder.
local function unpack(zip_path, staging, raw_dir)
    local has_archiver, Archiver = pcall(require, "ffi/archiver")
    if not has_archiver or type(Archiver) ~= "table" or not Archiver.Reader then
        local Device = require("device")
        if type(Device.unpackArchive) ~= "function" then return nil, "this KOReader cannot unpack archives" end
        lfs.mkdir(staging)
        local ok, err = Device:unpackArchive(zip_path, staging, true)
        if not ok then return nil, tostring(err or "archive extraction failed") end
        return true
    end
    os.execute("rm -rf " .. sq(raw_dir))
    if not lfs.mkdir(raw_dir) then return nil, "cannot create " .. raw_dir end
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        local err = arc.err
        arc:close()
        return nil, tostring(err or "cannot open the update")
    end
    for entry in arc:iterate() do
        if not arc:extractToPath(entry.path, raw_dir .. "/" .. entry.path) then break end
    end
    local err = arc.err
    arc:close()
    if err then return nil, tostring(err) end
    local names = childNames(raw_dir)
    local from = raw_dir
    if #names == 1 and lfs.attributes(raw_dir .. "/" .. names[1], "mode") == "directory" then
        from = raw_dir .. "/" .. names[1]
    end
    if not os.rename(from, staging) then return nil, "cannot move the update into place" end
    os.execute("rm -rf " .. sq(raw_dir))
    return true
end

-- Downloads `url` and replaces `plugin_dir` with it. Returns true or nil + error.
function Updater.install(url, plugin_dir)
    local dir = plugin_dir:gsub("/+$", "")
    local parent = dir:match("^(.*)/[^/]+$")
    local name = dir:match("([^/]+)$")
    if not parent or parent == "" then return nil, "cannot find the plugin folder" end
    local zip = parent .. "/" .. name .. ".download.zip"
    local staging = parent .. "/" .. name .. ".update"
    local raw = parent .. "/" .. name .. ".unpack"
    local backup = parent .. "/" .. name .. ".bak"
    os.execute("rm -rf " .. sq(staging) .. " " .. sq(raw))

    local ok, err = Updater.download(url, zip)
    if not ok then return nil, err end
    ok, err = unpack(zip, staging, raw)
    os.remove(zip)
    if not ok then
        os.execute("rm -rf " .. sq(staging) .. " " .. sq(raw))
        return nil, err
    end
    if lfs.attributes(staging .. "/main.lua", "mode") ~= "file" then
        os.execute("rm -rf " .. sq(staging))
        return nil, "the update does not contain the plugin"
    end
    os.execute("rm -rf " .. sq(backup))
    if not os.rename(dir, backup) then
        os.execute("rm -rf " .. sq(staging))
        return nil, "cannot back up the installed plugin"
    end
    if not os.rename(staging, dir) then
        os.rename(backup, dir)
        os.execute("rm -rf " .. sq(staging))
        return nil, "cannot install the update"
    end
    os.execute("rm -rf " .. sq(backup))
    return true
end

-- ------------------------------------------------------------------- mixin
-- Installed onto the plugin: check, ask, install, restart.
local Mixin = {}

function Mixin:hasKnownUpdate()
    return Updater.isNewer(self.settings.update_latest, self.PLUGIN_VERSION)
end

-- The daily check: once a day, only when Wi-Fi is already connected, quiet
-- unless there is a version the reader has not been asked about yet.
function Mixin:maybeCheckForUpdate()
    if self.settings.update_check == false or self._update_busy then return end
    if os.time() - (tonumber(self.settings.update_checked_at) or 0) < Updater.CHECK_INTERVAL then return end
    if not NetworkMgr:isConnected() then return end
    self:checkForUpdate(false)
end

-- interactive: the reader asked, so say what happened either way.
function Mixin:checkForUpdate(interactive, on_done)
    if self._update_busy then return end
    local Toast = require("dashboard_toast")
    local run = function()
        self._update_busy = true
        Trapper:wrap(function()
            local pill = interactive and Toast.loading(_("Checking for an update…")) or nil
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                local latest, err = Updater.fetchLatest()
                return { latest = latest, err = err }
            end, pill)
            if pill then pill:close() end
            self._update_busy = false
            if not completed then return end
            result = result or {}
            self.settings.update_checked_at = os.time()
            if not result.latest then
                logger.warn("Dashboard: update check failed:", result.err)
                if interactive then Toast.error(T(_("Could not check for an update: %1"), tostring(result.err))) end
                self:saveSettings()
                if on_done then on_done() end
                return
            end
            local latest = result.latest
            self.settings.update_latest = latest.version
            self:saveSettings()
            if on_done then on_done() end
            if not Updater.isNewer(latest.version, self.PLUGIN_VERSION) then
                if interactive then Toast.show(T(_("Bookorbit Dashboard is up to date, v%1"), self.PLUGIN_VERSION)) end
                return
            end
            if not interactive then
                if self.settings.update_asked == latest.version then return end
                self.settings.update_asked = latest.version
                self:saveSettings()
            end
            self:offerUpdate(latest)
        end)
    end
    if interactive then NetworkMgr:runWhenConnected(run) else run() end
end

function Mixin:offerUpdate(latest)
    if not latest.url then
        require("dashboard_toast").error(T(_("Version %1 is out, but its release has no plugin zip."), latest.version))
        return
    end
    local notes = latest.notes:gsub("\r", ""):sub(1, 400)
    require("dashboard_dialog_ui").confirm{
        title = T(_("Bookorbit Dashboard %1 is out"), latest.version),
        text = T(_("You have %1. Install the update now? KOReader restarts afterwards."), self.PLUGIN_VERSION)
            .. (notes ~= "" and ("\n\n" .. notes) or ""),
        ok_label = _("Update"),
        ok_icon = "download",
        on_ok = function() self:applyUpdate(latest) end,
    }
end

function Mixin:applyUpdate(latest)
    if self._update_busy or not self.path then return end
    local Toast = require("dashboard_toast")
    local plugin_dir = self.path
    if plugin_dir:sub(1, 1) ~= "/" then plugin_dir = lfs.currentdir() .. "/" .. plugin_dir end
    NetworkMgr:runWhenConnected(function()
        self._update_busy = true
        Trapper:wrap(function()
            -- Not dismissable: stopping halfway could leave the swap unfinished.
            local pill = Toast.loading(T(_("Downloading %1…"), latest.version), { dismissable = false })
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                local ok, err = Updater.install(latest.url, plugin_dir)
                return { ok = ok, err = err }
            end, pill)
            pill:close()
            self._update_busy = false
            if not completed then return end
            result = result or {}
            if not result.ok then
                Toast.error(T(_("Update failed: %1"), tostring(result.err or _("unexpected error"))))
                return
            end
            require("dashboard_dialog_ui").confirm{
                title = T(_("Updated to %1"), latest.version),
                text = _("Restart KOReader to use the new version."),
                ok_label = _("Restart now"),
                ok_icon = "rotate-ccw",
                on_ok = function() UIManager:restartKOReader() end,
            }
        end)
    end)
end

function Updater.installInto(Plugin)
    for name, fn in pairs(Mixin) do Plugin[name] = fn end
end

return Updater
