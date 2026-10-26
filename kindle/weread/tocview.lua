-- 目录页，和官方墨水屏版一样（ref/official/42-reader-toc.png）：全屏，顶部书名、“去底部”和全书搜索框，
-- 下面每行“章节名 …… 页码”，当前章节反白；底部栏左边返回，中间“书签”切到书签列表。
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local BottomBar = require("weread/bottombar")
local Canvas = require("weread/canvas")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

local ROW_H = 101
local FIRST_ROW = 32          -- 第一行文字顶部（内容坐标）；官方内容区从 y=250 开始，第一行在 282
local BOOKMARK_BTN = { x = 820, w = 150, h = 54 }

local TocView = PagedView:extend{
    tab = "back",
    viewport_top = 250,
    book = nil,           -- weread/book
    current = 1,          -- 当前章节序号
    page_of = nil,        -- function(i) → 估算的页码
    bookmarks = nil,      -- { { index, xpointer, title, text, percent }, … }
    on_select = nil,      -- function(index, xpointer)
    show_bookmarks = false,
}

function TocView:buildHeader()
    local title = self.book.meta.title or ""
    return {
        T(45, 58, title, Theme.BOLD, 34, nil, 1030),
        T(1126, 66, "↓去底部", Theme.BOLD, 26),
        { "frame", 45, 125, 1174, 90, 2, Theme.BLACK, 45 },
        { "image", 73, 149, Theme.res("icon_search.png"), 42, 42 },
        T(128, 156, "搜索全书内容", Theme.BOLD, 28, Theme.HINT_GRAY),
        { "hline", 0, 248, self.dimen.w, 2, Theme.LINE_GRAY },
    }
end

function TocView:chapterRows()
    local ops, anchors = {}, {}
    self.rows = {}
    for i, ch in ipairs(self.book.chapters) do
        local y = FIRST_ROW + (i - 1) * ROW_H
        anchors[#anchors + 1] = y - 30
        local indent = math.max(0, (ch.level or 1) - 1) * 40
        local name = ch.title or ""
        if i == self.current then
            -- 当前章节：文字反白（黑底）
            local face_w = math.min(1100 - indent, Canvas.textWidth(name, Theme.BOLD, 28) + 4)
            table.insert(ops, { "rect", 45 + indent - 2, y - 6, face_w, 46, Theme.BLACK })
            table.insert(ops, T(45 + indent, y + 6, name, Theme.BOLD, 28, Theme.WHITE, 1100 - indent))
        else
            table.insert(ops, T(45 + indent, y + 6, name, Theme.BOLD, 28, nil, 1100 - indent))
        end
        local page = self.page_of and self.page_of(i)
        if page then
            table.insert(ops, T(1219, y + 6, tostring(page), Theme.REGULAR, 28, nil, nil, "right"))
        end
        table.insert(ops, { "hline", 45, y + 70, 1174, 1, Theme.LINE_GRAY })
        self.rows[#self.rows + 1] = { y = y - 30, index = i }
    end
    return ops, anchors, FIRST_ROW + #self.book.chapters * ROW_H
end

function TocView:bookmarkRows()
    local ops, anchors = {}, {}
    self.rows = {}
    if #self.bookmarks == 0 then
        table.insert(ops, T(632, 300, "暂无书签", Theme.BOLD, 30, nil, nil, "center"))
        return ops, anchors, 600
    end
    for i, bm in ipairs(self.bookmarks) do
        local y = FIRST_ROW + (i - 1) * 140
        anchors[#anchors + 1] = y - 30
        table.insert(ops, T(45, y + 6, bm.title or "", Theme.BOLD, 28, nil, 1000))
        table.insert(ops, T(1219, y + 6, string.format("%d%%", bm.percent or 0), Theme.REGULAR, 26, nil, nil, "right"))
        table.insert(ops, T(45, y + 56, bm.text or "", Theme.REGULAR, 26, Theme.HINT_GRAY, 1174))
        table.insert(ops, { "hline", 45, y + 108, 1174, 1, Theme.LINE_GRAY })
        self.rows[#self.rows + 1] = { y = y - 30, h = 140, bookmark = bm }
    end
    return ops, anchors, FIRST_ROW + #self.bookmarks * 140
end

function TocView:buildContent()
    local ops, anchors, height
    if self.show_bookmarks then
        ops, anchors, height = self:bookmarkRows()
    else
        ops, anchors, height = self:chapterRows()
    end
    return { ops = ops, height = height + 40, anchors = anchors }
end

-- 打开时翻到当前章节所在的那一页
function TocView:open()
    self:refresh()
    if not self.show_bookmarks and self.anchors and self.anchors[self.current] then
        local vh = self:viewportHeight()
        local per_page = math.max(1, math.floor(vh / ROW_H))
        local first = math.floor((self.current - 1) / per_page) * per_page + 1
        self.offset = math.min(self.anchors[first] or 0, self:maxOffset())
        if first == 1 then self.offset = 0 end
        self:repaint("full")
    end
end

function TocView:repaint(mode)
    PagedView.repaint(self, mode)
    -- 底部栏中间的“书签”按钮：切换目录 / 书签列表，选中时反白
    local y0 = BottomBar.top()
    local by = y0 + math.floor((BottomBar.HEIGHT - BOOKMARK_BTN.h) / 2)
    local ops = self.bar_canvas.ops
    if self.show_bookmarks then
        table.insert(ops, { "rect", BOOKMARK_BTN.x, by, BOOKMARK_BTN.w, BOOKMARK_BTN.h, Theme.BLACK })
        table.insert(ops, T(BOOKMARK_BTN.x + BOOKMARK_BTN.w / 2, by + 12, "书签", Theme.BOLD, 28, Theme.WHITE, nil, "center"))
    else
        table.insert(ops, { "frame", BOOKMARK_BTN.x, by, BOOKMARK_BTN.w, BOOKMARK_BTN.h, 2, Theme.BLACK, 27 })
        table.insert(ops, T(BOOKMARK_BTN.x + BOOKMARK_BTN.w / 2, by + 12, "书签", Theme.BOLD, 28, nil, nil, "center"))
    end
    self.bar_canvas:setOps(ops)
end

function TocView:onTapBar(pos)
    if pos.x >= BOOKMARK_BTN.x and pos.x < BOOKMARK_BTN.x + BOOKMARK_BTN.w then
        self.show_bookmarks = not self.show_bookmarks
        self:refresh()
    end
    return true
end

function TocView:onTapHeader(pos)
    if pos.y < 120 and pos.x > 1100 then
        self.offset = self:maxOffset()
        self:repaint("partial")
    elseif pos.y >= 125 and pos.y < 215 then
        UIManager:show(InfoMessage:new{ text = "全书搜索稍后支持", timeout = 2 })
    end
end

function TocView:onTapContent(x, y)
    for _, row in ipairs(self.rows or {}) do
        if y >= row.y and y < row.y + (row.h or ROW_H) then
            UIManager:close(self)
            if row.bookmark then
                self.on_select(row.bookmark.index, row.bookmark.xpointer, row.bookmark.fraction)
            else
                self.on_select(row.index)
            end
            return
        end
    end
end

return TocView
