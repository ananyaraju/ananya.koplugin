-- data/library_scan.lua
-- Shared directory scanning for the Ananya/ library. Both the Home page
-- (currently reading) and the Library page (browsable list) use this so
-- there's exactly one place that knows how to walk the filesystem.

local lfs = require("libs/libkoreader-lfs")
local ffiutil = require("ffi/util")
local logger = require("logger")
local joinPath = ffiutil.joinPath

local LibraryScan = {}

-- EDIT THIS: absolute path to your library root on the device.
LibraryScan.root = "/mnt/us/Ananya"

-- The Library page lists these two subtrees separately (its "Books" vs
-- "Manga" major filter), rather than the flat whole-of-Ananya/ scan that
-- getAllFiles() below does for Home's "currently reading"/"recent books"
-- use cases. EDIT THESE if your folder names differ.
LibraryScan.booksRoot = LibraryScan.root .. "/Books"
LibraryScan.mangaRoot = LibraryScan.root .. "/Manga"

local SUPPORTED_EXTENSIONS = {
    epub = true, mobi = true, azw3 = true, azw = true, fb2 = true,
    pdf = true, djvu = true, txt = true, doc = true,
    cbz = true, cbr = true, cbt = true,
}

-- Recursively walk a directory, returning { {path=..., name=...}, ... }.
-- Skips KOReader's own ".sdr" sidecar folders.
local function scanDirectory(dir_path)
    local results = {}
    if lfs.attributes(dir_path, "mode") ~= "directory" then
        return results
    end
    for entry in lfs.dir(dir_path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = joinPath(dir_path, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                if not entry:match("%.sdr$") then
                    local sub_results = scanDirectory(full_path)
                    for _, r in ipairs(sub_results) do
                        table.insert(results, r)
                    end
                end
            elseif mode == "file" then
                local ext = entry:match("%.([%a%d]+)$")
                if ext and SUPPORTED_EXTENSIONS[ext:lower()] then
                    table.insert(results, { path = full_path, name = entry })
                end
            end
        end
    end
    return results
end

-- Returns the full flat list of every supported file under LibraryScan.root.
function LibraryScan.getAllFiles()
    return scanDirectory(LibraryScan.root)
end

-- Returns every supported file under Ananya/Books (recursively — series
-- kept in subfolders are still picked up, same as getAllFiles()).
function LibraryScan.getBooks()
    return scanDirectory(LibraryScan.booksRoot)
end

-- Returns every supported file under Ananya/Manga (recursively).
function LibraryScan.getManga()
    return scanDirectory(LibraryScan.mangaRoot)
end

-- Of a flat file list (defaults to a fresh full scan), returns the ones
-- that have been opened before and are not marked "complete", sorted by
-- how far along you are.
function LibraryScan.getCurrentlyReading(all_files)
    all_files = all_files or LibraryScan.getAllFiles()
    local BookList = require("ui/widget/booklist")
    local reading = {}
    for _, entry in ipairs(all_files) do
        if BookList.hasBookBeenOpened(entry.path) then
            local info = BookList.getBookInfo(entry.path)
            if info.status ~= "complete" then
                table.insert(reading, {
                    path = entry.path,
                    name = entry.name,
                    percent = info.percent_finished or 0,
                })
            end
        end
    end
    table.sort(reading, function(a, b) return a.percent > b.percent end)
    return reading
end

-- Returns up to `limit` most recently opened books under LibraryScan.root,
-- most-recent-first. Uses KOReader's own ReadHistory (already maintained
-- by the app every time any book is opened) rather than tracking this
-- ourselves — ReadHistory.hist is kept in most-recent-first order.
function LibraryScan.getRecentBooks(limit)
    limit = limit or 5
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then
        return {}
    end
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    local recent = {}
    for _, item in ipairs(ReadHistory.hist) do
        -- ReadHistory logs every file ever opened in KOReader (images
        -- viewed, text logs, whatever) — not just books. Filter to the
        -- same supported book/manga extensions used for library scanning,
        -- otherwise things like a viewed .jpeg wallpaper show up here too.
        local ext = item.file and item.file:match("%.([%a%d]+)$")
        if item.file and ext and SUPPORTED_EXTENSIONS[ext:lower()]
            and item.file:sub(1, #LibraryScan.root) == LibraryScan.root then
            local percent = 0
            if ok_bl then
                local ok_info, info = pcall(BookList.getBookInfo, item.file)
                if ok_info and info then
                    percent = info.percent_finished or 0
                end
            end
            table.insert(recent, { path = item.file, name = item.text, percent = percent })
            if #recent >= limit then
                break
            end
        end
    end
    return recent
end

-- Returns the single most-recently-opened book (via ReadHistory, so
-- "most recent" means recency, not progress) that is not marked
-- complete, or nil if there isn't one. Used for a single-book "Currently
-- Reading" section rather than listing every in-progress book.
function LibraryScan.getLastOpenedInProgress()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then
        return nil
    end
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if not ok_bl then
        return nil
    end
    for _, item in ipairs(ReadHistory.hist) do
        local ext = item.file and item.file:match("%.([%a%d]+)$")
        if item.file and ext and SUPPORTED_EXTENSIONS[ext:lower()]
            and item.file:sub(1, #LibraryScan.root) == LibraryScan.root then
            local ok_info, info = pcall(BookList.getBookInfo, item.file)
            if ok_info and info and info.been_opened and info.status ~= "complete" then
                return {
                    path = item.file,
                    name = item.text,
                    percent = info.percent_finished or 0,
                }
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Book metadata (title / page count / cover) — used by the Library page's
-- book rows, which need the actual TITLE (not the filename) plus a page
-- count and a small cover thumbnail.
-- ---------------------------------------------------------------------------

-- In-memory cache of extracted metadata, keyed by path, kept for the
-- lifetime of this module (i.e. the whole KOReader process — require()
-- only loads this file once). Opening a document just to read its title
-- is relatively expensive (EPUBs in particular need at least a partial
-- parse), so without this cache, every rebuild of the Library page (e.g.
-- re-filtering, or typing into the search box) would re-open every book
-- on disk from scratch on every keystroke.
LibraryScan._meta_cache = {}

-- Extracts { title, authors, pages, cover } for a single book, opening
-- the document only once (via pcall, so a corrupt/unsupported file
-- degrades to filename-based fallbacks instead of taking the page down),
-- then caching the result by path for subsequent calls.
--
-- `filename` is used as the title fallback (extension stripped) for
-- formats with no embedded title metadata — this is the normal case for
-- comic archives (cbz/cbr/cbt), which is most of what lives under
-- Ananya/Manga.
--
-- PAGE COUNT, verified against KOReader's own source
-- (apps/filemanager/filemanagerbookinfo.lua, the file behind KOReader's
-- own "Book information" dialog — same problem, "show a page count
-- without opening the reader", solved there first):
--   - For a book that has been opened before, an accurate page count is
--     already cached in its docsettings sidecar (BookList.getBookInfo()
--     reads it from "doc_pages" / reading-statistics history) — no need
--     to open the document at all for this.
--   - For a reflowable format (epub/mobi/fb2/txt — anything CreDocument
--     handles) that's never been opened, there is NO cheap way to get an
--     accurate count: crengine only knows real page boundaries after a
--     full CSS/font layout pass (Document:render()), which is expensive
--     enough that KOReader's own book-info dialog explicitly declines to
--     do it, noting that calling getPageCount() without that render pass
--     first returns a number that's "wrong, often 2 to 3 times" the real
--     count. So: pages stays nil (shown as "unknown") for a never-opened
--     book in a reflowable format, on purpose, matching KOReader itself.
--   - For a fixed-layout format (pdf/djvu/comic archives), getPageCount()
--     is immediate and accurate with no special loading step, since
--     "pages" there just means "how many images/pages exist", not
--     something that depends on reflow.
--
-- TITLE/AUTHORS: for CreDocument formats, getProps() only returns real
-- title/author metadata after the document has actually been loaded —
-- confirmed against credocument.lua directly (see home.lua's
-- getCoverAndProps, which hit this exact same issue first). Non-crengine
-- formats don't need this extra step.
function LibraryScan.getBookMeta(path, filename)
    local cached = LibraryScan._meta_cache[path]
    if cached then
        return cached
    end

    local meta = {
        title = filename:gsub("%.[%a%d]+$", ""), -- fallback: filename, no extension
        authors = nil,
        pages = nil,
        cover = nil,
    }

    -- Fast, safe path first: if this book has been opened before, its
    -- docsettings sidecar already has an accurate page count cached —
    -- no document needs to be opened at all to get it.
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl then
        local ok_info, info = pcall(BookList.getBookInfo, path)
        if ok_info and info and info.been_opened and info.pages then
            meta.pages = info.pages
        end
    end

    local ok = pcall(function()
        local DocumentRegistry = require("document/documentregistry")
        local doc = DocumentRegistry:openDocument(path)
        if not doc then return end

        local loaded = true
        if doc.loadDocument then
            -- CreDocument (epub/mobi/fb2/txt/html): needs an explicit
            -- load before getProps()/getCoverPageImage() return anything
            -- meaningful — see the big comment above this function.
            -- Deliberately NOT attempting getPageCount() for these; see
            -- above for why that would just be an inaccurate number.
            local ok_load, result = pcall(function() return doc:loadDocument() end)
            if not ok_load or not result then
                loaded = false
            end
        elseif not meta.pages then
            -- Fixed-layout formats (pdf/djvu/comic archives): safe and
            -- accurate immediately, no load step needed. Only bother if
            -- the sidecar cache above didn't already give us a count.
            local ok_pages, pages = pcall(function() return doc:getPageCount() end)
            if ok_pages and pages and pages > 0 then
                meta.pages = pages
            end
        end

        if loaded then
            local ok_props, props = pcall(function() return doc:getProps() end)
            if ok_props and props then
                if props.title and props.title ~= "" then
                    meta.title = props.title
                end
                if props.authors and props.authors ~= "" then
                    meta.authors = props.authors
                end
            end

            local ok_cover, cover = pcall(function() return doc:getCoverPageImage() end)
            if ok_cover and cover then
                -- Validate dimensions before accepting this cover at all. A
                -- corrupt or unusual source file (more likely for comic
                -- archives than for epub/pdf) can hand back a cover with a
                -- zero width or height. ImageWidget's "scale to fit" math
                -- does self.width / bb_w — dividing by a zero bb_w produces
                -- `inf` (Lua doesn't error on float division by zero), which
                -- then flows into a native buffer-scaling call as a
                -- nonsensical target size. That's a segfault, not a
                -- catchable Lua error, and it only actually happens once the
                -- row gets painted — which is exactly why this only showed
                -- up under some filters (whichever ones actually render
                -- that book's row) and not others.
                local ok_dim, cover_w, cover_h = pcall(function()
                    return cover:getWidth(), cover:getHeight()
                end)
                if ok_dim and cover_w and cover_h and cover_w > 0 and cover_h > 0 then
                    -- Copy rather than keep the buffer doc:getCoverPageImage()
                    -- hands back: some backends return a buffer backed
                    -- directly by the document's own internal (e.g. mupdf)
                    -- memory, which is only guaranteed valid while the
                    -- document stays open. Since we cache this cover
                    -- indefinitely (LibraryScan._meta_cache, for the whole
                    -- process lifetime) but the document below is closed
                    -- immediately, an uncopied reference would eventually
                    -- point at freed memory — see the doc:close() note just
                    -- below for why "eventually" here specifically means
                    -- "the next time you open a document from a different
                    -- folder", which is exactly what caused a segfault
                    -- switching Books -> Manga -> Books.
                    local ok_copy, cover_copy = pcall(function() return cover:copy() end)
                    if ok_copy and cover_copy then
                        meta.cover = cover_copy
                    end
                else
                    logger.warn("Ananya: skipping malformed cover (bad dimensions) ->", tostring(path))
                end
            end
        end

        -- IMPORTANT: doc:close(), NOT DocumentRegistry:closeDocument(path).
        -- The latter only decrements DocumentRegistry's internal refcount;
        -- actually freeing the document's native (mupdf/crengine/etc)
        -- resources only happens inside doc:close(), which calls
        -- DocumentRegistry:closeDocument() itself once it's done. Calling
        -- the registry method directly leaves the document's native
        -- backend "open" until Lua's GC happens to collect it, and
        -- DocumentRegistry:openDocument() *forces* a GC sweep at the
        -- start of every call — so the very next book you open (e.g.
        -- switching the major filter back to Books) can trigger that
        -- delayed cleanup mid-scan, freeing memory that an already-cached
        -- cover from the previous folder was still pointing at. That's
        -- the segfault this fixes.
        doc:close()
    end)
    if not ok then
        logger.warn("Ananya: failed to read book metadata ->", tostring(path))
    end

    LibraryScan._meta_cache[path] = meta
    return meta
end

-- Returns status, percent for a book:
--   status  - "complete", some other in-progress status string (e.g.
--             "reading"), or nil (never opened). Used by the Library
--             page's Completed/Ongoing filter — anything that isn't
--             exactly "complete" is treated as "Ongoing", never-opened
--             books included.
--   percent - 0.0-1.0 read fraction (0 for a never-opened book), from
--             KOReader's own per-book reading-progress tracking. Used
--             for the "X% read" shown on each row.
function LibraryScan.getReadStatus(path)
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if not ok_bl then
        return nil, 0
    end
    local ok_opened, opened = pcall(BookList.hasBookBeenOpened, path)
    if not ok_opened or not opened then
        return nil, 0
    end
    local ok_info, info = pcall(BookList.getBookInfo, path)
    if not ok_info or not info then
        return nil, 0
    end
    return info.status, info.percent_finished or 0
end

return LibraryScan