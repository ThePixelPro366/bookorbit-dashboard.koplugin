--[[--
Dashboard settings: one level deep, every value visible where it is changed.

On phones and 6-7" readers the root lists the groups with their current
values and each group is one page. On tablets and in landscape the groups sit
beside the open one, so nothing is drilled into. The shortcut picker is its
own page from Opening the dashboard. About carries the legal notices.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local BoardMetrics = require("dashboard_board_metrics")
local BoardStore = require("dashboard_board_store")
local BoardUI = require("dashboard_board_ui")
local MenuPage = require("dashboard_menu_page")
local MenuUI = require("dashboard_menu_ui")
local Shortcut = require("dashboard_shortcut")
local StartScreen = require("dashboard_start_screen")

local INK = BoardMetrics.INK
local px = BoardMetrics.px
local text, vstack, hstack, flex, space, icon = BoardUI.text, BoardUI.vstack, BoardUI.hstack, BoardUI.flex, BoardUI.space, BoardUI.icon

local Settings = {}

local PRESETS = { "reader", "stats", "library" }
local TILES = { "outline", "soft", "ink" }

-- Where the code comes from, for the notices the BookOrbit additional terms
-- (sections 1 and 3) ask every modified version to show in its About page.
Settings.UPSTREAM_URL = "https://github.com/bookorbit/bookorbit"
Settings.SOURCE_URL = "https://github.com/thepixelpro366/bookorbit-dashboard.koplugin"

local function scaleLabel(value)
    return string.format("%.2f", value):gsub("0$", "") .. "x"
end

local function indexOf(list, value, fallback)
    for index, v in ipairs(list) do
        if v == value then return index end
    end
    return fallback
end

-- ------------------------------------------------------------- summaries
function Settings.openMode(settings)
    local mode = settings.auto_open or "off"
    if mode == "home" then return 3 end
    if mode == "filemanager" then return 2 end
    return 1
end

local function shortcutLabel(page)
    local g = Shortcut.find(Shortcut.current(page.gestures_data))
    return g and g.label() or _("no shortcut")
end

local function openingSummary(page)
    local mode = Settings.openMode(page.plugin.settings)
    local first = mode == 3 and _("The dashboard is home") or mode == 2 and _("At startup") or _("File browser first")
    return first .. " · " .. shortcutLabel(page)
end

local PRESET_LABELS = { reader = function() return _("Reader") end, stats = function() return _("Stats") end, library = function() return _("Library") end }

local function boardSummary(settings)
    local state = BoardStore.read(settings)
    return T(_("%1 layout, %2 size"),
        (PRESET_LABELS[state.preset] or PRESET_LABELS.reader)(),
        scaleLabel(BoardMetrics.normalizeUserScale(settings.ui_scale)))
end

local function readingSummary(settings)
    local goal = tonumber(settings.goal)
    return goal and T(_.ngettext("Goal: %1 book a year", "Goal: %1 books a year", goal), goal) or _("No yearly goal")
end

local CATEGORIES = {
    { id = "opening", icon = "door-open", label = function() return _("Opening the dashboard") end, sub = function(page) return openingSummary(page) end },
    { id = "board", icon = "layout-grid", label = function() return _("Board") end, sub = function(page) return boardSummary(page.plugin.settings) end },
    { id = "reading", icon = "target", label = function() return _("Reading goal") end, sub = function(page) return readingSummary(page.plugin.settings) end },
}

local function titleOf(view)
    for _i, cat in ipairs(CATEGORIES) do
        if cat.id == view then return cat.label() end
    end
    if view == "about" then return _("About") end
    if view == "shortcut" then return _("Shortcut") end
    if view == "library" then return _("Library and Files") end
    return _("Settings")
end

-- ----------------------------------------------------------------- lists
local function categoryRows(page, w, compact)
    local rows = {}
    local selected = page.detail
    for _i, cat in ipairs(CATEGORIES) do
        table.insert(rows, MenuUI.row(w, {
            icon = cat.icon, label = cat.label(), bold = compact and selected == cat.id,
            sub = not compact and cat.sub(page) or nil, sub_data = true,
            chevron = not compact, action = { kind = "view", view = cat.id },
        }))
    end
    return rows
end

local function settingsList(page, w, compact)
    local iw = MenuUI.rowsIn(w)
    return {
        MenuUI.group(w, categoryRows(page, iw, compact)),
        space(nil, px(16)),
        MenuUI.section(w, _("Help"), MenuUI.group(w, {
            MenuUI.row(iw, { icon = "circle-help", label = _("About"), bold = compact and page.detail == "about",
                sub = not compact and T(_("Version %1 · legal notices"), page.plugin.PLUGIN_VERSION) or nil,
                chevron = not compact, action = { kind = "view", view = "about" } }),
        })),
    }
end

-- ---------------------------------------------------------------- bodies
local function segRow(w, label, sub, options, selected, action_for)
    return vstack({ w = w, pad = { px(12), 0, px(12), 0 } }, {
        text(label, { s = 16, w = w }),
        sub and text(sub, { s = 13, col = INK.g4, w = w }) or false,
        space(nil, px(8)),
        MenuUI.segmented(w, options, selected, action_for),
    })
end

local function menuBarStrip(page, w)
    local s = px(30)
    local names = { "appbar.filebrowser", "appbar.settings", "appbar.tools", "appbar.search", "dashboard", "appbar.menu" }
    local cells = {}
    for _i, name in ipairs(names) do
        local glyph
        if name == "dashboard" then
            glyph = MenuUI.tabIcon(s, page.plugin:menuBarIconPath())
        else
            glyph = IconWidget:new{ icon = name, width = s, height = s }
        end
        local cell = hstack({ w = px(44), h = px(44) }, { flex(0), glyph, flex(0) })
        if name == "dashboard" then
            cell = BoardUI.overlay(px(44), px(44), {
                { widget = cell },
                { widget = BoardUI.box({ w = px(44), h = px(44), radius = px(10), border = math.max(1, px(1.5)), border_col = INK.black }) },
            })
        end
        table.insert(cells, cell)
    end
    local strip = hstack({ w = w, h = px(52) }, { flex(0), cells[1], flex(0), cells[2], flex(0), cells[3], flex(0), cells[4], flex(0), cells[5], flex(0), cells[6], flex(0) })
    return vstack({ w = w }, { strip, BoardUI.rect(w, math.max(1, px(1.5)), INK.black) })
end

local function openingBody(page, w, embedded)
    local settings = page.plugin.settings
    local iw = MenuUI.rowsIn(w)
    local mode = Settings.openMode(settings)
    local choices = {
        { _("Show the file browser"), _("Open the dashboard from the menu bar or your shortcut"), "off" },
        { _("Open the dashboard"), _("Once, when KOReader starts"), "filemanager" },
        { _("Make the dashboard home"), _("At startup, and whenever you close a book"), "home" },
    }
    local radios = {}
    for index, c in ipairs(choices) do
        table.insert(radios, MenuUI.row(iw, { label = c[1], sub = c[2], radio = index == mode, h = 64, action = { kind = "open-mode", mode = c[3] } }))
    end

    local shortcut_card
    if not Device:isTouchDevice() then
        shortcut_card = MenuUI.card(w, { space(nil, px(12)), text(_("This device has no touchscreen. KOReader's keyboard shortcuts can open the dashboard: its action is \"Bookorbit Dashboard: open\"."), { s = 14, w = iw, lines = 3 }), space(nil, px(12)) })
    else
        local g = Shortcut.find(Shortcut.current(page.gestures_data))
        local pill = MenuUI.pill(g and _("Change") or _("Pick one"), { kind = "outline", h = 36, s = 14, pad_x = 14, action = { kind = "view", view = "shortcut" } })
        local illus = MenuUI.gesture(g and g.kind or "none", px(44))
        local mid_w = iw - illus:getSize().w - pill:getSize().w - 2 * px(14)
        shortcut_card = BoardUI.hit(MenuUI.card(w, {
            hstack({ w = iw, h = px(84), gap = px(14) }, {
                illus,
                vstack({ w = mid_w }, {
                    text(g and g.label() or _("No shortcut"), { s = 16, b = true, w = mid_w }),
                    text(g and (g.reader_only and _("Opens the dashboard from any book") or _("Opens the dashboard from the file browser and from any book")) or _("Pick a gesture to open the dashboard"), { s = 13, col = INK.g4, w = mid_w, lines = 2 }),
                }),
                pill,
            }),
        }), { kind = "view", view = "shortcut" })
    end

    local enabled = page.plugin:menuBarIconEnabled()
    local bar_card = MenuUI.card(w, {
        space(nil, px(4)),
        menuBarStrip(page, iw),
        MenuUI.row(iw, { icon = MenuUI.tabIcon(px(24), page.plugin:menuBarIconPath()), label = _("Dashboard in the menu bar"),
            sub = enabled and _("One tap from KOReader's top menu") or _("Only under Tools in KOReader's menu"), toggle = enabled, action = { kind = "menu-bar" } }),
    })

    return {
        embedded and text(_("Opening the dashboard"), { s = 18, b = true, w = w }) or false,
        embedded and space(nil, px(12)) or false,
        MenuUI.section(w, _("When KOReader starts"), MenuUI.group(w, radios, { inset = 0 })),
        space(nil, px(12)),
        MenuUI.group(w, {
            MenuUI.row(iw, { icon = "zap", label = _("Prepare in the background"),
                sub = page.plugin.settings.prewarm ~= false and _("Built while the file browser is idle, so it opens at once")
                    or _("Built when you open it"),
                toggle = page.plugin.settings.prewarm ~= false, action = { kind = "flag", key = "prewarm", default_on = true } }),
        }),
        space(nil, px(16)),
        MenuUI.section(w, _("Shortcut"), shortcut_card),
        space(nil, px(16)),
        MenuUI.section(w, _("KOReader menu bar"), bar_card),
    }
end

-- Where Library and Files lead: the book list, the file browser, or each
-- home screen a plugin adds to KOReader's Start with menu.
-- { label, sub, value } each, and the value in use.
local function libraryChoices(settings)
    local target = StartScreen.target(settings)
    local choices = {
        { _("Book list"), _("Library opens the dashboard's list, Files closes it"), "list" },
        { _("File browser"), _("With your covers plugin, if you use one"), "files" },
    }
    local listed = false
    for _i, home in ipairs(StartScreen.list(require("apps/filemanager/filemanager").instance)) do
        table.insert(choices, { home.label, home.current and _("Your start screen") or _("Home screen plugin"), home.id })
        listed = listed or home.id == target
    end
    -- A choice whose plugin cannot be seen from here (in a book) or is gone.
    if StartScreen.isHome(target) and not listed then
        table.insert(choices, { target:sub(1, 1):upper() .. target:sub(2), _("Not found, so the file browser opens"), target })
    end
    return choices, target
end

local function libraryLabel(settings)
    local choices, target = libraryChoices(settings)
    for _i, c in ipairs(choices) do
        if c[3] == target then return c[1] end
    end
end

local function libraryBody(page, w, embedded)
    local iw = MenuUI.rowsIn(w)
    local choices, target = libraryChoices(page.plugin.settings)
    local rows = {}
    for _i, c in ipairs(choices) do
        table.insert(rows, MenuUI.row(iw, { label = c[1], sub = c[2], radio = c[3] == target, h = 64, action = { kind = "library-target", value = c[3] } }))
    end
    return {
        embedded and text(_("Library and Files"), { s = 18, b = true, w = w }) or false,
        embedded and space(nil, px(12)) or false,
        MenuUI.group(w, rows, { inset = 0 }),
        space(nil, px(12)),
        MenuUI.card(w, { space(nil, px(12)), text(_("Home screens come from KOReader's Start with menu, where plugins such as Bookshelf and Simple UI add themselves."), { s = 13, col = INK.g4, w = iw, lines = 3, bg = INK.ge }), space(nil, px(12)) }, { fill = true }),
    }
end

local function boardBody(page, w, embedded)
    local settings = page.plugin.settings
    local state = BoardStore.read(settings)
    local iw = MenuUI.rowsIn(w)
    local top = MenuUI.group(w, {
        MenuUI.row(iw, { icon = "layout-grid", label = _("Customize the board"), sub = _("Move, resize, add and remove widgets"), chevron = true, action = { kind = "customize" } }),
        MenuUI.row(iw, { icon = "book-open", label = _("Tap Continue reading"), sub = settings.tap_resumes ~= false and _("Opens the book") or _("Shows the book's actions"),
            toggle = settings.tap_resumes ~= false, action = { kind = "flag", key = "tap_resumes", default_on = true } }),
        MenuUI.row(iw, { icon = "folder-open", label = _("Library and Files open"), sub = libraryLabel(settings), chevron = true, action = { kind = "view", view = "library" } }),
    })
    local preset_labels = { _("Reader"), _("Stats"), _("Library") }
    local tile_labels = { _("Outline"), _("Soft"), _("Ink") }
    local scale_labels = {}
    for index, scale in ipairs(BoardMetrics.UI_SCALES) do
        scale_labels[index] = scaleLabel(scale)
    end
    local a = segRow(iw, _("Starting layout"), _("Replaces your pages with a starter set"), preset_labels, indexOf(PRESETS, state.preset, 1),
        function(index) return { kind = "preset", value = PRESETS[index] } end)
    local b = segRow(iw, _("Tile style"), nil, tile_labels, indexOf(TILES, state.tiles, 1),
        function(index) return { kind = "tiles", value = TILES[index] } end)
    local c = segRow(iw, _("Interface size"), _("Text and controls across the dashboard"), scale_labels,
        indexOf(BoardMetrics.UI_SCALES, BoardMetrics.normalizeUserScale(settings.ui_scale), 1),
        function(index) return { kind = "ui-scale", value = BoardMetrics.UI_SCALES[index] } end)
    a._no_icon, b._no_icon, c._no_icon = true, true, true
    local look = MenuUI.group(w, { a, b, c }, { inset = 0 })
    local reset = MenuUI.group(w, {
        MenuUI.row(iw, { icon = "rotate-ccw", label = _("Reset the board"), sub = _("Back to the starting layout and outline tiles"), action = { kind = "reset-board" } }),
    })
    return {
        embedded and text(_("Board"), { s = 18, b = true, w = w }) or false,
        embedded and space(nil, px(12)) or false,
        top,
        space(nil, px(16)),
        MenuUI.section(w, _("Look"), look),
        space(nil, px(16)),
        reset,
    }
end

local function readingBody(page, w, embedded)
    local settings = page.plugin.settings
    local iw = MenuUI.rowsIn(w)
    local goal = tonumber(settings.goal) or 0
    return {
        embedded and text(_("Reading goal"), { s = 18, b = true, w = w }) or false,
        embedded and space(nil, px(12)) or false,
        MenuUI.group(w, {
            MenuUI.row(iw, { icon = "target", label = _("Books a year"), sub = goal > 0 and _("Shown by the Goal pace widget") or _("Off"), h = 64,
                trail = MenuUI.stepper(goal, _("books"), { kind = "goal", delta = -1 }, { kind = "goal", delta = 1 }) }),
        }),
        space(nil, px(12)),
        MenuUI.card(w, { space(nil, px(12)), text(_("A book counts once you mark it finished, in KOReader's book status or from the dashboard."), { s = 13, col = INK.g4, w = iw, lines = 3, bg = INK.ge }), space(nil, px(12)) }, { fill = true }),
    }
end

-- Check for update, or Update to the version a check found.
local function updateRow(plugin, iw)
    local latest = plugin.settings.update_latest
    if plugin:hasKnownUpdate() then
        return MenuUI.row(iw, { icon = "download", label = T(_("Update to %1"), latest), sub = T(_("You have %1"), plugin.PLUGIN_VERSION),
            trail = MenuUI.chip(_("New"), { ink = true }), chevron = true, action = { kind = "update" } })
    end
    local checked = tonumber(plugin.settings.update_checked_at)
    return MenuUI.row(iw, { icon = "refresh-cw", label = _("Check for update"),
        sub = checked and T(_("Up to date · checked %1"), MenuUI.ago(checked) or "") or _("Not checked yet"),
        chevron = true, action = { kind = "check-update" } })
end

local function aboutBody(page, w, embedded)
    local plugin = page.plugin
    local iw = MenuUI.rowsIn(w)
    local function para(str, o)
        o = o or {}
        return text(str, { s = o.s or 13, b = o.b, col = o.col or INK.g3, w = iw, lines = o.lines or 6, data = true })
    end
    return {
        embedded and text(_("About"), { s = 18, b = true, w = w }) or false,
        embedded and space(nil, px(12)) or false,
        MenuUI.card(w, {
            space(nil, px(12)),
            text(_("Bookorbit Dashboard"), { s = 16, b = true, w = iw }),
            text(T(_("Version %1 · modified %2"), plugin.PLUGIN_VERSION, plugin.MODIFIED_DATE), { s = 13, col = INK.g4, w = iw }),
            space(nil, px(8)),
            para(_("The Bookorbit Dashboard but stripped of everything related to Bookorbit: a board of reading widgets over KOReader's file browser, built from this device's own books, history and statistics. Its only network request is the update check below.")),
            space(nil, px(8)),
            para(T(_("Source code: %1"), Settings.SOURCE_URL)),
            space(nil, px(12)),
        }),
        space(nil, px(16)),
        MenuUI.section(w, _("Updates"), MenuUI.group(w, {
            updateRow(plugin, iw),
            MenuUI.row(iw, { icon = "calendar-check", label = _("Check daily"), sub = _("Once a day, when Wi-Fi is on"),
                toggle = plugin.settings.update_check ~= false, action = { kind = "flag", key = "update_check", default_on = true } }),
        })),
        space(nil, px(16)),
        MenuUI.section(w, _("Legal notices"), MenuUI.card(w, {
            space(nil, px(12)),
            BoardUI.hit(text("Powered by BookOrbit", { s = 15, b = true, w = iw }), { kind = "upstream" }),
            space(nil, px(4)),
            para("Copyright (C) 2025-2026 neon.\nAdditional copyright is held by the respective BookOrbit contributors."),
            para("Original project: " .. Settings.UPSTREAM_URL),
            space(nil, px(8)),
            para("Licensed under the GNU Affero General Public License, version 3 only, with additional terms. This software is provided without warranty. You may redistribute and modify it under those terms."),
            space(nil, px(8)),
            para("This is a modified version of BookOrbit and is not an official BookOrbit release.", { b = true, col = INK.black }),
            space(nil, px(12)),
        })),
    }
end

local BODIES = { opening = openingBody, board = boardBody, reading = readingBody, about = aboutBody, library = libraryBody }

local function bodyFor(page, view, w, embedded)
    return (BODIES[view] or openingBody)(page, w, embedded)
end

-- --------------------------------------------------------------- shortcut
local function shortcutBody(page, w)
    local options = Shortcut.available(Device:hasMultitouch())
    local current = Shortcut.current(page.gestures_data)
    local W = BoardMetrics.get().W
    local total = #options + 1
    local cols = W >= 900 and math.min(total, 5) or W >= 700 and 3 or 2
    local gap = px(10)
    local cw = math.floor((w - (cols - 1) * gap) / cols)
    local illus = math.min(px(64), math.floor(cw * 0.42))
    local pad = px(14)
    local name_of = function(binding)
        local ok, name = pcall(function() return require("dispatcher"):menuTextFunc(binding) end)
        return ok and name or _("another action")
    end
    local cards = {}
    local entries = {}
    for _i, g in ipairs(options) do table.insert(entries, { id = g.id, kind = g.kind, label = g.label() }) end
    table.insert(entries, { id = false, kind = "none", label = _("No shortcut") })
    for _i, e in ipairs(entries) do
        local on = (e.id or nil) == current
        local note, warn
        if e.id then
            note, warn = Shortcut.describe(page.gestures_data, e.id, name_of)
        else
            note = _("Menu bar only")
        end
        local iw = cw - 2 * pad
        local note_row = hstack({ w = iw, gap = px(5), valign = "top" }, {
            warn and icon("triangle-alert", px(14), { sw = 2.25 }) or false,
            text(note, { s = 12, col = INK.g4, b = warn, lines = 2, w = iw - (warn and px(19) or 0), data = true }),
        })
        local inner = vstack({ w = iw, pad = { pad, 0, pad, 0 } }, {
            MenuUI.gesture(e.kind, illus),
            space(nil, px(10)),
            text(e.label, { s = 15, b = true, lines = 2, w = iw }),
            space(nil, px(10)),
            note_row,
        })
        local h = inner:getSize().h
        local border = on and math.max(2, px(2.5)) or MenuUI.line()
        local card = BoardUI.overlay(cw, h, {
            { widget = BoardUI.box({ w = cw, h = h, radius = px(12), border = border, border_col = on and INK.black or INK.g8, bg = INK.white }) },
            { widget = inner, x = pad, y = 0 },
            on and { widget = MenuUI.check(), x = cw - px(10) - px(24), y = px(10) } or {},
        })
        table.insert(cards, BoardUI.hit(card, { kind = "shortcut", id = e.id, replaces = warn and note or nil }))
    end
    local rows = {}
    for start = 1, #cards, cols do
        local items = {}
        for index = start, math.min(#cards, start + cols - 1) do table.insert(items, cards[index]) end
        if #rows > 0 then table.insert(rows, space(nil, gap)) end
        table.insert(rows, hstack({ gap = gap, valign = "top" }, items))
    end
    local iw = MenuUI.rowsIn(w)
    return {
        vstack({ w = w }, rows),
        space(nil, px(16)),
        MenuUI.card(w, {
            hstack({ w = iw, gap = px(12), valign = "top" }, {
                vstack({}, { space(nil, px(12)), icon("info", px(20), { sw = 2 }) }),
                vstack({ w = iw - px(32), pad = { px(12), 0, px(12), 0 } }, {
                    text(_("Top-left hold and top-right tap work in books only. Other choices also work in the file browser. Existing actions are named before replacement."), { s = 13, col = INK.g4, lines = 4, w = iw - px(32), bg = INK.ge }),
                }),
            }),
        }, { fill = true }),
    }
end

-- ------------------------------------------------------------------ build
local function build(page, sw, sh)
    local mx = MenuUI.mx()
    local top, bottom = px(6), px(12)
    local w = sw - 2 * mx
    local view = page.stack[#page.stack]
    local items
    if view == "shortcut" then
        items = { MenuUI.pageHeader(w, _("Shortcut"), { sub = _("Choose how to open the dashboard") }), space(nil, px(8)) }
        for _i, item in ipairs(shortcutBody(page, w)) do table.insert(items, item) end
    elseif MenuUI.wide() then
        page.detail = view ~= "root" and view or page.detail or "opening"
        local left_w = math.floor(math.min(px(300), w * 0.36))
        local gutter = px(24)
        local right_w = w - left_w - gutter
        local left = vstack({ w = left_w }, settingsList(page, left_w, true))
        local right = vstack({ w = right_w }, bodyFor(page, page.detail, right_w, true))
        local split_h = math.max(left:getSize().h, right:getSize().h)
        items = {
            MenuUI.pageHeader(w, _("Settings"), {}),
            space(nil, px(8)),
            hstack({ w = w, h = split_h, valign = "top" }, {
                left,
                space(math.floor(gutter / 2), 1),
                BoardUI.rect(MenuUI.hair(), split_h, INK.gc),
                space(gutter - math.floor(gutter / 2) - MenuUI.hair(), 1),
                right,
            }),
        }
    elseif view == "root" then
        items = { MenuUI.pageHeader(w, _("Settings"), { sub = _("Bookorbit Dashboard") }), space(nil, px(8)) }
        for _i, item in ipairs(settingsList(page, w, false)) do table.insert(items, item) end
        table.insert(items, flex(px(8)))
        table.insert(items, text(T(_("Bookorbit Dashboard %1"), page.plugin.PLUGIN_VERSION), { s = 13, col = INK.g4, w = w, align = "center" }))
    else
        items = { MenuUI.pageHeader(w, titleOf(view), { sub = _("Settings") }), space(nil, px(8)) }
        for _i, item in ipairs(bodyFor(page, view, w, false)) do table.insert(items, item) end
    end
    page.panel_rect = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    return vstack({ w = sw, h = sh, pad = { top, mx, bottom, mx } }, items)
end

-- ---------------------------------------------------------------- actions
local function confirm(title, body, ok_text, ok, ok_icon)
    require("dashboard_dialog_ui").confirm{ title = title, text = body, ok_label = ok_text, ok_icon = ok_icon, on_ok = ok }
end

local function onAction(page, action)
    local plugin, view = page.plugin, page.view
    local settings = plugin.settings
    local kind = action.kind
    if kind == "view" then
        if MenuUI.wide() and action.view ~= "shortcut" then
            page.detail = action.view
            page.stack = { "root" }
        else
            table.insert(page.stack, action.view)
        end
        page:refresh()
    elseif kind == "library-target" then
        settings.library_target = action.value
        settings.library_opens_files = nil
        plugin:saveSettings()
        page:refresh()
    elseif kind == "open-mode" then
        settings.auto_open = action.mode
        plugin:saveSettings()
        page:refresh()
    elseif kind == "menu-bar" then
        plugin:setMenuBarIconEnabled(not plugin:menuBarIconEnabled())
        page:refresh()
    elseif kind == "flag" then
        local current = settings[action.key]
        if action.default_on then current = current ~= false end
        settings[action.key] = not current
        plugin:saveSettings()
        if view then view:updateItems() end
        page:refresh()
    elseif kind == "goal" then
        local goal = math.max(0, math.min(500, (tonumber(settings.goal) or 0) + action.delta))
        settings.goal = goal > 0 and goal or nil
        plugin:saveSettings()
        if view then view:boardReload() end
        page:refresh()
    elseif kind == "customize" then
        page:close()
        plugin:customizeBoard(view)
    elseif kind == "preset" then
        if BoardStore.read(settings).preset == action.value then return true end
        confirm(_("Start the board from this layout?"), _("Your pages are replaced by this layout's pages."), _("Replace"), function()
            plugin:applyBoardSetting(view, function(s) return BoardStore.withPreset(s, action.value) end)
            page:refresh()
        end)
    elseif kind == "tiles" then
        plugin:applyBoardTiles(view, action.value)
        page:refresh()
    elseif kind == "ui-scale" then
        if settings.ui_scale == action.value then return true end
        settings.ui_scale = BoardMetrics.setUserScale(action.value)
        plugin:saveSettings()
        BoardUI.clearSnapshots()
        if view then view:updateItems() end
        page:refresh()
    elseif kind == "reset-board" then
        confirm(_("Reset the board?"), _("Your pages and tile style go back to how they started."), _("Reset"), function()
            plugin:applyBoardSetting(view, function(s)
                local state = BoardStore.withPreset(s, BoardStore.read(s).preset)
                state.tiles = "outline"
                return state
            end)
            page:refresh()
        end)
    elseif kind == "check-update" then
        plugin:checkForUpdate(true, function() page:refresh() end)
    elseif kind == "update" then
        plugin:checkForUpdate(true, function() page:refresh() end)
    elseif kind == "upstream" then
        local size = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.6)
        UIManager:show(require("ui/widget/qrmessage"):new{ text = Settings.UPSTREAM_URL, width = size, height = size })
    elseif kind == "shortcut" then
        local apply = function()
            if not plugin:applyShortcut(action.id or nil) then return end
            page.gestures_data = plugin:gesturesData()
            page:refresh()
        end
        if action.replaces then
            confirm(_("Use this gesture for the dashboard?"), T(_("%1."), action.replaces), _("Use it"), apply)
        else
            apply()
        end
    end
    return true
end

-- Back steps out of the shortcut picker (or a group on a phone) before it
-- closes Settings.
local function onBack(page)
    if #page.stack > 1 then
        table.remove(page.stack)
        page:refresh()
        return true
    end
    return false
end

-- view: the open dashboard, or nil. group: nil for the root, or a group id
-- ("opening", "board", "reading", "about", "shortcut").
function Settings.open(plugin, view, group)
    -- On wide screens a group opens beside the list rather than on top of it;
    -- only the shortcut picker is a page of its own there.
    local stack = { "root" }
    if group and group ~= "root" and (group == "shortcut" or not MenuUI.wide()) then table.insert(stack, group) end
    local page = MenuPage:new{
        name = "dashboard_settings",
        build = build,
        on_action = onAction,
        on_back = onBack,
        plugin = plugin,
        view = view,
        stack = stack,
        detail = group and group ~= "root" and group ~= "shortcut" and group or nil,
        gestures_data = plugin:gesturesData(),
    }
    UIManager:show(page, "ui")
    return page
end

return Settings
