-- 新书介绍（官方墨水屏版的书籍详情）：不是单独的详情页，而是预览阅读器的前两页：
--   第 1 页 封面信息页（BaseCoverPageView）：封面、书名、作者；下面是 推荐值分布图（RatingPivotChart）、
--           推荐 / 一般 / 不行 三个按钮（RatingButtonsView）、阅读 / 可读 / 字数 三栏（BookAndReadingInfoLayout）、“左滑开始阅读”
--   第 2 页 简介页（BookIntroPageView）：左上角“简介”，整页简介，“上滑显示工具栏”
-- 再往后翻就进入正文（第一章通常是“版权信息”，页尾有“加入书架 随时阅读”，见 ReaderView 的预览模式）。
-- 尺寸全部取自反编译源码（dp × 1.875）和 ref/official/23-bookdetail.png 实测。
local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = Device.screen

local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local Quit = require("weread/quit")
local Theme = require("weread/theme")

local T = Canvas.text

local W, H = 1264, 1680
local MARGIN_X = 75             -- 封面页左右 40dp
local TIP_GRAY = Blitbuffer.Color8(102)     -- 底部提示 alpha 0.6 的黑
local TRACK_GRAY = Blitbuffer.Color8(187)

local BookPreviewView = InputContainer:extend{
    book = nil,
    on_read = nil,      -- function(book)：翻过最后一页，进入正文
    on_back = nil,
}

function BookPreviewView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.page = self.page or 1
    self[1] = Canvas:new{ ops = {} }
    -- 实体翻页键（和阅读页一样：左右两侧的翻页键都能用）
    self.key_events = {
        NextPage = { { { "RPgFwd", "LPgFwd" } } },
        PrevPage = { { { "RPgBack", "LPgBack" } } },
    }
    self:registerTouchZones({
        { id = "preview_tap", ges = "tap", screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function(ges) return self:onTap(ges.pos) end },
        { id = "preview_swipe", ges = "swipe", screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function(ges)
              if Quit.handleSwipe(ges) then return true end
              if ges.direction == "west" or ges.direction == "north" then return self:turn(1) end
              if ges.direction == "east" or ges.direction == "south" then return self:turn(-1) end
          end },
    })
end

function BookPreviewView:load()
    local info = Direct.bookInfo(self.book.bookId)
    if info then
        for k, v in pairs(info) do self.book[k] = v end
    end
    self.cover_file = Direct.coverFile(self.book)
    self:render("full")
end

-- 息屏画面：把封面信息页画成一张图（不上屏），失败返回 nil。会请求网络取书籍信息，不要在息屏当口调用
function BookPreviewView.snapshot(book)
    local view = BookPreviewView:new{ book = book, page = 1 }
    local info = Direct.bookInfo(book.bookId)
    if not info then return nil end
    for k, v in pairs(info) do view.book[k] = v end
    view.cover_file = Direct.coverFile(view.book)
    local ops = { { "rect", 0, 0, W, H, Theme.WHITE } }
    view:coverPage(ops)
    local canvas = Canvas:new{ ops = ops }
    local bb = Blitbuffer.new(W, H, Screen.bb:getType())
    canvas:paintTo(bb, 0, 0)
    return bb
end

function BookPreviewView:refresh()
    self:render("full")
end

-- ---- 小工具 ----

-- 官方 WRUIUtil.formatNumberToTenThousand：不到一万是整数，一万以上是“x.x”+“万”
local function formatCount(n)
    n = tonumber(n) or 0
    if n >= 10000 then
        local v = string.format("%.1f", n / 10000):gsub("%.0$", "")
        return v, "万"
    end
    return tostring(math.floor(n)), ""
end

-- 一行里依次排几段文字：{ {文字, 字体, 字号, 颜色} … }，从 x 开始，ink_top 是墨迹顶部；返回总宽度
local function run(ops, x, ink_top, segs)
    local x0 = x
    for _, s in ipairs(segs) do
        local text, weight, px, color = s[1], s[2], s[3], s[4]
        if text ~= "" then
            table.insert(ops, T(x, ink_top + (s.dy or 0), text, weight, px, color))
            x = x + Canvas.textWidth(text, weight, px)
        end
    end
    return x - x0
end

local function runWidth(segs)
    local w = 0
    for _, s in ipairs(segs) do w = w + Canvas.textWidth(s[1], s[2], s[3]) end
    return w
end

-- 居中排一行
local function runCentered(ops, cx, ink_top, segs)
    run(ops, math.floor(cx - runWidth(segs) / 2), ink_top, segs)
end

local function imageSize(path)
    local bb = RenderImage:renderImageFile(path, false)
    if not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    bb:free()
    return w, h
end

-- 按宽度把一行字拆成最多两行（书名 23sp 居中，最多两行）
local function splitTitle(text, px, max_w)
    if Canvas.textWidth(text, Theme.SERIF, px) <= max_w then return { text } end
    local chars = {}
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    local line, rest = "", {}
    for i, ch in ipairs(chars) do
        if Canvas.textWidth(line .. ch, Theme.SERIF, px) > max_w then
            local tail = table.concat(chars, "", i)
            if Canvas.textWidth(tail, Theme.SERIF, px) > max_w then tail = tail:sub(1, #tail - 6) .. "…" end
            return { line, tail }
        end
        line = line .. ch
    end
    return { line }
end

-- ---- 第 1 页：封面信息页 ----

function BookPreviewView:coverPage(ops)
    local b = self.book
    -- 底部提示 “左滑开始阅读”：官方距底边 40dp，内边距 8dp
    local tip_ink_bottom = H - 75 - 15
    local tip_top = tip_ink_bottom - 26 - 15
    self:tip(ops, tip_ink_bottom - 26, "左滑开始阅读", "icon_arrow_left.svg")
    -- 阅读 / 可读 / 字数：三栏，标签在上、数字在下
    local info_bottom = tip_top - 60
    local info_top = info_bottom - 92
    -- 接口里没有的数据显示“—”；字数没给时用书籍大小估（UTF-8 汉字 3 字节）
    local words = b.totalWords or (b.bookSize and math.floor(b.bookSize / 3))
    local cols = {
        { label = "阅读", value = b.readingCount and { formatCount(b.readingCount) }, unit = "人" },
        { label = "可读", text = b.free == 1 and "免费" or "会员卡" },
        { label = "字数", value = words and { formatCount(words) }, unit = "字" },
    }
    for i, c in ipairs(cols) do
        local cx = W / 6 + (i - 1) * W / 3
        table.insert(ops, T(cx, info_top + 10, c.label, Theme.BOLD, 22, nil, nil, "center"))
        if c.text or not c.value then
            table.insert(ops, T(cx, info_top + 46, c.text or "—", Theme.BOLD, 34, nil, nil, "center"))
        else
            local num, wan = c.value[1], c.value[2]
            runCentered(ops, cx, info_top + 44, {
                { num, Theme.DIN_BOLD, 45 }, { wan .. c.unit, Theme.BOLD, 24, nil, dy = 18 },
            })
        end
        if i < 3 then table.insert(ops, { "vline", math.floor(W / 3 * i), info_top + 22, 56, 1, Theme.LINE_GRAY }) end
    end
    -- 推荐 / 一般 / 不行：三个描边药丸，高 32dp、圆角 18dp、间距 12dp
    local d = b.newRatingDetail or {}
    local btn_top = info_top - 22 - 60
    local gap = 22
    local bw = math.floor((W - 2 * MARGIN_X - 2 * gap) / 3)
    for i, lv in ipairs{ { "推荐", d.good }, { "一般", d.fair }, { "不行", d.poor } } do
        local x = MARGIN_X + (i - 1) * (bw + gap)
        table.insert(ops, { "frame", x, btn_top, bw, 60, 2, Theme.BLACK, 30 })
        local num, wan = formatCount(lv[2])
        runCentered(ops, x + bw / 2, btn_top + 18, {
            { lv[1] .. " ", Theme.BOLD, 24 }, { num, Theme.DIN_BOLD, 28, nil, dy = 2 }, { wan, Theme.BOLD, 24 },
        })
    end
    -- 推荐值分布图：左边“微信读书推荐值 90.6%”、评语（神作）、“N人点评”；右边推荐 / 一般 / 不行三条进度
    local chart_bottom = btn_top - 38
    local chart_top = chart_bottom - 150
    self:ratingChart(ops, chart_top)
    -- 上半：封面 + 书名 + 作者，贴着上半部分的底部
    local top_bottom = chart_top - 30
    local author_ink = top_bottom - 26
    table.insert(ops, T(W / 2, author_ink, b.author or "", Theme.SERIF, 26, nil, W - 2 * MARGIN_X, "center"))
    local lines = splitTitle(b.title or "", 43, W - 2 * MARGIN_X)
    local title_top = author_ink - 11 - #lines * 52 + 4
    for i, line in ipairs(lines) do
        table.insert(ops, T(W / 2, title_top + (i - 1) * 52, line, Theme.SERIF, 43, nil, W - 2 * MARGIN_X, "center"))
    end
    local cover_top, cover_bottom = 86, title_top - 22
    local ch = cover_bottom - cover_top
    if self.cover_file then
        local iw, ih = imageSize(self.cover_file)
        local cw = (iw and ih) and math.floor(ch * iw / ih) or math.floor(ch * 0.72)
        if cw > W - 2 * MARGIN_X then
            cw = W - 2 * MARGIN_X
            ch = (iw and ih) and math.floor(cw * ih / iw) or ch
        end
        local cx = math.floor((W - cw) / 2)
        table.insert(ops, { "image", cx, cover_top, self.cover_file, cw, ch })
        table.insert(ops, { "shade", cx, cover_top, cw, ch, 2, 0.267 })
    end
end

function BookPreviewView:ratingChart(ops, top)
    local b = self.book
    local d = b.newRatingDetail or {}
    local score = tonumber(b.newRating) or 0
    local count = tonumber(b.newRatingCount) or 0
    local label_w = Canvas.textWidth("微信读书推荐值", Theme.BOLD, 30)
    table.insert(ops, T(MARGIN_X, top, "微信读书推荐值", Theme.BOLD, 30))
    local left_w = label_w
    if score > 0 then
        local num = string.format("%.1f", score / 10)
        -- 分数在标签右边，基线对齐，“%”小一号
        local sx = MARGIN_X + label_w + 8
        local w = run(ops, sx, top + 1, { { num, Theme.DIN_MEDIUM, 34 }, { "%", Theme.DIN_MEDIUM, 26, nil, dy = 8 } })
        local title = d.title
        if title and title ~= "" then
            table.insert(ops, T(MARGIN_X, top + 49, title, Theme.SERIF, 58))
            left_w = math.max(Canvas.textWidth(title, Theme.SERIF, 58), 0)
        end
        left_w = math.max(left_w, 0)
    else
        table.insert(ops, T(MARGIN_X, top + 59, count > 0 and "评分不足" or "待评分", Theme.SERIF, 48))
        left_w = Canvas.textWidth("评分不足", Theme.SERIF, 48)
    end
    if count > 0 then
        local num, wan = formatCount(count)
        local cw = run(ops, MARGIN_X, top + 128, { { num, Theme.DIN_MEDIUM, 24 }, { wan .. "人点评", Theme.REGULAR, 22, nil, dy = 1 } })
        left_w = math.max(left_w, cw)
    end
    -- 右边三条进度：标签 10sp 粗体，条高 5dp，行距 6dp，离左边内容 21dp
    local total = (d.good or 0) + (d.fair or 0) + (d.poor or 0)
    local col_x = MARGIN_X + left_w + 39
    local label_px = 19
    local bar_x = col_x + Canvas.textWidth("推荐", Theme.BOLD, label_px) + 15
    local bar_w = W - MARGIN_X - bar_x
    for i, lv in ipairs{ { "推荐", d.good }, { "一般", d.fair }, { "不行", d.poor } } do
        local ry = top + 49 + (i - 1) * 39
        table.insert(ops, T(col_x, ry + 4, lv[1], Theme.BOLD, label_px))
        table.insert(ops, { "rrect", bar_x, ry + 10, bar_w, 9, TRACK_GRAY, 4 })
        if total > 0 and (lv[2] or 0) > 0 then
            table.insert(ops, { "rrect", bar_x, ry + 10, math.max(9, math.floor(bar_w * lv[2] / total)), 9, Theme.BLACK, 4 })
        end
    end
end

-- 底部提示：箭头 + 灰色粗体字，水平居中
function BookPreviewView:tip(ops, ink_top, text, icon)
    local w = Canvas.textWidth(text, Theme.BOLD, 26)
    local x0 = math.floor((W - (15 + 12 + w)) / 2)
    table.insert(ops, { "image", x0 - 8, ink_top - 2, Theme.res(icon), 30, 30 })
    table.insert(ops, T(x0 + 27, ink_top + 2, text, Theme.BOLD, 26, TIP_GRAY))
end

-- ---- 第 2 页：简介页 ----

function BookPreviewView:introPage(ops)
    table.insert(ops, { "image", 52, 46, Theme.res("reading_back.svg"), 38, 38 })
    table.insert(ops, T(94, 53, "简介", Theme.REGULAR, 24))
    local intro = self.book.intro
    if not intro or intro == "" then intro = "暂无简介" end
    -- 正文 41px、行距 73px（官方截图实测：每行 73.2px，第一行墨迹顶在 y=163）
    table.insert(ops, (Canvas.textBox(55, 143, 1154, intro, Theme.REGULAR, 41, nil, 17, 73 / 41 - 1)))
    self:tip(ops, 1606, "上滑显示工具栏", "icon_up_arrow.svg")
end

-- ---- 绘制与翻页 ----

function BookPreviewView:render(mode)
    local ops = { { "rect", 0, 0, W, H, Theme.WHITE } }
    if self.page == 1 then
        table.insert(ops, { "image", 52, 46, Theme.res("reading_back.svg"), 38, 38 })
        self:coverPage(ops)
    else
        self:introPage(ops)
    end
    self[1]:setOps(ops)
    UIManager:setDirty(self, mode or "partial")
end

function BookPreviewView:turn(delta)
    local to = self.page + delta
    if to > 2 then
        if self.on_read then self.on_read(self.book) end
        return true
    end
    if to < 1 then return true end
    self.page = to
    self:render("full")
    return true
end

function BookPreviewView:onNextPage() return self:turn(1) end

function BookPreviewView:onPrevPage() return self:turn(-1) end

function BookPreviewView:onTap(pos)
    if pos.x < 160 and pos.y < 140 then
        UIManager:close(self, "full")
        if self.on_back then self.on_back() end
        return true
    end
    -- 左边三成翻上一页，其余翻下一页（和阅读页一样）
    return self:turn(pos.x < W * 0.3 and -1 or 1)
end

return BookPreviewView
