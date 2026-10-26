-- 书单页：榜单“查看全部”和搜索结果共用。顶部标题，下面一行一本（封面 + 书名 + 作者 + 推荐值），
-- 翻到最后一页附近时自动加载下一批。
local UIManager = require("ui/uimanager")

local Canvas = require("weread/canvas")
local Items = require("weread/bookitems")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

local ROW_H = 250
local FIRST = 30

local BookListView = PagedView:extend{
    tab = "back",
    viewport_top = 150,
    title = "",
    ranked = false,       -- 书名前显示排名
    fetch = nil,          -- function(max_idx) → books, has_more
    on_open_book = nil,
}

function BookListView:init()
    PagedView.init(self)
    self.books = {}
    self.has_more = true
end

function BookListView:load()
    self:loadMore()
end

function BookListView:loadMore()
    if self.loading or not self.has_more then return end
    self.loading = true
    local fetch, from = self.fetch, #self.books
    require("weread/async").run(function()
        local books, has_more = fetch(from)
        return books and { books = books, has_more = has_more and true or false } or nil
    end, function(res)
        self.loading = false
        if self.closed then return end
        local books = res and res.books
        if not books then
            self.has_more = false
            self.message = "加载失败"
        else
            for _, b in ipairs(books) do self.books[#self.books + 1] = b end
            self.has_more = res.has_more and #books > 0
            if #self.books == 0 then self.message = "没有找到相关的书" end
        end
        self:refresh(true)
        self:fetchCovers(books)
    end)
end

function BookListView:buildHeader()
    return {
        T(38, 66, self.title, Theme.SERIF, 46, nil, 1150),
        { "hline", 0, 148, self.dimen.w, 2, Theme.LINE_GRAY },
    }
end

function BookListView:buildContent()
    local ops, anchors = {}, {}
    self.rows = {}
    if self.message and #self.books == 0 then
        table.insert(ops, T(632, 300, self.message, Theme.BOLD, 30, nil, nil, "center"))
        return { ops = ops, height = 600 }
    end
    for i, b in ipairs(self.books) do
        local y = FIRST + (i - 1) * ROW_H
        anchors[#anchors + 1] = y - 20
        Items.row(ops, b, 38, y, 1188, self.ranked and (b.rank or i) or nil)
        table.insert(ops, { "hline", 38, y + 225, 1188, 1, Theme.LINE_GRAY })
        self.rows[#self.rows + 1] = { y = y, book = b }
    end
    return { ops = ops, height = FIRST + #self.books * ROW_H + 40, anchors = anchors }
end

-- 翻到快到底时加载下一批
function BookListView:onNextPage()
    local r = PagedView.onNextPage(self)
    if self.has_more and self.offset >= self:maxOffset() - self:viewportHeight() then
        UIManager:nextTick(function() self:loadMore() end)
    end
    return r
end

function BookListView:onTapContent(x, y)
    for _, row in ipairs(self.rows or {}) do
        if y >= row.y and y < row.y + 205 then
            if self.on_open_book then self.on_open_book(row.book) end
            return
        end
    end
end

return BookListView
