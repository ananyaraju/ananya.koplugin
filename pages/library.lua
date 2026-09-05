-- pages/library.lua
-- The Library page: persistent header + bottom nav, with a custom
-- scrollable list of books/manga under Ananya/Books and Ananya/Manga.
-- Tapping a row opens it directly in the reader.
--
-- ARCHITECTURE NOTE (why this doesn't use KOReader's stock Menu widget):
-- An earlier version embedded ui/widget/menu.lua as a *child* inside this
-- page's own header/bottomnav layout. Menu is a large, stateful widget
-- designed to be shown directly via UIManager:show() as its own top-level
-- screen (that's how KOReader's file browser, OPDS catalog, etc. all use
-- it) — nesting it inside another widget's layout is not how it's meant
-- to be used, and was the likely cause of a crash. This version follows
-- SimpleUI's own lead (it hand-builds its book grid rather than reusing
-- Menu) and uses custom rows instead, same recipe as Home's "Currently
-- Reading" rows.
--
-- FILTERS:
--   - Major filter: Books vs Manga — these are two entirely separate
--     folders (Ananya/Books, Ananya/Manga), scanned independently by
--     data/library_scan.lua, so switching this re-scans rather than just
--     re-filtering an in-memory list.
--   - Status filter: All / Ongoing / Completed, based on KOReader's own
--     per-book read status (see LibraryScan.getReadStatus). "Ongoing"
--     includes never-opened books, not just partially-read ones — there
--     was no third "unread" bucket in the request, so it's lumped in with
--     Ongoing rather than silently hidden.
--   - Title search: a standalone InputDialog (shown the normal, correct
--     way — as its own top-level widget via UIManager:show()). Filters by
--     the book's actual TITLE (from metadata, via LibraryScan.getBookMeta)
--     rather than filename.
--
-- Each row shows a cover-thumbnail icon, the title, and a page count —
-- all sourced from LibraryScan.getBookMeta(), which opens the document
-- once and caches the result, since opening every book on disk just to
-- read its title is too expensive to redo on every keystroke/filter
-- change (see the cache comment in library_scan.lua for details).

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

local Screen = Device.screen

-- Same helper as home.lua: wraps opening a book in pcall so any error
-- (bad file, corrupt document, whatever) shows a message instead of
-- taking the app down.
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
    getBooks = function() return {} end,
    getManga = function() return {} end,
    getBookMeta = function(path, filename) return { title = filename, pages = nil, cover = nil } end,
    getReadStatus = function() return nil end,
})

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

    self.major_filter = "books"   -- "books" | "manga"
    self.status_filter = "all"    -- "all" | "ongoing" | "completed"
    self.search_query = nil       -- nil = no active title filter

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

-- See home.lua's onShowingReader for the full explanation: this is the
-- correct, koreader-native way to close ourselves when a book opens,
-- instead of manually closing right before calling showReader().
function AnanyaLibrary:onShowingReader()
    self:onClose()
end

function AnanyaLibrary:switchTo(target_id)
    if target_id == "home" then
        UIManager:close(self)
        local AnanyaHome = require("pages/home")
        UIManager:show(AnanyaHome:new{})
    elseif target_id == "newpage" then
        UIManager:close(self)
        local AnanyaNewPage = require("pages/newpage")
        UIManager:show(AnanyaNewPage:new{})
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
-- Filter state changes — all funnel through rebuild()
-- ---------------------------------------------------------------------------

function AnanyaLibrary:setMajorFilter(id)
    if self.major_filter == id then return end
    self.major_filter = id
    self:rebuild()
end

function AnanyaLibrary:setStatusFilter(id)
    if self.status_filter == id then return end
    self.status_filter = id
    self:rebuild()
end

-- Rebuilds the whole page in place (simplest safe way to reflect a new
-- filter/search state — no partial-update bookkeeping to get wrong).
function AnanyaLibrary:rebuild()
    local ok, err = pcall(function() self:buildUI() end)
    if not ok then
        logger.warn("Ananya: library rebuild failed ->", tostring(err))
        self:buildFailSafeUI()
    end
    UIManager:setDirty(self, "full")
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

function AnanyaLibrary:openSearchDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Search by title"),
        input = self.search_query or "",
        input_hint = _("Title contains…"),
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

-- ---------------------------------------------------------------------------
-- Toggle-style filter buttons (major filter row + status filter row)
-- ---------------------------------------------------------------------------

local function buildToggleButton(label, is_active, callback)
    return Button:new{
        text = label,
        callback = callback,
        text_font_size = 15,
        text_font_bold = is_active,
        bordersize = is_active and Size.border.button or 0,
        margin = Screen:scaleBySize(2),
        padding_h = Screen:scaleBySize(8),
        radius = 0,
    }
end

-- ---------------------------------------------------------------------------
-- Book rows
-- ---------------------------------------------------------------------------

-- A tappable row: cover icon + title + page count, opens the book
-- directly. Same recipe as pages/home.lua's ReadingRow.
local BookRow = InputContainer:extend{}

function BookRow:init()
    -- See home.lua's ReadingRow for why this explicit re-wrap matters:
    -- VerticalGroup/HorizontalGroup's getSize() returns a plain table,
    -- not a real Geom, which crashes GestureRange:match(). framed here
    -- is a FrameContainer (safe either way), but this makes the class
    -- robust regardless of what gets passed as the child in the future.
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function BookRow:onTap()
    if self.callback then self.callback() end
    return true
end

local ICON_W = Screen:scaleBySize(44)
local ICON_H = Screen:scaleBySize(62) -- ~2:3, typical book/manga cover ratio

-- Builds the small cover-thumbnail icon for a row. Uses `image =` (a
-- pre-decoded BlitBuffer from doc:getCoverPageImage(), same recipe as
-- newpage.lua's Recent Books shelf) rather than `file =`, which matters:
-- ImageWidget's `file =` path runs decoded buffers through its shared
-- 8MB-capped ImageCache before any resize happens if scale_factor is set,
-- which is exactly what crashed the Home page logo earlier. `image =`
-- skips that cache entirely, so scale_factor=0 (best-fit, since covers
-- come in all sorts of aspect ratios unlike our fixed-ratio logo) is safe
-- to use here.
--
-- IMPORTANT: image_disposable = false. This cover BlitBuffer comes from
-- LibraryScan's own metadata cache (LibraryScan._meta_cache), which is
-- deliberately shared and long-lived — reused across every rebuild()
-- triggered by clicking a filter, not re-decoded each time. ImageWidget
-- defaults image_disposable to true, meaning it assumes it OWNS the
-- buffer and will free() it once the widget itself is discarded. Since
-- every filter click discards the old row widgets and builds fresh ones
-- pointing at that *same* shared buffer, leaving the default in place
-- meant the first rebuild's widget would free memory the cache was still
-- holding a reference to — the next filter click then handed that
-- already-freed buffer to a new ImageWidget. That's what was crashing on
-- repeated filter clicks. Setting this to false tells ImageWidget the
-- buffer is owned elsewhere (by the cache) and must not be freed here.
local function buildCoverIcon(cover)
    if cover then
        local ok_dim, cover_w, cover_h = pcall(function()
            return cover:getWidth(), cover:getHeight()
        end)
        if not (ok_dim and cover_w and cover_h and cover_w > 0 and cover_h > 0) then
            cover = nil -- fall through to the placeholder below
        end
    end
    if cover then
        return ImageWidget:new{
            image = cover,
            width = ICON_W,
            height = ICON_H,
            scale_factor = 0,
            image_disposable = false,
        }
    end
    -- No cover available (extraction failed, or format has none): a
    -- plain bordered placeholder box instead of leaving a gap.
    return FrameContainer:new{
        width = ICON_W,
        height = ICON_H,
        bordersize = Size.border.window,
        color = Blitbuffer.COLOR_LIGHT_GRAY,
        background = Blitbuffer.COLOR_WHITE,
        margin = 0,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = ICON_W, h = ICON_H },
            TextWidget:new{ text = "", face = Font:getFace("cfont", 9) },
        },
    }
end

function AnanyaLibrary:buildBookRow(entry, row_w)
    local text_w = row_w - ICON_W - Screen:scaleBySize(12)

    local cover_widget = buildCoverIcon(entry.cover)

    local title_widget = TextWidget:new{
        text = entry.title,
        face = Font:getFace("cfont", 16),
        max_width = text_w,
    }

    local pages_text
    if entry.pages then
        pages_text = string.format(_("%d pages"), entry.pages)
    else
        pages_text = _("Pages unknown")
    end
    local pages_widget = TextWidget:new{
        text = pages_text,
        face = Font:getFace("cfont", 13),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local text_col = VerticalGroup:new{
        align = "left",
        title_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        pages_widget,
    }

    local row = HorizontalGroup:new{
        cover_widget,
        HorizontalSpan:new{ width = Screen:scaleBySize(12) },
        text_col,
    }

    local framed = FrameContainer:new{
        width = row_w,
        bordersize = 0, margin = 0,
        padding_top = Screen:scaleBySize(8),
        padding_bottom = Screen:scaleBySize(8),
        padding_left = Screen:scaleBySize(4),
        padding_right = Screen:scaleBySize(4),
        row,
    }

    return BookRow:new{
        callback = function()
            safeOpenBook(entry.path)
        end,
        framed,
    }
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function AnanyaLibrary:buildUI()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local side_margin = Screen:scaleBySize(16)
    local content_w = screen_w - 2 * side_margin

    local header = Header.build{ on_close = function() self:onClose() end }
    local bottom_nav = BottomNav.build("library", function(target_id)
        self:switchTo(target_id)
    end)

    -- ── Scan + gather metadata for the active major filter ─────────────
    local ok_files, raw_files
    if self.major_filter == "manga" then
        ok_files, raw_files = pcall(LibraryScan.getManga)
    else
        ok_files, raw_files = pcall(LibraryScan.getBooks)
    end
    if not ok_files then
        logger.warn("Ananya: library scan failed ->", tostring(raw_files))
        raw_files = {}
    end

    local all_entries = {}
    for _, f in ipairs(raw_files) do
        local ok_meta, meta = pcall(LibraryScan.getBookMeta, f.path, f.name)
        if not ok_meta then
            logger.warn("Ananya: getBookMeta failed ->", tostring(meta))
            meta = { title = f.name, pages = nil, cover = nil }
        end
        local ok_status, status = pcall(LibraryScan.getReadStatus, f.path)
        if not ok_status then status = nil end
        table.insert(all_entries, {
            path = f.path,
            title = meta.title,
            pages = meta.pages,
            cover = meta.cover,
            status = status,
        })
    end

    -- ── Apply status filter (All / Ongoing / Completed) ─────────────────
    local status_filtered = all_entries
    if self.status_filter ~= "all" then
        status_filtered = {}
        for _, entry in ipairs(all_entries) do
            local is_complete = entry.status == "complete"
            if (self.status_filter == "completed" and is_complete)
                or (self.status_filter == "ongoing" and not is_complete) then
                table.insert(status_filtered, entry)
            end
        end
    end

    -- ── Apply title search ──────────────────────────────────────────────
    local visible_entries = status_filtered
    if self.search_query then
        local needle = util.stringLower(self.search_query)
        visible_entries = {}
        for _, entry in ipairs(status_filtered) do
            if util.stringLower(entry.title):find(needle, 1, true) then
                table.insert(visible_entries, entry)
            end
        end
    end

    table.sort(visible_entries, function(a, b)
        return util.stringLower(a.title) < util.stringLower(b.title)
    end)

    -- ── Toolbar: major filter row, status filter + search row, count ───
    local major_row = HorizontalGroup:new{
        buildToggleButton(_("Books"), self.major_filter == "books", function()
            self:setMajorFilter("books")
        end),
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        buildToggleButton(_("Manga"), self.major_filter == "manga", function()
            self:setMajorFilter("manga")
        end),
    }

    local search_btn = Button:new{
        text = _("Search"),
        callback = function() self:openSearchDialog() end,
        text_font_size = 15,
        bordersize = Size.border.button,
        margin = Screen:scaleBySize(2),
        radius = 0,
    }

    local status_row = HorizontalGroup:new{
        buildToggleButton(_("All"), self.status_filter == "all", function()
            self:setStatusFilter("all")
        end),
        HorizontalSpan:new{ width = Screen:scaleBySize(6) },
        buildToggleButton(_("Ongoing"), self.status_filter == "ongoing", function()
            self:setStatusFilter("ongoing")
        end),
        HorizontalSpan:new{ width = Screen:scaleBySize(6) },
        buildToggleButton(_("Completed"), self.status_filter == "completed", function()
            self:setStatusFilter("completed")
        end),
        HorizontalSpan:new{ width = Screen:scaleBySize(12) },
        search_btn,
    }

    local count_text
    if self.search_query then
        count_text = string.format(_("\"%s\" — %d of %d"),
            self.search_query, #visible_entries, #status_filtered)
    else
        count_text = string.format(_("%d items"), #visible_entries)
    end
    local count_widget = TextWidget:new{
        text = count_text,
        face = Font:getFace("cfont", 13),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local toolbar = VerticalGroup:new{
        align = "left",
        major_row,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        status_row,
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        count_widget,
    }

    -- ── Book list ────────────────────────────────────────────────────
    local rows = VerticalGroup:new{ align = "left" }
    if #visible_entries == 0 then
        local empty_text
        if self.search_query then
            empty_text = _("No matches.")
        elseif self.major_filter == "manga" then
            empty_text = _("No manga found under Ananya/Manga.")
        else
            empty_text = _("No books found under Ananya/Books.")
        end
        table.insert(rows, TextWidget:new{
            text = empty_text,
            face = Font:getFace("cfont", 15),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    else
        for _, entry in ipairs(visible_entries) do
            table.insert(rows, self:buildBookRow(entry, content_w))
        end
    end

    -- NOTE: no ScrollableContainer here — see home.lua's buildUI for the
    -- full history of bugs it caused (false-positive scrollbar, viewport
    -- panning, clipped text). This list COULD be long (unlike Home's
    -- genuinely-bounded content), but stability comes first. Trade-off:
    -- if you have more items than fit on one screen, only the first ones
    -- (alphabetically, within the active filters) will be visible for
    -- now — search/status filters still work to narrow down to a
    -- specific item regardless of where it'd fall in the full list.
    local body = VerticalGroup:new{
        align = "left",
        toolbar,
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        rows,
    }

    local content_h = screen_h - Header.HEIGHT - BottomNav.HEIGHT

    -- Same forced-height fix as home.lua/newpage.lua's buildUI: a
    -- FrameContainer's getSize() ignores its own explicit height and
    -- derives it from its child's actual content instead. Without this,
    -- content_area shrinks to fit however many rows are actually visible,
    -- so on a short/filtered-down list bottom_nav rides up right after
    -- the content instead of staying pinned to the bottom of the screen.
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

return AnanyaLibrary