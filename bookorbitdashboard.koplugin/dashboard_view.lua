--[[--
The dashboard: a full-screen board of widgets over KOReader's file browser.

Draws the board for the current page: a header (greeting, date, device
status, search and menu), the packed grid of widget tiles, and a footer that
moves between the pages. Swipes and page-turn keys flip pages too; a swipe
down from the top edge opens the dashboard menu, and Back closes it to the
file browser.

Every tile is one InputContainer, so a change refreshes only that tile's
rectangle. Widgets record the regions a tap can land on while they paint, so
a tap goes to exactly what was drawn there: a cover, a stepper, a button. A
D-pad press is a tap at the focused tile's centre, which lands on the tile's
own action.

Each page, once built, is kept as a bitmap with its tiles: showing it again
(a page flip, coming back from a list) is one blit, and the pages beside the
one on screen are built while the reader is idle. A tile or the header that
changes repaints only its own rectangle of that bitmap. Edit mode, the
starter and D-pad focus draw live instead.

This module is derived from BookOrbit's KOReader plugin (catalog board); see
the NOTICE file shipped with this plugin.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local T = require("ffi/util").template
local _ = require("gettext")

local BoardData = require("dashboard_board_data")
local BoardEdit = require("dashboard_board_edit")
local BoardLayout = require("dashboard_board_layout")
local BoardMetrics = require("dashboard_board_metrics")
local BoardStore = require("dashboard_board_store")
local BoardUI = require("dashboard_board_ui")
local BoardWidgets = require("dashboard_board_widgets")
local Library = require("dashboard_library")
local StartScreen = require("dashboard_start_screen")

local Screen = Device.screen
local INK = BoardMetrics.INK
local px, lh1 = BoardMetrics.px, BoardMetrics.lh1
local text, runs, vstack, hstack, flex, space, icon = BoardUI.text, BoardUI.runs, BoardUI.vstack, BoardUI.hstack, BoardUI.flex, BoardUI.space, BoardUI.icon

local function focusable(child)
    if not Device:hasDPad() or Device:isTouchDevice() then return child end
    return FrameContainer:new{
        margin = 0,
        padding = 0,
        bordersize = 0,
        focusable = true,
        focus_inner_border = true,
        focus_border_size = px(3),
        child,
    }
end

local DashboardView = FocusManager:extend{
    name = "dashboard",
    covers_fullscreen = true,
    -- The plugin: settings, and what the menu button opens.
    plugin = nil,
    settings = nil,
}


-- --------------------------------------------------------------- tiles
local BoardTile = InputContainer:extend{
    item = nil,
    menu = nil,
    hits = nil,
}

function BoardTile:init()
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function BoardTile:actionAt(pos)
    if pos and self.hits then
        for index = #self.hits, 1, -1 do
            local area = self.hits[index]
            if area.dimen and pos:intersectWith(area.dimen) then return area.action end
        end
    end
    return self.item.action
end

function BoardTile:onTapSelect(_, ges)
    Library.busy()
    local action = self:actionAt(ges and ges.pos)
    if action then self.menu:boardRun(action, self) end
    return true
end

-- Holding a widget starts editing the board with that widget selected.
function BoardTile:onHoldSelect()
    if self.item.index and not self.menu:boardEditing() then
        self.menu:boardEnterEdit(self.item.index)
    end
    return true
end

-- -------------------------------------------------------------- context
function DashboardView:boardHasLight()
    return Device:hasFrontlight()
end

function DashboardView:boardLandscape()
    local m = BoardMetrics.get()
    return m.w > m.h
end

function DashboardView:boardPages(cols)
    return BoardStore.pages(self.settings, cols, self:boardHasLight(), self:boardLandscape())
end

-- The names of the pages on screen, in order: a Stats or Library starter puts
-- a different page first.
function DashboardView:boardPageNames(cols)
    if self.board_edit then return BoardStore.pageNames(self.board_edit.pages) end
    return BoardStore.pageNames(self:boardPages(cols))
end

-- The page shown, kept on the dashboard context so going into a book and
-- back returns to the same page.
function DashboardView:boardPage()
    local context = self.current_context or {}
    local page = tonumber(context.board_page) or 1
    return math.max(1, math.min(BoardStore.PAGE_COUNT, page))
end

-- --------------------------------------------------------------- render
function DashboardView:recalculateDashboardDimen()
    self.perpage = 1
    self.page = 1
    self.page_num = 1
    local top_height, bottom_height = self:menuChromeHeight()
    self.available_height = self.inner_dimen.h - top_height - bottom_height
    self.item_dimen = Geom:new{ x = 0, y = 0, w = self.inner_dimen.w, h = self.available_height }
end

local statusCluster = BoardUI.statusCluster

function DashboardView:boardHeader(d, w, mode, page_name)
    local box = px(44)
    local tap_pad = math.floor((box - px(24)) / 2)
    local function iconButton(name, action, nudge)
        local btn = hstack({ w = box, h = box }, { flex(0), icon(name, px(23), { sw = 2 }), flex(0) })
        return BoardUI.hit(btn, action), nudge
    end
    if mode == "edit" then
        local done_inner = hstack({ h = px(40) }, { space(px(20), 1), text(_("Done"), { s = 15, b = true, col = INK.white }), space(px(20), 1) })
        local done = BoardUI.hit(BoardUI.box({ w = done_inner:getSize().w, h = px(40), radius = px(20), bg = INK.black }, done_inner), { kind = "edit-done" })
        local tw = w - done:getSize().w - px(12)
        return hstack({ w = w, h = px(64) }, {
            vstack({ w = tw }, {
                text(T(_("Edit %1"), page_name), { s = 22, b = true, w = tw }),
                text(_("Tap a widget to move, resize or remove it"), { s = 13, col = INK.g4, w = tw }),
            }),
            space(px(12), 1),
            done,
        })
    end
    local status = statusCluster(d)
    local search = iconButton("search", { kind = "search" })
    local menu = iconButton("menu", { kind = "menu" })
    local right_w = status:getSize().w + px(6) + 2 * box - tap_pad
    local tw = w - right_w
    local sub = runs({ { t = d.date_long } }, { s = 13, col = INK.g4, w = tw })
    return hstack({ w = w + tap_pad, h = px(64) }, {
        vstack({ w = tw }, { text(d.greeting, { s = 22, b = true, w = tw }), sub }),
        status,
        space(px(6), 1),
        search,
        menu,
    })
end

function DashboardView:boardFooter(w, page, mode)
    local fh = px(40)
    local names = self:boardPageNames(self._board_geometry and self._board_geometry.cols or BoardLayout.columnsFor(BoardMetrics.get().W))
    local function chev(name, enabled, delta)
        local btn = hstack({ w = px(44), h = fh }, { flex(0), icon(name, px(20), { sw = 2.5, col = enabled and "black" or "gb" }), flex(0) })
        return BoardUI.hit(btn, enabled and { kind = "page", delta = delta } or { kind = "noop" })
    end
    local dot_items = {}
    for index = 1, BoardStore.PAGE_COUNT do
        table.insert(dot_items, BoardUI.dot(px(7), index == page, { off = INK.g8 }))
    end
    local dots = hstack({ gap = px(6) }, dot_items)
    if mode == "edit" then
        local add_inner = hstack({ h = px(38), gap = px(8) }, { space(px(6), 1), icon("plus", px(17), { col = "white", sw = 2.75 }), text(_("Add widget"), { s = 14, b = true, col = INK.white }), space(px(10), 1) })
        local add = BoardUI.hit(BoardUI.box({ w = add_inner:getSize().w, h = px(38), radius = px(19), bg = INK.black }, add_inner), { kind = "edit-add" })
        local side = px(120)
        return hstack({ w = w, h = fh }, {
            hstack({ w = side, gap = px(8) }, { dots, text(names[page], { s = 13, b = true }), flex(0) }),
            flex(0), add, flex(0),
            BoardUI.hit(hstack({ w = side, gap = px(4) }, { flex(0), icon("layout-grid", px(16), { sw = 2.25 }), text(_("Pages"), { s = 13, b = true }) }), { kind = "edit-pages" }),
        })
    end
    return hstack({ w = w, h = fh }, {
        flex(0),
        chev("chevron-left", page > 1, -1), space(px(6), 1),
        dots, space(px(6), 1), space(px(4), 1), space(px(6), 1),
        text(names[page], { s = 13, b = true }), space(px(6), 1),
        chev("chevron-right", page < BoardStore.PAGE_COUNT, 1),
        flex(0),
    })
end

-- Default tap action for each widget type. Widgets that draw their own
-- buttons (Resume, steppers, covers) route those taps themselves.
function DashboardView:boardItemAction(item, d)
    local t = item.type
    local lead = d.continue_reading[1]
    local tap_resumes = self.settings.tap_resumes ~= false
    if t == "hero" or t == "forecast" then
        if lead then return { kind = "book", book = lead, resume = tap_resumes, list = { label = _("Continue reading"), books = d.continue_reading } } end
        return { kind = "shelf", source = "all", props = { source = "all", title = _("All books") } }
    elseif t == "goalpace" then
        return { kind = "goal" }
    elseif t == "also" then
        return { kind = "shelf", source = "in-progress", props = { source = "in-progress" } }
    elseif t == "highlight" and d.highlight then
        return { kind = "highlight", highlight = d.highlight }
    elseif t == "shelf" then
        local source = item.props and item.props.source
        return { kind = "shelf", source = source, props = item.props }
    elseif t == "link" then
        return { kind = "link", link = item.props and item.props.link }
    elseif t == "yearago" and d.year_ago and d.year_ago.book and d.year_ago.book.path then
        return { kind = "detail", book_id = d.year_ago.book.id }
    elseif t == "word" and d.word then
        return { kind = "lookup", word = d.word.word }
    elseif t == "chapters" and lead then
        return { kind = "book", book = lead, resume = tap_resumes, list = { label = _("Continue reading"), books = d.continue_reading } }
    elseif t == "dust" then
        local dust = d.dust
        if dust and dust.book then return { kind = "detail", book_id = dust.book.id } end
    end
    return nil
end

function DashboardView:boardBuildTile(ctx, item, w, h, edit)
    local frame, hits = BoardUI.collectHits(function() return BoardWidgets.tile(ctx, item, w, h) end)
    return BoardTile:new{
        dimen = Geom:new{ w = w, h = h },
        item = item,
        menu = self,
        -- In edit mode a tap selects the widget, whatever is drawn under it.
        hits = not edit and hits or nil,
        focusable(frame),
    }
end

-- A tappable region that is not a widget tile: the header, the footer, the
-- edit bar, a sheet.
function DashboardView:boardRegion(build, action)
    local widget, hits = BoardUI.collectHits(build)
    local size = widget:getSize()
    return BoardTile:new{
        dimen = Geom:new{ w = size.w, h = size.h },
        item = { action = action },
        menu = self,
        hits = hits,
        focusable(widget),
    }
end

-- ---------------------------------------------------------- edit overlays
local SIZE_ORDER = { "S", "M", "L", "W", "XL" }
local SIZE_LABELS = { S = "S", M = "M", L = "L", W = function() return _("Wide") end, XL = "XL" }

local function sizeLabel(code)
    local l = SIZE_LABELS[code]
    return type(l) == "function" and l() or l
end

function DashboardView:boardEditBar(item, index, g)
    local bar_h = px(52)
    local function button(name, label, action)
        local inner = vstack({ align = "center" }, {
            icon(name, px(19), { col = "white", sw = 2.25 }),
            space(nil, px(2)),
            text(label, { s = 11, b = true, col = INK.white }),
        })
        return BoardUI.hit(hstack({ h = bar_h }, { space(px(10), 1), inner, space(px(10), 1) }), action)
    end
    local function divider()
        return BoardUI.rect(math.max(1, px(1)), px(30), INK.g5)
    end
    local entry = BoardEdit.entryFor(item)
    local current = BoardEdit.sizeCode(item, g.cols)
    local segs = { text(_("Size"), { s = 11, b = true, col = INK.gb }) }
    local offered = {}
    for _i, code in ipairs(entry and entry.sizes or { current }) do offered[code] = true end
    local seen_dims = {}
    for _i, code in ipairs(SIZE_ORDER) do
        local cw, rh = BoardLayout.sizeDims(code, g.cols)
        local dims = cw .. "x" .. rh
        if offered[code] and not seen_dims[dims] then
            seen_dims[dims] = true
            local on = cw == math.min(item.cw, g.cols) and rh == item.rh
            local label = text(sizeLabel(code), { s = 13, b = true, col = on and INK.black or INK.white })
            local w = math.max(px(30), label:getSize().w + 2 * px(6))
            local seg = BoardUI.box({ w = w, h = px(30), radius = px(6), bg = on and INK.white or nil, border = on and 0 or math.max(1, px(1)), border_col = INK.g8 },
                hstack({ w = w - (on and 0 or 2 * math.max(1, px(1))), h = px(30) - (on and 0 or 2 * math.max(1, px(1))) }, { flex(0), label, flex(0) }))
            table.insert(segs, BoardUI.hit(seg, { kind = "edit-size", code = code }))
        end
    end
    local inner = hstack({ h = bar_h, gap = px(2) }, {
        space(px(6) - px(2), 1),
        button("chevron-left", _("Earlier"), { kind = "edit-move", delta = -1 }),
        button("chevron-right", _("Later"), { kind = "edit-move", delta = 1 }),
        divider(),
        hstack({ h = bar_h, gap = px(5) }, { space(px(8) - px(5), 1), unpack(segs) }),
        space(px(8), 1),
        divider(),
        button("layout-grid", _("Page"), { kind = "edit-page" }),
        button("x", _("Remove"), { kind = "edit-remove", index = index }),
        space(px(6) - px(2), 1),
    })
    local w = inner:getSize().w
    local ring = px(2)
    return BoardUI.overlay(w + 2 * ring, bar_h + 2 * ring, {
        { widget = BoardUI.rect(w + 2 * ring, bar_h + 2 * ring, INK.white, px(12) + ring) },
        { widget = BoardUI.box({ w = w, h = bar_h, radius = px(12), bg = INK.black }, inner), x = ring, y = ring },
    })
end

-- ------------------------------------------------------------ the sheet
function DashboardView:boardPreview(ctx, entry, box_w, box_h, g)
    -- Previews are drawn at the narrowest real column (132dp, a 6" panel),
    -- so a preview never shows a widget smaller than any board does.
    local unit = px(132)
    local cw, rh = BoardLayout.sizeDims(entry.sizes[1], 4)
    local pw = cw == 1 and unit or cw * unit + (cw - 1) * px(10)
    local ph = rh * unit + (rh - 1) * px(10)
    local scale = math.min(1, (box_h - px(16)) / ph, (box_w - px(20)) / pw)
    local sw, sh = math.floor(pw * scale + 0.5), math.floor(ph * scale + 0.5)
    local item = { type = entry.type, cw = cw, rh = rh, chrome = entry.chrome or "line", props = entry.props }
    local key = "preview:" .. entry.type .. ":" .. tostring(entry.props and (entry.props.source or entry.props.link or entry.props.animal) or "") .. ":" .. pw .. "x" .. ph .. ":" .. sw
    local shot = BoardUI.snapshot(key, pw, ph, sw, sh, function()
        return BoardWidgets.tile({ d = ctx.d, tiles = "outline", menu = self }, item, pw, ph)
    end)
    return BoardUI.box({ w = box_w, h = box_h, radius = px(12), bg = INK.ge }, hstack({ w = box_w, h = box_h }, { flex(0), shot, flex(0) }))
end

function DashboardView:boardSheet(ctx, g, screen_w, screen_h)
    local edit = self.board_edit
    local sheet_h = math.floor(screen_h * 0.7 + 0.5)
    local mx = g.mx
    local w = screen_w - 2 * mx
    local pad = px(18)
    local entries, new_count = {}, 0
    for _i, entry in ipairs(BoardEdit.LIBRARY) do
        if entry.new then new_count = new_count + 1 end
        if (edit.sheet_tab == "new" and entry.new) or entry.tab == edit.sheet_tab then table.insert(entries, entry) end
    end
    local tabs = {}
    for _i, tab in ipairs(BoardEdit.TABS) do
        local on = tab.id == edit.sheet_tab
        local label = text(tab.label(), { s = 14, b = on, col = on and INK.black or INK.g4 })
        table.insert(tabs, BoardUI.hit(vstack({ w = label:getSize().w, h = px(40) }, {
            flex(0), label, flex(0), on and BoardUI.rect(label:getSize().w, px(3), INK.black) or space(nil, px(3)),
        }), { kind = "sheet-tab", tab = tab.id }))
    end
    local tab_row = vstack({ w = w }, {
        hstack({ w = w, h = px(40), gap = px(BoardMetrics.get().W < 560 and 16 or 22), valign = "bottom" }, tabs),
        BoardUI.rect(w, math.max(1, px(1)), INK.gb),
    })
    local cols_n = BoardMetrics.get().W >= 700 and 3 or 2
    local gap = px(14)
    local card_w = math.floor((w - (cols_n - 1) * gap) / cols_n)
    local preview_h = px(122)
    local function card(entry)
        local chips = {}
        for _i, code in ipairs(entry.sizes) do
            local label = text(sizeLabel(code), { s = 11, b = true, col = INK.g3 })
            table.insert(chips, BoardUI.box({ w = label:getSize().w + 2 * px(5), h = label:getSize().h, radius = px(4), border = math.max(1, px(1)), border_col = INK.g8 },
                hstack({ w = label:getSize().w + 2 * px(5) - 2 * math.max(1, px(1)) }, { flex(0), label, flex(0) })))
        end
        local chip_row = hstack({ gap = px(4) }, chips)
        local name = text(entry.name(), { s = 14, b = true, w = card_w - chip_row:getSize().w - px(6) })
        return BoardUI.hit(vstack({ w = card_w }, {
            self:boardPreview(ctx, entry, card_w, preview_h, g),
            space(nil, px(6)),
            BoardUI.spread(card_w, name, chip_row),
            space(nil, px(6)),
            text(entry.desc(), { s = 12, col = INK.g4, lines = 2, w = card_w }),
        }), { kind = "sheet-add", entry = entry })
    end
    local head_h = pad + lh1(20) + lh1(13) + px(10) + px(40) + math.max(1, px(1)) + px(16)
    local pager_h = px(52)
    local sample = card(entries[1] or BoardEdit.LIBRARY[1])
    local card_h = sample:getSize().h
    local vgap = px(16)
    local rows_fit = math.max(1, math.floor((sheet_h - head_h - pager_h + vgap) / (card_h + vgap)))
    local per_page = rows_fit * cols_n
    local pages = math.max(1, math.ceil(#entries / per_page))
    edit.sheet_page = math.min(edit.sheet_page or 1, pages)
    local first = (edit.sheet_page - 1) * per_page + 1
    local grid_rows = {}
    for r = 0, rows_fit - 1 do
        local cards = {}
        for c = 0, cols_n - 1 do
            local entry = entries[first + r * cols_n + c]
            if entry then table.insert(cards, card(entry)) end
        end
        if #cards > 0 then
            if #grid_rows > 0 then table.insert(grid_rows, space(nil, vgap)) end
            table.insert(grid_rows, hstack({ gap = gap, valign = "top" }, cards))
        end
    end
    local function chev(name, enabled, delta)
        local b = hstack({ w = px(44), h = pager_h }, { flex(0), icon(name, px(22), { sw = 2.5, col = enabled and "black" or "gb" }), flex(0) })
        return BoardUI.hit(b, enabled and { kind = "sheet-page", delta = delta } or { kind = "noop" })
    end
    local pager = vstack({ w = w }, {
        BoardUI.rect(w, math.max(1, px(0.75)), INK.gc),
        hstack({ w = w, h = pager_h - math.max(1, px(0.75)), gap = px(18) }, {
            flex(0), chev("chevron-left", edit.sheet_page > 1, -1),
            text(T(_("%1 of %2"), edit.sheet_page, pages), { s = 13, b = true }),
            chev("chevron-right", edit.sheet_page < pages, 1), flex(0),
        }),
    })
    local close = BoardUI.hit(BoardUI.circle(px(40), { border = math.max(1, px(1.5)), bg = INK.white }, icon("x", px(20), { sw = 2.5 })), { kind = "sheet-close" })
    local title = vstack({}, {
        text(_("Add a widget"), { s = 20, b = true }),
        text(T(_("%1 widgets · %2 new"), #BoardEdit.LIBRARY, new_count), { s = 13, col = INK.g4 }),
    })
    local body = vstack({ w = screen_w, h = sheet_h, pad = { pad, mx, 0, mx } }, {
        BoardUI.spread(w, title, close),
        space(nil, px(10)),
        tab_row,
        space(nil, px(16)),
        vstack({ w = w }, grid_rows),
        flex(0),
        pager,
    })
    local line = math.max(1, px(2))
    local r = px(18)
    return BoardUI.overlay(screen_w, sheet_h + line, {
        { widget = BoardUI.rect(screen_w, sheet_h + line + r, INK.black, r) },
        { widget = BoardUI.rect(screen_w, sheet_h + r, INK.white, r), y = line },
        { widget = body, y = line },
    })
end

-- ----------------------------------------------------------- first run
function DashboardView:boardShowStarter(state, context)
    return not state.started and context.dashboard ~= nil and not self.board_edit and not self.board_snapshotting
end

local PRESET_INFO = {
    { id = "reader", name = function() return _("Reader") end, desc = function() return _("Your book first, then your pile, highlight and shelves") end },
    { id = "stats", name = function() return _("Stats") end, desc = function() return _("Year in reading, records and forecast up front") end },
    { id = "library", name = function() return _("Library") end, desc = function() return _("Pick back up, Up next and Want to read first") end },
}

function DashboardView:boardBuildStarter(ctx, g, screen_w, screen_h)
    local choice = self.board_starter_choice or "reader"
    local mx = g.mx
    local w = screen_w - 2 * mx
    local top = px(24)
    local head = vstack({ w = w }, {
        text(_("Set up your dashboard"), { s = 24, b = true, w = w }),
        space(nil, px(6)),
        text(_("Pick a starting layout. Each comes with four pages, Home, Insights, Library and Decor, that you can change any time: hold a widget to edit it."),
            { s = 14, col = INK.g3, lines = 3, w = w }),
    })
    local gap = px(BoardMetrics.get().W < 560 and 10 or 16)
    local card_w = math.floor((w - 2 * gap) / 3)
    local btn_h = px(48)
    local text_h = px(10) + lh1(16) + px(2) + 3 * BoardMetrics.lh(12) + px(8)
    local avail_prev = screen_h - top - head:getSize().h - px(24) - text_h - px(24) - btn_h - px(24)
    local scale = math.min((card_w - px(16)) / screen_w, avail_prev / screen_h)
    local pw, ph = math.floor(screen_w * scale + 0.5), math.floor(screen_h * scale + 0.5)
    local function snapshotFor(preset, page, sw, sh)
        return BoardUI.snapshot("starter:" .. preset .. ":" .. page .. ":" .. sw .. "x" .. sh, screen_w, screen_h, sw, sh, function()
            self.board_snapshotting = true
            local board = self:boardBuildScreen(ctx, g, page, screen_w, screen_h, { preset = preset, snapshot = true })
            self.board_snapshotting = false
            return board
        end)
    end
    local cards = {}
    local selected_name
    for _i, info in ipairs(PRESET_INFO) do
        local sel = info.id == choice
        if sel then selected_name = info.name() end
        local prev = BoardUI.overlay(pw, ph, {
            { widget = snapshotFor(info.id, 1, pw, ph) },
            { widget = BoardUI.box({ w = pw, h = ph, radius = px(6), border = math.max(1, px(1)), border_col = INK.gb }) },
        })
        local radio = BoardUI.circle(px(20), { border = math.max(1, px(1.5)), bg = INK.white },
            sel and BoardUI.circle(px(10), { bg = INK.black }, space(1, 1)) or space(1, 1))
        local iw = card_w - 2 * px(8)
        local inner = vstack({ w = card_w, pad = px(8), align = "center" }, {
            prev,
            space(nil, px(10)),
            hstack({ w = iw, gap = px(8) }, { radio, text(info.name(), { s = 16, b = true, w = iw - px(20) - px(8) }) }),
            space(nil, px(2)),
            text(info.desc(), { s = 12, col = INK.g4, lines = 3, w = iw }),
            space(nil, px(8)),
        })
        local size = inner:getSize()
        local card_box = BoardUI.overlay(card_w, size.h, {
            { widget = BoardUI.rect(card_w, size.h, sel and INK.white or INK.ge, px(12)) },
            { widget = inner },
            { widget = BoardUI.box({ w = card_w, h = size.h, radius = px(12), border = sel and px(2.5) or math.max(1, px(1)), border_col = sel and INK.black or INK.gb }) },
        })
        table.insert(cards, self:boardRegion(function() return card_box end,
            { kind = "starter-pick", preset = info.id }))
    end
    local cards_row = hstack({ gap = gap, valign = "top" }, cards)
    local strip_label_h = lh1(13) + px(8)
    local strip_cap_h = px(6) + lh1(12)
    local room = screen_h - 2 * top - head:getSize().h - px(24) - cards_row:getSize().h - px(28) - strip_label_h - strip_cap_h - px(24) - btn_h
    local strip = false
    if room >= px(110) then
        local sg = px(14)
        local page_count = BoardStore.PAGE_COUNT
        local s2 = math.min((w - (page_count - 1) * sg) / page_count / screen_w, room / screen_h)
        local pw2, ph2 = math.floor(screen_w * s2 + 0.5), math.floor(screen_h * s2 + 0.5)
        local thumbs = {}
        for page, name in ipairs(BoardStore.pageNames(BoardStore.starterPages(g.cols, choice, self:boardHasLight(), self:boardLandscape()))) do
            table.insert(thumbs, vstack({ align = "center" }, {
                BoardUI.overlay(pw2, ph2, {
                    { widget = snapshotFor(choice, page, pw2, ph2) },
                    { widget = BoardUI.box({ w = pw2, h = ph2, radius = px(4), border = math.max(1, px(1)), border_col = INK.gb }) },
                }),
                space(nil, px(6)),
                text(page .. "  " .. name, { s = 12, b = true, col = INK.g3 }),
            }))
        end
        strip = vstack({ w = w, align = "center" }, {
            text(T(_("%1 comes with four pages"), selected_name), { s = 13, b = true }),
            space(nil, px(8)),
            hstack({ gap = sg }, thumbs),
        })
    end
    local btn_label = text(T(_("Start with %1"), selected_name), { s = 16, b = true, col = INK.white })
    local btn_w = btn_label:getSize().w + 2 * px(28)
    local button = self:boardRegion(function()
        return BoardUI.box({ w = btn_w, h = btn_h, radius = math.floor(btn_h / 2), bg = INK.black },
            hstack({ w = btn_w, h = btn_h }, { flex(0), btn_label, flex(0) }))
    end, { kind = "starter-start", preset = choice })
    local screen = vstack({ w = screen_w, h = screen_h, pad = { top, mx, top, mx } }, {
        head,
        space(nil, px(24)),
        cards_row,
        flex(px(16)),
        strip,
        strip and flex(px(16)) or false,
        hstack({ w = w }, { flex(0), button, flex(0) }),
    })
    return screen, { cards, { button } }
end

-- ------------------------------------------------------------ the board
-- Builds one board screen. opts.preset draws a starter layout instead of the
-- reader's pages; opts.snapshot builds it for a thumbnail and records
-- nothing on the catalog.
function DashboardView:boardBuildScreen(ctx, g, page, screen_w, screen_h, opts)
    opts = opts or {}
    local d = ctx.d
    local edit = not opts.snapshot and self.board_edit or nil
    local packed
    if edit then
        packed = BoardLayout.pack(edit.pages[page].items, g.cols)
        packed.row_h = math.min(g.max_row, BoardLayout.rowHeight(g, packed.rows))
        packed.grid_h = packed.rows * packed.row_h + math.max(0, packed.rows - 1) * g.gap
    else
        local pages
        if opts.preset then
            pages = BoardStore.starterPages(g.cols, opts.preset, self:boardHasLight(), self:boardLandscape())
        else
            pages = self:boardPages(g.cols)
        end
        packed = BoardLayout.fitPage(g, pages[page].base, pages[page].extras)
    end
    local tiles = {}
    local layers = {}
    local rows = {}
    local selected
    for index, item in ipairs(packed.placed) do
        local tw = BoardLayout.spanWidth(g, item.x, item.cw)
        local th = item.rh * packed.row_h + (item.rh - 1) * g.gap
        local x, y = BoardLayout.cellX(g, item.x), item.y * (packed.row_h + g.gap)
        local placed = {}
        for k, v in pairs(item) do placed[k] = v end
        placed.index = index
        placed.action = edit and { kind = "edit-select", index = index } or self:boardItemAction(item, d)
        local tile = self:boardBuildTile(ctx, placed, tw, th, edit ~= nil)
        if edit and edit.selected == index then
            -- The selection ring: white, then black, outside the tile.
            local r = px(12)
            table.insert(layers, { widget = BoardUI.rect(tw + 2 * px(6), th + 2 * px(6), INK.black, r + px(6)), x = x - px(6), y = y - px(6) })
            table.insert(layers, { widget = BoardUI.rect(tw + 2 * px(3), th + 2 * px(3), INK.white, r + px(3)), x = x - px(3), y = y - px(3) })
            selected = { item = placed, index = index, x = x, y = y, w = tw, h = th }
        end
        table.insert(tiles, { tile = tile, item = placed, x = x, y = y, w = tw, h = th })
        table.insert(layers, { widget = tile, x = x, y = y })
        rows[item.y + 1] = rows[item.y + 1] or {}
        table.insert(rows[item.y + 1], tile)
    end
    if edit then
        local badge = px(26)
        for _i, entry in ipairs(tiles) do
            local b = self:boardRegion(function()
                return BoardUI.circle(badge, { border = math.max(1, px(1.5)), bg = INK.white }, icon("x", px(15), { sw = 3 }))
            end, { kind = "edit-remove", index = entry.item.index })
            table.insert(layers, { widget = b, x = entry.x - px(7), y = entry.y - px(7) })
        end
        if selected then
            local bar = self:boardRegion(function() return self:boardEditBar(selected.item, selected.index, g) end, { kind = "noop" })
            local bw, bh = bar:getSize().w, bar:getSize().h
            local left = math.max(0, math.min(g.w - bw, selected.x + math.floor((selected.w - bw) / 2)))
            local below = selected.y + selected.h + px(12)
            local top = BoardLayout.editBarTop(selected.y, selected.h, bh, px(12), g.avail)
            packed.grid_h = math.max(packed.grid_h, top + bh)
            table.insert(layers, { widget = bar, x = left, y = top })
        end
    end
    local grid = BoardUI.overlay(g.w, packed.grid_h, layers)
    local mode = edit and "edit" or "normal"
    local header = self:boardRegion(function() return self:boardHeader(d, g.w, mode, self:boardPageNames(g.cols)[page]) end)
    local footer = self:boardRegion(function() return self:boardFooter(g.w, page, mode) end)
    local board = vstack({ w = screen_w, h = screen_h, pad = { g.top, g.mx, g.bottom, g.mx } }, {
        header,
        space(nil, g.header_gap),
        grid,
        flex(g.footer_gap),
        footer,
    })
    if not opts.snapshot then
        self._board_tiles = tiles
        self._board_header = header
        self._board_origin = { x = g.mx, y = g.top + g.header_h + g.header_gap }
    end
    return board, rows, packed
end

function DashboardView:updateDashboardItems()
    local old_dimen = self:prepareCustomUpdate()
    BoardMetrics.refresh()
    local context = self.current_context or {}
    local m = BoardMetrics.get()
    local screen_w = self.inner_dimen.w
    local screen_h = self.available_height
    local g = BoardLayout.geometry(px, screen_w, screen_h, m.W)
    local page = self:boardPage()
    local d = BoardData.build(self, context, os.time())
    local state = BoardStore.read(self.settings)
    local ctx = { d = d, tiles = state.tiles, menu = self, tap_resumes = self.settings.tap_resumes ~= false }
    self._board_ctx = ctx
    self._board_geometry = g

    local screen, rows
    self._page_bb = nil
    if self:boardShowStarter(state, context) then
        screen, rows = self:boardBuildStarter(ctx, g, screen_w, screen_h)
        self._board_tiles, self._board_header = {}, nil
    elseif self:boardCacheable() then
        BoardUI.clearSnapshots("starter:")
        local entry = self:boardCachedPage(ctx, g, page, screen_w, screen_h)
        screen, rows = entry.screen, entry.rows
        self._board_tiles, self._board_header, self._page_bb = entry.tiles, entry.header, entry.bb
        self:boardFreshenClock(entry, ctx, g, page)
        self:boardSchedulePrebuild(page)
    else
        BoardUI.clearSnapshots("starter:")
        screen, rows = self:boardBuildScreen(ctx, g, page, screen_w, screen_h)
        if self.board_edit and self.board_edit.sheet then
            local sheet = self:boardRegion(function() return self:boardSheet(ctx, g, screen_w, screen_h) end, { kind = "noop" })
            local sh = sheet:getSize().h
            local backdrop = self:boardRegion(function()
                return space(screen_w, screen_h - sh)
            end, { kind = "sheet-close" })
            screen = BoardUI.overlay(screen_w, screen_h, {
                { widget = screen },
                { widget = backdrop },
                { widget = sheet, x = 0, y = screen_h - sh },
            })
        else
            BoardUI.clearSnapshots("preview:")
        end
    end
    table.insert(self.item_group, screen)
    -- D-pad order: the grid row by row.
    for row_index = 1, #rows do
        if rows[row_index] and #rows[row_index] > 0 then table.insert(self.layout, rows[row_index]) end
    end
    self:boardScheduleClock()
    self:finishCustomUpdate(old_dimen)
end

-- --------------------------------------------------------- page cache
-- Pages are cached as bitmaps only where nothing is drawn live over them.
function DashboardView:boardCacheable()
    if self.board_edit then return false end
    return not (Device:hasDPad() and not Device:isTouchDevice())
end

-- Everything a page's pixels depend on besides the data fingerprint.
function DashboardView:boardPageKey(ctx, page, screen_w, screen_h)
    return table.concat({ page, ctx.d.fingerprint, os.date("%H"), tostring(ctx.tiles), screen_w .. "x" .. screen_h,
        tostring(self.settings.ui_scale), tostring(self.settings.tap_resumes), Library.cover_version or 0,
        tostring(BoardStore.read(self.settings).preset) }, "|")
end

function DashboardView:boardFreePages()
    for _page, entry in pairs(self._pages or {}) do
        if entry.bb then entry.bb:free() end
    end
    self._pages = {}
    self._page_bb = nil
end

-- Builds a page's widgets and paints them once into a bitmap of the
-- screen's own type. Painting sets every tile's position, so taps land on
-- the cached page exactly as on a live one.
function DashboardView:boardBuildPage(ctx, g, page, screen_w, screen_h, key)
    local saved = { self._board_tiles, self._board_header, self._board_origin }
    local screen, rows = self:boardBuildScreen(ctx, g, page, screen_w, screen_h)
    local entry = { key = key, screen = screen, rows = rows, tiles = self._board_tiles, header = self._board_header }
    self._board_tiles, self._board_header, self._board_origin = saved[1], saved[2], saved[3]
    entry.bb = Blitbuffer.new(screen_w, screen_h, Screen.bb:getType())
    entry.bb:fill(INK.white)
    screen:paintTo(entry.bb, 0, 0)
    entry.clock = ctx.d.clock
    self._pages = self._pages or {}
    local old = self._pages[page]
    if old and old.bb and old.bb ~= self._page_bb then old.bb:free() end
    self._pages[page] = entry
    return entry
end

function DashboardView:boardCachedPage(ctx, g, page, screen_w, screen_h)
    local key = self:boardPageKey(ctx, page, screen_w, screen_h)
    local entry = self._pages and self._pages[page]
    if entry and entry.key == key then return entry end
    return self:boardBuildPage(ctx, g, page, screen_w, screen_h, key)
end

-- A cached page drawn a few minutes ago: its header (clock, battery, Wi-Fi)
-- and its clocks are drawn again into the bitmap before it is shown.
function DashboardView:boardFreshenClock(entry, ctx, g, page)
    if entry.clock == ctx.d.clock then return end
    entry.clock = ctx.d.clock
    local header_tile = entry.header
    if header_tile and header_tile.dimen and header_tile.dimen.x then
        local header, hits = BoardUI.collectHits(function() return self:boardHeader(ctx.d, g.w, "normal", self:boardPageNames(g.cols)[page]) end)
        header_tile[1] = header
        header_tile.hits = hits
        entry.bb:paintRect(header_tile.dimen.x, header_tile.dimen.y, header_tile.dimen.w, header_tile.dimen.h, INK.white)
        header_tile:paintTo(entry.bb, header_tile.dimen.x, header_tile.dimen.y)
    end
    for _i, t in ipairs(entry.tiles or {}) do
        if (t.item.type == "clock" or t.item.type == "analog") and t.tile.dimen and t.tile.dimen.x then
            local fresh = self:boardBuildTile(ctx, t.item, t.w, t.h)
            t.tile[1] = fresh[1]
            t.tile.hits = fresh.hits
            local dm = t.tile.dimen
            entry.bb:paintRect(dm.x, dm.y, dm.w, dm.h, INK.white)
            t.tile:paintTo(entry.bb, dm.x, dm.y)
        end
    end
end

-- While the reader looks at a page, the pages either side are built, one
-- per idle moment, so the next flip is a blit.
function DashboardView:boardSchedulePrebuild(page)
    if self._prebuild_task then UIManager:unschedule(self._prebuild_task) end
    self._prebuild_task = function()
        self._prebuild_task = nil
        if self.closed or self.board_edit or not self._board_ctx or self:boardPage() ~= page then return end
        if not self:boardIsTopmost() then return end
        local g = self._board_geometry
        for _i, other in ipairs({ page + 1, page - 1 }) do
            if other >= 1 and other <= BoardStore.PAGE_COUNT then
                local key = self:boardPageKey(self._board_ctx, other, self.inner_dimen.w, self.available_height)
                local entry = self._pages and self._pages[other]
                if not (entry and entry.key == key) then
                    self:boardBuildPage(self._board_ctx, g, other, self.inner_dimen.w, self.available_height, key)
                    -- One page per idle moment; the next one after another pause.
                    return self:boardSchedulePrebuild(page)
                end
            end
        end
    end
    UIManager:scheduleIn(1.5, self._prebuild_task)
end

-- Repaints one widget (a tile or the header) into the cached page and
-- refreshes only its rectangle.
function DashboardView:boardRepaintRegion(widget, mode)
    local dimen = widget.dimen
    if not dimen or not dimen.x then return self:updateItems() end
    if self._page_bb then
        self._page_bb:paintRect(dimen.x, dimen.y, dimen.w, dimen.h, INK.white)
        widget:paintTo(self._page_bb, dimen.x, dimen.y)
    end
    UIManager:setDirty(self, function() return mode or "ui", dimen end)
end

function DashboardView:paintTo(bb, x, y)
    local cached = self._page_bb
    if not cached then return FocusManager.paintTo(self, bb, x, y) end
    self.dimen.x, self.dimen.y = x, y
    bb:blitFrom(cached, x, y, 0, 0, cached:getWidth(), cached:getHeight())
end

-- Repaints one tile in place: rebuilds its content and refreshes only its
-- rectangle, so a stepper or a hero page does not flash the whole board.
function DashboardView:boardRefreshTile(entry, mode)
    if not entry or not self._board_ctx then return end
    self._board_ctx.d = BoardData.build(self, self.current_context or {}, os.time())
    local fresh = self:boardBuildTile(self._board_ctx, entry.item, entry.w, entry.h)
    entry.tile[1] = fresh[1]
    entry.tile.hits = fresh.hits
    self:boardRepaintRegion(entry.tile, mode)
    -- The other cached pages were drawn from older data.
    self:boardForgetOtherPages()
end

function DashboardView:boardForgetOtherPages()
    for page, entry in pairs(self._pages or {}) do
        if entry.bb ~= self._page_bb then
            if entry.bb then entry.bb:free() end
            self._pages[page] = nil
        end
    end
end

-- ------------------------------------------------------------- clock
-- Once a minute the header's clock and any Clock or Analog clock widget are
-- redrawn in place, and on the hour the Reading buddy and Moon phase.
-- Nothing else on the board changes on a timer.
function DashboardView:boardScheduleClock()
    if self._board_clock_task then UIManager:unschedule(self._board_clock_task) end
    self._board_clock_task = function()
        self._board_clock_task = nil
        if self.closed then return end
        if self:boardIsTopmost() then self:boardRefreshClock() end
        self:boardScheduleClock()
    end
    UIManager:scheduleIn(60 - os.time() % 60 + 1, self._board_clock_task)
end

function DashboardView:boardRefreshClock()
    if self.board_edit then return end
    local ctx = self._board_ctx
    local header_tile = self._board_header
    if not ctx or not header_tile or not header_tile.dimen or not header_tile.dimen.x then return end
    ctx.d = BoardData.build(self, self.current_context or {}, os.time())
    local g = self._board_geometry
    local header, hits = BoardUI.collectHits(function() return self:boardHeader(ctx.d, g.w, "normal", self:boardPageNames(g.cols)[self:boardPage()]) end)
    header_tile[1] = header
    header_tile.hits = hits
    self:boardRepaintRegion(header_tile, "fast")
    local hour = os.date("%H")
    local new_hour = self._board_clock_hour ~= nil and self._board_clock_hour ~= hour
    self._board_clock_hour = hour
    for _i, entry in ipairs(self._board_tiles or {}) do
        local t = entry.item.type
        -- The buddy yawns at night and the moon moves on: both change at most
        -- by the hour, so they are redrawn only when one turns.
        if t == "clock" or t == "analog" or (new_hour and (t == "buddy" or t == "moon")) then
            self:boardRefreshTile(entry, "fast")
        end
    end
end

function DashboardView:boardIsTopmost()
    local top = UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget()
    return top == nil or top == self or top == self.show_parent
end

-- ------------------------------------------------------------- actions
local function fileManager()
    return require("apps/filemanager/filemanager").instance
end

function DashboardView:boardRun(action, tile)
    local kind = action.kind
    if kind == "noop" then return end
    if kind:match("^edit%-") or kind:match("^sheet%-") then
        return self:boardEditRun(action)
    elseif kind == "starter-pick" then
        self.board_starter_choice = action.preset
        return self:updateItems()
    elseif kind == "starter-start" then
        self:persistSetting(BoardStore.SETTING_KEY, BoardStore.withPreset(self.settings, action.preset))
        BoardUI.clearSnapshots("starter:")
        self.current_context.board_page = 1
        return self:boardReload()
    elseif kind == "book-actions" then
        return self:showBookActions(action.book)
    end
    if kind == "page" then
        return self:boardFlip(action.delta)
    elseif kind == "menu" then
        self:showMenu()
    elseif kind == "search" then
        self:closeTo(function(fm) if fm.filesearcher then fm.filesearcher:onShowFileSearch() end end)
    elseif kind == "book" then
        if action.resume then
            self:openBook(action.book)
        else
            self:showBookActions(action.book)
        end
    elseif kind == "detail" then
        self:showBookInfo(action.book_id)
    elseif kind == "highlight" then
        self:showHighlight(action.highlight)
    elseif kind == "shelf" then
        self:boardOpenShelf(action)
    elseif kind == "shuffle" then
        self:boardShuffle()
    elseif kind == "link" then
        self:boardOpenLink(action.link)
    elseif kind == "lookup" then
        self:boardLookup(action.word)
    elseif kind == "goal" then
        self:editGoal()
    elseif kind == "light" then
        self:boardAdjustLight(action.what, action.delta)
    elseif kind == "wifi" then
        self:boardToggleWifi()
    elseif kind == "night" then
        UIManager:broadcastEvent(Event:new("ToggleNightMode"))
        self:updateItems()
    elseif kind == "frontlight" then
        UIManager:broadcastEvent(Event:new("ShowFlDialog"))
    elseif kind == "rotate" then
        UIManager:broadcastEvent(Event:new("IterateRotation"))
    elseif kind == "files" then
        self:closeToHome()
    elseif kind == "dust-next" then
        self:boardDustNext()
    elseif kind == "dust-remove" then
        self:boardDustRemove(action.book)
    end
end

-- ---------------------------------------------------------------- books
local function bookFor(book_or_path)
    if type(book_or_path) == "table" then return book_or_path end
    if type(book_or_path) == "string" then return Library.book(book_or_path) end
end

-- Closes the dashboard, then runs fn with the file browser underneath.
function DashboardView:closeTo(fn)
    self:onClose()
    local fm = fileManager()
    if fm and fn then UIManager:nextTick(function() fn(fm) end) end
end

-- Closes the dashboard to the home screen chosen in Settings (Bookshelf,
-- Simple UI, ...), or else to the file browser, at the home folder when
-- home_folder is set.
function DashboardView:closeToHome(home_folder)
    local target = StartScreen.target(self.settings)
    self:closeTo(function(fm)
        if StartScreen.isHome(target) and StartScreen.open(fm, target) then return end
        if home_folder then fm:onHome() end
    end)
end

function DashboardView:openBook(book)
    book = bookFor(book)
    if not book or not book.path then return end
    self:closeTo(function(fm) fm:openFile(book.path) end)
end

function DashboardView:showBookInfo(book)
    book = bookFor(book)
    local fm = fileManager()
    if not book or not book.path or not fm or not fm.bookinfo then return end
    fm.bookinfo:show(book.path)
end

-- Marks a book reading, finished or on hold, as KOReader's own status
-- buttons do: in the book's sidecar.
function DashboardView:setBookStatus(book, status)
    local BookList = require("ui/widget/booklist")
    local doc_settings = BookList.getDocSettings(book.path)
    local summary = doc_settings:readSetting("summary") or {}
    summary.status = status
    summary.modified = os.date("%Y-%m-%d", os.time())
    doc_settings:saveSetting("summary", summary)
    doc_settings:flush()
    BookList.setBookInfoCacheProperty(book.path, "status", status)
    Library.invalidateBooks(book.path)
    self:boardReload()
end

function DashboardView:showBookActions(book)
    book = bookFor(book)
    if not book or not book.path then return end
    local DialogUI = require("dashboard_dialog_ui")
    local rows = {
        { icon = "book-open", label = book.readStatus == "unread" and _("Start reading") or _("Resume reading"), run = function()
            self:openBook(book)
        end },
        { icon = "info", label = _("Book information"), opens = true, run = function()
            self:showBookInfo(book)
        end },
    }
    if book.readStatus ~= "finished" then
        table.insert(rows, { icon = "book-check", label = _("Mark as finished"), run = function() self:setBookStatus(book, "complete") end })
    end
    if book.readStatus == "finished" or book.readStatus == "abandoned" then
        table.insert(rows, { icon = "book-open-text", label = _("Mark as reading"), run = function() self:setBookStatus(book, "reading") end })
    end
    if book.readStatus == "reading" then
        table.insert(rows, { icon = "circle-pause", label = _("Put on hold"), run = function() self:setBookStatus(book, "abandoned") end })
    end
    local fm = fileManager()
    if fm and fm.collections then
        table.insert(rows, { icon = "folder-open", label = _("Collections…"), opens = true, run = function()
            fm.collections:onShowCollList(book.path, function()
                Library.invalidateBooks(book.path)
                self:boardReload()
            end)
        end })
    end
    table.insert(rows, { icon = "folder-search", label = _("Show in file browser"), run = function()
        self:closeTo(function(f)
            local dir = book.path:match("^(.*)/[^/]+$")
            if dir then f:showFiles(dir, book.path) end
        end)
    end })
    DialogUI.actions{ title = book.title, sub = book.authors[1], rows = rows }
end

function DashboardView:showHighlight(hl)
    if not hl then return end
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    viewer = TextViewer:new{
        title = hl.bookTitle or _("Highlight"),
        text = hl.text .. (hl.chapterTitle and ("\n\n— " .. hl.chapterTitle) or ""),
        buttons_table = {
            {
                { text = _("Close"), callback = function() UIManager:close(viewer) end },
                { text = _("Open book"), enabled = hl.book ~= nil, callback = function()
                    UIManager:close(viewer)
                    self:openBook(hl.book)
                end },
            },
        },
    }
    UIManager:show(viewer)
end

-- A list of books in KOReader's own list widget: tap opens, hold shows
-- the book's actions.
function DashboardView:showBookList(title, books)
    local BookList = require("ui/widget/booklist")
    local items = {}
    for _i, b in ipairs(books) do
        local pct = tonumber(b.progressPercentage)
        local mandatory
        if b.readStatus == "finished" then mandatory = _("Finished")
        elseif b.readStatus == "abandoned" then mandatory = _("On hold")
        elseif pct then mandatory = math.floor(pct + 0.5) .. "%" end
        local label = b.title
        if b.authors[1] then label = label .. " · " .. b.authors[1] end
        if b.seriesName and b.seriesIndex then label = label .. " (#" .. tostring(b.seriesIndex):gsub("%.0$", "") .. ")" end
        table.insert(items, { text = label, mandatory = mandatory, file = b.path, book = b })
    end
    local list
    list = BookList:new{
        title = T("%1 (%2)", title, #items),
        item_table = items,
        onMenuSelect = function(_menu, item)
            UIManager:close(list)
            self:openBook(item.book)
            return true
        end,
        onMenuHold = function(_menu, item)
            self:showBookActions(item.book)
            return true
        end,
        close_callback = function() UIManager:close(list) end,
    }
    UIManager:show(list)
end

-- Every author or series, with its book count; one opens its books.
function DashboardView:showNameList(kind)
    local Menu = require("ui/widget/menu")
    local body = self.current_context.dashboard or Library.body(os.time())
    local counts = {}
    for _i, b in ipairs(body._books or {}) do
        if kind == "author" then
            for _j, a in ipairs(b.authors) do counts[a] = (counts[a] or 0) + 1 end
        elseif b.seriesName then
            counts[b.seriesName] = (counts[b.seriesName] or 0) + 1
        end
    end
    local names = {}
    for name in pairs(counts) do table.insert(names, name) end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    local menu
    local items = {}
    for _i, name in ipairs(names) do
        table.insert(items, { text = name, mandatory = counts[name], callback = function()
            if self.picking then
                local picking = self.picking
                self.picking = nil
                UIManager:close(menu)
                return picking(name)
            end
            self:showBookList(name, Library.shelfBooks(kind, { name = name }, body._books or {}, os.time()))
        end })
    end
    menu = Menu:new{
        title = kind == "author" and _("Authors") or _("Series"),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        close_callback = function()
            self.picking = nil
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

-- Picks a collection, an author or a series for a new shelf.
function DashboardView:boardPickFrom(kind)
    local function add(name, title)
        self:boardAddPickedShelf({ type = kind, params = { name = name }, sourceName = title or name })
    end
    if kind == "collection" then
        local DialogUI = require("dashboard_dialog_ui")
        local rows = {}
        for _i, name in ipairs(Library.collectionNames()) do
            local title = Library.collectionDisplayName(name)
            table.insert(rows, { icon = "folder-open", label = title, run = function() add(name, title) end })
        end
        if #rows == 0 then
            return require("dashboard_toast").error(_("There are no collections yet."))
        end
        return DialogUI.actions{ title = _("Pick a collection"), rows = rows }
    end
    self.picking = function(name) add(name) end
    self:showNameList(kind)
end

-- ------------------------------------------------------------- shelves
local LINK_ACTIONS = {
    library = function(self)
        -- Optionally a plugin's home screen or the file browser instead.
        if StartScreen.target(self.settings) ~= "list" then return self:closeToHome(true) end
        self:boardOpenShelf({ source = "all", props = { source = "all", title = _("All books") } })
    end,
    series = function(self) self:showNameList("series") end,
    authors = function(self) self:showNameList("author") end,
    collections = function(self)
        local fm = fileManager()
        if fm and fm.collections then fm.collections:onShowCollList() end
    end,
    history = function(self)
        local fm = fileManager()
        if fm and fm.history then fm.history:onShowHist() end
    end,
    device = function(self) self:closeTo(function(fm) fm:onHome() end) end,
    search = function(self) self:closeTo(function(fm) if fm.filesearcher then fm.filesearcher:onShowFileSearch() end end) end,
}

function DashboardView:boardOpenLink(link)
    local fn = LINK_ACTIONS[link]
    if fn then fn(self) end
end

function DashboardView:boardOpenShelf(action)
    local props = action.props or { source = action.source }
    local body = self.current_context.dashboard or Library.body(os.time())
    local books = Library.shelfBooks(props.source, props.params, body._books or {}, os.time(),
        { by_path = body._by_path, shuffle = self:boardShuffleCount() })
    if props.source == "all" then
        return self:showBookList(props.title or _("All books"), books)
    end
    self:showBookList(BoardWidgets.shelfTitle(props), books)
end

function DashboardView:boardShuffleCount()
    local state = self.settings.board_shuffle
    if type(state) == "table" and state.day == os.date("%Y-%m-%d") then return tonumber(state.n) or 0 end
    return 0
end

-- Discover deals a new hand: the next shuffle of the day.
function DashboardView:boardShuffle()
    self:persistSetting("board_shuffle", { day = os.date("%Y-%m-%d"), n = self:boardShuffleCount() + 1 })
    self:boardReload()
end

-- Gathering dust: show the next unopened book for the rest of today.
function DashboardView:boardDustNext()
    local today = os.date("%Y-%m-%d")
    local state = self.settings.board_dust
    local skip = type(state) == "table" and state.day == today and tonumber(state.skip) or 0
    self:persistSetting("board_dust", { day = today, skip = skip + 1 })
    for _i, entry in ipairs(self._board_tiles or {}) do
        if entry.item.type == "dust" then self:boardRefreshTile(entry) end
    end
end

-- Removes an unopened book's file through KOReader's file manager, which
-- asks first.
function DashboardView:boardDustRemove(book)
    local fm = fileManager()
    if not book or not book.path or not fm then return end
    fm:showDeleteFileDialog(book.path, function()
        Library.invalidate()
        BoardData.invalidateUnopened()
        self:boardReload()
    end)
end

function DashboardView:boardLookup(word)
    local fm = fileManager()
    if fm and fm.dictionary and fm.dictionary.onLookupWord then
        fm.dictionary:onLookupWord(word)
    end
end

function DashboardView:editGoal()
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Yearly reading goal"),
        info_text = _("Books to finish this year. 0 hides the goal."),
        value = tonumber(self.settings.goal) or 12,
        value_min = 0,
        value_max = 500,
        value_step = 1,
        value_hold_step = 5,
        ok_text = _("Set goal"),
        callback = function(spin)
            self:persistSetting("goal", spin.value > 0 and spin.value or nil)
            self:boardReload()
        end,
    })
end

function DashboardView:boardFlip(delta)
    local page = self:boardPage() + (delta or 0)
    if page < 1 or page > BoardStore.PAGE_COUNT then return true end
    self.current_context.board_page = page
    self:updateItems()
    return true
end

function DashboardView:boardAdjustLight(what, delta)
    if not Device:hasFrontlight() then return end
    local powerd = Device:getPowerDevice()
    if what == "warmth" and Device:hasNaturalLight() then
        powerd:setWarmth(math.max(0, math.min(100, (powerd:frontlightWarmth() or 0) + delta)))
    else
        powerd:setIntensity(math.max(0, math.min(100, (powerd:frontlightIntensity() or 0) + delta)))
    end
    for _i, entry in ipairs(self._board_tiles or {}) do
        if entry.item.type == "light" then self:boardRefreshTile(entry) end
    end
end

function DashboardView:boardToggleWifi()
    if NetworkMgr:isWifiOn() then
        NetworkMgr:toggleWifiOff(function() self:updateItems() end)
    else
        NetworkMgr:toggleWifiOn(function() self:updateItems() end)
    end
end

-- ------------------------------------------------------------ sources
-- The shelves the board's pages show, so a build gathers only what some
-- widget will draw.
function DashboardView:boardSources()
    local m = BoardMetrics.get()
    local cols = BoardLayout.columnsFor(m.W)
    local sources = {}
    local all_pages = {}
    for _i, page in ipairs(self:boardPages(cols)) do table.insert(all_pages, page) end
    -- Before the first run every starter layout is previewed, so each one
    -- needs its shelves.
    if not BoardStore.read(self.settings).started then
        for _i, preset in ipairs(BoardStore.PRESETS) do
            for _j, page in ipairs(BoardStore.starterPages(cols, preset, self:boardHasLight(), self:boardLandscape())) do table.insert(all_pages, page) end
        end
    end
    -- Every shelf the Add widget sheet previews, and widgets added while editing.
    for _i, entry in ipairs(BoardEdit.LIBRARY) do
        if entry.type == "shelf" and entry.props then sources[BoardStore.shelfKey(entry.props)] = entry.props end
    end
    if self.board_edit then
        for _i, page in ipairs(self.board_edit.pages) do table.insert(all_pages, { base = page.items }) end
    end
    for _i, page in ipairs(all_pages) do
        for _i, list in ipairs({ page.base, page.extras }) do
            for _i, item in ipairs(list or {}) do
                if item.type == "shelf" and item.props and item.props.source then
                    sources[BoardStore.shelfKey(item.props)] = item.props
                end
            end
        end
    end
    return sources
end

-- Builds the dashboard body again from the library, then redraws.
function DashboardView:boardReload(no_draw)
    self.current_context.dashboard = Library.body(os.time(), {
        sources = self:boardSources(),
        goal = self.settings.goal,
        shuffle = self:boardShuffleCount(),
    })
    BoardData.invalidateUnopened()
    if not no_draw then self:updateItems() end
end

-- -------------------------------------------------------------- the host
function DashboardView:init()
    self.settings = self.settings or {}
    self.current_context = { kind = "dashboard", board_page = 1 }
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.inner_dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h }
    self.item_group = VerticalGroup:new{ align = "left" }
    self[1] = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = INK.white,
        dimen = self.dimen:copy(),
        self.item_group,
    }
    self.layout = {}
    if Device:hasKeys() then
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } }
    end
    -- New covers or metadata from the extractor: gather the board's data
    -- again, and redraw when nothing covers the board.
    Library.on_update = function(what)
        if self.closed then return end
        if what == "books" then
            BoardUI.clearSnapshots()
            self:boardReload(true)
        end
        if self:boardIsTopmost() and not self.board_edit then self:updateItems() end
    end
    self:boardReload(true)
    self:updateItems()
end

function DashboardView:persistSetting(key, value)
    self.settings[key] = value
    -- A new layout, preset or tile style: no cached page is right any more.
    if key == BoardStore.SETTING_KEY then self:boardFreePages() end
    if self.plugin and self.plugin.saveSettings then self.plugin:saveSettings() end
end

function DashboardView:menuChromeHeight()
    return 0, 0
end

function DashboardView:recalculateDashboardDimen()
    self.available_height = self.inner_dimen.h
end

function DashboardView:prepareCustomUpdate()
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self:recalculateDashboardDimen()
    return old_dimen
end

function DashboardView:finishCustomUpdate(old_dimen)
    if #self.layout > 0 then
        local y = math.min(self.selected and self.selected.y or 1, #self.layout)
        local x = math.min(self.selected and self.selected.x or 1, #self.layout[y])
        self.selected = { x = x, y = y }
    end
    UIManager:setDirty(self, function()
        return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen
    end)
end

function DashboardView:updateItems()
    return self:updateDashboardItems()
end

function DashboardView:onNextPage()
    if self.board_edit then return true end
    return self:boardFlip(1)
end

function DashboardView:onPrevPage()
    if self.board_edit then return true end
    return self:boardFlip(-1)
end

-- Swipe left or right turns the page; a swipe down from the top edge opens
-- the menu, as KOReader's own menu gesture does elsewhere.
function DashboardView:onSwipe(_arg, ges)
    Library.busy()
    local dir = ges and ges.direction
    if dir == "west" then
        return self:onNextPage()
    elseif dir == "east" then
        return self:onPrevPage()
    elseif dir == "south" and ges.pos and ges.pos.y < self.dimen.h / 8 and not self.board_edit then
        self:showMenu()
        return true
    end
    return false
end

function DashboardView:showMenu()
    if self.plugin and self.plugin.openMenuSheet then self.plugin:openMenuSheet(self) end
end

-- Back leaves editing first, then the dashboard.
function DashboardView:onClose()
    if self.board_edit then
        if self.board_edit.sheet then
            self.board_edit.sheet = false
            self:updateItems()
        else
            self:boardExitEdit()
        end
        return true
    end
    UIManager:close(self, "flashui")
    return true
end

function DashboardView:onSetDimensions(dimen)
    self.dimen = Geom:new{ x = 0, y = 0, w = dimen.w, h = dimen.h }
    self.inner_dimen = Geom:new{ w = dimen.w, h = dimen.h }
    self[1].dimen = self.dimen:copy()
    self:boardFreePages()
    BoardUI.clearSnapshots()
    self:updateItems()
end

-- KOReader rotated the screen: redraw for the new shape.
function DashboardView:onScreenResize(dimen)
    return self:onSetDimensions(dimen)
end

function DashboardView:onCloseWidget()
    self.closed = true
    if self._board_clock_task then UIManager:unschedule(self._board_clock_task) end
    if self._prebuild_task then UIManager:unschedule(self._prebuild_task) end
    self:boardFreePages()
    Library.on_update = nil
    if self.close_callback then self.close_callback() end
end

BoardEdit.install(DashboardView)

return DashboardView
