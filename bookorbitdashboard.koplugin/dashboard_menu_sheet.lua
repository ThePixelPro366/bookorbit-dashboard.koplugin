--[[--
The dashboard menu: the sheet the menu button and a swipe down from the top
edge open on the dashboard.

Where your books are, the three things done most (customize, history, leave
to the file browser), every place in the library with its count, then
settings and about. A full-width sheet from the top on phones and 6-7"
readers; a popover under the button it came from on tablets and in
landscape. Built from data the dashboard already holds.
]]

local _ = require("gettext")
local T = require("ffi/util").template

local BoardMetrics = require("dashboard_board_metrics")
local BoardUI = require("dashboard_board_ui")
local MenuPage = require("dashboard_menu_page")
local MenuUI = require("dashboard_menu_ui")

local INK = BoardMetrics.INK
local px = BoardMetrics.px
local text, vstack, hstack, flex, space, icon = BoardUI.text, BoardUI.vstack, BoardUI.hstack, BoardUI.flex, BoardUI.space, BoardUI.icon

local MenuSheet = {}

local NAV = {
    { link = "library", icon = "book-copy", label = function() return _("Library") end, count = "library" },
    { link = "authors", icon = "feather", label = function() return _("Authors") end, count = "authors" },
    { link = "series", icon = "layers-2", label = function() return _("Series") end, count = "series" },
    { link = "collections", icon = "folder-open", label = function() return _("Collections") end, count = "collections" },
    { link = "history", icon = "clock", label = function() return _("History") end, count = "in_progress" },
    { link = "device", icon = "house", label = function() return _("Home folder") end, count = "device" },
}

function MenuSheet.data(plugin, view)
    local body = view and view.current_context and view.current_context.dashboard or {}
    local counts = type(body.browseCounts) == "table" and body.browseCounts or {}
    local datetime = require("datetime")
    local now = os.time()
    local home = require("dashboard_library").homeDir() or ""
    local d = {
        name = _("Bookorbit Dashboard"),
        host = (home:gsub("/+$", "")):match("([^/]+)$") or home,
        clock = datetime.secondsToHour(now, G_reader_settings:isTrue("twelve_hour_clock")),
        counts = {
            library = tonumber(body.totalBooks),
            authors = tonumber(counts.authors),
            series = tonumber(counts.series),
            collections = tonumber(counts.collections),
            in_progress = tonumber(counts.inProgress),
            device = tonumber(body.totalBooks),
        },
        version = plugin.PLUGIN_VERSION,
    }
    return d
end

local function tile(w, h, glyph, label, sub, action, data)
    local pad = px(14)
    local iw = w - 2 * pad
    local inner = vstack({ w = iw, h = h }, {
        flex(0),
        icon(glyph, px(24), { sw = 2 }),
        space(nil, px(6)),
        text(label, { s = 15, b = true, w = iw }),
        text(sub, { s = 12, col = INK.g4, w = iw, data = data }),
        flex(0),
    })
    return BoardUI.hit(MenuUI.card(w, { inner }, { pad = 14 }), action)
end

local function navGrid(w, d, ncols)
    local pad = px(16)
    local iw = w - 2 * pad
    local gap = px(24)
    local cw = math.floor((iw - (ncols - 1) * gap) / ncols)
    local rh = px(50)
    local rows = {}
    for start = 1, #NAV, ncols do
        local cells = {}
        for index = start, math.min(#NAV, start + ncols - 1) do
            local entry = NAV[index]
            local here = false
            local count = d.counts[entry.count]
            local right = here and MenuUI.chip(_("Here"), { h = 22 })
                or text(count and tostring(count) or "", { s = 14, col = INK.g4 })
            local cell = hstack({ w = cw, h = rh, gap = px(12) }, {
                icon(entry.icon, px(20), { sw = here and 2.5 or 2 }),
                text(entry.label(), { s = 15, b = here, w = cw - px(20) - 2 * px(12) - right:getSize().w }),
                right,
            })
            table.insert(cells, BoardUI.hit(cell, { kind = "link", link = entry.link }))
        end
        if #rows > 0 then table.insert(rows, BoardUI.rect(iw, MenuUI.hair(), INK.gb)) end
        table.insert(rows, hstack({ w = iw, h = rh, gap = gap }, cells))
    end
    local card = MenuUI.card(w, rows)
    local layers = { { widget = card } }
    local h = card:getSize().h
    for k = 1, ncols - 1 do
        table.insert(layers, { widget = BoardUI.rect(MenuUI.hair(), h - 2 * px(10), INK.gb), x = pad + k * cw + math.floor((k - 0.5) * gap), y = px(10) })
    end
    return BoardUI.overlay(w, h, layers)
end

-- The sheet's content at width w. o.popover drops the status cluster and
-- search (the page behind keeps them in view); o.cols lays places out wider.
function MenuSheet.body(d, w, o)
    o = o or {}
    local inset = MenuUI.tapInset(24)
    local total = d.counts.library or 0
    local sub = { { t = T(_.ngettext("%1 book", "%1 books", total), total) .. " · " }, { t = T(_("in %1"), d.host) } }
    local right = {}
    if not o.popover then
        table.insert(right, BoardUI.statusCluster(d))
        table.insert(right, space(px(6), 1))
        table.insert(right, MenuUI.iconButton("search", { kind = "search" }))
    end
    table.insert(right, MenuUI.iconButton("x", { kind = "close" }))
    local right_group = hstack({}, right)
    local title_w = w - right_group:getSize().w + inset
    local header = hstack({ w = w + inset, h = px(64) }, {
        vstack({ w = title_w }, {
            text(d.name, { s = 22, b = true, w = title_w, data = true }),
            BoardUI.runs(sub, { s = 13, col = INK.g4, w = title_w, data = true }),
        }),
        right_group,
    })

    local gap = px(10)
    local tw = math.floor((w - 2 * gap) / 3)
    local th = px(o.popover and 80 or 84)
    local first = tile(tw, th, "layout-grid", _("Customize"), _("Edit this board"), { kind = "customize" })
    local second = tile(tw, th, "clock", _("History"), _("Books you opened"), { kind = "link", link = "history" })
    local last_w = w - 2 * tw - 2 * gap
    local third = tile(last_w, th, "folder-open", _("Files"), _("Close the dashboard"), { kind = "exit" })
    local tiles = hstack({ w = w, gap = gap }, { first, second, third })

    local iw = MenuUI.rowsIn(w)
    local rows = {}
    table.insert(rows, MenuUI.row(iw, { icon = "sliders-horizontal", label = _("Settings"), sub = _("Opening, layout, goal, interface size"), chevron = true, action = { kind = "settings" } }))
    table.insert(rows, MenuUI.row(iw, { icon = "circle-help", label = _("About"),
        sub = T(_("Version %1 · legal notices"), d.version),
        chevron = true, action = { kind = "about" } }))

    return {
        BoardUI.overlay(w, px(64), { { widget = header, x = 0, y = 0 } }),
        space(nil, px(8)),
        tiles,
        space(nil, px(16)),
        MenuUI.section(w, _("Go to"), navGrid(w, d, o.cols or 2)),
        space(nil, px(16)),
        MenuUI.group(w, rows),
    }
end

-- Builds the whole screen: the sheet or popover over the lightened backdrop.
local function build(page, sw, sh)
    local d = page.sheet_data
    local mx = MenuUI.mx()
    if MenuUI.wide() then
        local pw = math.min(px(MenuUI.landscape() and 620 or 460), sw - 2 * mx)
        local pad = px(18)
        local content = vstack({ w = pw - 2 * MenuUI.line(), pad = { px(4), pad - MenuUI.line(), pad, pad - MenuUI.line() } },
            MenuSheet.body(d, pw - 2 * pad, { popover = true, cols = MenuUI.landscape() and 3 or 2 }))
        local ph = content:getSize().h + 2 * MenuUI.line()
        local panel = BoardUI.box({ w = pw, h = ph, radius = px(16), border = math.max(1, px(1.5)), border_col = INK.black, bg = INK.white }, content)
        -- Under the button it came from: top right on Home and on the lists.
        local x = sw - mx - pw
        local y = px(52)
        page.panel_rect = require("ui/geometry"):new{ x = x, y = y, w = pw, h = ph }
        return BoardUI.overlay(sw, sh, { { widget = panel, x = x, y = y } })
    end
    local w = sw - 2 * mx
    local content = vstack({ w = sw, pad = { px(6), mx, px(18), mx } }, MenuSheet.body(d, w))
    local ph = content:getSize().h
    local line = math.max(1, px(1.5))
    local r = px(16)
    -- Square at the top edge, rounded at the bottom with a black rule along it.
    local layers = {
        { widget = BoardUI.rect(sw, ph, INK.black, r) },
        { widget = BoardUI.rect(sw, r, INK.black) },
        { widget = BoardUI.rect(sw, ph - line, INK.white, r) },
        { widget = BoardUI.rect(sw, r, INK.white) },
        { widget = content },
    }
    page.panel_rect = require("ui/geometry"):new{ x = 0, y = 0, w = sw, h = ph }
    return BoardUI.overlay(sw, sh, layers)
end

-- opts.on_action(page, action) runs everything the sheet does not do itself.
function MenuSheet.open(plugin, view, on_action)
    local page = MenuPage:new{
        name = "dashboard_menu_sheet",
        backdrop = true,
        dismiss_outside = true,
        build = build,
        on_action = on_action,
        sheet_data = MenuSheet.data(plugin, view),
    }
    require("ui/uimanager"):show(page, "ui")
    return page
end

return MenuSheet
