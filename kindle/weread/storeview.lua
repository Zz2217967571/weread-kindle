-- 书城，按官方墨水屏版（ref/official/20-store.png、21-store-p2/p3.png）：顶部固定搜索框（占位是热搜词），
-- 下面“最近阅读”五本封面、“猜你喜欢”两列六本（换一批）、“TOP50 / 飙升榜”“TOP50 / 新书榜”各四本（查看全部）。
local UIManager = require("ui/uimanager")

local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local Items = require("weread/bookitems")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

local COVER_COLS = { 38, 283, 528, 774, 1018 }
local HALF_X = { 38, 651 }       -- 两列条目的左边界
local HALF_W = 575
local RANKS = {
    { id = "rising", name = "飙升榜" },
    { id = "newbook", name = "新书榜" },
}

local StoreView = PagedView:extend{
    tab = "store",
    viewport_top = 157,
    on_open_book = nil,    -- 点了某本书：打开详情页
    on_search = nil,       -- 点了搜索框
    on_rank = nil,         -- 点了“查看全部”：function(rank_id, rank_name)
}

function StoreView:init()
    PagedView.init(self)
    self.guess_idx = 0
end

-- 书城首页要的所有数据，一次在子进程里取完
local function fetchHome(guess_idx)
    local shelf = Direct.shelf()
    local recent = {}
    for _, b in ipairs(shelf and shelf.books or {}) do
        if #recent >= 5 then break end
        if b.kind ~= "mp" then recent[#recent + 1] = b end
    end
    local ranks = {}
    for _, r in ipairs(RANKS) do
        ranks[#ranks + 1] = { id = r.id, name = r.name, books = Direct.rankBooks(r.id, 4) or {} }
    end
    local tags = Direct.searchTags()
    return { recent = recent, guess = Direct.guessYouLike(6, guess_idx) or {}, ranks = ranks, hint = tags[1] or "搜索" }
end

function StoreView:load()
    require("weread/async").swr("store", function() return fetchHome(0) end, function(home)
        if self.closed or not home then return end
        self.recent, self.guess, self.ranks, self.hint = home.recent, home.guess, home.ranks, home.hint
        self:refresh(true)
        local all = {}
        for _, list in ipairs{ self.recent, self.guess } do for _, b in ipairs(list) do all[#all + 1] = b end end
        for _, r in ipairs(self.ranks) do for _, b in ipairs(r.books) do all[#all + 1] = b end end
        self:fetchCovers(all)
    end)
end

function StoreView:buildHeader()
    return {
        { "frame", 38, 56, 1188, 90, 2, Theme.BLACK, 45 },
        { "image", 66, 79, Theme.res("icon_search.png"), 42, 42 },
        T(122, 86, self.hint or "搜索", Theme.BOLD, 29, Theme.HINT_GRAY, 1050),
    }
end

-- 区块标题：衬线大字，右边可选一个圆角按钮，下面一条灰线
local function section(ops, y, title, button)
    table.insert(ops, T(38, y, title, Theme.SERIF, 46))
    if button then
        local bw = Canvas.textWidth(button, Theme.BOLD, 26) + 70
        table.insert(ops, { "frame", 1226 - bw, y - 8, bw, 56, 2, Theme.BLACK, 28 })
        table.insert(ops, T(1226 - bw / 2, y + 6, button, Theme.BOLD, 26, nil, nil, "center"))
    end
    table.insert(ops, { "hline", 38, y + 70, 1188, 2, Theme.LINE_GRAY })
    return y + 108
end

function StoreView:buildContent()
    local ops, anchors = {}, {}
    self.hits = {}
    if not self.guess then
        table.insert(ops, T(632, 400, "正在加载书城…", Theme.BOLD, 30, nil, nil, "center"))
        return { ops = ops, height = 600 }
    end
    local y = 40
    -- 最近阅读
    anchors[#anchors + 1] = y - 30
    y = section(ops, y, "最近阅读")
    for i, b in ipairs(self.recent) do
        Items.cover(ops, b, COVER_COLS[i], y, 208, 300)
        self.hits[#self.hits + 1] = { x = COVER_COLS[i], y = y, w = 208, h = 300, book = b, shelf = true }
    end
    y = y + 300 + 70
    -- 猜你喜欢
    anchors[#anchors + 1] = y - 30
    self.guess_button_y = y
    y = section(ops, y, "猜你喜欢", "换一批")
    for i, b in ipairs(self.guess) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local ry = y + row * 240
        if col == 0 and row > 0 then anchors[#anchors + 1] = ry - 20 end
        Items.row(ops, b, HALF_X[col + 1], ry, HALF_W)
        self.hits[#self.hits + 1] = { x = HALF_X[col + 1], y = ry, w = HALF_W, h = 205, book = b }
    end
    y = y + math.ceil(#self.guess / 2) * 240 + 50
    -- 榜单
    for _, r in ipairs(self.ranks) do
        anchors[#anchors + 1] = y - 30
        r.button_y = y
        y = section(ops, y, "TOP50 / " .. r.name, "查看全部")
        for i, b in ipairs(r.books) do
            local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
            local ry = y + row * 240
            Items.row(ops, b, HALF_X[col + 1], ry, HALF_W, b.rank or i)
            self.hits[#self.hits + 1] = { x = HALF_X[col + 1], y = ry, w = HALF_W, h = 205, book = b }
        end
        y = y + math.ceil(#r.books / 2) * 240 + 50
    end
    return { ops = ops, height = y, anchors = anchors }
end

function StoreView:onTapHeader(pos)
    if pos.y >= 56 and pos.y <= 146 and self.on_search then self.on_search() end
end

function StoreView:onTapContent(x, y)
    if self.guess_button_y and y >= self.guess_button_y - 10 and y < self.guess_button_y + 60 and x > 1000 then
        self.guess_idx = self.guess_idx + 6
        local idx = self.guess_idx
        require("weread/async").run(function() return Direct.guessYouLike(6, idx) end, function(list)
            if self.closed or not list then return end
            self.guess = list
            self:refresh(true)
            self:fetchCovers(self.guess)
        end)
        return
    end
    for _, r in ipairs(self.ranks or {}) do
        if r.button_y and y >= r.button_y - 10 and y < r.button_y + 60 and x > 1000 then
            if self.on_rank then self.on_rank(r.id, r.name) end
            return
        end
    end
    for _, h in ipairs(self.hits or {}) do
        if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then
            if self.on_open_book then self.on_open_book(h.book, h.shelf) end
            return
        end
    end
end

return StoreView
