-- 底部栏：左边书城 / 书架 / 我 三个标签，右边上一页 / 下一页。贴着屏幕底边，高 105：
-- 顶上 2px 灰线，下面 103px 按钮区。坐标取自参照截图（官方 y=1515~1620，这里整体下移到屏幕底部）。
local Device = require("device")
local Screen = Device.screen

local Theme = require("weread/theme")

local BottomBar = {}

BottomBar.HEIGHT = 105
local TABS = { "store", "shelf", "me" }
local TAB_W = 165
local ICON = 53
local PAGING_X, PAGING_W, PAGING_SPLIT = 994, 270, 1129

function BottomBar.top()
    return Screen:getHeight() - BottomBar.HEIGHT
end

-- tab：当前标签；为 "back" 时是二级页面，左边只有一个返回箭头。can_prev / can_next：翻页按钮是否可用
function BottomBar.ops(tab, can_prev, can_next)
    local y0 = BottomBar.top()
    local W = Screen:getWidth()
    local ops = {
        { "rect", 0, y0, W, BottomBar.HEIGHT, Theme.WHITE },
        { "hline", 0, y0, W, 2, Theme.LINE_GRAY },
    }
    if tab == "back" then
        table.insert(ops, { "image", 44, y0 + 26, Theme.res("icon_toolbar_back.svg"), 53, 53 })
    elseif tab then
        for i, name in ipairs(TABS) do
            local file = Theme.res("tab_" .. name .. (name == tab and "_on" or "") .. ".png")
            table.insert(ops, { "image", (i - 1) * TAB_W + 56, y0 + 27, file, ICON, ICON })
        end
    end
    local state = (can_prev and "1" or "0") .. (can_next and "1" or "0")
    table.insert(ops, { "image", PAGING_X, y0 + 2, Theme.res("paging_" .. state .. ".png"), PAGING_W, 103 })
    return ops
end

-- 点在底部栏的哪个按钮上：返回 "store" / "shelf" / "me" / "back" / "prev" / "next"，不在底部栏返回 nil
function BottomBar.hit(pos, tab)
    local y0 = BottomBar.top()
    if pos.y < y0 then return nil end
    if pos.x >= PAGING_X then
        return pos.x < PAGING_SPLIT and "prev" or "next"
    end
    if tab == "back" and pos.x < 141 then return "back" end
    if tab and tab ~= "back" and pos.x < TAB_W * #TABS then
        return TABS[math.floor(pos.x / TAB_W) + 1]
    end
    return "bar"
end

return BottomBar
