-- 通用文字列表页（书评、热门划线等）：标题 + 每条“作者/标题、正文（最多若干行）、附注”，
-- 翻到最后自动加载下一批。fetch(offset) → items, has_more；item = { head, body, meta, on_tap }
local UIManager = require("ui/uimanager")

local Canvas = require("weread/canvas")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

local TextListView = PagedView:extend{
    tab = "back",
    viewport_top = 150,
    title = "",
    fetch = nil,
    body_lines = 5,
}

function TextListView:init()
    PagedView.init(self)
    self.items, self.has_more = {}, true
end

function TextListView:load()
    if self.loading or not self.has_more then return end
    self.loading = true
    local items, has_more = self.fetch(#self.items)
    self.loading = false
    for _, it in ipairs(items or {}) do self.items[#self.items + 1] = it end
    self.has_more = has_more and items and #items > 0
    self:refresh(true)
end

function TextListView:buildHeader()
    return {
        T(38, 66, self.title, Theme.SERIF, 44, nil, 1150),
        { "hline", 0, 148, self.dimen.w, 2, Theme.LINE_GRAY },
    }
end

function TextListView:buildContent()
    local ops, anchors = {}, {}
    self.rows = {}
    local y = 30
    local body_h = math.floor(28 * 1.6 * self.body_lines)
    for _, it in ipairs(self.items) do
        local top = y
        anchors[#anchors + 1] = y - 20
        if it.head then
            table.insert(ops, T(38, y, it.head, Theme.BOLD, 26, nil, 1000))
            y = y + 46
        end
        table.insert(ops, (Canvas.textBox(38, y - 6, 1188, it.body or "", Theme.REGULAR, 28, nil, self.body_lines)))
        y = y + body_h + 10
        if it.meta then
            table.insert(ops, T(38, y, it.meta, Theme.REGULAR, 22, Theme.HINT_GRAY))
            y = y + 40
        end
        y = y + 20
        table.insert(ops, { "hline", 38, y - 18, 1188, 1, Theme.LINE_GRAY })
        self.rows[#self.rows + 1] = { y0 = top - 10, y1 = y - 18, item = it }
    end
    if #self.items == 0 then
        table.insert(ops, T(632, 200, self.loading and "正在加载…" or "暂无内容", Theme.BOLD, 28, nil, nil, "center"))
    end
    return { ops = ops, height = y + 40, anchors = anchors }
end

function TextListView:onNextPage()
    local r = PagedView.onNextPage(self)
    if self.has_more and self.offset >= self:maxOffset() - self:viewportHeight() then
        UIManager:nextTick(function() self:load() end)
    end
    return r
end

function TextListView:onTapContent(x, y)
    for _, r in ipairs(self.rows or {}) do
        if y >= r.y0 and y < r.y1 and r.item.on_tap then
            UIManager:close(self)
            r.item.on_tap()
            return
        end
    end
end

return TextListView
