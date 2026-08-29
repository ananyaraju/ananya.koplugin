-- stats.lua - ananya
-- Builds and shows a full-screen "library home" page: shelf counts,
-- currently-reading list, and a browsable list of every book that
-- opens straight into the reader when tapped.

local lfs = require("libs/libkoreader-lfs")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local BookList = require("ui/widget/booklist")
local ReaderUI = require("apps/reader/readerui")
local ffiutil = require("ffi/util")
local joinPath = ffiutil.joinPath
local _ = require("gettext")

local StatsPage = {}

-- EDIT THIS: absolute path to your library root on the device.
-- On a Kindle this is typically under /mnt/us/...
StatsPage.library_root = "/mnt/us/Ananya"

-- File extensions we count as "books". Add/remove as you like.
local SUPPORTED_EXTENSIONS = {
    epub = true, mobi = true, azw3 = true, azw = true, fb2 = true,
    pdf = true, djvu = true, txt = true, doc = true,
    cbz = true, cbr = true, cbt = true,
}

-- Recursively walk a directory, returning { {path=..., name=...}, ... }
-- for every file with a supported extension. Skips KOReader's own
-- ".sdr" sidecar folders.
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

-- Scans Ananya/Manga and Ananya/Books and returns counts + file lists.
function StatsPage.getLibraryStats()
    local manga_dir = joinPath(StatsPage.library_root, "Manga")
    local books_dir = joinPath(StatsPage.library_root, "Books")

    return {
        manga = scanDirectory(manga_dir),
        books = scanDirectory(books_dir),
    }
end

-- Of a flat file list, returns the ones that have been opened before
-- and are not marked "complete", sorted by how far you've gotten.
local function getCurrentlyReading(all_files)
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

-- Opens a book directly in the reader, closing the stats menu first.
local function openBook(menu_instance, filepath)
    UIManager:close(menu_instance)
    ReaderUI:showReader(filepath)
end

function StatsPage.show()
    local stats = StatsPage.getLibraryStats()

    local all_files = {}
    for _, f in ipairs(stats.manga) do table.insert(all_files, f) end
    for _, f in ipairs(stats.books) do table.insert(all_files, f) end

    local reading = getCurrentlyReading(all_files)

    local item_table = {}

    -- Shelf counts (informational rows, no callback)
    table.insert(item_table, { text = string.format(_("Manga: %d"), #stats.manga) })
    table.insert(item_table, { text = string.format(_("Books: %d"), #stats.books) })
    table.insert(item_table, { text = string.format(_("Total: %d"), #all_files) })

    local menu -- forward declare so callbacks below can close it

    -- Currently reading section
    if #reading > 0 then
        table.insert(item_table, { text = _("── Currently Reading ──") })
        for _, entry in ipairs(reading) do
            table.insert(item_table, {
                text = entry.name,
                mandatory = string.format("%d%%", math.floor(entry.percent * 100)),
                callback = function() openBook(menu, entry.path) end,
            })
        end
    end

    -- Full browsable library
    table.insert(item_table, { text = _("── All Books ──") })
    for _, entry in ipairs(all_files) do
        table.insert(item_table, {
            text = entry.name,
            callback = function() openBook(menu, entry.path) end,
        })
    end

    menu = Menu:new{
        title = _("Ananya Library"),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
end

return StatsPage
