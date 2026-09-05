-- pages/newpage.lua
-- "New Page" — third bottom-nav tab. Currently hosts the "Recent Books"
-- shelf that used to live on the Home page (moved here per request).
-- Structured identically to home.lua/library.lua: persistent header +
-- bottom nav, no ScrollableContainer (see home.lua's buildUI for the full
-- history of bugs that caused), everything sized to fit on one screen.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

-- Same helper as home.lua/library.lua: wraps opening a book in pcall so
-- any error (bad file, corrupt document, whatever) shows a message
-- instead of taking the app down.
local function safeOpenBook(path)
    local ok, err = pcall(function()
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path)
    end)
    if not ok then
        logger.warn("Ananya: failed to open book ->", tostring(path), tostring(err))
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("Couldn't open that book. It may be missing or corrupted."),
        })
    end
end

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
    getRecentBooks = function() return {} end,
})

local Screen = Device.screen

local AnanyaNewPage = InputContainer:extend{
    name = "ananya_newpage",
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function AnanyaNewPage:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    local ok, err = pcall(function() self:buildUI() end)
    if not ok then
        logger.warn("Ananya: newpage buildUI failed ->", tostring(err))
        self:buildFailSafeUI()
    end
end

function AnanyaNewPage:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function AnanyaNewPage:onClose()
    UIManager:close(self)
    return true
end

-- See home.lua's onShowingReader for the full explanation.
function AnanyaNewPage:onShowingReader()
    self:onClose()
end

function AnanyaNewPage:switchTo(target_id)
    if target_id == "home" then
        UIManager:close(self)
        local AnanyaHome = require("pages/home")
        UIManager:show(AnanyaHome:new{})
    elseif target_id == "library" then
        UIManager:close(self)
        local AnanyaLibrary = require("pages/library")
        UIManager:show(AnanyaLibrary:new{})
    end
end

function AnanyaNewPage:buildFailSafeUI()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local Button = require("ui/widget/button")
    self[1] = FrameContainer:new{
        width = screen_w, height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text = _("Ananya failed to load. Check crash.log."),
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
-- Book cover fetch — same recipe as home.lua's getCoverAndProps, but we
-- only need the cover image here (no title/author/description shown).
-- ---------------------------------------------------------------------------

local function getCover(path)
    local ok, result = pcall(function()
        local DocumentRegistry = require("document/documentregistry")
        local doc = DocumentRegistry:openDocument(path)
        if not doc then return nil end
        local cover = nil
        local ok_cover, cover_or_err = pcall(function() return doc:getCoverPageImage() end)
        if ok_cover then cover = cover_or_err end
        DocumentRegistry:closeDocument(path)
        return { cover = cover }
    end)
    if ok then return result end
    return nil
end

-- ---------------------------------------------------------------------------
-- "Recent Books" — moved here from home.lua, unchanged behavior: 5 most
-- recently opened books (via KOReader's own ReadHistory), shown as a
-- horizontal shelf of cover + percent caption.
-- ---------------------------------------------------------------------------

local RECENT_SLOT_COUNT = 5

-- A tappable cover item — same defensive pattern as home.lua's ReadingRow
-- (see there for why the explicit Geom re-wrap matters).
local CoverItem = InputContainer:extend{}

function CoverItem:init()
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function CoverItem:onTap()
    if self.callback then self.callback() end
    return true
end

function AnanyaNewPage:buildRecentCoverItem(entry, item_w, item_h)
    local meta = getCover(entry.path) or {}

    local cover_widget
    if meta.cover then
        cover_widget = ImageWidget:new{
            image = meta.cover,
            width = item_w,
            height = item_h,
            scale_factor = 0,
        }
    else
        cover_widget = FrameContainer:new{
            width = item_w,
            height = item_h,
            bordersize = Size.border.window,
            color = Blitbuffer.COLOR_LIGHT_GRAY,
            background = Blitbuffer.COLOR_WHITE,
            margin = 0,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = item_w, h = item_h },
                TextWidget:new{ text = "", face = Font:getFace("cfont", 9) },
            },
        }
    end

    local percent_label = TextWidget:new{
        text = string.format("%d%% Read", math.floor((entry.percent or 0) * 100)),
        face = Font:getFace("cfont", 11),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local col = VerticalGroup:new{
        align = "center",
        cover_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        CenterContainer:new{
            dimen = Geom:new{ w = item_w, h = percent_label:getSize().h },
            percent_label,
        },
    }

    return CoverItem:new{
        callback = function()
            safeOpenBook(entry.path)
        end,
        col,
    }
end

function AnanyaNewPage:buildRecentBooksSection(content_w)
    local face_h2 = Font:getFace("tfont", 18)
    local heading = TextWidget:new{ text = _("Recent Books"), face = face_h2 }

    local ok, recent = pcall(LibraryScan.getRecentBooks, RECENT_SLOT_COUNT)
    if not ok then
        logger.warn("Ananya: getRecentBooks failed ->", tostring(recent))
        recent = {}
    end

    local body
    if #recent == 0 then
        body = TextWidget:new{
            text = _("No recently opened books yet."),
            face = Font:getFace("cfont", 15),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    else
        -- Fixed division by RECENT_SLOT_COUNT (5), regardless of how many
        -- books are actually present — see home.lua's original comment
        -- history for why this specific approach was settled on.
        local gap = Screen:scaleBySize(10)
        local item_w = math.floor((content_w - gap * (RECENT_SLOT_COUNT - 1)) / RECENT_SLOT_COUNT)
        local item_h = math.floor(item_w * 1.5) -- typical book cover aspect ratio

        local row = HorizontalGroup:new{}
        for i, entry in ipairs(recent) do
            table.insert(row, self:buildRecentCoverItem(entry, item_w, item_h))
            if i < #recent then
                table.insert(row, HorizontalSpan:new{ width = gap })
            end
        end
        body = row
    end

    return VerticalGroup:new{
        align = "left",
        heading,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        body,
    }
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function AnanyaNewPage:buildUI()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local side_margin = Screen:scaleBySize(16)
    local content_w = screen_w - 2 * side_margin

    local header = Header.build{ on_close = function() self:onClose() end }
    local bottom_nav = BottomNav.build("newpage", function(target_id)
        self:switchTo(target_id)
    end)

    local content_h = screen_h - Header.HEIGHT - BottomNav.HEIGHT

    local body = VerticalGroup:new{
        align = "left",
        self:buildRecentBooksSection(content_w),
    }

    -- Same forced-height fix as home.lua's buildUI — see there for why
    -- this is needed (FrameContainer:getSize() ignores its own explicit
    -- height and derives from its child's actual content instead).
    local body_top_pad = Screen:scaleBySize(16)
    local forced_body = WidgetContainer:new{
        dimen = Geom:new{ w = content_w, h = content_h - body_top_pad },
        body,
    }

    local content_area = FrameContainer:new{
        width = screen_w,
        height = content_h,
        bordersize = 0, margin = 0,
        padding_left = side_margin,
        padding_right = side_margin,
        padding_top = body_top_pad,
        padding_bottom = 0,
        background = Blitbuffer.COLOR_WHITE,
        forced_body,
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

return AnanyaNewPage