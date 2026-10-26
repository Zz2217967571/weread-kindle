-- 按绝对像素坐标画界面的组件：页面先算出一串绘制项（文字、图片、矩形、线），这里按顺序画，
-- 可以整体加一个纵向偏移（列表滚动）。这样能按参照截图里的坐标逐个摆放，不受布局容器的间距影响。
--
-- 绘制项：
--   { "text", x, ink_top, text, face, color?, max_width?, align? }  ink_top 是墨迹顶部；align 为 "center" / "right" 时 x 是中心 / 右边界
--   { "image", x, y, file, w, h }    等比缩放到 w×h 以内、居中
--   { "rect", x, y, w, h, color }
--   { "frame", x, y, w, h, border, color, radius? }  只画边框
--   { "invert", x, y, w, h }          反色（选中的文字）
--   { "darken", x, y, w, h, k }       把底下的像素压暗 k（0~1），用来标出自己的划线
--   { "shade", x, y, w, h, border, intensity }  边框处把底下的像素按比例压暗（官方封面描边：白底上是 187）
--   { "hline", x, y, w, thickness, color }
--   { "vline", x, y, h, thickness, color }
--   { "widget", x, y, widget }        任意 KOReader 组件
local Blitbuffer = require("ffi/blitbuffer")
local ImageWidget = require("ui/widget/imagewidget")
local RenderText = require("ui/rendertext")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")

local Theme = require("weread/theme")

local Canvas = Widget:extend{
    ops = nil,       -- 绘制项
    offset_y = 0,    -- 向上滚动的像素
    clip_top = nil,  -- 只画这个纵向范围内的项（滚动区域）；部分越界的项照常画，由上层盖住
    clip_bottom = nil,
}

function Canvas:init()
    self.ops = self.ops or {}
    self.cache = {}
end

function Canvas:setOps(ops)
    self.ops = ops
    self.cache = {}
end

-- 超宽时截断，末尾画省略号。官方（安卓）的省略号是 Roboto 的“…”：贴着基线的三个小点，总宽约 17px，
-- 比汉字字体里的“...”（24px）窄，能多放一个字。这里截断后另外画三个点（见 paintOp），返回截断后的文字
local ELLIPSIS_W = 17
local function truncate(text, face, max_width)
    local function width(t) return RenderText:sizeUtf8Text(0, math.huge, face, t, true, false).x end
    if width(text) <= max_width then return text, false end
    local chars = {}
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    local lo, hi = 0, #chars
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if width(table.concat(chars, "", 1, mid)) + ELLIPSIS_W <= max_width then lo = mid else hi = mid - 1 end
    end
    return table.concat(chars, "", 1, lo), true
end

-- 文字和图片组件建一次，翻页时复用
local function textWidget(op)
    local text = op[4]
    if op[7] then text, op.dots = truncate(op[4], op[5], op[7]) end
    local w = TextWidget:new{
        text = text,
        face = op[5],
        fgcolor = op[6] or Blitbuffer.COLOR_BLACK,
        padding = 0,
    }
    -- 墨迹顶部 → 文字框顶部
    op.box_dy = w:getBaseline() - math.floor(Theme.INK_ASCENT * op.px + 0.5)
    return w
end

function Canvas:widgetFor(i, op)
    local w = self.cache[i]
    if w then return w end
    local kind = op[1]
    if kind == "text" then
        w = textWidget(op)
    elseif kind == "image" then
        w = ImageWidget:new{ file = op[4], width = op[5], height = op[6], scale_factor = 0, alpha = true }
    elseif kind == "widget" then
        w = op[4]
    end
    self.cache[i] = w
    return w
end

local function opBounds(op)
    local kind = op[1]
    if kind == "text" then return op[3], op.px or 40 end
    if kind == "image" then return op[3], op[6] end
    if kind == "rect" or kind == "rrect" or kind == "frame" or kind == "shade" or kind == "invert" or kind == "darken" then return op[3], op[5] end
    if kind == "hline" then return op[3], op[5] end
    if kind == "vline" then return op[3], op[4] end
    if kind == "widget" then return op[3], op[4]:getSize().h end
    if kind == "lighten" then return op[3], op[5] end
    if kind == "circle_mask" or kind == "ring" then return op[3] - op[4] - op[5], 2 * (op[4] + op[5]) end
    return 0, 0
end

function Canvas:paintTo(bb, x, y)
    local dy = -self.offset_y
    for i, op in ipairs(self.ops) do
        local top, h = opBounds(op)
        local vis_top = top + dy
        if (not self.clip_top or vis_top + h > self.clip_top) and (not self.clip_bottom or vis_top < self.clip_bottom) then
            self:paintOp(bb, x, y + dy, i, op)
        end
    end
end

function Canvas:paintOp(bb, x, y, i, op)
    local kind = op[1]
    if kind == "rect" then
        bb:paintRect(x + op[2], y + op[3], op[4], op[5], op[6])
    elseif kind == "lighten" then
        bb:lightenRect(x + op[2], y + op[3], op[4], op[5], op[6])
    elseif kind == "circle_mask" then
        -- 把 (cx, cy) 为圆心、半径 r 以外到外接正方形的部分涂成 color（头像裁圆）
        bb:paintCircle(x + op[2], y + op[3], op[4] + op[5], op[6], op[5])
    elseif kind == "ring" then
        bb:paintCircle(x + op[2], y + op[3], op[4], op[6], op[5])
    elseif kind == "rrect" then
        bb:paintRoundedRect(x + op[2], y + op[3], op[4], op[5], op[6], op[7])
    elseif kind == "frame" then
        local bw, color, radius = op[6], op[7], op[8]
        if radius and radius > 0 then
            bb:paintBorder(x + op[2], y + op[3], op[4], op[5], bw, color, radius)
        else
            bb:paintBorder(x + op[2], y + op[3], op[4], op[5], bw, color)
        end
    elseif kind == "darken" then
        bb:darkenRect(x + op[2], y + op[3], op[4], op[5], op[6])
    elseif kind == "invert" then
        bb:invertRect(x + op[2], y + op[3], op[4], op[5])
    elseif kind == "shade" then
        local bx, by, bw, bh, t, k = x + op[2], y + op[3], op[4], op[5], op[6], op[7]
        bb:darkenRect(bx, by, bw, t, k)
        bb:darkenRect(bx, by + bh - t, bw, t, k)
        bb:darkenRect(bx, by + t, t, bh - 2 * t, k)
        bb:darkenRect(bx + bw - t, by + t, t, bh - 2 * t, k)
    elseif kind == "hline" then
        bb:paintRect(x + op[2], y + op[3], op[4], op[5], op[6])
    elseif kind == "vline" then
        bb:paintRect(x + op[2], y + op[3], op[5], op[4], op[6])
    elseif kind == "text" then
        local w = self:widgetFor(i, op)
        local tx = op[2]
        if op[8] == "center" then tx = tx - math.floor(w:getSize().w / 2)
        elseif op[8] == "right" then tx = tx - w:getSize().w end
        w:paintTo(bb, x + tx, y + op[3] - op.box_dy)
        if op.dots then
            -- 三个 3×3 的点，间距 5.5px，底边落在基线上（官方截图实测）
            local dx = x + tx + w:getSize().w + 2
            local bottom = y + op[3] + math.floor(0.84 * op.px + 0.5)
            for k = 0, 2 do
                bb:paintRect(dx + math.floor(k * 5.5), bottom - 3, 3, 3, op[6] or Blitbuffer.COLOR_BLACK)
            end
        end
    elseif kind == "image" or kind == "widget" then
        self:widgetFor(i, op):paintTo(bb, x + op[2], y + op[3])
    end
end

-- 文字宽度（像素）
function Canvas.textWidth(text, weight, px)
    return RenderText:sizeUtf8Text(0, math.huge, Theme.face(weight, px), text, true, false).x
end

-- 文字绘制项的构造函数：记下字号，供墨迹对齐用。weight 为 Theme.SERIF 时用思源宋体
function Canvas.text(x, ink_top, text, weight, px, color, max_width, align)
    return { "text", x, ink_top, text, Theme.face(weight, px), color, max_width, align, px = px }
end

-- 多行文字（简介等），自动换行，最多 max_lines 行
-- 注意：返回两个值，table.insert(ops, Canvas.textBox(...)) 会把行数当成插入位置而崩溃，要写成 table.insert(ops, (Canvas.textBox(...)))
-- 多行文字。line_height 是行距（占字号的比例，默认 0.6 即行高 1.6 倍字号）。
-- 第二个返回值是实际行数（超过 max_lines 时按 max_lines 算，末行带省略号）
function Canvas.textBox(x, y, width, text, weight, px, color, max_lines, line_height)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local face = Theme.face(weight, px)
    line_height = line_height or 0.6
    local w = TextBoxWidget:new{
        text = text, face = face, width = width, fgcolor = color,
        -- 实际行高按 face 的字号算，比 px 略大一点，多留几个像素免得最后一行被挤掉
        height = max_lines and math.ceil(px * (1 + line_height) * max_lines) + 4 or nil,
        height_overflow_show_ellipsis = max_lines ~= nil, line_height = line_height,
    }
    local lines = #(w.vertical_string_list or {})
    if max_lines then lines = math.min(lines, max_lines) end
    return { "widget", x, y, w }, math.max(lines, 1)
end

return Canvas
