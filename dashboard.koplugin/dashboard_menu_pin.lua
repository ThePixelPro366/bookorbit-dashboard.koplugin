--[[--
Pins the dashboard's entry onto the first page of the Tools menu, right
below calibre, and puts its icon in KOReader's menu bar just before the main
menu.

KOReader caches its bundled menu-order tables and lets plugins extend them
before the menu is built. Mutating those shared tables in memory preserves
entries added by every plugin regardless of load order, and writes nothing:
a hand-maintained menu-order file still wins.
]]

local logger = require("logger")

local TAB_ID = "reading_dashboard_tab"
local BUTTONS = "KOMenu:menu_buttons"
local MENU_ID = "reading_dashboard"

local ORDER_MODULES = {
    "ui/elements/reader_menu_order",
    "ui/elements/filemanager_menu_order",
}

local MenuPin = {
    done = false,
    -- Whether the icon belongs in the menu bar; set from the plugin's
    -- setting before ensure or refresh runs.
    tab = true,
}

local function removeId(list, id)
    for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i) end
    end
end

local function pinTools(tools)
    removeId(tools, MENU_ID)
    local insert_at = #tools
    for i, id in ipairs(tools) do
        if id == "calibre" then
            insert_at = i
            break
        end
    end
    table.insert(tools, insert_at + 1, MENU_ID)
end

-- The menu bar with the dashboard's tab just before the main menu (the last
-- button), or without it.
local function normalizeButtons(buttons, with_tab)
    removeId(buttons, TAB_ID)
    if not with_tab then return end
    local insert_at = #buttons + 1
    for i, id in ipairs(buttons) do
        if id == "main" then
            insert_at = i
            break
        end
    end
    table.insert(buttons, insert_at, TAB_ID)
end
MenuPin.normalizeButtons = normalizeButtons

local function ensureAll()
    for _i, module in ipairs(ORDER_MODULES) do
        local ok, order = pcall(require, module)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            pinTools(order.tools)
            if type(order[BUTTONS]) == "table" then
                normalizeButtons(order[BUTTONS], MenuPin.tab)
                -- MenuSorter treats a button as a tab only when it has an order list.
                order[TAB_ID] = MenuPin.tab and {} or nil
            end
        else
            logger.warn("Dashboard: cannot load menu order", module, order)
        end
    end
end

function MenuPin.ensure(with_tab)
    if MenuPin.done then return end
    MenuPin.done = true
    if with_tab ~= nil then MenuPin.tab = with_tab end
    ensureAll()
end

-- Updates both cached orders after the menu bar setting changes.
function MenuPin.refresh(with_tab)
    MenuPin.tab = with_tab ~= false
    MenuPin.done = true
    ensureAll()
end

return MenuPin
