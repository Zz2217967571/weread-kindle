-- “我”，按官方墨水屏版（ref/official/30-me.png）：衬线大字的用户名，累计阅读 / 本周阅读，
-- 下面五行：账户、微信文章、微信读书阅读器、设置、版本更新，每行左边圆形图标、右边箭头。
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

local ROW_TOP, ROW_H = 260, 180     -- 内容坐标：第一行顶部（官方屏幕 y=305）、行高

local MeView = PagedView:extend{
    tab = "me",
    viewport_top = 45,
    on_row = nil,      -- function(id)
}

function MeView:load()
    require("weread/async").swr("me", function()
        return { profile = Direct.profile() or false, card = Direct.memberCard() or false, balance = Direct.balance() or false }
    end, function(res)
        if self.closed or not res then return end
        self.profile, self.card, self.balance = res.profile or nil, res.card or nil, res.balance or nil
        self:refresh(true)
    end)
end

local function hm(secs)
    secs = secs or 0
    return math.floor(secs / 3600), math.floor(secs % 3600 / 60)
end

-- 一行里大小字混排（“累计阅读 48 小时 11 分钟”），按基线对齐
local function mixed(ops, x, baseline, segs)
    for _, s in ipairs(segs) do
        local text, weight, px = s[1], s[2], s[3]
        table.insert(ops, T(x, baseline - math.floor(0.86 * px + 0.5), text, weight, px))
        x = x + Canvas.textWidth(text, weight, px)
    end
end

function MeView:cardText()
    local c = self.card
    if not c or not c.remainTime then return nil end
    local days = math.ceil(c.remainTime / 86400)
    local kind = (c.payingRemainTime or 0) > 0 and "付费卡" or "体验卡"
    if c.expired == 1 or days <= 0 then return "会员卡已过期" end
    return string.format("%s · 还剩 %d 天", kind, days)
end

function MeView:rows()
    local coins = string.format("书币 %.2f", self.balance and self.balance.balance or 0)
    local card = self:cardText()
    return {
        { id = "account", icon = "me_account.png", title = "账户", sub = card and (coins .. "  |  " .. card) or coins },
        { id = "articles", icon = "me_article.png", title = "微信文章", sub = "微信文章收藏  |  微信浮窗文章" },
        { id = "device", icon = "me_device.png", title = "微信读书阅读器", sub = "为微信读书量身定制的墨水屏" },
        { id = "settings", icon = "me_settings.png", title = "设置", sub = "点击左侧翻到下一页  |  关闭个性化推荐 等" },
        { id = "update", icon = "me_update.png", title = "版本更新", sub = "已是最新版本" },
    }
end

function MeView:buildContent()
    local ops = {}
    local p = self.profile or {}
    table.insert(ops, T(38, 47, p.name or "", Theme.SERIF, 60, nil, 1188))
    local th, tm = hm(p.totalReadingTime)
    mixed(ops, 38, 160, {
        { "累计阅读 ", Theme.BOLD, 28 }, { tostring(th), Theme.BOLD, 46 }, { " 小时 ", Theme.BOLD, 28 },
        { tostring(tm), Theme.BOLD, 46 }, { " 分钟", Theme.BOLD, 28 },
    })
    local wh, wm = hm(p.rankWeek == 1 and p.currentReadingTime or 0)
    table.insert(ops, T(38, 183, string.format("本周阅读 %d 小时 %d 分钟", wh, wm), Theme.REGULAR, 28))
    table.insert(ops, { "hline", 38, ROW_TOP - 2, 1188, 2, Theme.LINE_GRAY })
    for i, r in ipairs(self:rows()) do
        local y = ROW_TOP + (i - 1) * ROW_H
        table.insert(ops, { "image", 37, y + 57, Theme.res(r.icon), 70, 70 })
        table.insert(ops, T(137, y + 54, r.title, Theme.BOLD, 32))
        table.insert(ops, T(137, y + 105, r.sub, Theme.REGULAR, 25, nil, 1040))
        table.insert(ops, { "image", 1198, y + 73, Theme.res("me_chevron.png"), 32, 38 })
        table.insert(ops, { "hline", 38, y + ROW_H - 2, 1188, 2, Theme.LINE_GRAY })
    end
    return { ops = ops, height = ROW_TOP + 5 * ROW_H + 40 }
end

function MeView:onTapContent(x, y)
    if y < ROW_TOP then return end
    local i = math.floor((y - ROW_TOP) / ROW_H) + 1
    local r = self:rows()[i]
    if not r then return end
    if r.id == "device" then
        UIManager:show(InfoMessage:new{ text = "你正在用 Kindle 读微信读书", timeout = 2 })
    elseif r.id == "update" then
        UIManager:show(InfoMessage:new{ text = "已是最新版本", timeout = 1 })
    elseif self.on_row then
        self.on_row(r.id)
    end
end

return MeView
