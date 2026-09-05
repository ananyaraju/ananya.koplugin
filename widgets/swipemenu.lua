-- widgets/swipemenu.lua
-- Shared "swipe down to open a menu" gesture, matching the exact
-- mechanism KOReader's own FileManager/Reader use for their native
-- Tools/Search menu (see apps/filemanager/filemanagermenu.lua's
-- initGesListener/onSwipeShowMenu in KOReader's own source — this is
-- modeled directly on that, right down to reusing the same screen zone
-- setting, so the swipe-down gesture feels identical to it).
--
-- THE ACTUAL MENU SHOWN IS KOREADER'S OWN, NOT A CUSTOM ONE. Ananya's
-- pages are shown via UIManager:show() *on top of* FileManager, not by
-- replacing/closing it — so FileManager is still alive underneath the
-- whole time Ananya is on screen, and FileManager.instance still points
-- at it. That's confirmed directly from KOReader's own source:
-- FileManager.instance is set on init and only cleared in its own
-- onClose(), and KOReader's own core code (e.g.
-- FileManager.getDisplayModeActions()) fetches "whichever main screen is
-- currently running" with exactly this pattern:
--     local ui = FileManager.instance or require("apps/reader/readerui").instance
-- So rather than build our own menu, this just calls that same running
-- instance's own :onShowMenu() — the literal same tabbed
-- Filter/Settings/Tools/Search menu you'd get from FileManager or the
-- Reader directly, not a lookalike. If for some reason neither instance
-- is available (shouldn't normally happen, since Ananya is always opened
-- from one of them), this falls back to a minimal menu with just a
-- Close entry, so swiping down never does nothing.
--
-- Usage from any page's :init():
--     local SwipeMenu = require("widgets/swipemenu")
--     SwipeMenu.attach(self, {
--         on_close = function() self:onClose() end,
--     })

local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local SwipeMenu = {}

-- Finds whichever real KOReader screen is currently running underneath
-- Ananya (FileManager, most commonly, since that's where the "AnanyaUI"
-- menu entry lives — see main.lua — but ReaderUI too, in case Ananya is
-- ever opened while a book is open).
local function getRunningUI()
    local ok, ui = pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        local ReaderUI = require("apps/reader/readerui")
        return FileManager.instance or ReaderUI.instance
    end)
    if ok then return ui end
    return nil
end

-- Minimal fallback menu — only used if getRunningUI() finds nothing,
-- which shouldn't normally happen.
local function showFallbackMenu(opts)
    local ok, err = pcall(function()
        local Menu = require("ui/widget/menu")
        local menu_instance
        menu_instance = Menu:new{
            title = opts.title or _("Ananya"),
            item_table = {
                { text = _("Close"), callback = opts.on_close },
            },
            width = math.floor(Screen:getWidth() * 0.8),
            height = math.floor(Screen:getHeight() * 0.6),
            is_popout = true,
        }
        menu_instance.close_callback = function()
            UIManager:close(menu_instance)
        end
        UIManager:show(menu_instance)
    end)
    if not ok then
        logger.warn("Ananya: fallback swipe-down menu failed ->", tostring(err))
    end
end

-- Shows the menu: KOReader's own real one if we can find the running
-- FileManager/ReaderUI instance, else the minimal fallback above.
function SwipeMenu.show(opts)
    opts = opts or {}
    local ui = getRunningUI()
    -- IMPORTANT: onShowMenu lives on ui.menu (a FileManagerMenu/ReaderMenu
    -- *submodule*), not on the FileManager/ReaderUI instance itself.
    -- Confirmed directly in filemanager.lua: modules are attached via
    -- registerModule(name, ui_module), whose implementation is just
    -- `self[name] = ui_module` — so FileManagerMenu ends up at
    -- ui.menu, never merged into ui's own prototype. Calling
    -- ui:onShowMenu() therefore always failed (no such method on ui
    -- itself) and silently fell back to the custom minimal menu every
    -- time, which is exactly the bug this fixes.
    if ui and ui.menu and ui.menu.onShowMenu then
        local ok, err = pcall(function() ui.menu:onShowMenu() end)
        if ok then return end
        logger.warn("Ananya: ui.menu:onShowMenu() failed, falling back ->", tostring(err))
    end
    showFallbackMenu(opts)
end

-- Wires up the swipe-down-to-menu gesture on `page`. `page` must be an
-- InputContainer (registerTouchZones lives on that base class — every
-- Ananya page already is one). `opts` is passed straight through to
-- SwipeMenu.show() (only used if it has to fall back).
function SwipeMenu.attach(page, opts)
    if not Device:isTouchDevice() then
        return
    end
    local ok, err = pcall(function()
        -- Reuse the exact same screen zone KOReader's own FileManager/
        -- Reader menu uses for its swipe-down gesture (a configurable
        -- top band of the screen, not the whole screen) — reusing it
        -- means Ananya's swipe-down zone matches whatever the device is
        -- already configured with, rather than a hardcoded guess.
        local zone = (G_defaults and G_defaults:readSetting("DTAP_ZONE_MENU"))
            or { x = 0, y = 0, w = 1, h = 0.1 }
        page:registerTouchZones({
            {
                id = "ananya_swipe_menu",
                ges = "swipe",
                screen_zone = {
                    ratio_x = zone.x, ratio_y = zone.y,
                    ratio_w = zone.w, ratio_h = zone.h,
                },
                handler = function(ges)
                    if ges.direction == "south" then
                        SwipeMenu.show(opts)
                        return true
                    end
                end,
            },
        })
    end)
    if not ok then
        logger.warn("Ananya: failed to attach swipe-down menu ->", tostring(err))
    end
end

return SwipeMenu