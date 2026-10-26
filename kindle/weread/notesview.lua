-- 笔记列表（阅读页底部“笔记”）：按章节列出我的划线和想法，点一条跳到原文。
-- 没有笔记时和官方一样提示“你可以在这里记录本书的想法、划线和书签”（ref/official/43-reader-notes.png）。
local UIManager = require("ui/uimanager")

local Canvas = require("weread/canvas")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

local NotesView = PagedView:extend{
    tab = "back",
    viewport_top = 150,
    bk = nil,           -- weread/book
    on_select = nil,    -- function(chapter_index, fraction)
}

function NotesView:buildHeader()
    return {
        T(38, 66, "笔记", Theme.SERIF, 46),
        { "hline", 0, 148, self.dimen.w, 2, Theme.LINE_GRAY },
    }
end

-- 按章节顺序整理：{ { index, title, items = { {kind, text, sub, range}, … } }, … }
function NotesView:groups()
    local by_uid = {}
    local notes = self.bk.notes or {}
    local function add(uid, item)
        by_uid[uid] = by_uid[uid] or {}
        table.insert(by_uid[uid], item)
    end
    for _, m in ipairs(notes.marks or {}) do
        if m.type == 1 then add(m.chapterUid, { kind = "mark", text = m.markText, range = m.range }) end
    end
    for _, t in ipairs(notes.thoughts or {}) do
        add(t.chapterUid, { kind = "thought", text = t.content, sub = "原文：" .. (t.abstract or ""), range = t.range })
    end
    local groups = {}
    for i, ch in ipairs(self.bk.chapters) do
        local items = by_uid[ch.chapterUid]
        if items then
            table.sort(items, function(a, b)
                return (tonumber((a.range or ""):match("^%d+")) or 0) < (tonumber((b.range or ""):match("^%d+")) or 0)
            end)
            groups[#groups + 1] = { index = i, title = ch.title, items = items }
        end
    end
    return groups
end

function NotesView:buildContent()
    local ops, anchors = {}, {}
    self.rows = {}
    local groups = self:groups()
    if #groups == 0 then
        table.insert(ops, { "frame", 300, 40, 664, 140, 2, Theme.LINE_GRAY, 16 })
        table.insert(ops, T(632, 76, "你可以在这里记录本书的", Theme.REGULAR, 26, nil, nil, "center"))
        table.insert(ops, T(632, 118, "想法、划线和书签", Theme.REGULAR, 26, nil, nil, "center"))
        return { ops = ops, height = 300 }
    end
    local y = 30
    for _, g in ipairs(groups) do
        anchors[#anchors + 1] = y - 10
        table.insert(ops, T(38, y, g.title or "", Theme.BOLD, 30, nil, 1188))
        y = y + 70
        for _, it in ipairs(g.items) do
            local top = y
            if it.kind == "mark" then
                table.insert(ops, { "rect", 38, y, 4, 120, Theme.LINE_GRAY })
                table.insert(ops, (Canvas.textBox(60, y - 6, 1166, it.text or "", Theme.REGULAR, 28, nil, 3)))
                y = y + 150
            else
                table.insert(ops, (Canvas.textBox(38, y - 6, 1188, it.text or "", Theme.BOLD, 28, nil, 3)))
                table.insert(ops, T(38, y + 140, it.sub or "", Theme.REGULAR, 24, Theme.HINT_GRAY, 1188))
                y = y + 200
            end
            table.insert(ops, { "hline", 38, y - 20, 1188, 1, Theme.LINE_GRAY })
            self.rows[#self.rows + 1] = { y0 = top - 10, y1 = y - 20, index = g.index, range = it.range }
        end
        y = y + 30
    end
    return { ops = ops, height = y + 40, anchors = anchors }
end

function NotesView:onTapContent(x, y)
    for _, r in ipairs(self.rows or {}) do
        if y >= r.y0 and y < r.y1 then
            -- 原文位置换成章节里的比例：range 起点 / 原始文件长度
            local frac = 0
            local src = self.bk:chapterSource(r.index)
            local a = tonumber((r.range or ""):match("^(%d+)"))
            if src and a then
                -- range 按字符计数：数一下 UTF-8 的字符数（非续字节的个数）
                local chars = select(2, src:gsub("[^\128-\191]", ""))
                if chars > 0 then frac = math.min(1, a / chars) end
            end
            UIManager:close(self)
            if self.on_select then self.on_select(r.index, frac) end
            return
        end
    end
end

return NotesView
