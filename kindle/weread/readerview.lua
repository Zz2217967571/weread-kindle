-- 阅读页，按官方墨水屏版复刻（ref/official/40~45-reader-*.png）：
--   正文全屏，左上角一个圆形返回图标；点屏幕中间呼出菜单。
--   菜单：顶部“书签 / 书评和想法 / 涂鸦 / 书架 / 下载”，底部“返回 | 目录 笔记 进度 字体 听书”。
--   进度、字体是底部栏上方弹出的面板；目录是全屏页（weread/tocview）。
-- 每章是一个小 EPUB（weread/book），用 KOReader 的 crengine 在本机排版；翻到章末自动接下一章。
local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local CreDocument = require("document/credocument")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = Device.screen

local Async = require("weread/async")
local Book = require("weread/book")
local BottomBar = require("weread/bottombar")
local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local Fonts = require("weread/fonts")
local Quit = require("weread/quit")
local ReaderNotes = require("weread/readernotes")
local Settings = require("weread/readersettings")
local Theme = require("weread/theme")
local TocView = require("weread/tocview")

local T = Canvas.text

-- 墨水屏连续局刷会留残影，每翻这么多页做一次全刷
local FULL_REFRESH_EVERY = 8
-- 正文上下边距（正文全屏，没有页眉页脚）；试读页底部留给购买面板
local PAGE_TOP, PAGE_BOTTOM = 110, 80
local LOCKED_BOTTOM = 470
-- 自动翻页间隔（秒）
local AUTO_TURN_SECONDS = 30
-- 估算阅读速度（字/分钟），用于“约 N 小时后读完”
local READ_SPEED = 500
-- 在一页停留多少秒后把阅读位置上报给服务端
local REPORT_DELAY = 10

-- 顶部工具栏：图标左上角 x（53×53，y=64），官方 reader_top_actionbar 高 137
local TOP_BAR_H = 137
local TOP_ICONS = {
    { id = "bookmark", x = 618 },
    { id = "review", x = 756, icon = "icon_toolbar_show_idea.svg" },
    { id = "graffiti", x = 894, icon = "icon_reader_note_graffiti.svg" },
    { id = "shelf", x = 1032, icon = "icon_toolbar_bookshelf_added.svg" },
    { id = "download", x = 1170 },
}
-- 底部工具栏：按钮区间和图标
local BOTTOM_BUTTONS = {
    { id = "back", x0 = 0, x1 = 141, icon = "icon_toolbar_back" },
    { id = "toc", x0 = 178, x1 = 393, icon = "icon_toolbar_catalog" },
    { id = "note", x0 = 396, x1 = 611, icon = "icon_toolbar_note" },
    { id = "progress", x0 = 614, x1 = 830, icon = "icon_toolbar_progress" },
    { id = "font", x0 = 833, x1 = 1049, icon = "icon_toolbar_font" },
    { id = "tts", x0 = 1049, x1 = 1264, icon = "icon_toolbar_tts" },
}

-- 预览模式下版权信息页上“加入书架 随时阅读”按钮的位置（ref/official/23-bookdetail-p2.png 实测）
local JOIN = { x = 54, y = 1090, w = 1156, h = 88 }

local engine_ready = false
local function ensureEngine()
    if engine_ready then return end
    local cre = CreDocument:engineInit()
    Settings.registerFonts(cre)
    engine_ready = true
end

local ReaderView = InputContainer:extend{
    book = nil,     -- 书架里的那条记录
    on_close = nil,
}

function ReaderView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.doc = nil
    self.index = nil
    self.page = 1
    self.turns = 0
    self.menu = nil          -- nil：正文；"menu"：工具栏；"progress" / "font"：工具栏加面板
    self.overlay = Canvas:new{ ops = {} }
    self.key_events = {
        NextPage = { { { "RPgFwd", "LPgFwd" } } },
        PrevPage = { { { "RPgBack", "LPgBack" } } },
    }
    self:registerTouchZones({
        {
            id = "reader_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onTap(ges.pos) end,
        },
        -- 长按选文字（划线、写想法）
        { id = "reader_hold", ges = "hold", screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function(ges) return self:onHold(ges.pos) end },
        { id = "reader_hold_pan", ges = "hold_pan", screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function(ges) return self:onHoldPan(ges.pos) end },
        { id = "reader_hold_release", ges = "hold_release", screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function(ges) return self:onHoldRelease(ges.pos) end },
        {
            id = "reader_swipe",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                if Quit.handleSwipe(ges) then return true end
                if self.menu then return true end
                if ges.direction == "west" then return self:onNextPage() end
                if ges.direction == "east" then return self:onPrevPage() end
            end,
        },
    })
end

-- ---- 绘制 ----

function ReaderView:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Theme.WHITE)
    if self.doc then
        self.doc:drawCurrentViewByPage(bb, x, y, Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.dimen.h }, self.page)
    end
    self.overlay:paintTo(bb, x, y)
end

function ReaderView:buildOverlay()
    local ops = {}
    local join = self:joinButton()
    if join then
        table.insert(ops, { "frame", join.x, join.y, join.w, join.h, 3, Theme.LINE_GRAY, 30 })
        table.insert(ops, T(join.x + join.w / 2, join.y + 28, "加入书架 随时阅读", Theme.BOLD, 30, nil, nil, "center"))
    end
    for _, op in ipairs(self:markOps()) do ops[#ops + 1] = op end
    for _, op in ipairs(self.selection_ops or {}) do ops[#ops + 1] = op end
    if self.status then
        table.insert(ops, T(632, 800, self.status, Theme.BOLD, 30, nil, 1100, "center"))
    end
    if self.locked and self.doc and self.page == self.doc:getPageCount() then
        self:buildBuyPanel(ops)
    end
    if not self.menu then
        if self.doc or self.status then
            table.insert(ops, { "image", 52, 46, Theme.res("reading_back.svg"), 38, 38 })
            -- 设置里“阅读时显示时间”
            if G_reader_settings:isTrue("weread_show_time") then
                table.insert(ops, T(632, 54, os.date("%H:%M"), Theme.REGULAR, 22, Theme.HINT_GRAY, nil, "center"))
            end
        end
    elseif self.menu == "indent" then
        self:buildIndentPanel(ops)
    else
        self:buildTopBar(ops)
        if self.menu == "progress" then self:buildProgressPanel(ops) end
        if self.menu == "morefont" then self:buildMoreFontPanel(ops) end
        if self.menu == "font" then self:buildFontPanel(ops) end
        if self.menu == "reviews" then self:buildReviewsPanel(ops) end
        self:buildBottomBar(ops)
    end
    self.overlay:setOps(ops)
end

-- 购买面板（ref/official/50-paid-chapter.png，坐标整体 +60 贴近屏幕底部）：
-- “本书为付费会员卡可读”，黑色“会员卡 19元/月 / 你正在使用体验卡 · 付费后即可阅读”，
-- 灰框“购买本章 0.16书币”，“自动购买后续章节”
local BUY = { member_y = 1381, member_h = 94, chapter_y = 1505, chapter_h = 89, auto_y = 1617 }

function ReaderView:buildBuyPanel(ops)
    local card = self.card or {}
    local hint = (card.mcardHint or "付费会员卡 19元/月"):gsub("^付费", "")
    local trial = (card.payingRemainTime or 0) == 0 and (card.remainTime or 0) > 0
    table.insert(ops, T(632, 1315, "本书为付费会员卡可读", Theme.REGULAR, 30, nil, nil, "center"))
    table.insert(ops, { "rect", 45, BUY.member_y, 1174, BUY.member_h, Theme.BLACK })
    table.insert(ops, T(632, BUY.member_y + 19, hint, Theme.BOLD, 28, Theme.WHITE, nil, "center"))
    table.insert(ops, T(632, BUY.member_y + 57, trial and "你正在使用体验卡 · 付费后即可阅读" or "开通后即可阅读本书",
        Theme.BOLD, 21, Theme.WHITE, nil, "center"))
    table.insert(ops, { "frame", 45, BUY.chapter_y, 1174, BUY.chapter_h, 3, Theme.LINE_GRAY, 22 })
    table.insert(ops, T(632, BUY.chapter_y + 30, string.format("购买本章 %s书币", tostring(self.locked.price or "")),
        Theme.BOLD, 28, nil, nil, "center"))
    local auto = G_reader_settings:isTrue("weread_autobuy_" .. self.book.bookId)
    if auto then
        table.insert(ops, { "rect", 520, BUY.auto_y + 4, 24, 24, Theme.BLACK })
    else
        table.insert(ops, { "frame", 520, BUY.auto_y + 4, 24, 24, 3, Theme.BLACK, 12 })
    end
    table.insert(ops, T(556, BUY.auto_y + 5, "自动购买后续章节", Theme.BOLD, 23))
end

function ReaderView:onBuyPanelTap(pos)
    local PayQrView = require("weread/payqrview")
    local reload = function()
        self.locked = nil
        self:loadChapter(self.index)
    end
    if pos.y >= BUY.member_y and pos.y < BUY.member_y + BUY.member_h then
        UIManager:show(PayQrView:new{
            title = "开通付费会员卡", hint = "开通后可阅读本书全部付费章节",
            url = Direct.memberCardUrl(), on_paid = reload,
        }, "full")
    elseif pos.y >= BUY.chapter_y and pos.y < BUY.chapter_y + BUY.chapter_h then
        local balance = Direct.balance()
        local coins = balance and balance.balance or 0
        local price = tonumber(self.locked.price) or 0
        if coins >= price then
            UIManager:show(ConfirmBox:new{
                text = string.format("用 %s 书币购买《%s》？\n（余额 %.2f）", tostring(price), self.bk:chapter(self.index).title, coins),
                ok_text = "购买",
                ok_callback = function()
                    local ch = self.bk:chapter(self.index)
                    local ok = Direct.buyChapters(self.book.bookId, tostring(ch.chapterUid), price, self.locked.payType,
                        G_reader_settings:isTrue("weread_autobuy_" .. self.book.bookId))
                    UIManager:show(InfoMessage:new{ text = ok and "购买成功" or "购买失败", timeout = 1 })
                    if ok then reload() end
                end,
            })
        else
            UIManager:show(PayQrView:new{
                title = "书币不足，请先充值", hint = string.format("本章 %s 书币，当前余额 %.2f", tostring(price), coins),
                url = Direct.rechargeUrl(), on_paid = reload,
            }, "full")
        end
    elseif pos.y >= BUY.auto_y - 10 and pos.y < BUY.auto_y + 50 and pos.x > 480 and pos.x < 800 then
        G_reader_settings:flipNilOrFalse("weread_autobuy_" .. self.book.bookId)
        self:redraw()
    end
    return true
end

function ReaderView:buildTopBar(ops)
    table.insert(ops, { "rect", 0, 0, self.dimen.w, TOP_BAR_H, Theme.WHITE })
    table.insert(ops, { "hline", 0, 135, self.dimen.w, 2, Blitbuffer.Color8(221) })
    for _, it in ipairs(TOP_ICONS) do
        local icon = it.icon
        if it.id == "bookmark" then
            icon = self:currentBookmark() and "icon_reader_deletebookmark.svg" or "icon_reader_addbookmark.svg"
        elseif it.id == "download" then
            icon = self.bk and self.bk:allCached() and "icon_toolbar_download_done.svg" or "icon_toolbar_download.svg"
        elseif it.id == "shelf" and self:inPreview() then
            icon = "icon_toolbar_bookshelf_add.svg"
        end
        table.insert(ops, { "image", it.x, 64, Theme.res(icon), 53, 53 })
    end
end

function ReaderView:buildBottomBar(ops)
    local y0 = BottomBar.top()
    table.insert(ops, { "rect", 0, y0, self.dimen.w, BottomBar.HEIGHT, Theme.WHITE })
    table.insert(ops, { "hline", 0, y0, self.dimen.w, 2, Theme.LINE_GRAY })
    table.insert(ops, { "vline", 159, y0 + 31, 46, 1, Theme.LINE_GRAY })
    for _, b in ipairs(BOTTOM_BUTTONS) do
        local selected = b.id == self.menu or (b.id == "font" and self.menu == "morefont")
        local icon = b.icon .. (selected and "_selected" or "") .. ".svg"
        table.insert(ops, { "image", math.floor((b.x0 + b.x1 - 53) / 2), y0 + 26, Theme.res(icon), 53, 53 })
    end
end

-- 面板区（底部栏上方）：官方坐标 +60，因为 Kindle 的底部栏贴着屏幕底边
local function panelY(official_y) return official_y + 60 end

function ReaderView:buildProgressPanel(ops)
    local top = panelY(1122)
    table.insert(ops, { "rect", 0, top, self.dimen.w, BottomBar.top() - top, Theme.WHITE })
    table.insert(ops, { "hline", 0, top, self.dimen.w, 2, Theme.LINE_GRAY })
    local pct = self:bookPercent()
    local remain_min = self.bk:remainingWords(self.index, self.page, self.doc:getPageCount()) / READ_SPEED
    local remain = remain_min >= 60 and string.format("约 %d 小时后读完", math.floor(remain_min / 60 + 0.5))
        or string.format("约 %d 分钟后读完", math.max(1, math.floor(remain_min + 0.5)))
    local secs = self.reading_time or 0
    local time_text = secs >= 3600 and string.format("%d小时%d分钟", math.floor(secs / 3600), math.floor(secs % 3600 / 60))
        or string.format("%d分钟", math.floor(secs / 60))
    local cols = {
        { cx = 210, big = string.format("%d%%", pct), small = remain },
        { cx = 632, big = time_text, small = "阅读时长" },
        { cx = 1054, big = string.format("%d条", self.notes_count or 0), small = "笔记" },
    }
    for _, c in ipairs(cols) do
        table.insert(ops, T(c.cx, panelY(1166), c.big, Theme.BOLD, 40, nil, nil, "center"))
        table.insert(ops, T(c.cx, panelY(1226), c.small, Theme.REGULAR, 24, nil, nil, "center"))
    end
    table.insert(ops, { "vline", 420, panelY(1168), 75, 2, Theme.LINE_GRAY })
    table.insert(ops, { "vline", 842, panelY(1168), 75, 2, Theme.LINE_GRAY })
    -- 进度条：点哪儿跳到全书的哪儿
    local bar = { x = 45, y = panelY(1297), w = 1174, h = 64 }
    self.progress_bar = bar
    local knob_x = bar.x + 32 + math.floor((bar.w - 64) * pct / 100)
    table.insert(ops, { "frame", bar.x, bar.y, bar.w, bar.h, 2, Theme.BLACK, 32 })
    table.insert(ops, { "rect", bar.x + 32, bar.y + 30, knob_x - bar.x - 32, 4, Theme.BLACK })
    table.insert(ops, { "rect", knob_x - 22, bar.y + 10, 44, 44, Theme.WHITE })
    table.insert(ops, { "frame", knob_x - 22, bar.y + 10, 44, 44, 3, Theme.BLACK, 22 })
    -- 自动翻页
    local auto = { x = 45, y = panelY(1406), w = 1174, h = 64 }
    self.auto_button = auto
    if self.auto_timer then
        table.insert(ops, { "rect", auto.x, auto.y, auto.w, auto.h, Theme.BLACK })
        table.insert(ops, T(632, auto.y + 18, "关闭自动翻页", Theme.BOLD, 28, Theme.WHITE, nil, "center"))
    else
        table.insert(ops, { "frame", auto.x, auto.y, auto.w, auto.h, 2, Theme.BLACK, 32 })
        table.insert(ops, T(632, auto.y + 18, "开启自动翻页", Theme.BOLD, 28, nil, nil, "center"))
    end
end

-- 字体面板里的四个滑块：字号、字重、行距、边距
local SLIDERS = {
    { key = "font_size", y = 843, levels = #Settings.FONT_SIZES_DP, left = "小", right = "大",
      label = function(v) return tostring(Settings.FONT_SIZES_DP[v]) end },
    { key = "font_weight", y = 922, levels = #Settings.FONT_WEIGHTS, left = "细", right = "粗",
      label = function(v) return tostring(v - 1) end },
    { key = "line_spacing", y = 1001, levels = #Settings.LINE_SPACINGS, left = "紧", right = "松",
      label = function() return "行距" end },
    { key = "padding", y = 1080, levels = #Settings.PADDINGS, left = "小", right = "大",
      label = function() return "边距" end },
}
local FONT_GRID = { x = 38, y = 1234, w = 229, h = 75, dx = 240, dy = 86, cols = 5 }

function ReaderView:buildFontPanel(ops)
    local top = panelY(744)
    table.insert(ops, { "rect", 0, top, self.dimen.w, BottomBar.top() - top, Theme.WHITE })
    table.insert(ops, { "hline", 0, top, self.dimen.w, 2, Theme.LINE_GRAY })
    table.insert(ops, T(38, panelY(779), "字体设置", Theme.BOLD, 30))
    -- 右上角“首行顶格 / 首行缩进”：148×53 的圆角描边按钮，右边是箭头图标（官方截图实测）
    table.insert(ops, { "frame", 1078, panelY(767), 148, 53, 2, Theme.BLACK, 26 })
    table.insert(ops, T(1098, panelY(783), Settings.indentOn() and "首行缩进" or "首行顶格", Theme.BOLD, 23))
    table.insert(ops, { "image", 1200, panelY(781), Theme.res("icon_general_arrow.svg"), 15, 22 })
    for _, s in ipairs(SLIDERS) do
        local y = panelY(s.y)
        local v = Settings.get(s.key)
        -- 减号、加号按钮：60×60 圆框
        -- 笔画 4px 粗、18px 长（官方截图实测）
        table.insert(ops, { "frame", 38, y, 60, 60, 2, Theme.BLACK, 30 })
        table.insert(ops, { "rect", 59, y + 28, 18, 4, Theme.BLACK })
        table.insert(ops, { "frame", 1166, y, 60, 60, 2, Theme.BLACK, 30 })
        table.insert(ops, { "rect", 1187, y + 28, 18, 4, Theme.BLACK })
        table.insert(ops, { "rect", 1194, y + 19, 4, 18, Theme.BLACK })
        -- 滑轨（官方截图实测）：和两边的按钮一样高的 60px 全圆角粗条，灰底、已填充的部分黑色，
        -- 填充区里每个档位位置有一条 1px 的浅灰刻度线；滑块是和轨道同高 60px 的白色圆（2px 黑圈），里面写数字或“行距 / 边距”
        local bx, bw = 113, 1038
        local knob = bx + 30 + math.floor((bw - 60) * (v - 1) / (s.levels - 1))
        table.insert(ops, { "rrect", bx, y, bw, 60, Blitbuffer.Color8(187), 30 })
        -- 填充一直铺到滑块的右缘（藏在滑块下面）：滑块在最左边时填充是个 60 宽的圆头，方角不会露出来；
        -- 拉到最大时整条轨道全黑，滑块和轨道圆头之间差的那一个像素也不会漏出灰色
        table.insert(ops, { "rrect", bx, y, math.min(bw, math.max(knob - bx + 30, 60)), 60, Theme.BLACK, 30 })
        for k = 1, s.levels - 2 do
            local tx = bx + 30 + math.floor((bw - 60) * k / (s.levels - 1))
            if tx < knob - 30 then table.insert(ops, { "rect", tx, y, 1, 60, Blitbuffer.Color8(180) }) end
        end
        table.insert(ops, T(bx + 22, y + 18, s.left, Theme.BOLD, 26, Theme.WHITE))
        table.insert(ops, T(bx + bw - 22, y + 18, s.right, Theme.BOLD, 26, nil, nil, "right"))
        -- 滑块和轨道一样高（直径 60），中心从 bx+30 走到 bx+bw-30，所以拉到两端时正好贴住轨道的两个圆头
        table.insert(ops, { "rrect", knob - 30, y, 60, 60, Theme.BLACK, 30 })
        table.insert(ops, { "rrect", knob - 28, y + 2, 56, 56, Theme.WHITE, 28 })
        -- 两个字的标签（行距、边距）比数字宽，缩小一点，别顶到圆圈的黑边
        local label = s.label(v)
        local px = Canvas.textWidth(label, Theme.BOLD, 24) > 44 and 21 or 24
        table.insert(ops, T(knob, y + (px == 24 and 18 or 20), label, Theme.BOLD, px, nil, nil, "center"))
        s.bar = { x = bx, w = bw, y = y }
    end
    local current = self:fontSelected()
    table.insert(ops, T(38, panelY(1176), "当前选择 · " .. current.name, Theme.BOLD, 28))
    local entries = Fonts.entries()
    local more = #entries > FONT_GRID.cols * 3
    local count = more and FONT_GRID.cols * 3 - 1 or #entries
    for i = 1, count do
        local r, c = math.floor((i - 1) / FONT_GRID.cols), (i - 1) % FONT_GRID.cols
        self:buildFontCell(ops, FONT_GRID.x + c * FONT_GRID.dx, panelY(FONT_GRID.y) + r * FONT_GRID.dy, entries[i], current)
    end
    -- 最后一格：查看更多 ›
    if more then
        local x, y = FONT_GRID.x + 4 * FONT_GRID.dx, panelY(FONT_GRID.y) + 2 * FONT_GRID.dy
        table.insert(ops, { "rrect", x, y, FONT_GRID.w, FONT_GRID.h, Blitbuffer.Color8(187), 15 })
        table.insert(ops, T(x + FONT_GRID.w / 2, y + 23, "查看更多 ›", Theme.BOLD, 26, nil, nil, "center"))
    end
end

-- 界面上选中的字体：点了没下载的字体就立刻是它（下载中），设置要下载完才改
function ReaderView:fontSelected()
    return Fonts.byId(self.font_sel or Settings.font().id) or Settings.font()
end

-- 一个字体格（官方 reader_font_list_item + FontTypeAdapter）：灰底圆角，选中黑底；里面是预览图（用这个字体写的字体名），
-- 没有预览图的内置字体直接写字；下载中显示“下载中”和一层从左到右的进度
function ReaderView:buildFontCell(ops, x, y, e, current)
    local W, H = FONT_GRID.w, FONT_GRID.h
    local selected = e.id == current.id
    table.insert(ops, { "rrect", x, y, W, H, selected and Theme.BLACK or Blitbuffer.Color8(187), 15 })
    if e.downloading then
        local w = math.floor((W - 12) * (e.progress or 0) / 100)
        if w > 0 and not selected then table.insert(ops, { "rect", x + 6, y + 6, w, H - 12, Blitbuffer.Color8(165) }) end
        table.insert(ops, T(x + W / 2, y + 23, "下载中", Theme.BOLD, 26, selected and Theme.WHITE or nil, nil, "center"))
    elseif e.preview_n then
        local h = e.preview_h
        table.insert(ops, { "image", x + math.floor((W - e.preview_w) / 2), y + math.floor((H - h) / 2),
            selected and e.preview_s or e.preview_n, e.preview_w, h })
    else
        table.insert(ops, T(x + W / 2, y + 23, e.name, e.id == "system" and Theme.REGULAR or Theme.BOLD, 26,
            selected and Theme.WHITE or nil, W - 20, "center"))
    end
end

-- 点一个字体格：已下载的直接换；没下载的开始下载，下完（如果界面上还选着它）再换
function ReaderView:onFontCellTap(e)
    self.font_sel = e.id
    if Fonts.isReady(e) then
        if e.id ~= Settings.font().id then
            Settings.set("font", e.id)
            self:reflow()
        else
            self:redraw("ui")
        end
        return
    end
    if e.downloading then return end
    Fonts.download(e, function()
        if not self.closed and self.menu then self:redraw("ui") end
    end, function(_, ok)
        if self.closed then return end
        if ok then
            if self.font_sel == e.id then
                Settings.set("font", e.id)
                self:reflow()
            else
                self:redraw("ui")
            end
        else
            UIManager:show(InfoMessage:new{ text = "下载失败，请检查网络后重试", timeout = 2 })
            if self.font_sel == e.id then self.font_sel = nil end
            self:redraw("ui")
        end
    end)
    self:redraw("ui")
end

-- ---- 更多字体面板（官方 FontTypeSettingTable）----
-- 标题“字体”+“当前选择 · XX”，下面一排分类标签（全部 / 仓耳 / 方正 / 其他），再下面是该分类的所有字体，格子和字体面板一样
local MORE = { h = 791, header_h = 130, tab_h = 60, tab_gap = 15, grid_gap = 38 }

function ReaderView:moreFontGeom()
    local top = BottomBar.top() - MORE.h
    local tabs_y = top + 9 + MORE.header_h + MORE.tab_gap
    return top, tabs_y, tabs_y + MORE.tab_h + MORE.grid_gap
end

function ReaderView:buildMoreFontPanel(ops)
    local top, tabs_y, grid_y = self:moreFontGeom()
    local current = self:fontSelected()
    table.insert(ops, { "rect", 0, top, self.dimen.w, MORE.h, Theme.WHITE })
    table.insert(ops, { "hline", 0, top, self.dimen.w, 2, Theme.LINE_GRAY })
    -- 标题区：左边收起按钮，中间标题和当前选择
    table.insert(ops, { "image", 38, top + 9 + 38, Theme.res("icon_topbar_undeploy.svg"), 53, 53 })
    table.insert(ops, T(632, top + 9 + 30, "字体", Theme.BOLD, 30, nil, nil, "center"))
    table.insert(ops, T(632, top + 9 + 78, "当前选择 · " .. current.name, Theme.REGULAR, 22, Theme.HINT_GRAY, nil, "center"))
    -- 分类标签：圆角描边条，选中的一格是黑色药丸
    local tags = Fonts.tags()
    self.font_tag = math.min(self.font_tag or 1, #tags)
    table.insert(ops, { "frame", 38, tabs_y, 1188, MORE.tab_h, 2, Blitbuffer.Color8(191), MORE.tab_h / 2 })
    local tab_w = (1188 - 12) / #tags
    for i, tag in ipairs(tags) do
        local tx = 38 + 6 + (i - 1) * tab_w
        if i == self.font_tag then
            table.insert(ops, { "rrect", math.floor(tx), tabs_y + 6, math.floor(tab_w), MORE.tab_h - 12, Theme.BLACK, (MORE.tab_h - 12) / 2 })
        end
        table.insert(ops, T(tx + tab_w / 2, tabs_y + 17, tag.name, Theme.BOLD, 24, i == self.font_tag and Theme.WHITE or nil, nil, "center"))
    end
    for i, e in ipairs(tags[self.font_tag].fonts) do
        local r, c = math.floor((i - 1) / FONT_GRID.cols), (i - 1) % FONT_GRID.cols
        self:buildFontCell(ops, FONT_GRID.x + c * FONT_GRID.dx, grid_y + r * FONT_GRID.dy, e, current)
    end
end

function ReaderView:onMoreFontTap(pos)
    local top, tabs_y, grid_y = self:moreFontGeom()
    if pos.y < top or (pos.y < top + 9 + MORE.header_h and pos.x < 200) then
        self.menu = "font"
        self:redraw()
        return true
    end
    local tags = Fonts.tags()
    if pos.y >= tabs_y and pos.y < tabs_y + MORE.tab_h and pos.x >= 38 and pos.x < 1226 then
        local i = math.floor((pos.x - 44) / ((1188 - 12) / #tags)) + 1
        if tags[i] and i ~= self.font_tag then
            self.font_tag = i
            self:redraw("ui")
        end
        return true
    end
    if pos.y >= grid_y then
        local c = math.floor((pos.x - FONT_GRID.x) / FONT_GRID.dx)
        local r = math.floor((pos.y - grid_y) / FONT_GRID.dy)
        local e = c >= 0 and c < FONT_GRID.cols and tags[self.font_tag or 1].fonts[r * FONT_GRID.cols + c + 1]
        if e then self:onFontCellTap(e) end
    end
    return true
end

function ReaderView:redraw(mode)
    self:buildOverlay()
    UIManager:setDirty(self, mode or "ui")
end

-- ---- 打开书、切章 ----

-- 打开：有本地缓存就先用缓存直接开（不等网络），同时在子进程里取最新的书籍信息、笔记、进度；
-- 没有缓存（第一次打开）才等网络，但等的时候界面不卡，能点返回
function ReaderView:open()
    self.status = "正在打开《" .. self.book.title .. "》…"
    self:redraw("full")
    UIManager:nextTick(function()
        ensureEngine()
        self.bk = Book.open(self.book)
        local cached = self.bk:loadCache()
        local book_id = self.book.bookId
        local function start(server)
            local pos = self.bk:loadPosition()
            local server_index = server and server.chapterUid and self.bk.index_of[server.chapterUid]
            local local_ok = pos and self.bk:chapter(pos.index)
            self.status = nil
            if server_index and (not local_ok or (server.updateTime or 0) > (pos.time or 0)) then
                local ch = self.bk:chapter(server_index)
                local frac = (ch.wordCount or 0) > 0 and (server.chapterOffset or 0) / ch.wordCount or 0
                self:loadChapter(server_index, { fraction = frac })
            elseif local_ok then
                self:loadChapter(pos.index, { xpointer = pos.xpointer })
            else
                self:loadChapter(1)
            end
            if self.on_opened then self.on_opened() end
        end
        Async.run(function() return Book.fetchFresh(book_id) end, function(res)
            if self.closed or not self.bk then return end
            res = res or {}
            self.reading_time = res.read_info and res.read_info.readingTime
            self.card = res.card
            if cached then
                -- 已经按缓存打开了：换上新数据；别的设备上读得更靠后、而本机还没动过，就跳过去
                local notes_changed = self.bk:applyFresh(res)
                local server = res.progress
                local idx = server and server.chapterUid and self.bk.index_of[server.chapterUid]
                local pos = self.bk:loadPosition()
                if idx and not self.interacted and (server.updateTime or 0) > ((pos and pos.time) or 0) and idx ~= self.index then
                    local ch = self.bk:chapter(idx)
                    local frac = (ch.wordCount or 0) > 0 and (server.chapterOffset or 0) / ch.wordCount or 0
                    self:loadChapter(idx, { fraction = frac })
                elseif notes_changed and self.doc and not self.interacted then
                    self.bk:invalidateChapter(self.index)
                    self:loadChapter(self.index, { page = self.page })
                end
            else
                local ok, err = self.bk:loadFresh(res)
                if not ok then
                    self.status = err or "打开失败"
                    self:redraw()
                    UIManager:scheduleIn(3, function() self:close() end)
                    return
                end
                start(res.progress)
            end
        end)
        if cached then start(nil) end
    end)
end

-- 打开第 i 章。opts.at_end：停在最后一页（往回翻时）；opts.xpointer：停在这个位置
function ReaderView:loadChapter(i, opts)
    opts = opts or {}
    if not self.bk:chapter(i) then
        UIManager:show(InfoMessage:new{ text = i < 1 and "已经是第一页" or "已经是最后一页", timeout = 1 })
        return false
    end
    local info
    if not self.bk:isCached(i) and not opts.fetched then
        -- 下载在子进程里做，网络慢也不会把界面卡死；下完再回来接着开这一章
        if self.fetching then return false end
        self.fetching = true
        local had_doc = self.doc ~= nil
        if not had_doc then
            -- 刚打开书、还没有页面：用状态文字（能点返回取消）；已经在读的时候用提示框
            self.status = "正在下载《" .. self.bk:chapter(i).title .. "》…"
            self:redraw("ui")
        else
            info = InfoMessage:new{ text = "正在下载《" .. self.bk:chapter(i).title .. "》…" }
            UIManager:show(info)
        end
        local bk = self.bk
        Async.run(function()
            bk:ensureChapter(i)
            return true
        end, function()
            self.fetching = false
            if info then UIManager:close(info) end
            if self.closed then return end
            self.status = nil
            opts.fetched = true
            self:loadChapter(i, opts)
        end)
        return true
    end
    local epub, err, kind, lock = self.bk:ensureChapter(i)
    -- 没买的付费章节：显示试读，最后一页底部是购买面板（和官方一样）
    self.locked = kind == "locked" and lock or nil
    if not epub then
        local text = kind == "unavailable" and "《" .. self.bk:chapter(i).title .. "》需要购买，请在手机微信读书里购买后再读"
            or "这一章暂时读不了：" .. tostring(err)
        UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
        -- 刚打开书就停在读不了的章节（比如手机上读到了还没买的章）：退回上一章末尾，至少能接着读已解锁的部分
        if not self.doc then
            if kind == "unavailable" and i > 1 and (opts.fallbacks or 0) < 5 then
                return self:loadChapter(i - 1, { at_end = true, fallbacks = (opts.fallbacks or 0) + 1 })
            end
            UIManager:scheduleIn(3, function() self:close() end)
        end
        return false
    end

    -- 经 DocumentRegistry 打开，close() 时才能正常注销。注册表按路径缓存打开的文档：
    -- 同一章重新打包后（笔记、显示设置变了）要先关掉旧的，不然拿回来的还是旧内容
    if self.doc and self.doc.file == epub then
        self.doc:close()
        self.doc = nil
    end
    local doc = DocumentRegistry:openDocument(epub, DocumentRegistry:getProvider(epub))
    doc:setupDefaultView()
    doc:loadDocument()
    doc:setStatusLineProp(1)
    Settings.apply(doc, self.dimen, PAGE_TOP, self.locked and LOCKED_BOTTOM or PAGE_BOTTOM)
    doc:render()
    if self.doc then self.doc:close() end
    self.doc, self.index = doc, i
    self.bk:notePageCount(i, doc:getPageCount())
    self:computeMarks()

    if opts.at_end then
        self.page = doc:getPageCount()
    elseif opts.xpointer and doc:isXPointerInDocument(opts.xpointer) then
        self.page = doc:getPageFromXPointer(opts.xpointer)
    elseif opts.page then
        self.page = math.max(1, math.min(doc:getPageCount(), opts.page))
    elseif opts.fraction then
        self.page = math.max(1, math.min(doc:getPageCount(), math.floor(opts.fraction * doc:getPageCount()) + 1))
    else
        self.page = 1
    end
    self:showPage("full")
    return true
end

-- 改了字号/字体等设置后重排，尽量停在同一段文字上
function ReaderView:reflow()
    if not self.doc then return end
    local xp = self.doc:getPageXPointer(self.page)
    Settings.apply(self.doc, self.dimen, PAGE_TOP, self.locked and LOCKED_BOTTOM or PAGE_BOTTOM)
    self.doc:render()
    self.bk:notePageCount(self.index, self.doc:getPageCount())
    self.page = xp and self.doc:getPageFromXPointer(xp) or 1
    self:computeMarks()
    self:redraw("full")
end

-- 读到章末附近时把下一章先下好，翻过去不用等
function ReaderView:prefetchNext()
    local nxt = self.index + 1
    if self.prefetching or not self.bk:chapter(nxt) or self.bk:isCached(nxt) or self.bk:mayNeedPay(nxt) then return end
    self.prefetching = true
    -- 下载下一章放在子进程里，翻到章末也不卡
    UIManager:scheduleIn(1, function()
        local bk = self.bk
        Async.run(function()
            local ok, err = pcall(bk.ensureChapter, bk, nxt)
            if not ok then logger.warn("weread: prefetch failed", err) end
            return ok
        end, function() self.prefetching = false end)
    end)
end

function ReaderView:showPage(refresh)
    self.turns = self.turns + 1
    self:tickReadingTime()
    if not refresh then
        refresh = (self.turns % FULL_REFRESH_EVERY == 0) and "full" or "ui"
    end
    self:redraw(refresh)
    self.bk:savePosition(self.index, self.doc:getPageXPointer(self.page))
    if self.page >= self.doc:getPageCount() - 1 then self:prefetchNext() end
    -- 停在一页上超过 REPORT_DELAY 秒才上报，连续翻页时不频繁请求
    if self.report_task then UIManager:unschedule(self.report_task) end
    self.report_task = function()
        self.report_task = nil
        self:reportProgress()
    end
    UIManager:scheduleIn(REPORT_DELAY, self.report_task)
end

-- 阅读计时，和官方 ProgressReportStrategy 一样：每次翻页（或在菜单里操作）时，把距上次操作的时间
-- 计入当前小时的桶；两次操作之间最多计 MaxReadingTime 秒（服务端配置，默认 130），走开了不会一直算
function ReaderView:tickReadingTime()
    local now = os.time()
    if self.last_active then
        local secs = math.min(now - self.last_active, Direct.maxReadingTime())
        if secs > 0 then
            local start = Direct.hourStart(now)
            self.hours = self.hours or {}
            local bucket
            for _, h in ipairs(self.hours) do
                if h.startOfHour == start then bucket = h end
            end
            if not bucket then
                bucket = { startOfHour = start, timeZone = Direct.timeZone(), readingTime = 0, ttsTime = 0 }
                table.insert(self.hours, bucket)
            end
            bucket.readingTime = bucket.readingTime + secs
            self.reading_time = (self.reading_time or 0) + secs
        end
    end
    self.last_active = now
end

-- 把当前位置和这段时间的阅读时长报给服务端（章内偏移按页数比例折算成字数）；成功后清零时长
function ReaderView:reportProgress()
    if not self.doc or not self.bk or self:inPreview() then return end
    local ch = self.bk:chapter(self.index)
    local offset = math.floor((ch.wordCount or 0) * (self.page - 1) / math.max(self.doc:getPageCount(), 1))
    local hours, total = self.hours or {}, 0
    for _, h in ipairs(hours) do total = total + h.readingTime end
    -- 上报放在子进程里，期间新攒的阅读时长另记；失败了把这批放回去下次再报
    local book_id, version, uid, idx, percent, title = self.book.bookId, self.bk.info.version, ch.chapterUid,
        ch.chapterIdx or self.index, self:bookPercent(), ch.title
    self.hours = {}
    Async.run(function()
        local ok, res = pcall(Direct.reportProgress, book_id, version, uid, idx, offset, percent, title, total, hours)
        return ok and res and true or nil
    end, function(done)
        if done then return end
        logger.warn("weread: report progress failed")
        local merged = {}
        for _, h in ipairs(hours) do merged[#merged + 1] = h end
        for _, h in ipairs(self.hours or {}) do merged[#merged + 1] = h end
        self.hours = merged
    end)
end

function ReaderView:turn(delta)
    self.interacted = true
    if not self.doc then return true end
    local target = self.page + delta
    if target >= 1 and target <= self.doc:getPageCount() then
        self.page = target
        self:showPage()
    elseif delta > 0 then
        self:loadChapter(self.index + 1)
    elseif self.preview and self.index <= 1 and self.on_front then
        -- 预览模式：正文第一页再往回翻，回到简介页
        self.on_front(self)
    else
        self:loadChapter(self.index - 1, { at_end = true })
    end
    return true
end

function ReaderView:onNextPage()
    if self.menu then return true end
    return self:turn(1)
end

function ReaderView:onPrevPage()
    if self.menu then return true end
    return self:turn(-1)
end

-- ---- 进度、书签 ----

function ReaderView:bookPercent()
    return self.bk:progressPercent(self.index, self.page, self.doc:getPageCount())
end

-- 当前页上的书签（及其序号），没有返回 nil
function ReaderView:currentBookmark()
    if not self.doc or not self.bk then return nil end
    for i, bm in ipairs(self.bk:bookmarks()) do
        if bm.index == self.index and self.doc:isXPointerInDocument(bm.xpointer)
            and self.doc:getPageFromXPointer(bm.xpointer) == self.page then
            return bm, i
        end
    end
    return nil
end

function ReaderView:toggleBookmark()
    local bm, i = self:currentBookmark()
    if bm then
        if bm.bookmarkId then Direct.removeBookmark(bm.bookmarkId) end
        self.bk:removeBookmark(i)
        UIManager:show(InfoMessage:new{ text = "已删除书签", timeout = 1 })
    else
        local xp = self.doc:getPageXPointer(self.page)
        local next_xp = self.page < self.doc:getPageCount() and self.doc:getPageXPointer(self.page + 1) or nil
        local text = (next_xp and self.doc:getTextFromXPointers(xp, next_xp)) or ""
        -- 按字符截断，免得切开汉字
        text = text:gsub("%s+", " ")
        local cut, n = 0, 0
        for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            if n >= 60 then break end
            n, cut = n + 1, cut + #c
        end
        text = text:sub(1, cut)
        -- 同步到服务端：range 是这一页开头在原文里的字符位置（用开头一小段文字反查）
        local ch = self.bk:chapter(self.index)
        local head = text:gsub("%s+", ""):match("^" .. ("[%z\1-\127\194-\244][\128-\191]*"):rep(12))
        local range = head and self.bk:findRange(self.index, head, self:chapterFraction())
        local bookmark_id = range and Direct.addPageBookmark(self.book.bookId, ch.chapterUid,
            tonumber(range:match("^(%d+)")), text, self.bk.info.version)
        self.bk:addBookmark{
            index = self.index, xpointer = xp, title = ch.title, bookmarkId = bookmark_id,
            text = text, percent = self:bookPercent(), time = os.time(),
        }
        UIManager:show(InfoMessage:new{ text = "已添加书签", timeout = 1 })
    end
    self:redraw()
end

-- ---- 自动翻页、整本下载 ----

function ReaderView:toggleAutoTurn()
    if self.auto_timer then
        UIManager:unschedule(self.auto_timer)
        self.auto_timer = nil
    else
        self.auto_timer = function()
            self:turn(1)
            UIManager:scheduleIn(AUTO_TURN_SECONDS, self.auto_timer)
        end
        UIManager:scheduleIn(AUTO_TURN_SECONDS, self.auto_timer)
        self.menu = nil
        UIManager:show(InfoMessage:new{ text = string.format("已开启自动翻页，每 %d 秒翻一页，点屏幕停止", AUTO_TURN_SECONDS), timeout = 2 })
    end
    self:redraw()
end

-- 后台整本下载；没买的付费章节跳过（只能拿到试读）
function ReaderView:downloadAll()
    if self.bk:allCached() then
        UIManager:show(InfoMessage:new{ text = "全书已下载", timeout = 1 })
        return
    end
    local i, skipped = 0, 0
    local msg
    local function step()
        if self.closed then return end
        i = i + 1
        if msg then UIManager:close(msg) msg = nil end
        if not self.bk:chapter(i) then
            local text = skipped > 0 and string.format("下载完成，%d 章付费章节未下载", skipped) or "全书已下载"
            UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
            self:redraw()
            return
        end
        if not self.bk:isCached(i) then
            if self.bk:mayNeedPay(i) then
                skipped = skipped + 1
            else
                msg = InfoMessage:new{ text = string.format("正在下载 %d / %d", i, self.bk:chapterCount()) }
                UIManager:show(msg)
                UIManager:forceRePaint()
                self.bk:ensureChapter(i)
            end
        end
        UIManager:scheduleIn(0.05, step)
    end
    step()
end

-- ---- 触摸 ----

local function inside(pos, x, y, w, h)
    return pos.x >= x and pos.x < x + w and pos.y >= y and pos.y < y + h
end

function ReaderView:onTap(pos)
    self.interacted = true
    if not self.doc then
        -- 正在打开 / 下载的时候，点左上角的返回可以取消
        if self.status and pos.x < 140 and pos.y < 130 then self:close() end
        return true
    end
    self:tickReadingTime()
    if self.auto_timer then
        self:toggleAutoTurn()
        return true
    end
    if not self.menu then
        if self.locked and self.page == self.doc:getPageCount() and pos.y >= BUY.member_y - 20 then
            return self:onBuyPanelTap(pos)
        end
        if self.sel then
            if not self:onQuickMenuTap(pos) then self:clearSelection() end
            return true
        end
        if pos.x < 140 and pos.y < 130 then
            self:close()
        elseif self:joinButton() and inside(pos, JOIN.x, JOIN.y, JOIN.w, JOIN.h) then
            self:addToShelf()
        elseif self:handleNoteTap(pos) then
            return true
        elseif pos.x > self.dimen.w * 0.3 and pos.x < self.dimen.w * 0.7
            and pos.y > self.dimen.h * 0.25 and pos.y < self.dimen.h * 0.75 then
            self.menu = "menu"
            self:redraw()
        elseif pos.x < self.dimen.w * 0.3 then
            -- 设置里“点击左侧翻到下一页”打开时，左侧也是下一页（单手拿书时方便）
            self:turn(G_reader_settings:isTrue("weread_tap_left_next") and 1 or -1)
        else
            self:turn(1)
        end
        return true
    end

    -- 菜单打开时
    if self.menu == "indent" then return self:onIndentTap(pos) end
    if self.menu == "reviews" and not (pos.y < TOP_BAR_H and pos.x >= 716 and pos.x < 849) then
        return self:onReviewsPanelTap(pos)
    end
    if pos.y < TOP_BAR_H then
        for _, it in ipairs(TOP_ICONS) do
            if pos.x >= it.x - 40 and pos.x < it.x + 93 then return self:onTopAction(it.id) end
        end
        return true
    end
    if pos.y >= BottomBar.top() then
        for _, b in ipairs(BOTTOM_BUTTONS) do
            if pos.x >= b.x0 and pos.x < b.x1 then return self:onBottomAction(b.id) end
        end
        return true
    end
    if self.menu == "progress" and pos.y >= panelY(1122) then return self:onProgressPanelTap(pos) end
    if self.menu == "font" and pos.y >= panelY(744) then return self:onFontPanelTap(pos) end
    if self.menu == "morefont" then return self:onMoreFontTap(pos) end
    -- 点在正文上：收起菜单
    self.menu = nil
    self:redraw()
    return true
end

function ReaderView:onTopAction(id)
    if id == "bookmark" then
        self:toggleBookmark()
    elseif id == "download" then
        self:downloadAll()
    elseif id == "shelf" then
        if self:inPreview() then
            self:addToShelf()
        else
            UIManager:show(InfoMessage:new{ text = "已在书架", timeout = 1 })
        end
    elseif id == "review" then
        self:showReviewMenu()
    elseif id == "graffiti" then
        UIManager:show(InfoMessage:new{ text = "涂鸦稍后支持", timeout = 2 })
    end
    return true
end

function ReaderView:onBottomAction(id)
    if id == "back" then
        self:close()
    elseif id == "toc" then
        self:openToc()
    elseif id == "progress" or id == "font" then
        self.menu = self.menu == id and "menu" or id
        self:redraw()
    elseif id == "note" then
        self:openNotes()
    elseif id == "tts" then
        UIManager:show(InfoMessage:new{ text = "听书稍后支持", timeout = 2 })
    end
    return true
end

function ReaderView:onProgressPanelTap(pos)
    local bar, auto = self.progress_bar, self.auto_button
    if bar and inside(pos, bar.x, bar.y - 20, bar.w, bar.h + 40) then
        local frac = math.max(0, math.min(1, (pos.x - bar.x - 32) / (bar.w - 64)))
        local index = self.bk:chapterAtPercent(frac * 100)
        self.menu = nil
        self:loadChapter(index)
    elseif auto and inside(pos, auto.x, auto.y, auto.w, auto.h) then
        self:toggleAutoTurn()
    end
    return true
end

function ReaderView:onFontPanelTap(pos)
    for _, s in ipairs(SLIDERS) do
        local b = s.bar
        if b and pos.y >= b.y - 6 and pos.y < b.y + 66 then
            local v = Settings.get(s.key)
            if pos.x < 105 then
                v = v - 1
            elseif pos.x > 1158 then
                v = v + 1
            else
                v = 1 + math.floor((pos.x - b.x - 30) / (b.w - 60) * (s.levels - 1) + 0.5)
            end
            v = math.max(1, math.min(s.levels, v))
            if v ~= Settings.get(s.key) then
                Settings.set(s.key, v)
                self:reflow()
            end
            return true
        end
    end
    local gy = panelY(FONT_GRID.y)
    if pos.y >= gy and pos.x >= FONT_GRID.x then
        local c = math.floor((pos.x - FONT_GRID.x) / FONT_GRID.dx)
        local r = math.floor((pos.y - gy) / FONT_GRID.dy)
        local i = r * FONT_GRID.cols + c + 1
        local entries = Fonts.entries()
        local more = #entries > FONT_GRID.cols * 3
        if more and i == FONT_GRID.cols * 3 then
            self.menu = "morefont"
            self.font_tag = 1
            self:redraw()
            -- 字体清单有更新就补上（阻塞约 1 秒，只在这里更新一次）
            if not Fonts.refreshed then
                Fonts.refreshed = true
                UIManager:nextTick(function()
                    if Fonts.refresh() and self.menu == "morefont" then self:redraw("ui") end
                end)
            end
        elseif entries[i] and c >= 0 and c < FONT_GRID.cols then
            self:onFontCellTap(entries[i])
        end
        return true
    end
    if pos.y < panelY(830) and pos.x > 1000 then
        self.menu = "indent"
        self:redraw()
    end
    return true
end

-- ---- 首行缩进面板（官方 ReaderIndentFirstLineSettingTable，尺寸 dp × 1.875）----
-- 底部栏上方一块白底：左右两个大按钮“首行顶格 / 首行缩进”（选中黑底白字），缩进按钮里还有“段间距”开关；
-- 底部栏只剩返回；点面板上方的空白也是返回（回到字体面板）
local INDENT = { h = 326, pad = 38, bx = 38, bw = 585, gap = 19, bh = 251, r = 22 }
local PARA_LABEL_PX = 26

function ReaderView:indentGeom()
    local top = BottomBar.top() - INDENT.h
    local by = top + INDENT.pad
    local label_w = Canvas.textWidth("段间距", Theme.REGULAR, PARA_LABEL_PX)
    local rx = INDENT.bx + INDENT.bw + INDENT.gap
    -- 开关：标签右边的 94×60 视图，里面的图标四周留 15
    local sw = { x = rx + 30 + label_w, y = by + INDENT.bh - 66, w = 94, h = 60 }
    return top, by, rx, sw
end

function ReaderView:buildIndentPanel(ops)
    local top, by, rx, sw = self:indentGeom()
    local indent, space = Settings.indentOn(), Settings.paraSpaceOn()
    table.insert(ops, { "rect", 0, top, self.dimen.w, INDENT.h, Theme.WHITE })
    table.insert(ops, { "hline", 0, top, self.dimen.w, 2, Theme.LINE_GRAY })
    local buttons = {
        { x = INDENT.bx, on = not indent, icon = "icon_reader_no_indent", label = "首行顶格" },
        { x = rx, on = indent, icon = "icon_reader_indent", label = "首行缩进" },
    }
    for _, b in ipairs(buttons) do
        -- 选中：黑底白字白图标；没选中：10% 黑底黑字（#1A000000 叠在白底上约 229 灰）
        table.insert(ops, { "rrect", b.x, by, INDENT.bw, INDENT.bh, b.on and Theme.BLACK or Blitbuffer.Color8(229), INDENT.r })
        table.insert(ops, { "image", b.x + 30, by + 30, Theme.res(b.icon .. (b.on and "_white" or "") .. ".svg"), 45, 45 })
        table.insert(ops, T(b.x + 30, by + 98, b.label, Theme.BOLD, 28, b.on and Theme.WHITE or nil))
    end
    -- 段间距开关：缩进选中时可点（白底黑点），没选中时是灰的
    local color = indent and Theme.WHITE or nil
    table.insert(ops, T(rx + 30, by + INDENT.bh - 36 - 14, "段间距", Theme.REGULAR, PARA_LABEL_PX, color))
    local sw_icon = (indent and "icon_select_switch_" or "icon_unselect_switch_") .. (space and "on" or "off") .. ".svg"
    table.insert(ops, { "image", sw.x + 15, sw.y + 15, Theme.res(sw_icon), space and 64 or 60, 30 })
    -- 底部栏：只有返回
    local y0 = BottomBar.top()
    table.insert(ops, { "rect", 0, y0, self.dimen.w, BottomBar.HEIGHT, Theme.WHITE })
    table.insert(ops, { "hline", 0, y0, self.dimen.w, 2, Theme.LINE_GRAY })
    table.insert(ops, { "vline", 159, y0 + 31, 46, 1, Theme.LINE_GRAY })
    table.insert(ops, { "image", math.floor((0 + 141 - 53) / 2), y0 + 26, Theme.res("icon_toolbar_back.svg"), 53, 53 })
end

-- 设置存在本地，也同步到账号（官方 AccountService.updateConfigs → POST /updateConfig）
local function syncAccountConfig(config)
    UIManager:nextTick(function()
        local ok, err = pcall(Direct.api, "POST", "/updateConfig", nil, config)
        if not ok then logger.warn("weread: updateConfig failed", err) end
    end)
end

function ReaderView:onIndentTap(pos)
    local top, by, rx, sw = self:indentGeom()
    if pos.y >= BottomBar.top() then
        if pos.x < 160 then
            self.menu = "font"
            self:redraw()
        end
        return true
    end
    if pos.y < top then
        self.menu = "font"
        self:redraw()
        return true
    end
    if pos.y < by or pos.y >= by + INDENT.bh then return true end
    local indent = Settings.indentOn()
    if pos.x >= INDENT.bx and pos.x < INDENT.bx + INDENT.bw then
        if indent then
            G_reader_settings:saveSetting("weread_indent", false)
            G_reader_settings:flush()
            self:reflow()
            syncAccountConfig{ indentFirstLine = false }
        end
    elseif pos.x >= rx and pos.x < rx + INDENT.bw then
        if inside(pos, sw.x - 10, sw.y - 10, sw.w + 20, sw.h + 20) then
            -- 开关只在“首行缩进”选中时可点
            if indent then
                local on = not Settings.paraSpaceOn()
                G_reader_settings:saveSetting("weread_para_space", on)
                G_reader_settings:flush()
                self:reflow()
                syncAccountConfig{ paragraphSpaceEnabled = on }
            end
        elseif not indent then
            G_reader_settings:saveSetting("weread_indent", true)
            G_reader_settings:flush()
            self:reflow()
            syncAccountConfig{ indentFirstLine = true }
        end
    end
    return true
end

function ReaderView:openToc()
    local toc = TocView:new{
        book = self.bk,
        current = self.index,
        bookmarks = self.bk:allBookmarks(),
        page_of = function(i) return self.bk:estimatedPage(i) end,
        on_select = function(index, xpointer, fraction)
            self.menu = nil
            if index == self.index and xpointer and self.doc:isXPointerInDocument(xpointer) then
                self.page = self.doc:getPageFromXPointer(xpointer)
                self:showPage("full")
            else
                self:loadChapter(index, { xpointer = xpointer, fraction = fraction })
            end
        end,
        on_back = function() self:redraw("full") end,
    }
    UIManager:show(toc, "full")
    toc:open()
end

-- 顶部“书评和想法”气泡（官方 ReaderTopBookmarkView，坐标取自 ref/official/47-reader-reviews.xml）：
-- 左“书评 N 条”、右“热门划线 N 条”，下面“隐藏 / 显示书友想法”按钮；顶上小三角指着图标
local REVIEWS = {
    box = { 625, 161, 513, 326 }, arrow_x = 782, arrow_top = 148,
    left = { 625, 881 }, right = { 882, 1138 }, items_bottom = 357,
    button = { 655, 375, 453, 82 },
}

-- 官方 ReaderTopBookMarkItem.render：超过 1 万显示“14.1 万条”（整数时不带 .0），否则原数
local function countText(n)
    n = math.max(0, n or 0)
    if n > 10000 then
        local r = math.floor(n / 1000 + 0.5)
        return (r % 10 == 0) and tostring(math.floor(r / 10)) or string.format("%.1f", r / 10), "万条"
    end
    return tostring(n), "条"
end

function ReaderView:showReviewMenu()
    if self.menu == "reviews" then
        self.menu = "menu"
        return self:redraw()
    end
    -- 书评数：书信息里的 newRatingCount；热门划线数：官方是本地同步到的全书热门划线条数（最多 500）
    if not self.hot_total then
        local _, _, total = Direct.bestBookmarks(self.book.bookId, 0, 1)
        self.hot_total = math.min(total or 0, 500)
    end
    self.menu = "reviews"
    self:redraw()
end

function ReaderView:buildReviewsPanel(ops)
    local R = REVIEWS
    local x, y, w, h = unpack(R.box)
    table.insert(ops, { "rrect", x, y, w, h, Theme.WHITE, 30 })
    table.insert(ops, { "frame", x, y, w, h, 2, Theme.BLACK, 30 })
    -- 小三角：白底盖住边框，两条斜边 2px
    for yy = R.arrow_top, y + 1 do
        local hw = yy - R.arrow_top
        table.insert(ops, { "rect", R.arrow_x - hw, yy, 2 * hw + 1, 1, Theme.WHITE })
        table.insert(ops, { "rect", R.arrow_x - hw - 1, yy, 2, 1, Theme.BLACK })
        table.insert(ops, { "rect", R.arrow_x + hw, yy, 2, 1, Theme.BLACK })
    end
    local function item(x0, title, n)
        local num, unit = countText(n)
        -- 纵向位置按官方截图的墨迹对齐（WeReadLS 的字框和思源黑体不同）
        table.insert(ops, T(x0, 223, title, Theme.BOLD, 28))
        local nw = Canvas.textWidth(num, Theme.DIN_BOLD, 52)
        table.insert(ops, T(x0, 279, num, Theme.DIN_BOLD, 52))
        table.insert(ops, T(x0 + nw, 296, unit, Theme.BOLD, 28))
        local uw = Canvas.textWidth(unit, Theme.BOLD, 28)
        table.insert(ops, { "image", x0 + nw + uw, 303, Theme.res("me_chevron.png"), 15, 23 })
    end
    item(681, "书评", self.bk.info and self.bk.info.newRatingCount)
    table.insert(ops, { "vline", 881, 216, 105, 1, Theme.LINE_GRAY })
    item(938, "热门划线", self.hot_total)
    local bx, by, bw, bh = unpack(R.button)
    table.insert(ops, { "frame", bx, by, bw, bh, 1, Theme.LINE_GRAY, 22 })
    table.insert(ops, T(bx + bw / 2, by + 24, self.bk:showHot() and "隐藏书友想法" or "显示书友想法", Theme.BOLD, 28, nil, nil, "center"))
end

-- 点气泡：左右两栏打开列表，按钮切换显示 / 隐藏书友想法；点在气泡外收起整个菜单（官方 ReaderActionFrame.reset）
function ReaderView:onReviewsPanelTap(pos)
    local R = REVIEWS
    local x, y, w = unpack(R.box)
    if pos.y >= y and pos.y < R.items_bottom then
        if pos.x >= R.left[1] and pos.x < R.left[2] then self.menu = nil; return self:openBookReviews() end
        if pos.x >= R.right[1] and pos.x < R.right[2] then self.menu = nil; return self:openHotUnderlines() end
    end
    local bx, by, bw, bh = unpack(R.button)
    if inside(pos, bx, by, bw, bh) then
        self.bk:setShowHot(not self.bk:showHot())
        self.menu = nil
        self:computeMarks()
        return self:redraw("full")
    end
    self.menu = nil
    self:redraw()
    return true
end

local function openList(self, view)
    view.on_back = function() self:redraw("full") end
    UIManager:show(view, "full")
    view:refresh()
    UIManager:nextTick(function() view:load() end)
    return true
end

function ReaderView:openBookReviews()
    local TextListView = require("weread/textlistview")
    local book_id = self.book.bookId
    return openList(self, TextListView:new{ title = "书评", fetch = function(offset)
        local list, more = Direct.bookReviews(book_id, offset, 10)
        local items = {}
        for _, r in ipairs(list) do
            items[#items + 1] = { head = r.author, body = r.content, meta = r.likes > 0 and (r.likes .. " 赞") or nil }
        end
        return items, more
    end })
end

function ReaderView:openHotUnderlines()
    local TextListView = require("weread/textlistview")
    local book_id = self.book.bookId
    return openList(self, TextListView:new{ title = "热门划线", body_lines = 4, fetch = function(offset)
        local list, more = Direct.bestBookmarks(book_id, offset, 20)
        local items = {}
        for _, m in ipairs(list) do
            local index = self.bk.index_of[m.chapterUid]
            items[#items + 1] = {
                body = m.text, meta = string.format("%d 人划线 · %s", m.count or 0, index and self.bk:chapter(index).title or ""),
                on_tap = index and function()
                    local a = tonumber((m.range or ""):match("^(%d+)")) or 0
                    local src = self.bk:chapterSource(index)
                    local chars = src and select(2, src:gsub("[^\128-\191]", "")) or 0
                    self:loadChapter(index, { fraction = chars > 0 and a / chars or 0 })
                end,
            }
        end
        return items, more
    end })
end

-- 笔记列表：按章节列出我的划线和想法，点一条跳过去
function ReaderView:openNotes()
    local NotesView = require("weread/notesview")
    local view = NotesView:new{
        bk = self.bk,
        on_select = function(index, frac)
            self.menu = nil
            self:loadChapter(index, { fraction = frac })
        end,
        on_back = function() self:redraw("full") end,
    }
    UIManager:show(view, "full")
    view:refresh()
end

-- ---- 关闭 ----

-- ---- 预览模式（从书城点进来、还没加书架的书）----
-- 官方的书籍介绍就是预览阅读器：翻完封面信息页、简介页进入正文，不记阅读进度；正文第一章“版权信息”页尾有
-- “加入书架 随时阅读”按钮，加入后就是正常的书了

function ReaderView:inPreview()
    return self.preview and not self.added
end

function ReaderView:addToShelf()
    local ok = Direct.addToShelf(self.book.bookId)
    if ok then self.added = true end
    UIManager:show(InfoMessage:new{ text = ok and "已加入书架" or "加入书架失败", timeout = 1 })
    self:redraw()
end

-- 当前页是版权信息页时返回按钮的位置，否则 nil
function ReaderView:joinButton()
    if not self:inPreview() or self.menu or not self.bk or not self.bk.info or self.page ~= 1 then return nil end
    local ch = self.bk:chapter(self.index)
    for _, uid in ipairs(self.bk.info.copyrightChapterUids or {}) do
        if ch and uid == ch.chapterUid then return JOIN end
    end
end

function ReaderView:closeDoc()
    if self.auto_timer then
        UIManager:unschedule(self.auto_timer)
        self.auto_timer = nil
    end
    if self.report_task then
        UIManager:unschedule(self.report_task)
        self.report_task = nil
    end
    if self.doc then
        self.bk:savePosition(self.index, self.doc:getPageXPointer(self.page))
        self:tickReadingTime()
        if not self:inPreview() then self:reportProgress() end
        self.doc:close()
        self.doc = nil
    end
end

function ReaderView:close()
    self.closed = true
    self:closeDoc()
    UIManager:close(self, "full")
    if self.on_close then self.on_close() end
end

function ReaderView:onCloseWidget()
    self.closed = true
end

-- 唤醒时系统状态栏会在屏幕顶上重画一次电量，等它画完再整屏重画盖掉
function ReaderView:onResume()
    UIManager:scheduleIn(2, function() UIManager:setDirty(self, "full") end)
end

ReaderNotes.mixin(ReaderView)

return ReaderView
