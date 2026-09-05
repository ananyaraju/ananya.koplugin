-- main.lua — Ananya
-- Plugin entry point. Keeps this file tiny: all UI lives in pages/ and
-- widgets/.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Ananya = WidgetContainer:extend{
    name = "AnanyaUI",
    is_doc_only = false,
}

-- Setting key for "Start with Ananya Home" (see addToMainMenu below).
-- G_reader_settings is KOReader's own persistent settings store — this
-- is the same mechanism the device's own "12-hour clock" toggle etc. use,
-- so it survives restarts without Ananya needing its own settings file.
local START_WITH_SETTING = "ananya_start_with_home"

function Ananya:init()
    self.ui.menu:registerToMainMenu(self)

    -- Auto-open Home on startup, if enabled — this is how SimpleUI's own
    -- "Start with Desktop" works too: not a KOReader core setting (there
    -- isn't a generic "which screen replaces the file manager" hook —
    -- confirmed directly in reader.lua, which only recognizes a small
    -- fixed set of start_with values: "last", "filemanager", "history",
    -- "favorites", "folder_shortcuts" — nothing pluggable), but a plugin
    -- auto-showing its own screen right after the real startup screen
    -- has finished initializing.
    --
    -- FileManager-only (self.ui.file_chooser only exists on FileManager,
    -- not ReaderUI): Ananya:init() also runs when a book is opened
    -- (ReaderUI has its own instance of every plugin), and auto-popping
    -- Home open every time you open a book would be wrong — this should
    -- only fire for "KOReader just started up into the file manager".
    --
    -- registerPostInitCallback, not an immediate call: at the point
    -- init() runs, FileManager/ReaderUI is still mid-setup (this is
    -- itself being called *from* that setup, as part of loading every
    -- installed plugin) — showing another full-screen widget on top of
    -- it right now would be jumping the gun. postInitCallback is
    -- KOReader's own mechanism for "run this once the screen has
    -- actually finished initializing", confirmed present on both
    -- FileManager and ReaderUI, and used internally by KOReader itself
    -- for exactly this kind of deferred setup.
    if self.ui.file_chooser and G_reader_settings:isTrue(START_WITH_SETTING) then
        self.ui:registerPostInitCallback(function()
            self:openHome()
        end)
    end
end

function Ananya:addToMainMenu(menu_items)
    menu_items.ananya_home = {
        text = _("AnanyaUI"),
        sorting_hint = "more_tools",
        callback = function()
            self:openHome()
        end,
    }
    menu_items.ananya_start_with_home = {
        text = _("Start with Ananya Home"),
        sorting_hint = "more_tools",
        checked_func = function()
            return G_reader_settings:isTrue(START_WITH_SETTING)
        end,
        callback = function()
            if G_reader_settings:isTrue(START_WITH_SETTING) then
                G_reader_settings:flipFalse(START_WITH_SETTING)
            else
                G_reader_settings:flipTrue(START_WITH_SETTING)
            end
        end,
    }
end

function Ananya:openHome()
    local ok, AnanyaHome_or_err = pcall(require, "pages/home")
    if not ok then
        logger.warn("Ananya: failed to load pages/home ->", tostring(AnanyaHome_or_err))
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("Ananya failed to load. Check crash.log."),
        })
        return
    end
    UIManager:show(AnanyaHome_or_err:new{})
end

return Ananya