-- widgets/header.lua
-- Reusable status header for every Ananya page: clock on the left,
-- Wi-Fi status + battery % on the right, and an optional small close (x)
-- button at the far right.
--
-- NOTE ON SCOPE: SimpleUI's top bar (screens/sui_topbar.lua) is a fully
-- configurable status bar because SimpleUI *replaces* the device's home
-- screen. Ananya is a plugin launched from Tools, not a home-screen
-- replacement, so it still needs an explicit way to exit back to the file
-- browser/reader — hence the optional close button, which has no SimpleUI
-- equivalent. Everything else (clock/wifi/battery, snapshot-not-live) is
-- unchanged from before.
--
-- Usage from any page:
--     local Header = require("widgets/header")
--     local page = VerticalGroup:new{
--         Header.build{ on_close = function() self:onClose() end },
--         ... rest of the page ...
--     }

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Font = require("ui/font")
local Size = require("ui/size")
local logger = require("logger")
local Screen = Device.screen
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local datetime = require("datetime")

local Header = {}

-- Overall bar height and text size — tweak these two to resize everything.
local BAR_H = Screen:scaleBySize(36)
local FONT_SIZE = 16

-- Total height including the bottom divider line. Pages should subtract
-- this from their own available content height.
Header.HEIGHT = BAR_H + Size.line.thin

-- --------------------------------------------------------------------------
-- Close button.
--
-- NOTE: an earlier version tried to avoid interfering with the Kindle's
-- swipe-down gesture by using InputContainer:registerTouchZones to claim
-- only "hold" (not "tap") over this corner, the same technique SimpleUI
-- uses for its own top bar. That stopped this button from stealing your
-- swipe, but it did NOT restore the actual thing you wanted — KOReader's
-- native Tools/Search menu on swipe-down. That menu is implemented inside
-- the File Manager and Reader screens themselves; Ananya is a separate
-- custom screen that never had that behavior, with or without this
-- button. Reproducing it would mean building Ananya on top of FileManager
-- itself rather than as its own screen — a much bigger change than a
-- button tweak. So this reverts to a plain, reliable tap-to-close button.
-- --------------------------------------------------------------------------

-- --------------------------------------------------------------------------
-- Small custom battery glyph (outline + fill level + nub), built from plain
-- rectangles so it doesn't depend on any icon font being present.
-- --------------------------------------------------------------------------
local function buildBatteryIcon(percent)
    local batt_w = Screen:scaleBySize(22)
    local batt_h = Screen:scaleBySize(12)
    local nub_w = Screen:scaleBySize(2)
    local nub_h = Screen:scaleBySize(6)
    local border = Screen:scaleBySize(2)

    local inner_w = batt_w - 2 * border
    local fill_w = math.max(0, math.floor(inner_w * (percent / 100)))

    -- NOTE: a solid-color rectangle with no child widget must be a
    -- LineWidget, not a childless FrameContainer — FrameContainer:getSize()
    -- crashes ("attempt to index a nil value") when it has no child,
    -- because it unconditionally sizes itself from self[1]. This was the
    -- actual crash: it only surfaced during paint, not during build, so
    -- the pcall around buildUI() never caught it.
    local fill = LineWidget:new{
        dimen = Geom:new{ w = fill_w, h = batt_h - 2 * border },
        background = Blitbuffer.COLOR_BLACK,
    }

    local outline = FrameContainer:new{
        width = batt_w,
        height = batt_h,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        margin = 0,
        padding = 0,
        radius = 0,
        fill,
    }

    local nub_line = LineWidget:new{
        dimen = Geom:new{ w = nub_w, h = nub_h },
        background = Blitbuffer.COLOR_BLACK,
    }
    local nub = CenterContainer:new{
        dimen = Geom:new{ w = nub_w + Screen:scaleBySize(2), h = batt_h },
        nub_line,
    }

    return HorizontalGroup:new{ outline, nub }
end

-- --------------------------------------------------------------------------
-- Data readers — each wrapped so a device lacking the capability (no wifi
-- toggle, no battery) just quietly omits that piece instead of erroring.
-- --------------------------------------------------------------------------
local function getClockText()
    local twelve_hour = G_reader_settings and G_reader_settings:isTrue("twelve_hour_clock")
    return datetime.secondsToHour(os.time(), twelve_hour)
end

local function getWifiIcon()
    if not Device:hasWifiToggle() then
        return nil
    end
    local NetworkMgr = require("ui/network/manager")
    local ok, wifi_on = pcall(function() return NetworkMgr:isWifiOn() end)
    if not ok then
        return nil
    end
    return IconWidget:new{
        icon = wifi_on and "wifi.open.100" or "wifi",
        width = Screen:scaleBySize(FONT_SIZE),
        height = Screen:scaleBySize(FONT_SIZE),
    }
end

local function getBatteryCapacity()
    if not Device:hasBattery() then
        return nil
    end
    local ok, capacity = pcall(function()
        return Device:getPowerDevice():getCapacity()
    end)
    if not ok or type(capacity) ~= "number" then
        return nil
    end
    return capacity
end

-- --------------------------------------------------------------------------
-- Real builder
-- --------------------------------------------------------------------------
function Header._buildInner(opts)
    opts = opts or {}
    local screen_w = Screen:getWidth()
    local face = Font:getFace("cfont", FONT_SIZE)

    local clock = TextWidget:new{ text = getClockText(), face = face }

    local right_items = {}
    local wifi_icon = getWifiIcon()
    if wifi_icon then
        table.insert(right_items, wifi_icon)
        table.insert(right_items, HorizontalSpan:new{ width = Screen:scaleBySize(10) })
    end

    local capacity = getBatteryCapacity()
    if capacity then
        table.insert(right_items, buildBatteryIcon(capacity))
        table.insert(right_items, HorizontalSpan:new{ width = Screen:scaleBySize(4) })
        table.insert(right_items, TextWidget:new{ text = capacity .. "%", face = face })
    end

    if opts.on_close then
        table.insert(right_items, HorizontalSpan:new{ width = Screen:scaleBySize(14) })
        table.insert(right_items, Button:new{
            text = "\u{2715}", -- ✕
            callback = opts.on_close,
            bordersize = 0,
            margin = 0,
            padding = 0,
            text_font_size = FONT_SIZE + 2,
            text_font_bold = true,
        })
    end

    local right_group = HorizontalGroup:new(right_items)

    local inner_w = screen_w - Screen:scaleBySize(24)
    local row = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = BAR_H },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = BAR_H }, clock },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = BAR_H }, right_group },
    }

    local bottom_rule = LineWidget:new{
        dimen = Geom:new{ w = screen_w, h = Size.line.thin },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }

    return VerticalGroup:new{
        FrameContainer:new{
            width = screen_w,
            height = BAR_H,
            bordersize = 0,
            margin = 0,
            padding = 0,
            padding_left = Screen:scaleBySize(12),
            padding_right = Screen:scaleBySize(12),
            background = Blitbuffer.COLOR_WHITE,
            row,
        },
        bottom_rule,
    }
end

-- --------------------------------------------------------------------------
-- Plain-text fallback: no IconWidget/SVG, no nested battery-fill geometry,
-- but STILL includes the close button if requested, since that one is
-- essential (not decorative) and shouldn't be lost on fallback.
-- --------------------------------------------------------------------------
function Header._buildFallback(opts)
    opts = opts or {}
    local screen_w = Screen:getWidth()
    local face = Font:getFace("cfont", FONT_SIZE)

    local clock = TextWidget:new{ text = getClockText(), face = face }

    local right_items = {}
    local ok_batt, capacity = pcall(getBatteryCapacity)
    if ok_batt and capacity then
        table.insert(right_items, TextWidget:new{ text = capacity .. "%", face = face })
    end
    if opts.on_close then
        table.insert(right_items, HorizontalSpan:new{ width = Screen:scaleBySize(14) })
        table.insert(right_items, Button:new{
            text = "\u{2715}",
            callback = opts.on_close,
            bordersize = 0, margin = 0, padding = 0,
            text_font_size = FONT_SIZE + 2, text_font_bold = true,
        })
    end
    local right_group = HorizontalGroup:new(right_items)

    local inner_w = screen_w - Screen:scaleBySize(24)
    local row = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = BAR_H },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = BAR_H }, clock },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = BAR_H }, right_group },
    }

    return VerticalGroup:new{
        FrameContainer:new{
            width = screen_w,
            height = BAR_H,
            bordersize = 0, margin = 0, padding = 0,
            padding_left = Screen:scaleBySize(12),
            padding_right = Screen:scaleBySize(12),
            background = Blitbuffer.COLOR_WHITE,
            row,
        },
        LineWidget:new{
            dimen = Geom:new{ w = screen_w, h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
    }
end

-- --------------------------------------------------------------------------
-- Public: build the header widget. opts = { on_close = function() ... end }
-- Wrapped in pcall so a build failure degrades to plain text (and, as a
-- last resort, an empty spacer) instead of crashing the page.
-- --------------------------------------------------------------------------
function Header.build(opts)
    local ok, widget_or_err = pcall(Header._buildInner, opts)
    if ok then
        return widget_or_err
    end
    logger.warn("Ananya header: build failed, using fallback ->", tostring(widget_or_err))
    local ok2, fallback_or_err = pcall(Header._buildFallback, opts)
    if ok2 then
        return fallback_or_err
    end
    logger.warn("Ananya header: fallback ALSO failed ->", tostring(fallback_or_err))
    return VerticalGroup:new{}
end

return Header