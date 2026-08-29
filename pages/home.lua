-- pages/home.lua
-- The Ananya home page: persistent header + bottom nav (see widgets/), a
-- "Currently Reading" section listing in-progress books, and a blank
-- "Stats" placeholder below it.

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
local ScrollableContainer
do
    -- Not every KOReader version ships the same scroll-container name; try
    -- the common one and fall back to a plain (non-scrolling) container so
    -- a missing module can't crash the whole page.
    local ok, mod = pcall(require, "ui/widget/container/scrollablecontainer")
    ScrollableContainer = ok and mod or nil
end
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")

-- Defensive requires: any of these being missing/misplaced degrades
-- gracefully instead of taking the whole plugin down at load time.
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
    getCurrentlyReading = function() return {} end,
})

local Screen = Device.screen

local AnanyaHome = InputContainer:extend{
    name = "ananya_home",
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function AnanyaHome:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Close via a HOLD over the header's close-glyph area, not a tap —
    -- see widgets/header.lua's CLOSE_ZONE_RATIO comment for why this
    -- approach (InputContainer:registerTouchZones claiming only "hold")
    -- is used instead of an embedded Button, which would also silently
    -- claim tap/swipe over that same corner.
    self:registerTouchZones{
        {
            id = "ananya_home_close",
            ges = "hold",
            screen_zone = Header.getCloseZoneRatio(),
            handler = function()
                self:onClose()
                return true
            end,
        },
    }

    local ok, err = pcall(function() self:buildUI() end)
    if not ok then
        logger.warn("Ananya: home buildUI failed ->", tostring(err))
        self:buildFailSafeUI()
    end
end

function AnanyaHome:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function AnanyaHome:onClose()
    UIManager:close(self)
    return true
end

function AnanyaHome:switchTo(target_id)
    if target_id == "library" then
        UIManager:close(self)
        local AnanyaLibrary = require("pages/library")
        UIManager:show(AnanyaLibrary:new{})
    end
end

-- A minimal, definitely-tappable-closed screen for when buildUI() errors.
function AnanyaHome:buildFailSafeUI()
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
-- "Currently Reading" section
-- ---------------------------------------------------------------------------

-- A tappable card: cover + title/author/progress, opens the book directly.
local ReadingRow = InputContainer:extend{}

function ReadingRow:init()
    self.dimen = self[1]:getSize()
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function ReadingRow:onTap()
    if self.callback then self.callback() end
    return true
end

-- Safe progress bar: outer FrameContainer (border + track color) wrapping
-- ONE real child LineWidget for the fill. Never a childless FrameContainer
-- (see header.lua's buildBatteryIcon comment for why that crashes).
local function buildProgressBar(ratio, width, height)
    ratio = math.min(1, math.max(0, ratio or 0))
    local fill_w = math.floor(width * ratio)
    local fill = LineWidget:new{
        dimen = Geom:new{ w = fill_w, h = height },
        background = Blitbuffer.COLOR_BLACK,
    }
    return FrameContainer:new{
        width = width,
        height = height,
        bordersize = 0,
        margin = 0,
        padding = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        fill,
    }
end

-- Opens the document briefly to read its title/authors and cover image.
-- Wrapped in pcall throughout: a corrupt or unsupported file must degrade
-- to "no cover, filename as title" rather than break the whole page.
-- NOTE: this opens the actual document per book — fine for a short
-- "currently reading" list, but would be slow for a long one.
local function getCoverAndProps(path)
    local ok, result = pcall(function()
        local DocumentRegistry = require("document/documentregistry")
        local doc = DocumentRegistry:openDocument(path)
        if not doc then return nil end
        local props = doc:getProps() or {}
        local cover = nil
        local ok_cover, cover_or_err = pcall(function() return doc:getCoverPageImage() end)
        if ok_cover then cover = cover_or_err end
        DocumentRegistry:closeDocument(path)
        return { title = props.title, authors = props.authors, cover = cover }
    end)
    if ok then return result end
    return nil
end

function AnanyaHome:buildReadingCard(entry, card_w)
    local cover_w = Screen:scaleBySize(60)
    local cover_h = Screen:scaleBySize(90)
    local gap = Screen:scaleBySize(12)
    local text_w = card_w - cover_w - gap

    local meta = getCoverAndProps(entry.path) or {}

    local cover_widget
    if meta.cover then
        cover_widget = ImageWidget:new{
            image = meta.cover,
            width = cover_w,
            height = cover_h,
            scale_factor = 0, -- best-fit within width/height, keep aspect ratio
        }
    else
        -- Fallback placeholder — has a real child (CenterContainer), so it
        -- can't hit the childless-FrameContainer crash.
        cover_widget = FrameContainer:new{
            width = cover_w,
            height = cover_h,
            bordersize = Size.border.window,
            color = Blitbuffer.COLOR_LIGHT_GRAY,
            background = Blitbuffer.COLOR_WHITE,
            margin = 0,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                TextWidget:new{ text = "", face = Font:getFace("cfont", 10) },
            },
        }
    end

    local title_widget = TextWidget:new{
        text = meta.title or entry.name,
        face = Font:getFace("tfont", 16),
        max_width = text_w,
    }

    local bar_h = Screen:scaleBySize(6)
    local percent_label = TextWidget:new{
        text = string.format("%d%% Read", math.floor(entry.percent * 100)),
        face = Font:getFace("cfont", 12),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    -- Build the text column with table.insert (never a nil hole in the
    -- middle of a widget-group's array, which would break its iteration).
    local text_col = VerticalGroup:new{}
    table.insert(text_col, title_widget)
    table.insert(text_col, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    if meta.authors then
        table.insert(text_col, TextWidget:new{
            text = meta.authors,
            face = Font:getFace("cfont", 13),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = text_w,
        })
        table.insert(text_col, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    else
        table.insert(text_col, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    end
    table.insert(text_col, buildProgressBar(entry.percent, text_w, bar_h))
    table.insert(text_col, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(text_col, percent_label)

    local row = HorizontalGroup:new{
        cover_widget,
        HorizontalSpan:new{ width = gap },
        text_col,
    }

    local framed = FrameContainer:new{
        width = card_w,
        bordersize = 0,
        margin = 0,
        padding_top = Screen:scaleBySize(8),
        padding_bottom = Screen:scaleBySize(8),
        row,
    }

    return ReadingRow:new{
        callback = function()
            local ReaderUI = require("apps/reader/readerui")
            UIManager:close(self)
            ReaderUI:showReader(entry.path)
        end,
        framed,
    }
end

function AnanyaHome:buildCurrentlyReadingSection(content_w)
    local face_h2 = Font:getFace("tfont", 18)
    local heading = TextWidget:new{ text = _("Currently Reading"), face = face_h2 }

    local ok, reading = pcall(LibraryScan.getCurrentlyReading)
    if not ok then
        logger.warn("Ananya: getCurrentlyReading failed ->", tostring(reading))
        reading = {}
    end

    local body
    if #reading == 0 then
        body = TextWidget:new{
            text = _("Nothing in progress yet."),
            face = Font:getFace("cfont", 15),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    else
        local rows = VerticalGroup:new{}
        for _, entry in ipairs(reading) do
            table.insert(rows, self:buildReadingCard(entry, content_w))
        end
        body = rows
    end

    return VerticalGroup:new{
        heading,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        body,
    }
end

-- ---------------------------------------------------------------------------
-- "Stats" section — placeholder for now, per your request.
-- ---------------------------------------------------------------------------

function AnanyaHome:buildStatsSection(content_w)
    local face_h2 = Font:getFace("tfont", 18)
    local heading = TextWidget:new{ text = _("Stats"), face = face_h2 }

    local placeholder = FrameContainer:new{
        width = content_w,
        height = Screen:scaleBySize(90),
        bordersize = Size.border.window,
        color = Blitbuffer.COLOR_LIGHT_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        radius = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = Screen:scaleBySize(90) },
            TextWidget:new{
                text = _("Coming soon"),
                face = Font:getFace("cfont", 15),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        },
    }

    return VerticalGroup:new{
        heading,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        placeholder,
    }
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function AnanyaHome:buildUI()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local side_margin = Screen:scaleBySize(16)
    -- Small safety margin: content is built to exactly content_w, but a
    -- 1px rounding difference anywhere would make ScrollableContainer
    -- think the content overflows and draw a horizontal scrollbar along
    -- the bottom (this was the "trailing bar" bug) — a couple of spare
    -- pixels of headroom makes that structurally very unlikely.
    local content_w = screen_w - 2 * side_margin - Screen:scaleBySize(4)

    local header = Header.build{ on_close = function() self:onClose() end }
    local bottom_nav = BottomNav.build("home", function(target_id)
        self:switchTo(target_id)
    end)

    local content_h = screen_h - Header.HEIGHT - BottomNav.HEIGHT

    local body = VerticalGroup:new{
        self:buildCurrentlyReadingSection(content_w),
        VerticalSpan:new{ width = Screen:scaleBySize(24) },
        self:buildStatsSection(content_w),
    }

    -- Wrap in a scroll container if available, so a long "currently
    -- reading" list doesn't get clipped by the fixed content height.
    local scrollable_body
    if ScrollableContainer then
        scrollable_body = ScrollableContainer:new{
            dimen = Geom:new{ w = content_w, h = content_h },
            body,
        }
        -- ScrollableContainer's own docs require the widget passed to
        -- UIManager:show() (that's us) to expose this, or repaint/invert
        -- flashing can leak outside the scrollable area.
        self.cropping_widget = scrollable_body
    else
        scrollable_body = body
    end

    local content_area = FrameContainer:new{
        width = screen_w,
        height = content_h,
        bordersize = 0, margin = 0,
        padding_left = side_margin,
        padding_right = side_margin,
        padding_top = Screen:scaleBySize(16),
        background = Blitbuffer.COLOR_WHITE,
        scrollable_body,
    }

    local page = VerticalGroup:new{
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

return AnanyaHome