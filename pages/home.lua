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
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

-- Opens a book, catching ANY error (bad file, corrupt document, whatever)
-- so it shows a message instead of taking the whole app down. Used by
-- every "tap a book to open it" callback in this file.
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

-- ReaderUI:showReader() documents itself as "the *only* safe way" to open
-- a book — it closes whatever screen was active FOR you, by broadcasting
-- a "ShowingReader" event that any active widget can catch (this is
-- exactly how KOReader's own Menu and FileManager widgets handle it).
-- We were previously calling UIManager:close(self) manually right before
-- showReader() from inside an active tap callback, which raced against
-- this same built-in mechanism and left a dangling, partially-torn-down
-- widget in the stack — that was the actual cause of the crash on the
-- next touch after returning from a book.
function AnanyaHome:onShowingReader()
    self:onClose()
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
    -- IMPORTANT: don't use self[1]:getSize() directly as the GestureRange
    -- range. VerticalGroup/HorizontalGroup's own getSize() returns a
    -- PLAIN Lua table ({w=.., h=..}), not a real Geom object — confirmed
    -- directly from koreader's own source. A plain table has no :contains()
    -- method, so GestureRange:match() crashes the instant anyone taps
    -- inside it ("attempt to call method 'contains' (a nil value)"). This
    -- is exactly why Recent Books (whose row wraps a VerticalGroup)
    -- crashed while Currently Reading (whose row wraps a FrameContainer,
    -- which DOES return a proper Geom) did not. Explicitly re-wrapping in
    -- Geom:new{} here makes this safe regardless of what self[1] is.
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h }
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
        -- Epub/etc descriptions are frequently raw HTML (tags + entities
        -- like &#8212;) — util.htmlToPlainTextIfHtml is KOReader's own
        -- built-in for exactly this (it's what SimpleUI uses too, for the
        -- same <dc:description> field).
        local description = props.description
        if description then
            local ok_html, plain = pcall(util.htmlToPlainTextIfHtml, description)
            description = ok_html and plain or description
        end
        return { title = props.title, authors = props.authors, description = description, cover = cover }
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

    local cover_w = is_hero and Screen:scaleBySize(160) or Screen:scaleBySize(50)
    local cover_h = is_hero and Screen:scaleBySize(240) or Screen:scaleBySize(75)
    local gap = Screen:scaleBySize(is_hero and 20 or 10)
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
        face = Font:getFace("tfont", is_hero and 22 or 15),
        max_width = text_w,
    }

    local author_widget = nil
    if meta.authors then
        author_widget = TextWidget:new{
            text = meta.authors,
            face = Font:getFace("cfont", is_hero and 16 or 12),
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
            face = Font:getFace("cfont", 14),
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
            safeOpenBook(entry.path)
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
            safeOpenBook(entry.path)
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
        -- Fixed division by RECENT_SLOT_COUNT (5), regardless of how many
        -- books are actually present. This is what the reference image
        -- shows: 5 comfortably-sized covers filling the row. (An earlier
        -- version divided by the ACTUAL count instead, which made covers
        -- balloon when only 2-3 books existed; a later version went too
        -- far the other way with a tiny fixed size. This is the middle
        -- ground: consistent, screenshot-matching size, with unused space
        -- on the right if you have fewer than 5 recent books.)
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

function AnanyaHome:buildUI()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local side_margin = Screen:scaleBySize(16)
    local content_w = screen_w - 2 * side_margin

    local header = Header.build{ on_close = function() self:onClose() end }
    local bottom_nav = BottomNav.build("home", function(target_id)
        self:switchTo(target_id)
    end)

    local content_h = screen_h - Header.HEIGHT - BottomNav.HEIGHT

    -- NOTE: deliberately NOT using ScrollableContainer here anymore. Its
    -- false-positive horizontal-scrollbar logic (triggers whenever a
    -- vertical scrollbar shows AND content fills the full width) was the
    -- root of a whole recurring bug class here: a phantom bar at the
    -- bottom, content getting visually shifted/cropped, and even text
    -- losing its first characters (the viewport was panned). This page's
    -- content is bounded — one hero card and a small row of covers — so
    -- it's sized to simply fit without scrolling at all, which is also
    -- what was explicitly asked for: no scroll, content stays on-page.
    local body = VerticalGroup:new{
        align = "left",
        self:buildCurrentlyReadingSection(content_w),
        VerticalSpan:new{ width = Screen:scaleBySize(20) },
        self:buildRecentBooksSection(content_w),
    }

    -- IMPORTANT: FrameContainer:getSize() (used just below) always
    -- computes its reported size from its CHILD's actual content size —
    -- it ignores its own explicit width/height fields for that purpose
    -- (those only affect what gets painted, not what's reported to the
    -- parent for layout). Since body is now shorter than content_h (more
    -- so after removing the Stats placeholder), content_area was
    -- reporting a shorter-than-intended height to the page below, which
    -- left bottom_nav positioned above where it should be — a visible
    -- gap between it and the true bottom edge, with white background
    -- showing through underneath. A plain WidgetContainer with an
    -- explicit `dimen` DOES honor that fixed size for getSize(), and
    -- paints its child at the top-left with no extra offset, so wrapping
    -- body in one forces content_area to correctly report the full
    -- content_h, and bottom_nav ends up exactly where it belongs.
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

return AnanyaHome