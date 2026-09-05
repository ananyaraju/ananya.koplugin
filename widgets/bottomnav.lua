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
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Screen = Device.screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")

local BottomNav = {}

-- Finds this plugin's own installation directory on disk, so custom tab
-- icon PNGs (under icons/) can be located by absolute path. Same
-- debug.getinfo-based pattern as pages/home.lua's getPluginRoot (see
-- there for the full explanation) — duplicated here rather than shared,
-- since it's a handful of lines and pulling in a whole shared module for
-- it isn't worth the indirection.
local function getPluginRoot()
    local src_info = debug.getinfo(1, "S").source or ""
    if src_info:sub(1, 1) ~= "@" then
        return nil
    end
    local this_dir = src_info:sub(2):match("^(.*)/[^/]+$") -- .../ananya.koplugin/widgets
    if not this_dir then
        return nil
    end
    local plugin_root = this_dir:match("^(.*)/[^/]+$") -- strip "/widgets"
    if not plugin_root then
        return nil
    end
    if plugin_root:sub(1, 1) ~= "/" then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        local cwd = ok_lfs and lfs and lfs.currentdir()
        if cwd then
            plugin_root = cwd .. "/" .. plugin_root
        end
    end
    return plugin_root
end

-- Loads a small square custom icon PNG from icons/, sized to ICON_SZ.
-- `dim` (defined below, alongside ICON_SZ) darkens it for an inactive
-- tab — same `dim` field IconWidget itself uses, since it's actually
-- just a plain ImageWidget setting (confirmed in imagewidget.lua: dim
-- applies at paintTo() time regardless of subclass).
local function buildCustomIcon(icon_filename, size, dim)
    local ok, widget_or_err = pcall(function()
        local plugin_root = getPluginRoot()
        if not plugin_root then return nil end
        return ImageWidget:new{
            file = plugin_root .. "/icons/" .. icon_filename,
            width = size,
            height = size,
            alpha = true,
            dim = dim,
        }
    end)
    if ok and widget_or_err then
        return widget_or_err
    end
    logger.warn("Ananya: failed to load tab icon " .. tostring(icon_filename) .. " ->", tostring(widget_or_err))
    return nil
end

local BAR_H = Screen:scaleBySize(64)
local ICON_SZ = Screen:scaleBySize(26)
local INDIC_H = Screen:scaleBySize(3)
local LABEL_FS = 12

-- The three tabs this build supports, in display order: Library, Home,
-- New Page (Home in the middle, per request).
--
-- Library and Home use custom PNG icons (icon_file) with no label
-- underneath (show_label = false), per request. New Page is left as
-- before — built-in icon font glyph (icon) plus its label — since no
-- change was asked for there.
local TABS = {
    { id = "library", icon_file = "library.png", show_label = false },
    { id = "home",    icon_file = "home.png",    show_label = false },
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

    local icon
    if tab.icon_file then
        icon = buildCustomIcon(tab.icon_file, ICON_SZ, not is_active)
    end
    if not icon then
        -- Either a built-in icon was requested (tab.icon), or a custom
        -- one failed to load — IconWidget's built-in glyphs are also the
        -- safe fallback for a missing/corrupt custom PNG, so the tab
        -- never ends up with a blank gap where its icon should be.
        icon = IconWidget:new{
            icon = tab.icon or "appbar.menu",
            dim = not is_active,
            width = ICON_SZ,
            height = ICON_SZ,
        }
    end

    -- icon (+ label, if shown) as their own group, separate from the
    -- indicator — see below for why.
    local icon_group = VerticalGroup:new{ align = "center", icon }
    if tab.show_label ~= false then
        local label = TextWidget:new{
            text = tab.label,
            face = Font:getFace("cfont", LABEL_FS),
            fgcolor = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        table.insert(icon_group, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        table.insert(icon_group, label)
    end

    -- IMPORTANT: the indicator is pinned flush to the very top of the
    -- tab (height INDIC_H, no space above it), and icon_group is
    -- separately centered in whatever height remains below it — rather
    -- than putting indicator+icon+label all in one VerticalGroup and
    -- centering that whole block in the tab. That block approach is what
    -- caused the indicator to drift: removing the label (show_label =
    -- false) shortened the block's total height, and centering a
    -- shorter block in the same BAR_H box pushes its top edge (the
    -- indicator) further down than on a tab that still has its label —
    -- so Library/Home's indicator ended up visibly lower than New
    -- Page's, and lower than the top divider rule above the whole bar.
    -- Pinning the indicator's position independently of icon_group's
    -- height keeps it flush at the same spot on every tab regardless of
    -- whether that tab has a label.
    local icon_area = CenterContainer:new{
        dimen = Geom:new{ w = tab_w, h = BAR_H - INDIC_H },
        icon_group,
    }

    local content = VerticalGroup:new{
        align = "center",
        indicator,
        icon_area,
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