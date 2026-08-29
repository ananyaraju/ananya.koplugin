-- main.lua — Ananya
-- Plugin entry point. Keeps this file tiny: all UI lives in pages/ and
-- widgets/.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Ananya = WidgetContainer:extend{
    name = "AnanyaUI",
    is_doc_only = false,
}

function Ananya:init()
    self.ui.menu:registerToMainMenu(self)
end

function Ananya:addToMainMenu(menu_items)
    menu_items.ananya_home = {
        text = _("AnanyaUI"),
        sorting_hint = "more_tools",
        callback = function()
            self:openHome()
        end,
    }
end

function Ananya:openHome()
    local ok, AnanyaHome_or_err = pcall(require, "pages/home")
    if not ok then
        local logger = require("logger")
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
