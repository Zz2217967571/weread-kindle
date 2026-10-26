-- 登录页，和官方墨水屏版一致（ref/official/01-login.png、02-login-qr.png）：
-- logo，“使用微信扫描二维码登录”，灰色占位二维码上一个“获取二维码”按钮，底下“已阅读并同意 用户协议 & 隐私政策”。
-- 勾选同意后点按钮才拉二维码；扫码后标题换成“扫描成功，请在手机上确认登录”；过期显示“二维码已过期 / 重新加载”。
local Device = require("device")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local Quit = require("weread/quit")
local Theme = require("weread/theme")

local T = Canvas.text

local QR_FILE = "/tmp/weread_login_qr.png"
local QR_X, QR_Y, QR_SIZE = 408, 652, 448
local BUTTON = { x = 504, y = 839, w = 256, h = 75 }
local AGREE = { x = 424, y = 1200, w = 416, h = 44 }

local LoginView = InputContainer:extend{
    on_done = nil,
}

function LoginView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.agreed = false
    -- idle：等用户点“获取二维码”；loading；qr；scanned；retry（过期或失败，按钮变“重新加载”）
    self.state = "idle"
    self.title = "使用微信扫描二维码登录"
    self.qr = nil
    self.qr_widget = nil
    self.canvas = Canvas:new{ ops = {} }
    self[1] = self.canvas
    self:registerTouchZones({
        {
            id = "login_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onTap(ges.pos) end,
        },
        {
            id = "login_swipe",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return Quit.handleSwipe(ges) end,
        },
    })
    self:render()
end

function LoginView:render()
    local ops = {
        { "rect", 0, 0, self.dimen.w, self.dimen.h, Theme.WHITE },
        { "image", 470, 405, Theme.res("login_logo.png"), 330, 85 },
        T(632, 571, self.title, Theme.BOLD, 30, nil, nil, "center"),
    }
    if (self.state == "qr" or self.state == "scanned") and self.qr_widget then
        table.insert(ops, { "widget", QR_X, QR_Y, self.qr_widget })
    else
        table.insert(ops, { "image", QR_X, QR_Y, Theme.res("login_qr_placeholder.png"), QR_SIZE, QR_SIZE })
        if self.state ~= "loading" then
            local label = self.state == "retry" and "重新加载" or "获取二维码"
            table.insert(ops, { "rect", BUTTON.x, BUTTON.y, BUTTON.w, BUTTON.h, Theme.WHITE })
            table.insert(ops, { "frame", BUTTON.x, BUTTON.y, BUTTON.w, BUTTON.h, 2, Theme.BLACK, 16 })
            table.insert(ops, T(632, 862, label, Theme.BOLD, 28, nil, nil, "center"))
        end
    end
    table.insert(ops, { "image", AGREE.x, AGREE.y, Theme.res(self.agreed and "login_agree_on.png" or "login_agree.png"), AGREE.w, AGREE.h })
    self.canvas:setOps(ops)
    UIManager:setDirty(self, "ui")
end

-- 微信给的二维码图片四周有白边，官方是二维码贴满 448×448。裁掉白边再缩放
local function qrWidget(png_file)
    local bb = RenderImage:renderImageFile(png_file, false)
    if not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    local x0, y0, x1, y1 = w, h, -1, -1
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if bb:getPixel(x, y):getColor8().a < 128 then
                if x < x0 then x0 = x end
                if x > x1 then x1 = x end
                if y < y0 then y0 = y end
                if y > y1 then y1 = y end
            end
        end
    end
    if x1 < 0 then return nil end
    local cropped = bb:viewport(x0, y0, x1 - x0 + 1, y1 - y0 + 1):copy()
    bb:free()
    local scaled = RenderImage:scaleBlitBuffer(cropped, QR_SIZE, QR_SIZE)
    return ImageWidget:new{ image = scaled, width = QR_SIZE, height = QR_SIZE }
end

function LoginView:fetchQrcode()
    self.state = "loading"
    self.title = "使用微信扫描二维码登录"
    self:render()
    UIManager:forceRePaint()
    local qr, err = Direct.loginQrcode()
    if not qr then
        self.state, self.title = "retry", "二维码加载失败"
        self:render()
        if err then UIManager:show(InfoMessage:new{ text = err, timeout = 2 }) end
        return
    end
    local f = io.open(QR_FILE, "wb")
    f:write(qr.png)
    f:close()
    self.qr_widget = qrWidget(QR_FILE)
    os.remove(QR_FILE)
    self.qr = qr
    self.state = "qr"
    self:render()
    self.poll_gen = (self.poll_gen or 0) + 1
    local gen = self.poll_gen
    UIManager:scheduleIn(0.5, function() self:poll(gen) end)
end

-- Direct.loginPoll 每次最多阻塞十来秒，所以每轮之间留一点空隙让界面处理点按
function LoginView:poll(gen)
    if gen ~= self.poll_gen or self.closed then return end
    local state, err = Direct.loginPoll(self.qr)
    if gen ~= self.poll_gen or self.closed then return end
    if state == "done" then
        self.closed = true
        UIManager:close(self)
        if self.on_done then self.on_done() end
        return
    elseif state == "scanned" then
        if self.state ~= "scanned" then
            self.state, self.title = "scanned", "扫描成功，请在手机上确认登录"
            self:render()
        end
    elseif state == "expired" then
        self.state, self.title = "retry", "二维码已过期"
        self:render()
        return
    elseif not state then
        self.state, self.title = "retry", "登录失败，请重试"
        self:render()
        if err then UIManager:show(InfoMessage:new{ text = err, timeout = 2 }) end
        return
    end
    UIManager:scheduleIn(0.2, function() self:poll(gen) end)
end

local function inside(pos, r)
    return pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function LoginView:onTap(pos)
    if inside(pos, { x = AGREE.x, y = AGREE.y - 10, w = 190, h = AGREE.h + 20 }) then
        self.agreed = not self.agreed
        self:render()
    elseif (self.state == "idle" or self.state == "retry") and inside(pos, BUTTON) then
        if not self.agreed then
            UIManager:show(InfoMessage:new{ text = "请先阅读并同意用户协议和隐私政策", timeout = 2 })
        else
            UIManager:nextTick(function() self:fetchQrcode() end)
        end
    end
    return true
end

function LoginView:onCloseWidget()
    self.closed = true
end

return LoginView
