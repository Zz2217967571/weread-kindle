-- 退出 App：从屏幕顶边往下滑时弹出确认。官方设备有实体 Home 键，Kindle 没有，界面上又不加按钮，就用这个手势。
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")

local Quit = {}

-- 起点离顶边多近算“从顶边下滑”
Quit.EDGE = 120

function Quit.confirm()
    UIManager:show(ConfirmBox:new{
        text = "退出微信读书？",
        ok_text = "退出",
        ok_callback = function() UIManager:quit() end,
    })
    return true
end

-- 手势处理里先调它：是从顶边下滑就弹确认并返回 true
function Quit.handleSwipe(ges)
    if ges.direction == "south" and ges.pos.y < Quit.EDGE then return Quit.confirm() end
end

return Quit
