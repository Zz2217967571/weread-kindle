-- 书架“导入”：和官方墨水屏版一样只是一页说明（官方 ImportGuideDialog），教你从手机 App 或电脑浏览器把书传过来。
-- 整屏白底，中间一个黑框圆角的内容区：“从手机中导入”+ 步骤 + 示意图，“从电脑中导入”+ 步骤 + 示意图，
-- 下面一个圆形的关闭按钮。尺寸取自源码（dp × 1.875）。
local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local Canvas = require("weread/canvas")
local Theme = require("weread/theme")

local T = Canvas.text

-- 内容框：左右各 69dp、上 60dp、黑色 1dp 边、圆角 16dp、内边距 20dp
local BOX = { x = 129, y = 112, w = 1006, h = 1324, r = 30 }
local PAD = 38
local CLOSE = { size = 105, bottom = 79 }
local TITLE_PX, TEXT_PX = 36, 26
local PIC_W, PIC_H = 926, 453

local ImportGuideView = InputContainer:extend{ on_close = nil }

-- 一行里粗体、常规混排：segments = { {文字, 是否粗体}, … }，从 x 开始依次排
local function line(ops, x, ink_top, segments)
    for _, seg in ipairs(segments) do
        local weight = seg[2] and Theme.BOLD or Theme.REGULAR
        table.insert(ops, T(x, ink_top, seg[1], weight, TEXT_PX))
        x = x + Canvas.textWidth(seg[1], weight, TEXT_PX)
    end
end

function ImportGuideView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    local ops = {
        { "rect", 0, 0, self.dimen.w, self.dimen.h, Theme.WHITE },
        { "frame", BOX.x, BOX.y, BOX.w, BOX.h, 2, Theme.BLACK, BOX.r },
    }
    local x0 = BOX.x + 2 + PAD
    local y = BOX.y + 2 + PAD
    -- 从手机中导入
    table.insert(ops, T(x0, y, "从手机中导入", Theme.BOLD, TITLE_PX))
    y = y + TITLE_PX + 22
    line(ops, x0, y, { { "打开手机版微信读书 App  →  " }, { "【书架】", true }, { "  →  " }, { "【导入】", true } })
    y = y + TEXT_PX + 30
    table.insert(ops, { "image", x0, y, Theme.res("import_guide_phone.png"), PIC_W, PIC_H })
    y = y + PIC_H + 43
    -- 从电脑中导入
    table.insert(ops, T(x0, y, "从电脑中导入", Theme.BOLD, TITLE_PX))
    y = y + TITLE_PX + 22
    line(ops, x0, y, { { "在电脑浏览器中打开网址" }, { "【r.qq.com】", true }, { "  →  " }, { "【传书到手机】", true } })
    y = y + TEXT_PX + 30
    table.insert(ops, { "image", x0, y, Theme.res("import_guide_imac.png"), PIC_W, PIC_H })
    -- 关闭按钮：圆形，水平居中，离屏幕底边 42dp
    self.close_rect = { x = math.floor((self.dimen.w - CLOSE.size) / 2), y = self.dimen.h - CLOSE.bottom - CLOSE.size,
        w = CLOSE.size, h = CLOSE.size }
    local c = self.close_rect
    table.insert(ops, { "image", c.x, c.y, Theme.res("icon_general_cancel_button.svg"), c.w, c.h })
    self[1] = Canvas:new{ ops = ops }
    self:registerTouchZones({{
        id = "import_guide_tap", ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        handler = function(ges) return self:onTap(ges.pos) end,
    }})
end

function ImportGuideView:onTap(pos)
    local c = self.close_rect
    -- 圆形按钮点得宽松一些
    if pos.x >= c.x - 30 and pos.x < c.x + c.w + 30 and pos.y >= c.y - 30 and pos.y < c.y + c.h + 30 then
        UIManager:close(self, "full")
        if self.on_close then self.on_close() end
    end
    return true
end

return ImportGuideView
