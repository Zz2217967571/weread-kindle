-- 阅读页里的笔记交互，混入 ReaderView：
--   长按选中一个词，按住拖动扩大选区，松手后弹出“划线 / 写想法 / 取消”；
--   点划线：自己的可以删除、写想法；想法显示内容、可删除；热门划线弹出“N 人划线”和书友在这句话上的想法。
-- 划线位置（range）由 Book:findRange 从选中的文字反查；显示时由 computeMarks / markOps 在正文上叠画。
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local ConfirmBox = require("ui/widget/confirmbox")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local rapidjson = require("rapidjson")

local Direct = require("weread/direct")
local Settings = require("weread/readersettings")
local Theme = require("weread/theme")
local Canvas = require("weread/canvas")
local T = Canvas.text

local Notes = {}

local function geom(pos) return Geom:new{ x = pos.x, y = pos.y, w = 0, h = 0 } end

-- 选区在章节里的大致位置（0~1），用来在原文里挑最近的那处同样文字
function Notes:chapterFraction()
    return (self.page - 0.5) / math.max(self.doc:getPageCount(), 1)
end

function Notes:onHold(pos)
    if self.menu or not self.doc then return true end
    local res = self.doc:getWordFromPosition(geom(pos), true)
    if not res or not res.pos0 then return true end
    self.sel = { start = geom(pos), pos0 = res.pos0, pos1 = res.pos1, text = res.word }
    self:drawSelection()
    return true
end

function Notes:onHoldPan(pos)
    if not self.sel then return true end
    local res = self.doc:getTextFromPositions(self.sel.start, geom(pos), true)
    if res and res.pos0 then
        self.sel.pos0, self.sel.pos1, self.sel.text = res.pos0, res.pos1, res.text
        self:drawSelection()
    end
    return true
end

function Notes:onHoldRelease()
    if not self.sel then return true end
    self:showSelectionMenu()
    return true
end

-- 选区（官方 SELECT_LINE + 两端手柄，参照 ref/official/71-select-plain.png）：选中的文字下面一条 2px 实线，
-- 起点左下、终点右下各一个直径 29px 的黑色水滴手柄
local HANDLE_R = 14

function Notes:selectionBoxes()
    if not self.sel then return {} end
    return self.doc:getScreenBoxesFromPositions(self.sel.pos0, self.sel.pos1, true) or {}
end

function Notes:drawSelection()
    local ops = {}
    local boxes = self:selectionBoxes()
    for _, b in ipairs(boxes) do
        ops[#ops + 1] = { "rect", b.x, b.y + b.h - 2, b.w, 2, Theme.BLACK }
    end
    local first, last = boxes[1], boxes[#boxes]
    if first then
        local ly = first.y + first.h
        local cx, cy = first.x + HANDLE_R, ly + 27
        ops[#ops + 1] = { "rect", cx, ly, HANDLE_R + 1, cy - ly, Theme.BLACK }
        ops[#ops + 1] = { "ring", cx, cy, HANDLE_R, HANDLE_R, Theme.BLACK }
        ly = last.y + last.h
        cx = last.x + last.w - HANDLE_R
        ops[#ops + 1] = { "rect", cx - HANDLE_R, ly, HANDLE_R + 1, 27, Theme.BLACK }
        ops[#ops + 1] = { "ring", cx, ly + 27, HANDLE_R, HANDLE_R, Theme.BLACK }
    end
    for _, op in ipairs(self:quickMenuOps(boxes)) do ops[#ops + 1] = op end
    self.selection_ops = ops
    self:redraw("ui")
end

function Notes:clearSelection()
    self.sel = nil
    self.selection_ops = nil
    self.quick_menu = nil
    self:redraw("ui")
end

-- 选区上的快捷菜单（官方 QuickActionPopup，quick_action_popup_horizontal.xml）：圆角气泡，
-- 五个按钮“划线 / 查询 / 写想法 / 复制 / 听当前”；选的是自己已有的划线时第一个是“删除划线”。
-- 气泡在选区上方，小三角对着选区中间；上方放不下就放到下方，三角朝上
local QM = { w = 581, h = 135, item = 113, pad = 8, icon = 40, arrow = 15, margin = 30 }

function Notes:quickMenuOps(boxes)
    local ops = {}
    if not self.quick_menu or #boxes == 0 then return ops end
    local first, last = boxes[1], boxes[#boxes]
    local left, right = math.huge, 0
    for _, b in ipairs(boxes) do left, right = math.min(left, b.x), math.max(right, b.x + b.w) end
    local ax = math.floor((left + right) / 2)
    if first.y == last.y then ax = math.floor((first.x + last.x + last.w) / 2) end
    local x = math.max(QM.margin, math.min(self.dimen.w - QM.margin - QM.w, ax - math.floor(QM.w / 2)))
    local y = first.y - 26 - QM.arrow - QM.h
    local up = y < 60
    if up then y = last.y + last.h + 27 + HANDLE_R + 12 + QM.arrow end
    ax = math.max(x + 40, math.min(x + QM.w - 40, ax))
    table.insert(ops, { "rrect", x, y, QM.w, QM.h, Theme.WHITE, 24 })
    table.insert(ops, { "frame", x, y, QM.w, QM.h, 2, Theme.BLACK, 24 })
    -- 小三角：白底盖住边框，两条斜边 2px
    for k = 0, QM.arrow do
        local yy = up and (y - QM.arrow + k) or (y + QM.h + QM.arrow - k)
        table.insert(ops, { "rect", ax - k, yy, 2 * k + 1, 1, Theme.WHITE })
        table.insert(ops, { "rect", ax - k - 1, yy, 2, 1, Theme.BLACK })
        table.insert(ops, { "rect", ax + k, yy, 2, 1, Theme.BLACK })
    end
    self.quick_menu.rects = {}
    for n, it in ipairs(self.quick_menu.items) do
        local cx = x + QM.pad + math.floor(QM.item / 2) + (n - 1) * QM.item
        table.insert(ops, { "image", cx - QM.icon / 2, y + 27, Theme.res(it.icon), QM.icon, QM.icon })
        table.insert(ops, T(cx, y + 88, it.text, Theme.BOLD, 26, nil, nil, "center"))
        self.quick_menu.rects[n] = { x = cx - QM.item / 2, y = y, w = QM.item, h = QM.h }
    end
    return ops
end

-- 点快捷菜单：点中按钮返回 true；点在别处由调用方清掉选区
function Notes:onQuickMenuTap(pos)
    local qm = self.quick_menu
    for n, r in ipairs(qm and qm.rects or {}) do
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then
            qm.items[n].action()
            return true
        end
    end
    return false
end

function Notes:showSelectionMenu(note)
    local items = {
        note and { text = "删除划线", icon = "icon_reading_menu_delete_underline.svg", action = function()
            if Direct.removeBookmark(note.bookmarkId) then self:reloadNotes() else self:clearSelection() end
        end } or { text = "划线", icon = "icon_reading_menu_underline.svg", action = function() self:addHighlight() end },
        { text = "查询", icon = "icon_reading_menu_inspect.svg", action = function()
            self:clearSelection()
            UIManager:show(InfoMessage:new{ text = "查询稍后支持", timeout = 2 })
        end },
        { text = "写想法", icon = "icon_reader_selection_menu_review_black.svg", action = function()
            if note then self:writeThought(note.range, note.markText) else self:writeThought() end
        end },
        { text = "复制", icon = "icon_reader_selection_menu_copy.svg", action = function()
            local text = self.sel and self.sel.text or ""
            if Device.input and Device.input.setClipboardText then Device.input.setClipboardText(text) end
            self:clearSelection()
            UIManager:show(InfoMessage:new{ text = "已复制", timeout = 1 })
        end },
        { text = "听当前", icon = "icon_floating_listen.svg", action = function()
            self:clearSelection()
            UIManager:show(InfoMessage:new{ text = "听书稍后支持", timeout = 2 })
        end },
    }
    self.quick_menu = { items = items }
    self:drawSelection()
end

-- 选中的文字 → range；找不到时提示
function Notes:selectionRange()
    local text = (self.sel.text or ""):gsub("%s+", "")
    local range = self.bk:findRange(self.index, text, self:chapterFraction())
    if not range then
        UIManager:show(InfoMessage:new{ text = "这段文字暂时不能划线", timeout = 2 })
        logger.warn("weread notes: range not found for", text)
    end
    return range, text
end

-- 笔记变了：重新拉笔记，按新的笔记重新打包这一章，停在同一页
function Notes:reloadNotes()
    self.sel, self.selection_ops, self.quick_menu = nil, nil, nil
    self.bk:loadNotes()
    self.bk:invalidateChapter(self.index)
    self:loadChapter(self.index, { page = self.page })
end

function Notes:addHighlight()
    local range, text = self:selectionRange()
    if not range then return self:clearSelection() end
    local ch = self.bk:chapter(self.index)
    local id = Direct.addHighlight(self.book.bookId, ch.chapterUid, range, text, self.bk.info.version)
    if not id then
        UIManager:show(InfoMessage:new{ text = "划线失败", timeout = 2 })
        return self:clearSelection()
    end
    self:reloadNotes()
end

-- 写想法：range 可以来自选区，也可以来自已有的划线
function Notes:writeThought(range, abstract)
    if not range then
        range, abstract = self:selectionRange()
        if not range then return self:clearSelection() end
    end
    local dialog
    dialog = InputDialog:new{
        title = "写想法",
        input = "",
        input_hint = abstract,
        allow_newline = true,
        buttons = {{
            { text = "取消", id = "close", callback = function() UIManager:close(dialog) self:clearSelection() end },
            {
                text = "发表",
                callback = function()
                    local content = dialog:getInputText()
                    UIManager:close(dialog)
                    if content == "" then return self:clearSelection() end
                    local ch = self.bk:chapter(self.index)
                    local id = Direct.addThought(self.book.bookId, ch.chapterUid, range, abstract, content, self.bk.info.version)
                    UIManager:show(InfoMessage:new{ text = id and "已发表" or "发表失败", timeout = 1 })
                    if id then self:reloadNotes() else self:clearSelection() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- 点在已有的划线上就处理并返回 true；不是划线返回 false（照常翻页）
function Notes:handleNoteTap(pos)
    if not self.doc or not self.bk then return false end
    local ch = self.bk:chapter(self.index)
    if not self.mark_ranges or #self.mark_ranges == 0 then return false end
    -- 按当前页上每条划线的屏幕方框判断点在了哪一条（按字在全章里的位置去猜会在重复的字上猜错）；
    -- 方框下沿多算一点，下划线那一条细线也能点中
    self.doc:gotoPage(self.page)
    local hit
    for _, r in ipairs(self.mark_ranges) do
        for _, bx in ipairs(self:rangeOnPage(r) and self.doc:getScreenBoxesFromPositions(r[1], r[2], true) or {}) do
            if pos.x >= bx.x and pos.x < bx.x + bx.w and pos.y >= bx.y and pos.y < bx.y + bx.h + 8 then
                if not hit or r[5].pri > hit.pri then hit = r[5] end
            end
        end
    end
    if not hit then return false end
    -- 官方 ReviewInduceTouch / UnderlineTouch：划线超过 10 个字时，点在左边 42、右边 62 像素以内照常翻页（TurnPageConfig 默认值，
    -- 直接和像素比较，不是 dp）。官方是从**正文边缘**往里量的，所以这两条翻页带落在文字里面；我们的页边距能调（最小 60），
    -- 按正文边缘量的话边距一调小，翻页带就压到文字上，点划线变成翻页。这里改成从**屏幕边缘**量：翻页带永远在页边距里，
    -- 点划线的文字一定弹评论，页边距里照常翻页
    if hit.b - hit.a > 10 and (pos.x < 42 or pos.x > self.dimen.w - 62) then return false end
    local note = hit.note
    if note.hot then
        self:showHotUnderline(ch, hit)
    elseif note.reviewId then
        local dialog
        dialog = ButtonDialog:new{
            title = note.content,
            buttons = {{
                { text = "删除想法", callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = "删除这条想法？", ok_text = "删除",
                        ok_callback = function()
                            if Direct.deleteThought(note.reviewId) then self:reloadNotes() end
                        end,
                    })
                end },
                { text = "关闭", callback = function() UIManager:close(dialog) end },
            }},
        }
        UIManager:show(dialog)
    else
        -- 自己的划线：选中它并弹出快捷菜单，第一个按钮是“删除划线”（ref/official/79-own-highlight-menu.png）
        for _, r in ipairs(self.mark_ranges or {}) do
            if r[4] == note then
                self.sel = { pos0 = r[1], pos1 = r[2], text = note.markText }
                self:showSelectionMenu(note)
                return true
            end
        end
    end
    return true
end

-- 划线在排版后的文档里的位置：按原文搜索（findAllText），出现多处时取离 range 最近的；
-- 跨段落整句搜不到时，分别搜开头、结尾各一小段。结果 { { pos0, pos1, style }, … }，style 是 "line" 或 "dash"
local function utf8chars(s)
    local t = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
    return t
end

function Notes:findInDoc(text, frac)
    local hits = self.doc:findAllText(text, false, 0, 20) or {}
    local best, best_d
    local pages = self.doc:getPageCount()
    for _, h in ipairs(hits) do
        local p = self.doc:getPageFromXPointer(h.start) or 1
        local d = math.abs(p / pages - frac)
        if not best or d < best_d then best, best_d = h, d end
    end
    return best and best.start, best and best["end"]
end

-- 在排版后的文档里找一段文字：整段搜；搜不到且够长时，分别搜开头、结尾各一小段
function Notes:locateText(text, frac)
    local p0, p1 = self:findInDoc(text, frac)
    if p0 then return p0, p1 end
    local chars = utf8chars(text)
    if #chars > 24 then
        local head = table.concat(chars, "", 1, 12):gsub(" +$", "")
        local tail = table.concat(chars, "", #chars - 11, #chars):gsub("^ +", "")
        local h0 = self:findInDoc(head, frac)
        local _, t1 = self:findInDoc(tail, frac)
        if h0 and t1 then return h0, t1 end
    end
end

function Notes:computeMarks()
    self.mark_ranges = {}
    if not self.doc or not self.bk then return end
    local t0 = os.clock()
    local searches = 0
    local findInDoc = self.findInDoc
    self.findInDoc = function(this, ...) searches = searches + 1 return findInDoc(this, ...) end
    local ch = self.bk:chapter(self.index)
    local src = self.bk:chapterSource(self.index) or ""
    local total = math.max(1, select(2, src:gsub("[^\128-\191]", "")))
    -- 把每条划线定位到文档里的 xpointer 很慢（几百条要好几秒）；xpointer 只跟文档结构有关、跟字号排版无关，
    -- 所以算过一次就存下来，区间列表（决定了章节怎么打包）没变就直接用
    local intervals = self.bk:noteIntervals(ch)
    local sig = {}
    for i, iv in ipairs(intervals) do sig[i] = iv.a .. "-" .. iv.b .. iv.cls end
    sig = table.concat(sig, ",")
    local cache_path = string.format("%s/marks_%d.json", self.bk.dir, ch.chapterUid)
    local cache
    local f = io.open(cache_path, "rb")
    if f then
        cache = rapidjson.decode(f:read("*a"))
        f:close()
    end
    if type(cache) ~= "table" or cache.sig ~= sig or cache.src_len ~= #src then cache = nil end
    local found = {}
    for i, iv in ipairs(intervals) do
        local p0, p1
        if cache then
            local c = cache.found[i]
            if c then p0, p1 = c[1], c[2] end
        else
            local frac = iv.a / total
            -- range 是原始 XHTML 里的字符位置：先取保留空格的原文去搜（中英文混排时排版后的文字带空格），
            -- 搜不到再用去掉空格的文字（跨段落、换行的情况）
            local spaced = self.bk:textOfRange(self.index, iv.a, iv.b, true)
            if spaced and spaced ~= "" then p0, p1 = self:locateText(spaced, frac) end
            if not p0 then
                local text = iv.cls == "wr-hot" and self.bk:textOfRange(self.index, iv.a, iv.b)
                    or (iv.note.markText or iv.note.abstract)
                text = (text or ""):gsub("%s+", "")
                if text ~= "" then p0, p1 = self:locateText(text, frac) end
            end
            found[i] = p0 and { p0, p1 } or false
        end
        if p0 then
            -- 官方 PageView.drawAllLine：自己的划线是实线（UnderlineStyle.StyleStraight），
            -- 自己的想法（MY_REVIEW）和热门划线（BEST_MARK）是虚线（underlineDotPaint）
            self.mark_ranges[#self.mark_ranges + 1] = { p0, p1, iv.cls == "wr-mark" and "line" or "dash", iv.note, iv }
        end
    end
    if not cache then
        local out = io.open(cache_path, "wb")
        if out then
            out:write(rapidjson.encode{ sig = sig, src_len = #src, found = found })
            out:close()
        end
    end
    self.findInDoc = nil
    logger.info(string.format("weread notes: %d marks, %d searches, %.1fs", #self.mark_ranges, searches, os.clock() - t0))
end

-- 热门划线的虚线（官方 PaintManager.underlineDotPaint）：线宽 1.5dp，画 3dp 空 3dp，黑色
local DASH, DASH_W = math.floor(3 * 1.875 + 0.5), math.floor(1.5 * 1.875 + 0.5)

-- 当前页上的划线：自己的划线画实线，想法和热门划线画虚线
-- 这个区间是不是（部分）落在当前页。页码只算一次（排版变了 mark_ranges 会重建）
function Notes:rangeOnPage(r)
    if not r.p_from then
        r.p_from = self.doc:getPageFromXPointer(r[1])
        r.p_to = self.doc:getPageFromXPointer(r[2])
    end
    return r.p_from <= self.page and r.p_to >= self.page
end

function Notes:markOps()
    local ops = {}
    if not self.mark_ranges or #self.mark_ranges == 0 then return ops end
    self.doc:gotoPage(self.page)
    for _, r in ipairs(self.mark_ranges) do
        -- 每个区间覆盖的页码只算一次（排版变了 mark_ranges 会重建）；不在当前页的区间不用问 crengine 要文字框，
        -- 否则整章几百条划线每翻一页都要问一遍，一页要多花半秒
        if not self:rangeOnPage(r) then goto continue end
        for _, b in ipairs(self.doc:getScreenBoxesFromPositions(r[1], r[2], true) or {}) do
            if r[3] == "dash" then
                local y = b.y + b.h - DASH_W
                for x = b.x, b.x + b.w - 1, 2 * DASH do
                    ops[#ops + 1] = { "rect", x, y, math.min(DASH, b.x + b.w - x), DASH_W, Theme.BLACK }
                end
            else
                -- 实线：线宽 1.5dp，在文字框下沿再往下 1dp（StyleStraight.draw）
                ops[#ops + 1] = { "rect", b.x, b.y + b.h - DASH_W + 2, b.w, DASH_W, Theme.BLACK }
            end
        end
        ::continue::
    end
    return ops
end

-- 热门划线：弹出书友想法卡片（官方 PageView.showUnderLineReview → ReaderReviewListPopup）
function Notes:showHotUnderline(ch, hit)
    local UnderlineReviewsView = require("weread/underlinereviewsview")
    local range = hit.note.range
    local quote = self.bk:textOfRange(self.index, hit.a, hit.b) or ""
    local view = UnderlineReviewsView:new{
        book_id = self.book.bookId, chapter_uid = ch.chapterUid, range = range, quote = quote, under = self,
        on_back = function() self:redraw("full") end,
        on_highlight = function()
            local id = Direct.addHighlight(self.book.bookId, ch.chapterUid, range, quote, self.bk.info.version)
            if id then self:reloadNotes() else UIManager:show(InfoMessage:new{ text = "划线失败", timeout = 2 }) end
        end,
        on_write = function()
            self:redraw("full")
            self:writeThought(range, quote)
        end,
    }
    -- 只在打开时整屏闪刷一次；数据和头像到了再用局部刷新补上
    view:refresh(false, "ui")
    UIManager:show(view, "full")
    UIManager:nextTick(function() view:load() end)
end

function Notes.mixin(cls)
    for k, v in pairs(Notes) do
        if k ~= "mixin" then cls[k] = v end
    end
end

return Notes
