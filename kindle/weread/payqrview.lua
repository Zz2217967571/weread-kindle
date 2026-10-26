-- 付款二维码页：墨水屏设备上不直接付款，和官方一样显示一个二维码，用手机微信扫码后在网页里付款
-- （开通会员卡、充值书币）。付完点“已完成支付”，调用方重新加载章节。
local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local Canvas = require("weread/canvas")
local Theme = require("weread/theme")

local T = Canvas.text

local QR_SIZE = 520
local BUTTON_Y, BUTTON_H = 1300, 90

local PayQrView = InputContainer:extend{
    title = "",
    hint = "",
    url = "",
    on_paid = nil,
}

function PayQrView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    local qr = QRWidget:new{ text = self.url, width = QR_SIZE, height = QR_SIZE }
    local qx = math.floor((self.dimen.w - QR_SIZE) / 2)
    self[1] = Canvas:new{ ops = {
        { "rect", 0, 0, self.dimen.w, self.dimen.h, Theme.WHITE },
        T(632, 240, self.title, Theme.BOLD, 40, nil, nil, "center"),
        T(632, 310, self.hint, Theme.REGULAR, 28, Theme.HINT_GRAY, 1100, "center"),
        { "widget", qx, 420, qr },
        T(632, 1000, "使用微信扫一扫，在手机上完成支付", Theme.BOLD, 28, nil, nil, "center"),
        { "rect", 45, BUTTON_Y, 1174, BUTTON_H, Theme.BLACK },
        T(632, BUTTON_Y + 30, "已完成支付", Theme.BOLD, 32, Theme.WHITE, nil, "center"),
        { "frame", 45, BUTTON_Y + 130, 1174, BUTTON_H, 3, Theme.LINE_GRAY, 20 },
        T(632, BUTTON_Y + 160, "关闭", Theme.BOLD, 32, nil, nil, "center"),
    } }
    self:registerTouchZones({{
        id = "payqr_tap", ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        handler = function(ges) return self:onTap(ges.pos) end,
    }})
end

function PayQrView:onTap(pos)
    if pos.y >= BUTTON_Y and pos.y < BUTTON_Y + BUTTON_H then
        UIManager:close(self, "full")
        if self.on_paid then self.on_paid() end
    elseif pos.y >= BUTTON_Y + 130 and pos.y < BUTTON_Y + 130 + BUTTON_H then
        UIManager:close(self, "full")
    end
    return true
end

return PayQrView
