-- 书架：和官方墨水屏版一样，顶部固定一个搜索框；下面是“书架”标题、导入 / 选择，五列封面网格，
-- 最后一行下面是“N本公开阅读 · M本私密阅读”。坐标取自 ref/official/10-shelf.png、11-shelf-p2.png。
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")

local ActionSheet = require("weread/actionsheet")
local BottomBar = require("weread/bottombar")
local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local ImportGuideView = require("weread/importguideview")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

-- 网格：五列，封面 208×300，列左边界（截图实测）
local COLS = { 38, 283, 528, 774, 1018 }
local COVER_W, COVER_H = 208, 300
local ROW_PITCH = 391
-- 以下纵坐标都是内容坐标（内容区上沿为 0，官方内容区从屏幕 y=157 开始）
local TITLE_INK = 47          -- “书架”
local GRID_TOP = 127          -- 第一行封面顶部
local NAME_INK = 324          -- 书名行（“已下载”图标）顶部，相对封面顶部；文字墨迹比图标高 2px
local FOOTER_INK = 400        -- 页脚文字墨迹顶部，相对最后一行封面顶部
local CONTENT_END = 475       -- 内容结束，相对最后一行封面顶部

-- 选择模式（官方 ShelfToolBar 的 cancelMode）：标题行变成 左“全选”、中“已选择 N 本书籍”、右“取消”；
-- 每本书封面右下角有个勾选框（checkbox_big：24dp，离右、下各 4dp）；底部栏换成 下载 / 移出书架 / 私密阅读
local CHECK = { size = 45, margin = 8 }
local EDIT_BUTTONS = {
    { id = "download", icon = "icon_toolbar_download_start.svg" },
    { id = "remove", icon = "icon_toolbar_bookshelf_remove.svg" },
    { id = "secret", icon = "icon_toolbar_private.svg" },
}
local TAB_W, PAGING_X = 165, 994

local ShelfView = PagedView:extend{
    tab = "shelf",
    viewport_top = 157,
    on_open_book = nil,
    on_relogin = nil,
    on_search = nil,
}

function ShelfView:init()
    PagedView.init(self)
    self.books = nil
    self.message = nil
    self.select_mode = false
    self.checked = {}
end

function ShelfView:load()
    -- 先用上次的书架立刻显示，再在后台取最新的
    require("weread/async").swr("shelf", Direct.shelf, function(data, err, kind)
        if self.closed then return end
        if not data then
            if kind == "relogin" and self.on_relogin then
                self.on_relogin()
                return
            end
            self:showMessage(err or "书架加载失败")
            return
        end
        -- 缓存和最新的一样（常见情况）就不重画，免得白闪一下
        local sig = require("rapidjson").encode(data)
        if sig == self.loaded_sig then return end
        self.loaded_sig = sig
        self.data = data
        self.books = data.books
        self.message = nil
        self:refresh(true)
        -- 封面在后台陆续下载，下完一批重画一次
        self:fetchCovers(self.books)
    end)
end

function ShelfView:showMessage(text)
    self.message = text
    self:refresh()
end

-- 下载状态：全部章节都在本地是 "full"（实心对勾）；下过一部分是 "partly" 加比例（官方画成进度饼图）；没下过是 nil
local function downloadState(book)
    local dir = Direct.bookDir(book.bookId) .. "/epub"
    if lfs.attributes(dir, "mode") ~= "directory" then return nil end
    local n = 0
    for f in lfs.dir(dir) do
        if f:match("^%d+%.epub$") then n = n + 1 end
    end
    if n == 0 then return nil end
    local f = io.open(Direct.bookDir(book.bookId) .. "/chapters.json", "rb")
    local data = f and rapidjson.decode(f:read("*a"))
    if f then f:close() end
    local total = type(data) == "table" and data.chapters and #data.chapters or 0
    if total > 0 and n >= total then return "full" end
    return "partly", total > 0 and n / total or 0
end

function ShelfView:buildHeader()
    -- 搜索框：2px 黑边、两端半圆
    return {
        { "frame", 38, 56, 1188, 90, 2, Theme.BLACK, 45 },
        { "image", 66, 79, Theme.res("icon_search.png"), 42, 42 },
        T(122, 86, "搜索", Theme.BOLD, 29, Theme.HINT_GRAY),
    }
end

function ShelfView:buildContent()
    local ops
    if self.select_mode then
        ops = {
            T(38, 50, self:allChecked() and "取消全选" or "全选", Theme.BOLD, 32),
            T(632, 50, self:countText(), Theme.BOLD, 32, nil, 700, "center"),
            T(1226, 50, "取消", Theme.BOLD, 32, nil, nil, "right"),
        }
    else
        ops = {
            T(38, TITLE_INK, "书架", Theme.REGULAR, 45),
            { "image", 973, 46, Theme.res("icon_import.png"), 40, 42 },
            T(1017, 50, "导入", Theme.BOLD, 31),
            { "image", 1120, 46, Theme.res("icon_select.png"), 40, 42 },
            T(1164, 50, "选择", Theme.BOLD, 31),
        }
    end
    if self.message or not self.books then
        table.insert(ops, T(632, 400, self.message or "正在加载书架…", Theme.BOLD, 30, nil, nil, "center"))
        return { ops = ops, height = 600 }
    end

    self.cells = {}
    local anchors = {}
    local rows = math.ceil(#self.books / #COLS)
    for i, book in ipairs(self.books) do
        local r, c = math.floor((i - 1) / #COLS), (i - 1) % #COLS
        local x, y = COLS[c + 1], GRID_TOP + r * ROW_PITCH
        if c == 0 then anchors[#anchors + 1] = y end
        local cover = Direct.cachedCover(book)
        if cover then
            table.insert(ops, { "image", x, y, cover, COVER_W, COVER_H })
        end
        -- 官方描边是把封面边缘 2px 压暗约 27%（白底上正好是 187）
        table.insert(ops, { "shade", x, y, COVER_W, COVER_H, 2, 0.267 })
        if book.private then
            table.insert(ops, { "image", x, y + COVER_H - 53, Theme.res("icon_bookshelf_privacy.svg"), 53, 53 })
        end
        local name_x, name_w = x, COVER_W
        local downloaded, ratio = downloadState(book)
        if downloaded then
            -- 饼图按 5% 一档预先生成（res/pie_00 ~ pie_20），至少显示一档
            local icon = downloaded == "full" and "icon_bookshelf_downloaded.svg"
                or string.format("pie_%02d.svg", math.max(1, math.min(19, math.floor(ratio * 20 + 0.5))))
            table.insert(ops, { "image", x, y + NAME_INK, Theme.res(icon), 20, 20 })
            name_x, name_w = x + 23, COVER_W - 23
        end
        table.insert(ops, T(name_x, y + NAME_INK - 3, book.title or "", Theme.BOLD, 24, nil, name_w))
        if self.select_mode and book.kind ~= "mp" then
            local icon = self.checked[book.bookId] and "icon_checkbox_big_checked.svg" or "icon_checkbox_big.svg"
            table.insert(ops, { "image", x + COVER_W - CHECK.margin - CHECK.size, y + COVER_H - CHECK.margin - CHECK.size,
                Theme.res(icon), CHECK.size, CHECK.size })
        end
        self.cells[#self.cells + 1] = { x = x, y = y, book = book }
    end
    local last_top = GRID_TOP + math.max(rows - 1, 0) * ROW_PITCH
    local footer = string.format("%d本公开阅读 · %d本私密阅读", self.data.public_count, self.data.private_count)
    table.insert(ops, T(632, last_top + FOOTER_INK, footer, Theme.REGULAR, 23, nil, nil, "center"))
    return { ops = ops, height = last_top + CONTENT_END, anchors = anchors }
end

function ShelfView:onTapHeader(pos)
    if pos.y >= 56 and pos.y <= 146 and self.on_search then self.on_search() end
end

function ShelfView:onTapContent(x, y)
    if y < GRID_TOP then
        if y <= 30 then return end
        if self.select_mode then
            if x < 400 then
                self:selectAll(not self:allChecked())
            elseif x > 900 then
                self:exitSelect()
            end
        elseif x > 960 then
            if x < 1110 then
                UIManager:show(ImportGuideView:new{ on_close = function() self:refresh(true) end }, "full")
            else
                self:enterSelect()
            end
        end
        return
    end
    for _, cell in ipairs(self.cells or {}) do
        if x >= cell.x and x < cell.x + COVER_W and y >= cell.y and y < cell.y + NAME_INK + 40 then
            if self.select_mode then
                if cell.book.kind ~= "mp" then self:toggle(cell.book) end
            elseif self.on_open_book then
                self.on_open_book(cell.book)
            end
            return
        end
    end
end

-- ---- 选择模式 ----

function ShelfView:checkedBooks()
    local list = {}
    for _, b in ipairs(self.books or {}) do
        if self.checked[b.bookId] then list[#list + 1] = b end
    end
    return list
end

function ShelfView:allChecked()
    local n, total = 0, 0
    for _, b in ipairs(self.books or {}) do
        if b.kind ~= "mp" then
            total = total + 1
            if self.checked[b.bookId] then n = n + 1 end
        end
    end
    return total > 0 and n == total
end

-- 官方 BookshelfTopBar.formatCheckCount：一本都没选时显示“选择书籍”
function ShelfView:countText()
    local n = #self:checkedBooks()
    return n == 0 and "选择书籍" or string.format("已选择 %d 本书籍", n)
end

function ShelfView:enterSelect()
    if not self.books then return end
    self.select_mode, self.checked = true, {}
    self:refresh(true, "ui")
end

function ShelfView:exitSelect()
    self.select_mode, self.checked = false, {}
    self:refresh(true, "ui")
end

function ShelfView:toggle(book)
    self.checked[book.bookId] = not self.checked[book.bookId] or nil
    self:refresh(true, "ui")
end

function ShelfView:selectAll(on)
    self.checked = {}
    if on then
        for _, b in ipairs(self.books or {}) do
            if b.kind ~= "mp" then self.checked[b.bookId] = true end
        end
    end
    self:refresh(true, "ui")
end

-- 底部栏：左边三个按钮（没选书时是灰的），右边照旧是翻页
function ShelfView:editBarOps()
    local ops = BottomBar.ops(nil, self.offset > 0, self.offset < self:maxOffset())
    local y0 = BottomBar.top()
    local enabled = next(self.checked) ~= nil
    for i, b in ipairs(EDIT_BUTTONS) do
        local icon = b.icon
        if b.id == "secret" and self:allSecret() then icon = "icon_toolbar_private_cancel.svg" end
        local x = (i - 1) * TAB_W + 56
        table.insert(ops, { "image", x, y0 + 27, Theme.res(icon), 53, 53 })
        if not enabled then table.insert(ops, { "lighten", x, y0 + 27, 53, 53, 0.5 }) end
    end
    return ops
end

function ShelfView:repaint(mode)
    PagedView.repaint(self, mode)
    if self.select_mode then self.bar_canvas:setOps(self:editBarOps()) end
end

function ShelfView:onTap(pos)
    if self.select_mode and pos.y >= BottomBar.top() and pos.x < PAGING_X then
        local i = math.floor(pos.x / TAB_W) + 1
        if EDIT_BUTTONS[i] and next(self.checked) ~= nil then self:onEditButton(EDIT_BUTTONS[i].id) end
        return true
    end
    return PagedView.onTap(self, pos)
end

function ShelfView:allSecret()
    local list = self:checkedBooks()
    if #list == 0 then return false end
    for _, b in ipairs(list) do
        if not b.private then return false end
    end
    return true
end

local function bookIds(list)
    local ids = {}
    for _, b in ipairs(list) do ids[#ids + 1] = b.bookId end
    return ids
end

function ShelfView:updateCounts()
    local private = 0
    for _, b in ipairs(self.books) do
        if b.private then private = private + 1 end
    end
    self.data.private_count = private
    self.data.public_count = #self.books - private
end

function ShelfView:onEditButton(id)
    local list = self:checkedBooks()
    if id == "download" then
        self:downloadBooks(list)
    elseif id == "remove" then
        -- 官方 BaseShelfView.deleteButton：只选一本时带书名
        local title = #list == 1 and string.format("是否将《%s》移出书架？", list[1].title or "") or "是否将所选书籍移出书架？"
        UIManager:show(ActionSheet:new{ title = title, item = "移 出", on_confirm = function()
            local ok, err = Direct.removeFromShelf(bookIds(list))
            if not ok then
                UIManager:show(InfoMessage:new{ text = err or "移出书架失败", timeout = 2 })
                return
            end
            local gone = {}
            for _, b in ipairs(list) do gone[b.bookId] = true end
            local kept = {}
            for _, b in ipairs(self.books) do
                if not gone[b.bookId] then kept[#kept + 1] = b end
            end
            self.books = kept
            self.data.books = kept
            self:updateCounts()
            self:exitSelect()
            UIManager:show(InfoMessage:new{ text = "已移出书架", timeout = 2 })
        end })
    elseif id == "secret" then
        local to_secret = not self:allSecret()
        UIManager:show(ActionSheet:new{
            title = to_secret and "开启后，所选书籍的阅读记录将不会对外公开" or "是否对所选书籍关闭私密阅读?",
            item = to_secret and "开 启" or "关 闭",
            on_confirm = function()
                local ok, err = Direct.setSecret(bookIds(list), to_secret)
                if not ok then
                    UIManager:show(InfoMessage:new{ text = err or "设置失败", timeout = 2 })
                    return
                end
                for _, b in ipairs(list) do b.private = to_secret end
                self:updateCounts()
                self:exitSelect()
            end,
        })
    end
end

-- 下载选中的书：一本一本、一章一章在后台下，付费章节跳过；封面左下角的下载标记随进度更新
function ShelfView:downloadBooks(list)
    local Book = require("weread/book")
    local queue = {}
    for _, b in ipairs(list) do
        if b.kind ~= "mp" and downloadState(b) ~= "full" then queue[#queue + 1] = b end
    end
    if #queue == 0 then
        UIManager:show(InfoMessage:new{ text = "已离线全部可阅读内容", timeout = 2 })
        self:exitSelect()
        return
    end
    UIManager:show(InfoMessage:new{ text = "开始下载选中书籍", timeout = 2 })
    self:exitSelect()
    local bi, ci, bk = 0, 0, nil
    local function step()
        if self.closed then return end
        if not bk or not bk:chapter(ci) then
            bi, ci = bi + 1, 1
            if bi > #queue then
                self:refresh(true, "ui")
                return
            end
            bk = Book.open(queue[bi])
            if not bk:load() then bk = nil end
            if not bk then return UIManager:scheduleIn(0.05, step) end
        end
        if not bk:isCached(ci) and not bk:mayNeedPay(ci) then pcall(bk.ensureChapter, bk, ci) end
        ci = ci + 1
        -- 每下几章刷新一次下载标记
        if ci % 5 == 0 then self:refresh(true, "ui") end
        UIManager:scheduleIn(0.05, step)
    end
    UIManager:scheduleIn(0.5, step)
end

return ShelfView
