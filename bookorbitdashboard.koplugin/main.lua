--[[--
Bookorbit Dashboard plugin: the Bookorbit Dashboard but stripped of
everything related to Bookorbit.

A board of widgets over KOReader's file browser, built from this device's
books, history and statistics. This file owns the plugin's lifecycle: its
settings, its entries in KOReader's menus and menu bar, the gesture action,
opening at startup or as home, and remembering a book's chapters when it
closes (for the Chapter line widget).

Derived from the BookOrbit KOReader plugin; see NOTICE and the About page.
]]

local Dispatcher = require("dispatcher")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local BoardMetrics = require("dashboard_board_metrics")
local BoardStore = require("dashboard_board_store")
local ChapterMap = require("dashboard_chapter_map")
local Library = require("dashboard_library")
local MenuPin = require("dashboard_menu_pin")
local Updater = require("dashboard_updater")

local SETTINGS_KEY = "bookorbit_dashboard"
-- A closed book returns to the dashboard only if the file browser shows up
-- within this many seconds of the reader closing.
local RETURN_HOME_WINDOW = 10
-- Seconds after that return to check nothing ended up over the dashboard.
local RAISE_AFTER_RETURN = 1

local Dashboard = WidgetContainer:extend{
    name = "bookorbitdashboard",
    settings = nil,
}

Dashboard.PLUGIN_VERSION = "1.2.4"
Dashboard.MODIFIED_DATE = "2026-10-24"

Updater.installInto(Dashboard)

Dashboard.default_settings = {
    auto_open = "off",
    menu_bar_icon = true,
    ui_scale = 1.05,
    tap_resumes = true,
}

function Dashboard:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY)
    if type(self.settings) ~= "table" then
        self.settings = {}
        for k, v in pairs(self.default_settings) do self.settings[k] = v end
        G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
    end
    self.settings.ui_scale = BoardMetrics.setUserScale(self.settings.ui_scale)
    pcall(MenuPin.ensure, self.settings.menu_bar_icon ~= false)

    -- The reader clears its document before its widgets close, so remember
    -- which side this instance serves.
    self.in_reader = self.ui ~= nil and self.ui.document ~= nil
    if self.in_reader then PluginShare.bookorbit_dashboard_return = nil end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:onStart()
    if not self.in_reader then
        -- The daily update check, a little after the file browser settles.
        UIManager:scheduleIn(15, function() self:maybeCheckForUpdate() end)
    end
end

-- Wi-Fi coming up is a good moment for the daily update check.
function Dashboard:onNetworkConnected()
    if not self.in_reader then self:maybeCheckForUpdate() end
end

function Dashboard:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function Dashboard:onDispatcherRegisterActions()
    Dispatcher:registerAction("bookorbit_dashboard_open",
        { category = "none", event = "BookorbitDashboardOpen", title = _("Bookorbit Dashboard: open"), general = true, separator = true })
end

-- ------------------------------------------------------------------ open
function Dashboard:isOpen()
    return self.board_view ~= nil and not self.board_view.closed
end

-- Moves an open dashboard back to the top of the window stack. Another home
-- screen (Bookshelf, for one) raises itself the same way when a book
-- closes, which would leave the dashboard hidden underneath it.
function Dashboard:raiseDashboard()
    local view = self.board_view
    if not self:isOpen() or UIManager:getTopmostVisibleWidget() == view then return end
    local stack = UIManager._window_stack or {}
    for i, entry in ipairs(stack) do
        if entry.widget == view then
            table.remove(stack, i)
            table.insert(stack, entry)
            UIManager:setDirty(view, "ui")
            return
        end
    end
end

function Dashboard:openDashboard()
    if self:isOpen() then
        self:raiseDashboard()
        return self.board_view
    end
    if self.in_reader then
        -- The dashboard lives over the file browser: close the book and come
        -- back to it there.
        PluginShare.bookorbit_dashboard_return = os.time()
        PluginShare.bookorbit_dashboard_once = true
        self.ui:onHome()
        return
    end
    local DashboardView = require("dashboard_view")
    self.board_view = DashboardView:new{
        plugin = self,
        settings = self.settings,
        close_callback = function() self.board_view = nil end,
    }
    UIManager:show(self.board_view)
    return self.board_view
end

function Dashboard:onBookorbitDashboardOpen()
    if self:isOpen() and UIManager:getTopmostVisibleWidget() == self.board_view then
        -- Already open: the shortcut opens its menu instead.
        self:openMenuSheet(self.board_view)
        return true
    end
    self:openDashboard()
    return true
end

function Dashboard:onStart()
    if self.in_reader or PluginShare.bookorbit_dashboard_started then return end
    PluginShare.bookorbit_dashboard_started = true
    local mode = self.settings.auto_open or "off"
    if mode ~= "filemanager" and mode ~= "home" then return end
    UIManager:nextTick(function()
        if self.ui and self.ui.file_chooser and not self:isOpen() then self:openDashboard() end
    end)
end

-- "Make the dashboard home": the file browser a closed book returns to opens
-- the dashboard over itself before its first paint, so it never flashes.
function Dashboard:onShow()
    if self.in_reader then return end
    local closed_at = PluginShare.bookorbit_dashboard_return
    if not closed_at then return end
    local once = PluginShare.bookorbit_dashboard_once
    PluginShare.bookorbit_dashboard_return = nil
    PluginShare.bookorbit_dashboard_once = nil
    if os.time() - closed_at > RETURN_HOME_WINDOW then return end
    if not once and self.settings.auto_open ~= "home" then return end
    self:openDashboard()
    -- The book's close can still bring another home screen up over it.
    UIManager:scheduleIn(RAISE_AFTER_RETURN, function() self:raiseDashboard() end)
end

-- A book closing: its chapters are kept for the Chapter line, and the
-- library forgets what it knew about it (progress, status, highlights).
function Dashboard:onCloseDocument()
    local ui = self.ui
    local file = ui and ui.document and ui.document.file
    if not file then return end
    local md5 = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
    pcall(ChapterMap.remember, ui, md5)
    Library.invalidateBooks(file)
end

function Dashboard:onCloseWidget()
    if self.in_reader and self.settings.auto_open == "home" and not PluginShare.bookorbit_dashboard_return then
        PluginShare.bookorbit_dashboard_return = os.time()
    end
end

-- Files added, moved or deleted in the file browser change the library.
function Dashboard:onFileManagerChanged()
    Library.invalidate()
end
Dashboard.onPathChanged = Dashboard.onFileManagerChanged

-- ------------------------------------------------------------------ menus
function Dashboard:menuBarIconEnabled()
    return self.settings.menu_bar_icon ~= false
end

function Dashboard:menuBarIconPath()
    if not self.path then return nil end
    local path = self.path .. "/assets/dashboard.tab.svg"
    if path:sub(1, 1) ~= "/" then
        local cwd = require("libs/libkoreader-lfs").currentdir()
        if cwd then path = cwd .. "/" .. path end
    end
    return path
end

-- KOReader's tab bar looks icons up by name under its icon folders. Enough
-- ".." segments climb from any of them to the root, so the shipped SVG is
-- found by its absolute path without copying it anywhere.
function Dashboard:menuBarIconName()
    local path = self:menuBarIconPath()
    if not path then return "appbar.menu" end
    return string.rep("../", 32) .. path:gsub("^/+", ""):gsub("%.svg$", "")
end

function Dashboard:setMenuBarIconEnabled(enabled)
    self.settings.menu_bar_icon = enabled == true
    self:saveSettings()
    MenuPin.refresh(enabled == true)
    -- The menu rebuilds from the new order the next time it opens.
    if self.ui and self.ui.menu then self.ui.menu.tab_item_table = nil end
end

local function closeKOReaderMenu(ui)
    local menu = ui and ui.menu
    if not menu then return end
    if menu.onCloseFileManagerMenu then
        menu:onCloseFileManagerMenu()
    elseif menu.onCloseReaderMenu then
        menu:onCloseReaderMenu()
    end
end

function Dashboard:addToMainMenu(menu_items)
    menu_items.bookorbit_dashboard = {
        text = _("Bookorbit Dashboard"),
        -- Fallback placement only: MenuPin normally pins this entry right
        -- below calibre on the first page of the Tools menu.
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open dashboard"),
                callback = function()
                    UIManager:tickAfterNext(function() self:openDashboard() end)
                end,
            },
            {
                text = _("Settings"),
                callback = function()
                    UIManager:tickAfterNext(function() self:openSettings(self.board_view) end)
                end,
            },
        },
    }
    if self:menuBarIconEnabled() then
        -- A tab that acts as a button, like the reader's file browser tab.
        menu_items.bookorbit_dashboard_tab = {
            -- Only shown if the tab ever ends up as an orphan row: without
            -- text, KOReader's menu would crash on it.
            text = _("Bookorbit Dashboard"),
            icon = self:menuBarIconName(),
            remember = false,
            callback = function()
                closeKOReaderMenu(self.ui)
                UIManager:tickAfterNext(function() self:openDashboard() end)
            end,
        }
    end
end

function Dashboard:openMenuSheet(view)
    return require("dashboard_menu_sheet").open(self, view, function(page, action)
        return self:onMenuSheetAction(page, view, action)
    end)
end

function Dashboard:openSettings(view, group)
    return require("dashboard_settings_page").open(self, view, group)
end

-- What the menu sheet does with a tap it does not handle itself.
function Dashboard:onMenuSheetAction(page, view, action)
    local kind = action.kind
    local after = function(fn)
        page:close()
        UIManager:nextTick(fn)
    end
    if kind == "customize" then
        page:close()
        self:customizeBoard(view)
    elseif kind == "exit" then
        after(function() if view then view:closeToHome() end end)
    elseif kind == "search" then
        after(function() if view then view:boardRun({ kind = "search" }) end end)
    elseif kind == "link" then
        after(function() if view then view:boardOpenLink(action.link) end end)
    elseif kind == "settings" then
        after(function() self:openSettings(view) end)
    elseif kind == "about" then
        after(function() self:openSettings(view, "about") end)
    end
    return true
end

-- ---------------------------------------------------------------- board
function Dashboard:customizeBoard(view)
    view = view or self:openDashboard()
    if not view then return end
    UIManager:nextTick(function()
        if view.boardEnterEdit then view:boardEnterEdit() end
    end)
end

function Dashboard:applyBoardSetting(view, change)
    local state = change(self.settings)
    if view then
        view:persistSetting(BoardStore.SETTING_KEY, state)
        view.board_edit = nil
        view.current_context.board_page = 1
        view:boardReload()
    else
        self.settings[BoardStore.SETTING_KEY] = state
        self:saveSettings()
    end
end

function Dashboard:applyBoardTiles(view, tiles)
    if view then
        view:boardSetTiles(tiles)
    else
        self.settings[BoardStore.SETTING_KEY] = BoardStore.withTiles(self.settings, tiles)
        self:saveSettings()
    end
end

-- -------------------------------------------------------------- shortcut
function Dashboard:gesturesData()
    local gestures = self.ui and self.ui.gestures
    return gestures and gestures.data or nil
end

function Dashboard:applyShortcut(id)
    local ok = require("dashboard_shortcut").apply(self.ui and self.ui.gestures, id)
    if not ok then
        logger.warn("Dashboard: gestures plugin not available")
        require("dashboard_toast").error(_("Turn on KOReader's Gestures plugin first: Settings, Taps and gestures."))
    end
    return ok
end

return Dashboard
