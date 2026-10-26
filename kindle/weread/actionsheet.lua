-- 底部确认菜单（官方 ActionSheetKt：QMUIBottomSheet，e-ink 版贴着屏幕底边，上面一圈调淡的遮罩）：
-- 一行标题、一个操作项（“移 出”“开 启”“关 闭”）、一个“取 消”。点遮罩不会关闭（官方 setCanceledOnTouchOutside(false)）。
local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local Canvas = require("weread/canvas")
local Theme = require("weread/theme")

local T = Canvas.text

local CANCEL_H = 142            -- bottom_sheet_cancel_height 76dp
local ITEM_H = 118
local TITLE_PX = 30
local PAD_X = 23                -- bottom_sheet_padding_horizontal 12dp
local MASK = 0.87

local ActionSheet = InputContainer:extend{
    title = "",
    item = "确 定",
    on_confirm = nil,
}

function ActionSheet:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.covers_fullscreen = false
    local inner = W - 2 * PAD_X
    local title_w = Canvas.textWidth(self.title, Theme.REGULAR, TITLE_PX)
    local title_op, lines
    if title_w <= inner then
        lines = 1
    else
        title_op, lines = Canvas.textBox(PAD_X, 0, inner, self.title, Theme.REGULAR, TITLE_PX, nil, 3)
    end
    local title_h = 56 + lines * 45
    local top = H - CANCEL_H - ITEM_H - title_h
    self.item_rect = { y = top + title_h, h = ITEM_H }
    self.cancel_rect = { y = H - CANCEL_H, h = CANCEL_H }
    local ops = {
        { "lighten", 0, 0, W, top, MASK },
        { "rect", 0, top, W, H - top, Theme.WHITE },
        { "hline", 0, top, W, 2, Theme.LINE_GRAY },
    }
    if title_op then
        title_op[3] = top + 28
        table.insert(ops, title_op)
    else
        table.insert(ops, T(W / 2, top + 28, self.title, Theme.REGULAR, TITLE_PX, nil, nil, "center"))
    end
    table.insert(ops, { "hline", 0, top + title_h, W, 1, Theme.LINE_GRAY })
    table.insert(ops, T(W / 2, top + title_h + 38, self.item, Theme.BOLD, 34, nil, nil, "center"))
    table.insert(ops, { "hline", 0, H - CANCEL_H, W, 1, Theme.LINE_GRAY })
    table.insert(ops, T(W / 2, H - CANCEL_H + 50, "取 消", Theme.BOLD, 34, nil, nil, "center"))
    self[1] = Canvas:new{ ops = ops }
    self:registerTouchZones({{
        id = "action_sheet_tap", ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        handler = function(ges) return self:onTap(ges.pos) end,
    }})
end

function ActionSheet:onTap(pos)
    if pos.y >= self.cancel_rect.y then
        UIManager:close(self, "ui")
    elseif pos.y >= self.item_rect.y and pos.y < self.item_rect.y + self.item_rect.h then
        UIManager:close(self, "ui")
        if self.on_confirm then self.on_confirm() end
    end
    return true
end

return ActionSheet
