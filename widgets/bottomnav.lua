-- widgets/bottomnav.lua
-- Persistent bottom navigation bar: Home | Library | New Page.
--
-- SCOPE: modeled on SimpleUI's screens/sui_bottombar.lua look-and-feel
-- (icon + label per tab, a thin active-indicator bar pinned to the top of
-- the active tab, dimmed icon for inactive tabs) but reimplemented from
-- scratch, much simplified: SimpleUI's actual bottombar is ~1800 lines
-- supporting per-user icon recoloring, drag-to-reorder, badges, and a
-- config-driven tab list. This version hardcodes exactly three tabs
-- (Settings/History intentionally excluded per an earlier request) and
-- skips the theming system.
--
-- Usage from any page:
--     local BottomNav = require("widgets/bottomnav")
--     local page = VerticalGroup:new{
--         ... rest of the page ...
--         BottomNav.build("home", function(target_id)
--             if target_id == "library" then
--                 UIManager:close(self)
--                 UIManager:show(require("pages/library"):new{})
--             end
--         end),
--     }

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Screen = Device.screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local BottomNav = {}

local BAR_H = Screen:scaleBySize(64)
local ICON_SZ = Screen:scaleBySize(26)
local INDIC_H = Screen:scaleBySize(3)
local LABEL_FS = 12

-- The three tabs this build supports.
local TABS = {
    { id = "home",    icon = "home",         label = "Home" },
    { id = "library", icon = "book.opened",  label = "Library" },
    { id = "newpage", icon = "appbar.menu",  label = "New Page" },
}

BottomNav.HEIGHT = BAR_H + Size.line.thin

-- A tappable tab cell. Plain InputContainer + manual gesture range, same
-- recipe KOReader's own Button widget uses internally.
local TabCell = InputContainer:extend{}

function TabCell:init()
    -- Same defensive re-wrap as home.lua's ReadingRow: cell here is a
    -- CenterContainer with an explicit dimen (already safe), but this
    -- guards against the VerticalGroup/HorizontalGroup plain-table
    -- getSize() bug regardless of future changes.
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = sz.w, h = sz.h }
    self.ges_events = {
        Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function TabCell:onTap()
    if self.callback then self.callback() end
    return true
end

local function buildTabCell(tab, is_active, tab_w, on_tap)
    -- Same fix as header.lua's buildBatteryIcon: a solid-color rectangle
    -- with no child widget must be a LineWidget, not a childless
    -- FrameContainer (which crashes getSize() during paint).
    local indicator = LineWidget:new{
        dimen = Geom:new{ w = tab_w, h = INDIC_H },
        background = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
    }

    local icon = IconWidget:new{
        icon = tab.icon,
        dim = not is_active,
        width = ICON_SZ,
        height = ICON_SZ,
    }

    local label = TextWidget:new{
        text = tab.label,
        face = Font:getFace("cfont", LABEL_FS),
        fgcolor = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }

    local content = VerticalGroup:new{
        align = "center",
        indicator,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        icon,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        label,
    }

    local cell = CenterContainer:new{
        dimen = Geom:new{ w = tab_w, h = BAR_H },
        content,
    }

    return TabCell:new{ callback = on_tap, cell }
end

-- Builds the bottom nav. `active_id` is "home" or "library". `on_switch`
-- is called with the tapped tab's id whenever a NON-active tab is tapped
-- (tapping the already-active tab is a no-op, so pages don't needlessly
-- close and reopen themselves).
function BottomNav.build(active_id, on_switch)
    local screen_w = Screen:getWidth()
    local tab_w = math.floor(screen_w / #TABS)

    local row = HorizontalGroup:new{}
    for _, tab in ipairs(TABS) do
        local is_active = tab.id == active_id
        local cell = buildTabCell(tab, is_active, tab_w, function()
            if tab.id ~= active_id and on_switch then
                on_switch(tab.id)
            end
        end)
        table.insert(row, cell)
    end

    local top_rule = LineWidget:new{
        dimen = Geom:new{ w = screen_w, h = Size.line.thin },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }

    return VerticalGroup:new{
        align = "left",
        top_rule,
        FrameContainer:new{
            width = screen_w,
            height = BAR_H,
            bordersize = 0, margin = 0, padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            row,
        },
    }
end

return BottomNav