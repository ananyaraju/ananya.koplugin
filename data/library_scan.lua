-- data/library_scan.lua
-- Shared directory scanning for the Ananya/ library. Both the Home page
-- (currently reading) and the Library page (browsable list) use this so
-- there's exactly one place that knows how to walk the filesystem.

local lfs = require("libs/libkoreader-lfs")
local ffiutil = require("ffi/util")
local joinPath = ffiutil.joinPath

local LibraryScan = {}

-- EDIT THIS: absolute path to your library root on the device.
LibraryScan.root = "/mnt/us/Ananya"

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

return LibraryScan
