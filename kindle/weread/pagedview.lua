-- 官方墨水屏版的通用页面骨架：顶部固定区 + 中间整页翻动的内容区 + 底部栏。
-- 内容区不滚动，只能用底部栏的上一页 / 下一页（或翻页键、上下滑动）整页翻，和官方一致。
--
-- 子类提供：
--   self.viewport_top       内容区顶部（固定区下沿）
--   self:buildContent()     → { ops = 绘制项（内容坐标）, height = 内容总高, anchors = 行顶坐标列表（可选）}
--   self:buildHeader()      → 固定区绘制项（屏幕坐标），可选
--   self:onTapContent(x, y) 点在内容区（y 是内容坐标）
--   self:onTapHeader(pos)   点在固定区
--   self.tab                底部栏高亮的标签；"back" 表示二级页面，左边是返回箭头（点了调 self:onBack()）
--   self.on_tab(name)       点了底部栏的标签
local Device = require("device")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local BottomBar = require("weread/bottombar")
local Canvas = require("weread/canvas")
local Quit = require("weread/quit")
local Theme = require("weread/theme")

-- 内容翻到某一行时，行顶离内容区上沿留的空隙
local ROW_MARGIN = 8

local PagedView = InputContainer:extend{
    tab = nil,
    on_tab = nil,
    viewport_top = 157,
}

function PagedView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.offset = 0
    self.content_canvas = Canvas:new{ ops = {} }
    self.header_canvas = Canvas:new{ ops = {} }
    self.bar_canvas = Canvas:new{ ops = {} }
    self.key_events = {
        NextPage = { { { "RPgFwd", "LPgFwd" } } },
        PrevPage = { { { "RPgBack", "LPgBack" } } },
    }
    self:registerTouchZones({
        {
            id = "paged_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onTap(ges.pos) end,
        },
        {
            id = "paged_swipe",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                if Quit.handleSwipe(ges) then return true end
                if ges.direction == "north" or ges.direction == "west" then return self:onNextPage() end
                if ges.direction == "south" or ges.direction == "east" then return self:onPrevPage() end
            end,
        },
    })
    self[1] = self.content_canvas
end

function PagedView:viewportHeight()
    return BottomBar.top() - self.viewport_top
end

function PagedView:maxOffset()
    return math.max(0, (self.content_height or 0) - self:viewportHeight())
end

-- 重新生成内容（数据变了时调用），keep_offset 为真时尽量停在原来的位置
-- mode：重画用的刷新方式，默认 "full"（整屏闪刷）；内容只是更新（头像到了、多加载几条）时用 "ui"
function PagedView:refresh(keep_offset, mode)
    local c = self:buildContent()
    self.content_canvas:setOps(c.ops)
    self.content_height = c.height
    self.anchors = c.anchors
    if not keep_offset then self.offset = 0 end
    self.offset = math.min(self.offset, self:maxOffset())
    self:repaint(mode or "full")
end

function PagedView:repaint(mode)
    self.content_canvas.offset_y = self.offset - self.viewport_top
    self.content_canvas.clip_top = self.viewport_top
    self.content_canvas.clip_bottom = BottomBar.top()
    local header = { { "rect", 0, 0, self.dimen.w, self.viewport_top, Theme.WHITE } }
    for _, op in ipairs(self.buildHeader and self:buildHeader() or {}) do table.insert(header, op) end
    self.header_canvas:setOps(header)
    self.bar_canvas:setOps(BottomBar.ops(self.tab, self.offset > 0, self.offset < self:maxOffset()))
    UIManager:setDirty(self, mode or "ui")
end

function PagedView:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Theme.WHITE)
    self.content_canvas:paintTo(bb, x, y)
    -- 固定区和底部栏后画，盖住滚出内容区的部分
    self.header_canvas:paintTo(bb, x, y)
    self.bar_canvas:paintTo(bb, x, y)
end

-- 下一页：把第一个没有完整显示的行翻到顶上；没有行信息时按内容区高度的八成翻
function PagedView:onNextPage()
    local max = self:maxOffset()
    if self.offset >= max then return true end
    local vh = self:viewportHeight()
    local target
    if self.anchors and #self.anchors > 1 then
        local row_h = self.anchors[2] - self.anchors[1]
        for _, a in ipairs(self.anchors) do
            if a + row_h > self.offset + vh then
                target = a - ROW_MARGIN
                break
            end
        end
    end
    -- 一张卡片比整个内容区还高时，按行推算出的位置不比现在靠下，会只挪 1 个像素；步长太小就按内容区高度的八成翻
    if not target or target - self.offset < vh * 0.3 then target = self.offset + math.floor(vh * 0.8) end
    self.offset = math.min(math.max(target, self.offset + 1), max)
    self:repaint("partial")
    return true
end

-- 上一页：往回翻同样多的行
function PagedView:onPrevPage()
    if self.offset <= 0 then return true end
    local vh = self:viewportHeight()
    local target
    if self.anchors and #self.anchors > 1 then
        local row_h = self.anchors[2] - self.anchors[1]
        local rows_per_page = math.max(1, math.floor(vh / row_h))
        local first
        for i, a in ipairs(self.anchors) do
            if a >= self.offset then first = i break end
        end
        first = first or #self.anchors
        local idx = first - rows_per_page
        target = idx >= 1 and (self.anchors[idx] - ROW_MARGIN) or 0
        -- 回到第一行时连同上面的标题一起显示
        if idx <= 1 then target = 0 end
    end
    if not target or self.offset - target < vh * 0.3 then target = self.offset - math.floor(vh * 0.8) end
    self.offset = math.max(0, math.min(target, self.offset - 1))
    self:repaint("partial")
    return true
end

-- 后台陆续下载这些书的封面（子进程里下，每批几张），每下完一批重画一次内容（保持当前位置）
function PagedView:fetchCovers(books)
    local Direct = require("weread/direct")
    local Async = require("weread/async")
    local pending = {}
    for _, b in ipairs(books or {}) do
        if b.cover and not Direct.cachedCover(b) then pending[#pending + 1] = b end
    end
    if #pending == 0 then return end
    local i = 0
    local function step()
        if self.closed then return end
        local batch = {}
        for _ = 1, 6 do
            i = i + 1
            if not pending[i] then break end
            batch[#batch + 1] = pending[i]
        end
        if #batch == 0 then return end
        Async.run(function()
            for _, b in ipairs(batch) do Direct.coverFile(b) end
            return true
        end, function()
            if self.closed then return end
            self:refresh(true)
            step()
        end)
    end
    step()
end

function PagedView:onCloseWidget()
    self.closed = true
end

function PagedView:onTap(pos)
    local hit = BottomBar.hit(pos, self.tab)
    if hit == "prev" then return self:onPrevPage() end
    if hit == "next" then return self:onNextPage() end
    if hit == "back" then return self:onBack() end
    if hit == "store" or hit == "shelf" or hit == "me" then
        if hit ~= self.tab and self.on_tab then self.on_tab(hit) end
        return true
    end
    if hit then return self:onTapBar(pos) end
    if pos.y < self.viewport_top then
        if self.onTapHeader then self:onTapHeader(pos) end
        return true
    end
    if self.onTapContent then self:onTapContent(pos.x, pos.y - self.viewport_top + self.offset) end
    return true
end

-- 点在底部栏的空白处（二级页面可以在这里放自己的按钮，子类覆盖）
function PagedView:onTapBar(pos)
    return true
end

function PagedView:onBack()
    UIManager:close(self)
    if self.on_back then self.on_back() end
    return true
end

-- 唤醒时系统状态栏会在屏幕顶上重画一次电量，等它画完再整屏重画盖掉
function PagedView:onResume()
    UIManager:scheduleIn(2, function() UIManager:setDirty(self, "full") end)
end

return PagedView
