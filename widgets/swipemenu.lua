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
-- instance's own menu submodule's :onShowMenu() — the literal same
-- tabbed Filter/Settings/Tools/Search menu you'd get from FileManager or
-- the Reader directly, not a lookalike.
--
-- IF NO RUNNING UI IS FOUND, DO NOTHING — deliberately, not a fallback
-- menu. An earlier version showed a minimal custom menu in that case, on
-- the assumption "nothing found" meant something had gone wrong and the
-- swipe shouldn't be a dead end. In practice that assumption was wrong,
-- and actively harmful: our swipe zone stays registered on the Ananya
-- page underneath even while the real menu is open on top of it, and
-- tapping "Exit" inside that real menu starts tearing down
-- FileManager/ReaderUI — during which our zone can pick up a stray
-- gesture and fire again, right as FileManager.instance/ReaderUI.instance
-- are being cleared. getRunningUI() legitimately finding nothing at that
-- exact moment isn't a broken state to rescue with a fallback menu — the
-- app is already exiting, and popping up ANY menu there just hijacks
-- that: the old fallback's "Close" button only closed Ananya's own
-- screen, not KOReader, which looked like "Exit doesn't work, and this
-- weird menu appears instead". Doing nothing lets the real exit proceed.
--
-- Usage from any page's :init():
--     local SwipeMenu = require("widgets/swipemenu")
--     SwipeMenu.attach(self, {
--         on_close = function() self:onClose() end,
--     })

local Device = require("device")
local logger = require("logger")

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

-- Shows KOReader's own real menu, via whichever FileManager/ReaderUI
-- instance is actually running. If none can be found, closes `page`
-- instead — see below for why that's essential, not optional.
function SwipeMenu.show(page)
    local ui = getRunningUI()
    -- IMPORTANT: onShowMenu lives on ui.menu (a FileManagerMenu/ReaderMenu
    -- *submodule*), not on the FileManager/ReaderUI instance itself.
    -- Confirmed directly in filemanager.lua: modules are attached via
    -- registerModule(name, ui_module), whose implementation is just
    -- `self[name] = ui_module` — so FileManagerMenu ends up at
    -- ui.menu, never merged into ui's own prototype.
    if ui and ui.menu and ui.menu.onShowMenu then
        local ok, err = pcall(function() ui.menu:onShowMenu() end)
        if ok then return end
        logger.warn("Ananya: ui.menu:onShowMenu() failed ->", tostring(err))
    end

    -- No running FileManager/ReaderUI found. An earlier version did
    -- nothing here, on the theory that this state only happens
    -- transiently while KOReader is exiting and shouldn't be
    -- interrupted with a menu. That was half right and half a serious
    -- bug: FileManager.instance/ReaderUI.instance genuinely being nil
    -- can persist (if Exit gets partway through tearing FileManager down
    -- and then stalls for any reason — including, plausibly, because
    -- Ananya's own widget was still sitting on top of the stack keeping
    -- UIManager:run() from ever seeing it as empty). "Do nothing" in
    -- that state meant swipe permanently stopped doing anything, with no
    -- ✕ button and (no hardware keys on this device) no other way out —
    -- genuinely stuck. Closing `page` here instead means: if the real
    -- screens are gone, get Ananya out of the way too, rather than
    -- becoming the one remaining un-closable thing on screen.
    if page and page.onClose then
        pcall(function() page:onClose() end)
    end
end

-- Wires up the swipe-down-to-menu gesture on `page`. `page` must be an
-- InputContainer (registerTouchZones lives on that base class — every
-- Ananya page already is one).
function SwipeMenu.attach(page)
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
                        SwipeMenu.show(page)
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

-- Removes the gesture zone — call from a page's onClose()/onCloseWidget()
-- as basic hygiene, so a closing page's zone can't still be live to catch
-- a stray gesture during teardown (see the big comment above).
function SwipeMenu.detach(page)
    local ok, err = pcall(function()
        page:unRegisterTouchZones({ { id = "ananya_swipe_menu" } })
    end)
    if not ok then
        logger.warn("Ananya: failed to detach swipe-down menu ->", tostring(err))
    end
end

return SwipeMenu