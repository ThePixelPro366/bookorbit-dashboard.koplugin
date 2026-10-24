--[[--
Home screens that plugins add to KOReader's Start with menu.

Home screen plugins (Bookshelf, Simple UI, ...) add an entry to KOReader's
own Start with menu. KOReader only acts on that choice at launch, so leaving
the dashboard mid-session lands in the plain file browser. This lists those
entries and opens one.

An entry is opened through its own menu callback, as if picked in the menu,
with the user's Start with choice put back afterwards. An entry that only
saves the choice gets a Dispatcher event instead, the one its plugin offers
for gestures.
]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local StartScreen = {}

-- KOReader's own entries, by their (translated) menu text.
local function builtIn()
    return {
        [_("file browser")] = true, [_("history")] = true, [_("favorites")] = true,
        [_("folder shortcuts")] = true, [_("last file")] = true,
    }
end

-- Start with values whose entry only saves the choice.
local EVENTS = {
    homescreen_simpleui = "SimpleUIGoHomescreen",
}

local function itemText(item)
    local text = item.text or (item.text_func and item.text_func())
    return type(text) == "string" and text ~= "" and text or nil
end

local function capitalize(text)
    return text:sub(1, 1):upper() .. text:sub(2)
end

-- The plugin entries of KOReader's Start with menu, in menu order:
-- { id = menu text, label = display name, current = KOReader starts with it, item }.
function StartScreen.list(fm)
    local menu = fm and fm.menu
    if not (menu and menu.getStartWithMenuTable) then return {} end
    local ok, start_with = pcall(menu.getStartWithMenuTable, menu)
    if not ok or type(start_with) ~= "table" or type(start_with.sub_item_table) ~= "table" then return {} end
    local own = builtIn()
    local homes = {}
    for _i, item in ipairs(start_with.sub_item_table) do
        local text = itemText(item)
        if text and not own[text] and item.callback then
            local current = item.checked_func and item.checked_func() or false
            table.insert(homes, { id = text, label = capitalize(text), current = current, item = item })
        end
    end
    return homes
end

-- Where Library and Files lead, from Settings: "list" (Library's own book
-- list), "files" (the file browser), or the id of a home screen. The earlier
-- on/off setting meant the file browser.
function StartScreen.target(settings)
    local target = settings.library_target
    if target == nil and settings.library_opens_files then target = "files" end
    return target or "list"
end

function StartScreen.isHome(target)
    return target ~= "list" and target ~= "files"
end

function StartScreen.find(fm, id)
    for _i, home in ipairs(StartScreen.list(fm)) do
        if home.id == id then return home end
    end
end

-- Opens the home screen with this id. False when it is gone (its plugin
-- was removed or turned off), so the caller can fall back.
function StartScreen.open(fm, id)
    local home = id and StartScreen.find(fm, id)
    if not home then return false end
    local before = G_reader_settings:readSetting("start_with")
    local ok, err = pcall(home.item.callback)
    -- The callback saved its own value: that names the plugin's event, and
    -- the user's choice goes back.
    local value = G_reader_settings:readSetting("start_with")
    if before == nil then
        G_reader_settings:delSetting("start_with")
    else
        G_reader_settings:saveSetting("start_with", before)
    end
    G_reader_settings:flush()
    if not ok then
        logger.warn("Dashboard: opening", id, "failed:", err)
        return false
    end
    if EVENTS[value] then UIManager:sendEvent(Event:new(EVENTS[value])) end
    return true
end

return StartScreen
