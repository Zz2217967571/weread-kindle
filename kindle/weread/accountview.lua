-- 账户，按官方墨水屏版（ref/official/32-account.png）：两张卡片并排，左边书币余额，右边会员卡剩余天数。
-- 充值、购买会员卡要付款，Kindle 上不做，提示去手机上操作。
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local Canvas = require("weread/canvas")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

local CARDS = { { x = 38, w = 574 }, { x = 652, w = 574 } }
local CARD_Y, CARD_H, BAR_H = 105, 450, 90

local AccountView = PagedView:extend{
    tab = "back",
    viewport_top = 45,
    balance = nil,
    card = nil,
}

function AccountView:buildContent()
    local ops = { T(632, 33, "账户", Theme.BOLD, 34, nil, nil, "center") }
    local coins = self.balance and self.balance.balance or 0
    local c = self.card or {}
    local days = c.remainTime and math.max(0, math.ceil(c.remainTime / 86400)) or 0
    local kind = (c.payingRemainTime or 0) > 0 and "付费卡" or "体验卡"
    local expire = c.expiredTime and os.date("%m/%d到期", c.expiredTime):gsub("^0", ""):gsub("/0", "/") or ""
    local cards = {
        { label = "书币余额", big = tostring(math.floor(coins)), small = string.format(".%02d", math.floor(coins * 100 + 0.5) % 100),
          note = "书币与 Android 版互通", button = "充值书币" },
        { label = kind, big = tostring(days), small = "天", note = expire, button = "购买会员卡" },
    }
    for i, card in ipairs(cards) do
        local x, w = CARDS[i].x, CARDS[i].w
        table.insert(ops, { "frame", x, CARD_Y, w, CARD_H, 2, Theme.BLACK })
        table.insert(ops, T(x + 44, CARD_Y + 45, card.label, Theme.BOLD, 30))
        table.insert(ops, T(x + 44, CARD_Y + 110, card.big, Theme.SERIF, 100))
        local bw = Canvas.textWidth(card.big, Theme.SERIF, 100)
        table.insert(ops, T(x + 48 + bw, CARD_Y + 172, card.small, Theme.SERIF, 40))
        table.insert(ops, T(x + 44, CARD_Y + 285, card.note, Theme.REGULAR, 24, nil, w - 80))
        table.insert(ops, { "rect", x, CARD_Y + CARD_H - BAR_H, w, BAR_H, Theme.BLACK })
        table.insert(ops, T(x + 44, CARD_Y + CARD_H - BAR_H + 30, card.button, Theme.BOLD, 30, Theme.WHITE))
        table.insert(ops, T(x + w - 44, CARD_Y + CARD_H - BAR_H + 26, "→", Theme.BOLD, 34, Theme.WHITE, nil, "right"))
    end
    return { ops = ops, height = CARD_Y + CARD_H + 60 }
end

function AccountView:onTapContent(x, y)
    if y >= CARD_Y + CARD_H - BAR_H and y < CARD_Y + CARD_H then
        UIManager:show(InfoMessage:new{ text = "付款需要在手机微信读书里完成", timeout = 2 })
    end
end

return AccountView
