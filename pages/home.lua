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
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer
do
    -- Not every KOReader version ships the same scroll-container name; try
    -- the common one and fall back to a plain (non-scrolling) container so
    -- a missing module can't crash the whole page.
    local ok, mod = pcall(require, "ui/widget/container/scrollablecontainer")
    ScrollableContainer = ok and mod or nil
end
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
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
    getRecentBooks = function() return {} end,
    getLastOpenedInProgress = function() return nil end,
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
        -- CreDocument (epub/mobi/fb2/txt/html) doesn't populate metadata
        -- until the document is explicitly loaded. getCoverPageImage()
        -- does this loading internally for itself, but getProps() does
        -- NOT — confirmed by reading credocument.lua directly — so
        -- without this, title/authors come back empty and we always
        -- fell back to the filename. Only CreDocument defines
        -- loadDocument, hence the existence check (PDF/CBZ/etc don't
        -- need or have this method).
        if doc.loadDocument then
            pcall(function() doc:loadDocument() end)
        end
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

-- Truncates text to roughly max_chars, breaking at the last whole word
-- rather than mid-word, and appending an ellipsis. Used for the
-- description preview so a long blurb doesn't blow up the card.
local function truncateText(text, max_chars)
    if not text or #text <= max_chars then
        return text
    end
    local cut = text:sub(1, max_chars):gsub("%s+%S*$", "")
    return cut .. "\u{2026}" -- …
end

-- One shared card builder for both the big "Currently Reading" hero card
-- and the smaller "Recent Books" rows. opts:
--   size            "hero" (large, with description) or "compact" (small)
--   show_progress   whether to draw the progress bar + "X% Read" label
--   percent         0..1, required if show_progress is true
function AnanyaHome:buildBookCard(entry, card_w, opts)
    opts = opts or {}
    local is_hero = opts.size == "hero"

    local cover_w = is_hero and Screen:scaleBySize(110) or Screen:scaleBySize(50)
    local cover_h = is_hero and Screen:scaleBySize(165) or Screen:scaleBySize(75)
    local gap = Screen:scaleBySize(is_hero and 16 or 10)
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
        face = Font:getFace("tfont", is_hero and 20 or 15),
        max_width = text_w,
    }

    local author_widget = nil
    if meta.authors then
        author_widget = TextWidget:new{
            text = meta.authors,
            face = Font:getFace("cfont", is_hero and 15 or 12),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = text_w,
        }
    end

    -- NOTE: an earlier version capped this bar's width to match the
    -- title/author text above it, thinking a full-width bar looked
    -- "misaligned". That diagnosis was wrong — the actual cause of that
    -- misalignment was VerticalGroup's default center-alignment (fixed
    -- separately), not the bar's width. Capping it made it look too
    -- small/disconnected from the card. Reverted to the full text_w,
    -- which is the correct, expected look (matches Kindle/Play Books
    -- style progress bars spanning the text column's full width).

    -- Build the text column with table.insert (never a nil hole in the
    -- middle of a widget-group's array, which would break its iteration).
    local text_col = VerticalGroup:new{ align = "left" }
    table.insert(text_col, title_widget)
    table.insert(text_col, VerticalSpan:new{ width = Screen:scaleBySize(4) })

    if author_widget then
        table.insert(text_col, author_widget)
        table.insert(text_col, VerticalSpan:new{ width = Screen:scaleBySize(is_hero and 8 or 4) })
    end

    -- Description preview — hero cards only, truncated to keep the card
    -- from growing unbounded (some epub descriptions run for paragraphs).
    if is_hero and meta.description then
        table.insert(text_col, TextBoxWidget:new{
            text = truncateText(meta.description, 260),
            face = Font:getFace("cfont", 13),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = text_w,
        })
        table.insert(text_col, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    end

    if opts.show_progress then
        local bar_h = Screen:scaleBySize(is_hero and 10 or 6)
        table.insert(text_col, buildProgressBar(opts.percent, text_w, bar_h))
        table.insert(text_col, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        table.insert(text_col, TextWidget:new{
            text = string.format("%d%% Read", math.floor((opts.percent or 0) * 100)),
            face = Font:getFace("cfont", is_hero and 13 or 11),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end

    local row = HorizontalGroup:new{
        cover_widget,
        HorizontalSpan:new{ width = gap },
        text_col,
    }

    local framed = FrameContainer:new{
        width = card_w,
        bordersize = 0,
        margin = 0,
        padding_top = Screen:scaleBySize(is_hero and 12 or 6),
        padding_bottom = Screen:scaleBySize(is_hero and 12 or 6),
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
    local face_h2 = Font:getFace("tfont", 20)
    local heading = TextWidget:new{ text = _("Currently Reading"), face = face_h2 }

    local ok, entry = pcall(LibraryScan.getLastOpenedInProgress)
    if not ok then
        logger.warn("Ananya: getLastOpenedInProgress failed ->", tostring(entry))
        entry = nil
    end

    local body
    if not entry then
        body = TextWidget:new{
            text = _("Nothing in progress yet."),
            face = Font:getFace("cfont", 15),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    else
        body = self:buildBookCard(entry, content_w, {
            size = "hero",
            show_progress = true,
            percent = entry.percent,
        })
    end

    return VerticalGroup:new{
        align = "left",
        heading,
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        body,
    }
end

-- ---------------------------------------------------------------------------
-- "Recent Books" section — 5 most recently opened books (via KOReader's
-- own ReadHistory), shown as a horizontal shelf: cover + percent caption
-- only, no title/author, matching the reference design.
-- ---------------------------------------------------------------------------

local RECENT_SLOT_COUNT = 5

function AnanyaHome:buildRecentCoverItem(entry, item_w, item_h)
    local meta = getCoverAndProps(entry.path) or {}

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

    return ReadingRow:new{
        callback = function()
            local ReaderUI = require("apps/reader/readerui")
            UIManager:close(self)
            ReaderUI:showReader(entry.path)
        end,
        col,
    }
end

function AnanyaHome:buildRecentBooksSection(content_w)
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
        -- Fixed 5-slot width regardless of how many books are actually
        -- present, so cover sizing stays consistent as your history fills
        -- in, rather than growing/shrinking per render.
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
        align = "left",
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
    local content_w = screen_w - 2 * side_margin

    -- ScrollableContainer always shows a vertical scrollbar here (our
    -- content is normally taller than one screen). When it does, it
    -- RE-CHECKS whether a horizontal scrollbar is ALSO needed by
    -- comparing content width against (dimen.w - 3*scrollbar_width) — not
    -- dimen.w itself. If our content fills the full content_w, that check
    -- always false-positives, which was BOTH the phantom bar at the
    -- bottom (issue: extra status bar) AND the content getting visually
    -- cropped/shifted (issue: progress bar pushed to the right — that was
    -- KOReader thinking horizontal scroll was needed and showing a
    -- shifted viewport). Building the actual content narrower than
    -- content_w by this same margin fixes both at the root, rather than
    -- being a cosmetic patch.
    local scrollbar_reserve = Screen:scaleBySize(20) -- 3x default scroll_bar_width(6) + a hair of margin
    local inner_w = content_w - scrollbar_reserve

    local header = Header.build{ on_close = function() self:onClose() end }
    local bottom_nav = BottomNav.build("home", function(target_id)
        self:switchTo(target_id)
    end)

    local content_h = screen_h - Header.HEIGHT - BottomNav.HEIGHT

    local body = VerticalGroup:new{
        align = "left",
        self:buildCurrentlyReadingSection(inner_w),
        VerticalSpan:new{ width = Screen:scaleBySize(24) },
        self:buildRecentBooksSection(inner_w),
        VerticalSpan:new{ width = Screen:scaleBySize(24) },
        self:buildStatsSection(inner_w),
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

return AnanyaHome