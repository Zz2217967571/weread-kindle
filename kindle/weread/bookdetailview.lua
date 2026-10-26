-- 书籍详情：封面、书名、作者、推荐值、阅读人数 / 字数 / 是否会员可读，简介；“开始阅读”“加入书架”。
-- （官方墨水屏版的详情是一个预览阅读器：首页是这些信息，左滑看简介再接正文，之后再按官方细调）
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local Items = require("weread/bookitems")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

local BUTTONS_Y = 980

local BookDetailView = PagedView:extend{
    tab = "back",
    viewport_top = 45,
    book = nil,          -- 至少有 bookId、title、cover
    on_read = nil,       -- function(book)：开始阅读
}

function BookDetailView:load()
    local info = Direct.bookInfo(self.book.bookId)
    if info then
        for k, v in pairs(info) do self.book[k] = v end
    end
    self:refresh(true)
    self:fetchCovers({ self.book })
end

local function wan(n)
    if not n then return nil end
    if n >= 10000 then return string.format("%.1f万", n / 10000) end
    return tostring(math.floor(n))
end

function BookDetailView:buildContent()
    local b = self.book
    local ops = {}
    Items.cover(ops, b, 502, 40, 260, 376)
    table.insert(ops, T(632, 460, b.title or "", Theme.SERIF, 44, nil, 1100, "center"))
    table.insert(ops, T(632, 530, b.author or "", Theme.BOLD, 28, Theme.HINT_GRAY, 1100, "center"))
    local rating = Items.ratingText(b)
    if rating then
        table.insert(ops, T(632, 600, rating, Theme.BOLD, 30, nil, 1100, "center"))
    end
    -- 三栏：阅读人数、会员卡可读、字数
    local cols = {
        { big = wan(b.readingCount) or "—", small = "阅读" },
        { big = b.free == 1 and "免费" or "会员卡", small = "可读" },
        { big = wan(b.totalWords) or "—", small = "字数" },
    }
    for i, c in ipairs(cols) do
        local cx = 210 + (i - 1) * 422
        table.insert(ops, T(cx, 680, c.big, Theme.BOLD, 36, nil, nil, "center"))
        table.insert(ops, T(cx, 734, c.small, Theme.REGULAR, 24, nil, nil, "center"))
    end
    table.insert(ops, { "hline", 38, 800, 1188, 2, Theme.LINE_GRAY })
    -- 简介
    if b.intro and b.intro ~= "" then
        table.insert(ops, (Canvas.textBox(38, 830, 1188, b.intro, Theme.REGULAR, 28, nil, 4)))
    end
    -- 按钮
    table.insert(ops, { "rect", 38, BUTTONS_Y + 70, 579, 80, Theme.BLACK })
    table.insert(ops, T(327, BUTTONS_Y + 92, "开始阅读", Theme.BOLD, 32, Theme.WHITE, nil, "center"))
    table.insert(ops, { "frame", 647, BUTTONS_Y + 70, 579, 80, 2, Theme.BLACK, 12 })
    table.insert(ops, T(936, BUTTONS_Y + 92, self.added and "已在书架" or "加入书架", Theme.BOLD, 32, nil, nil, "center"))
    return { ops = ops, height = BUTTONS_Y + 200 }
end

function BookDetailView:onTapContent(x, y)
    if y >= BUTTONS_Y + 70 and y < BUTTONS_Y + 150 then
        if x < 632 then
            if self.on_read then self.on_read(self.book) end
        elseif not self.added then
            local ok = Direct.addToShelf(self.book.bookId)
            self.added = ok ~= nil
            UIManager:show(InfoMessage:new{ text = ok and "已加入书架" or "加入书架失败", timeout = 1 })
            self:refresh(true)
        end
    end
end

return BookDetailView
