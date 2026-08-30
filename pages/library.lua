-- pages/library.lua
-- The Library page: persistent header + bottom nav, with a custom
-- scrollable list of every book under Ananya/ in between. Tapping a row
-- opens it directly in the reader.
--
-- ARCHITECTURE NOTE (why this doesn't use KOReader's stock Menu widget):
-- An earlier version embedded ui/widget/menu.lua as a *child* inside this
-- page's own header/bottomnav layout. Menu is a large, stateful widget
-- designed to be shown directly via UIManager:show() as its own top-level
-- screen (that's how KOReader's file browser, OPDS catalog, etc. all use
-- it) — nesting it inside another widget's layout is not how it's meant
-- to be used, and was the likely cause of the crash. Tellingly, SimpleUI
-- itself does NOT reuse the stock Menu widget for its library either — it
-- has its own hand-built list engine (engines/sui_book_grid.lua) for
-- exactly this reason. This version follows that lead: the book list here
-- is custom rows (same recipe as Home's "Currently Reading" rows) inside
-- a ScrollableContainer, which is the same proven, already-working
-- pattern from pages/home.lua.
--
-- SEARCH: a "Search" button opens a standalone InputDialog (shown the
-- normal, correct way — as its own top-level widget via UIManager:show(),
-- which is exactly what InputDialog is designed for). Typing a query and
-- confirming filters the list by filename substring match. This is
-- simpler than SimpleUI's faceted author/tag/series search, by design —
-- see the header comment note for why that's out of scope here.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer
do
    local ok, mod = pcall(require, "ui/widget/container/scrollablecontainer")
    ScrollableContainer = ok and mod or nil
end
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local function safeRequire(name, fallback)
    local ok, mod_or_err = pcall(require, name)
    if ok then return mod_or_err end
    logger.warn("Ananya: failed to load " .. name .. " ->", tostring(mod_or_err))
    return fallback
end

local Header = safeRequire("widgets/header", {
    HEIGHT = 0,
    build = function() return VerticalGroup:new{} end,
})
local BottomNav = safeRequire("widgets/bottomnav", {
    HEIGHT = 0,
    build = function() return VerticalGroup:new{} end,
})
local LibraryScan = safeRequire("data/library_scan", {
    getAllFiles = function() return {} end,
})

local Screen = Device.screen

local AnanyaLibrary = InputContainer:extend{
    name = "ananya_library",
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function AnanyaLibrary:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.search_query = nil -- nil = no active filter

    local ok, err = pcall(function() self:buildUI() end)
    if not ok then
        logger.warn("Ananya: library buildUI failed ->", tostring(err))
        self:buildFailSafeUI()
    end
end

function AnanyaLibrary:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function AnanyaLibrary:onClose()
    UIManager:close(self)
    return true
end

function AnanyaLibrary:switchTo(target_id)
    if target_id == "home" then
        UIManager:close(self)
        local AnanyaHome = require("pages/home")
        UIManager:show(AnanyaHome:new{})
    end
end

function AnanyaLibrary:buildFailSafeUI()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self[1] = FrameContainer:new{
        width = screen_w, height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text = _("Ananya Library failed to load. Check crash.log."),
                    face = Font:getFace("cfont", 16),
                },
                VerticalSpan:new{ width = Screen:scaleBySize(12) },
                Button:new{
                    text = _("Close"),
                    callback = function() self:onClose() end,
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Book rows
-- ---------------------------------------------------------------------------

-- A tappable row: filename, opens the book directly. Same recipe as
-- pages/home.lua's ReadingRow.
local BookRow = InputContainer:extend{}

function BookRow:init()
    self.dimen = self[1]:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function BookRow:onTap()
    if self.callback then self.callback() end
    return true
end

function AnanyaLibrary:buildBookRow(entry, row_w)
    local title = TextWidget:new{
        text = entry.name,
        face = Font:getFace("cfont", 16),
        max_width = row_w,
    }
    local framed = FrameContainer:new{
        width = row_w,
        bordersize = 0, margin = 0,
        padding_top = Screen:scaleBySize(8),
        padding_bottom = Screen:scaleBySize(8),
        padding_left = Screen:scaleBySize(4),
        padding_right = Screen:scaleBySize(4),
        title,
    }
    return BookRow:new{
        callback = function()
            local ReaderUI = require("apps/reader/readerui")
            UIManager:close(self)
            ReaderUI:showReader(entry.path)
        end,
        framed,
    }
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

function AnanyaLibrary:openSearchDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Search library"),
        input = self.search_query or "",
        input_hint = _("Filename contains…"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Clear"),
                    callback = function()
                        UIManager:close(dialog)
                        self.search_query = nil
                        self:rebuild()
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        self.search_query = (text ~= "") and text or nil
                        self:rebuild()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Rebuilds the whole page in place (simplest safe way to reflect a new
-- search filter — no partial-update bookkeeping to get wrong).
function AnanyaLibrary:rebuild()
    local ok, err = pcall(function() self:buildUI() end)
    if not ok then
        logger.warn("Ananya: library rebuild failed ->", tostring(err))
        self:buildFailSafeUI()
    end
    UIManager:setDirty(self, "full")
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function AnanyaLibrary:buildUI()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local side_margin = Screen:scaleBySize(16)
    local content_w = screen_w - 2 * side_margin
    -- See home.lua's buildUI for why this margin exists: ScrollableContainer
    -- false-positives a horizontal scrollbar whenever a vertical one is
    -- shown and the content fills the full available width.
    local scrollbar_reserve = Screen:scaleBySize(20)
    local inner_w = content_w - scrollbar_reserve

    local header = Header.build{ on_close = function() self:onClose() end }
    local bottom_nav = BottomNav.build("library", function(target_id)
        self:switchTo(target_id)
    end)

    local ok, all_files = pcall(LibraryScan.getAllFiles)
    if not ok then
        logger.warn("Ananya: getAllFiles failed ->", tostring(all_files))
        all_files = {}
    end
    self.all_files = all_files

    local visible_files = all_files
    if self.search_query then
        local needle = util.stringLower(self.search_query)
        visible_files = {}
        for _, entry in ipairs(all_files) do
            if util.stringLower(entry.name):find(needle, 1, true) then
                table.insert(visible_files, entry)
            end
        end
    end
    table.sort(visible_files, function(a, b) return a.name:lower() < b.name:lower() end)

    -- ── Toolbar: search button + result count / active filter ──────────
    local toolbar_h = Screen:scaleBySize(44)
    local search_btn = Button:new{
        text = _("Search"),
        callback = function() self:openSearchDialog() end,
        text_font_size = 15,
        bordersize = Size.border.button,
        margin = Screen:scaleBySize(2),
        radius = 0,
    }
    local count_text
    if self.search_query then
        count_text = string.format(_("\"%s\" — %d of %d"),
            self.search_query, #visible_files, #all_files)
    else
        count_text = string.format(_("%d books"), #all_files)
    end
    local toolbar = HorizontalGroup:new{
        search_btn,
        HorizontalSpan:new{ width = Screen:scaleBySize(12) },
        CenterContainer:new{
            dimen = Geom:new{
                w = content_w - search_btn:getSize().w - Screen:scaleBySize(12),
                h = toolbar_h,
            },
            TextWidget:new{
                text = count_text,
                face = Font:getFace("cfont", 14),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        },
    }

    -- ── Book list ────────────────────────────────────────────────────
    local rows = VerticalGroup:new{ align = "left" }
    if #visible_files == 0 then
        table.insert(rows, TextWidget:new{
            text = self.search_query and _("No matches.") or _("No books found under Ananya/."),
            face = Font:getFace("cfont", 15),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    else
        for _, entry in ipairs(visible_files) do
            table.insert(rows, self:buildBookRow(entry, inner_w))
        end
    end

    local content_h = screen_h - Header.HEIGHT - BottomNav.HEIGHT - toolbar_h
        - Screen:scaleBySize(16) -- top padding

    local list_area
    if ScrollableContainer then
        list_area = ScrollableContainer:new{
            dimen = Geom:new{ w = content_w, h = content_h },
            rows,
        }
        self.cropping_widget = list_area
    else
        list_area = rows
    end

    local content_area = FrameContainer:new{
        width = screen_w,
        height = content_h + toolbar_h + Screen:scaleBySize(16),
        bordersize = 0, margin = 0,
        padding_left = side_margin,
        padding_right = side_margin,
        padding_top = Screen:scaleBySize(16),
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            toolbar,
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            list_area,
        },
    }

    local page = VerticalGroup:new{
        align = "left",
        header,
        content_area,
        bottom_nav,
    }

    self[1] = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        bordersize = 0, margin = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        page,
    }
end

return AnanyaLibrary