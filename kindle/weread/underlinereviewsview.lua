-- 点热门划线弹出的书友想法（官方 ReaderReviewListPopup + PopupReviewItemView，
-- 参照 ref/official/61-hot-underline-tap.png、62-hot-underline-p2.png）：
-- 浮在调淡的正文上；顶部是原文（最多两行）和“划线”按钮，下面一张张卡片：头像、名字、想法、点赞数、评论数；
-- 底部栏左边返回，右边“写想法”和翻页。整列一起翻页，翻到最后自动加载下一批。
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")

local Async = require("weread/async")
local BottomBar = require("weread/bottombar")
local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

-- 坐标取自 61-hot-underline-tap.xml（安卓模拟器和 Kindle 同为 1264×1680）
local L, W = 257, 750              -- 卡片左边、宽
local PAD = 37                      -- 卡片内边距
local QUOTE = { y = 58, h = 155, split = 865 }
local GAP = 20                      -- 卡片间距
local CONTENT_PX, CONTENT_PITCH = 36, 51
local WRITE_BTN = { x = 780, y = 1595, w = 191, h = 70 }
local DIM = 0.87                    -- 正文调淡：黑字变成约 221 的浅灰
local DIVIDER = Blitbuffer.Color8(229)

local UnderlineReviewsView = PagedView:extend{
    tab = "back",
    viewport_top = 0,
    book_id = nil,
    chapter_uid = nil,
    range = nil,
    quote = "",
    on_highlight = nil,     -- function()：点了“划线”
    on_write = nil,         -- function()：点了“写想法”
    under = nil,            -- 下面的阅读页（重画时一起重画）
}

function UnderlineReviewsView:init()
    PagedView.init(self)
    -- 不盖住整个屏幕：下面的阅读页先画，再在上面调淡
    self.covers_fullscreen = false
    self.items, self.total, self.has_more = {}, 0, true
end

function UnderlineReviewsView:load()
    if self.loading or not self.has_more then return end
    self.loading = true
    local book_id, chapter_uid, range, from = self.book_id, self.chapter_uid, self.range, #self.items
    -- 取想法列表和下载头像都在子进程里做，等界面画出来之后一次性补上，期间点翻页、返回都不卡
    Async.run(function()
        local res = Direct.underlineReviews(book_id, chapter_uid, range, 10, from)
        for _, it in ipairs(res.items) do
            if it.avatar then it.avatar_file = Direct.avatarFile(it.avatar) end
        end
        return res
    end, function(res)
        self.loading, self.loaded = false, true
        if self.closed then return end
        res = res or { total = 0, items = {} }
        self.total = res.total
        for _, it in ipairs(res.items) do self.items[#self.items + 1] = it end
        self.has_more = #res.items > 0 and #self.items < res.total
        self:refresh(true, "ui")
    end)
end

local function card(ops, x, y, w, h)
    table.insert(ops, { "rrect", x, y, w, h, Theme.WHITE, 24 })
    table.insert(ops, { "frame", x, y, w, h, 2, Theme.BLACK, 24 })
end

function UnderlineReviewsView:buildContent()
    local ops, anchors = {}, {}
    self.hits = {}
    -- 原文 + 划线。文字框自带白底、按两行高度画，只有一行的短原文会盖住卡片下边框，所以边框最后画
    table.insert(ops, { "rrect", L, QUOTE.y, W, QUOTE.h, Theme.WHITE, 24 })
    local quote_op, quote_lines = Canvas.textBox(L + PAD, 0, QUOTE.split - L - 2 * PAD, self.quote or "", Theme.REGULAR, 33, nil, 2)
    quote_op[3] = QUOTE.y + math.floor((QUOTE.h - quote_lines * 53) / 2) + 2
    table.insert(ops, quote_op)
    table.insert(ops, { "vline", QUOTE.split, QUOTE.y, QUOTE.h, 2, Theme.BLACK })
    table.insert(ops, { "image", 911, 86, Theme.res("icon_reading_menu_underline.svg"), 49, 49 })
    table.insert(ops, T(936, 149, "划线", Theme.BOLD, 30, nil, nil, "center"))
    table.insert(ops, { "frame", L, QUOTE.y, W, QUOTE.h, 2, Theme.BLACK, 24 })
    self.hits[#self.hits + 1] = { x = QUOTE.split, y = QUOTE.y, w = L + W - QUOTE.split, h = QUOTE.h, action = "highlight" }

    local y = QUOTE.y + QUOTE.h + GAP
    for _, it in ipairs(self.items) do
        anchors[#anchors + 1] = y
        local top, inner = y, {}
        -- 头像（圆形，浅灰描边）和名字
        local ax, ay, ar = L + PAD, top + PAD, 24
        if it.avatar_file then
            table.insert(inner, { "image", ax, ay, it.avatar_file, 49, 49 })
            table.insert(inner, { "circle_mask", ax + ar, ay + ar, ar + 1, 12, Theme.WHITE })
        end
        table.insert(inner, { "ring", ax + ar, ay + ar, ar + 1, 2, Theme.LINE_GRAY })
        table.insert(inner, T(L + 108, top + 46, it.author ~= "" and it.author or "书友", Theme.BOLD, 32, nil, 580))
        -- 想法
        local body, lines = Canvas.textBox(L + PAD, top + 99, W - 2 * PAD, it.content or "", Theme.REGULAR,
            CONTENT_PX, nil, nil, CONTENT_PITCH / CONTENT_PX - 1)
        table.insert(inner, body)
        local div = top + 99 + lines * CONTENT_PITCH + 3 + 22
        table.insert(inner, { "hline", L + PAD, div, W - 2 * PAD, 1, DIVIDER })
        -- 点赞、评论（0 时只显示图标）
        local fy = div + 1
        table.insert(inner, { "image", 391, fy + 15, Theme.res(it.liked and "icon_review_like_selected.svg" or "icon_review_like.svg"), 49, 49 })
        if (it.likes or 0) > 0 then table.insert(inner, T(447, fy + 30, tostring(it.likes), Theme.REGULAR, 28)) end
        table.insert(inner, { "image", 783, fy + 15, Theme.res("icon_review_detail_comment.svg"), 49, 49 })
        if (it.comments or 0) > 0 then table.insert(inner, T(839, fy + 30, tostring(it.comments), Theme.REGULAR, 28)) end
        local bottom = fy + 80
        self.hits[#self.hits + 1] = { x = L, y = fy, w = W / 2, h = 80, action = "like", item = it }
        card(ops, L, top, W, bottom - top)
        for _, op in ipairs(inner) do ops[#ops + 1] = op end
        y = bottom + GAP
    end
    if #self.items == 0 then
        table.insert(ops, T(632, y + 40, (self.loading or not self.loaded) and "正在加载…" or "还没有书友在这里写想法", Theme.BOLD, 30, nil, nil, "center"))
    end
    return { ops = ops, height = y, anchors = anchors }
end

-- 调淡整屏很慢（Kindle 上约 0.35 秒，翻一页要重画好几次）。下面的阅读页在卡片打开期间不会变，
-- 所以第一次调淡后把结果存一份，以后直接贴上去，也不用再重画下面的阅读页
function UnderlineReviewsView:paintTo(bb, x, y)
    local h = BottomBar.top()
    if self.dim_bb then
        bb:blitFrom(self.dim_bb, x, y, 0, 0, self.dimen.w, h)
    else
        bb:lightenRect(x, y, self.dimen.w, h, DIM)
        self.dim_bb = Blitbuffer.new(self.dimen.w, h, bb:getType())
        self.dim_bb:blitFrom(bb, 0, 0, x, y, self.dimen.w, h)
    end
    self.content_canvas:paintTo(bb, x, y)
    self.bar_canvas:paintTo(bb, x, y)
end

function UnderlineReviewsView:onCloseWidget()
    if self.dim_bb then self.dim_bb:free() self.dim_bb = nil end
    PagedView.onCloseWidget(self)
end

function UnderlineReviewsView:repaint(mode)
    -- 第一次调淡前，下面的阅读页要先重画一遍，否则调淡会在上一次的画面上叠加；之后用存好的调淡画面，不用再画
    if self.under and not self.dim_bb then UIManager:setDirty(self.under, mode or "ui") end
    PagedView.repaint(self, mode)
    local ops = self.bar_canvas.ops
    local b = WRITE_BTN
    table.insert(ops, { "frame", b.x, b.y, b.w, b.h, 2, Theme.BLACK, b.h / 2 })
    table.insert(ops, { "image", b.x + 20, b.y + 12, Theme.res("icon_reader_selection_menu_review_black.svg"), 46, 46 })
    table.insert(ops, T(b.x + 78, b.y + 20, "写想法", Theme.BOLD, 30))
    self.bar_canvas:setOps(ops)
end

function UnderlineReviewsView:onTapBar(pos)
    local b = WRITE_BTN
    if pos.x >= b.x and pos.x < b.x + b.w then
        UIManager:close(self)
        if self.on_write then self.on_write() end
    end
    return true
end

function UnderlineReviewsView:onTapContent(x, y)
    for _, h in ipairs(self.hits or {}) do
        if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then
            if h.action == "highlight" then
                UIManager:close(self)
                if self.on_highlight then self.on_highlight() end
            elseif h.action == "like" and h.item.reviewId then
                local it = h.item
                if Direct.likeReview(it.reviewId, not it.liked) then
                    it.liked = not it.liked
                    it.likes = math.max(0, (it.likes or 0) + (it.liked and 1 or -1))
                    self:refresh(true, "ui")
                end
            end
            return
        end
    end
    -- 点在卡片下面的空白处：关闭（官方点空白处收起弹层）
    if y >= self.content_height then self:onBack() end
end

function UnderlineReviewsView:onNextPage()
    local r = PagedView.onNextPage(self)
    if self.has_more and self.offset >= self:maxOffset() - self:viewportHeight() then
        UIManager:nextTick(function() self:load() end)
    end
    return r
end

return UnderlineReviewsView
