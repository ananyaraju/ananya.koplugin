-- helloworld.lua - ananya
-- testing out whether my plugin can work on my jailbroken kindle

-- get WidgetContainer class from KOReader
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- specialized WidgetContainer
local AnanyaUI = WidgetContainer:extend{
    name = "ananyaUI",
}

-- initialize the plugin
function AnanyaUI:init()
    self.ui.menu:registerToMainMenu(self)
end

-- hook expected by KOReader menu system
function AnanyaUI:addToMainMenu(menu_items)
    menu_items.ananyaUI = {
        text = "Ananya UI",
        description = "Hello World to check init of AnanyaUI",
        -- what happens when menu item is selected
        callback = function()
            local UIManager = require("ui/uimanager")
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = "Hello Ananya" })
            print("Hello Ananya!")
        end,
    }
end

return AnanyaUI