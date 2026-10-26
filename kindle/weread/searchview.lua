-- 搜索页，按官方墨水屏版（ref/official/22-search.png）：顶部搜索框，下面一排热门搜索词标签。
-- 点搜索框弹出键盘输入，点标签直接搜；结果在书单页里显示。
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")

local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local PagedView = require("weread/pagedview")
local Theme = require("weread/theme")

local T = Canvas.text

local SearchView = PagedView:extend{
    tab = "back",
    viewport_top = 157,
    on_search = nil,     -- function(keyword)
}

function SearchView:load()
    self.tags = Direct.searchTags()
    self:refresh(true)
end

function SearchView:buildHeader()
    return {
        { "frame", 38, 56, 1188, 90, 2, Theme.BLACK, 45 },
        { "image", 66, 79, Theme.res("icon_search.png"), 42, 42 },
        T(122, 86, (self.tags and self.tags[1]) or "搜索", Theme.BOLD, 29, Theme.HINT_GRAY, 1050),
    }
end

-- 标签：圆角框，按宽度自动换行
function SearchView:buildContent()
    local ops = {}
    self.chips = {}
    local x, y = 38, 20
    for _, tag in ipairs(self.tags or {}) do
        local w = Canvas.textWidth(tag, Theme.BOLD, 24) + 48
        if x + w > 1226 then x, y = 38, y + 80 end
        table.insert(ops, { "frame", x, y, w, 58, 2, Theme.BLACK, 29 })
        table.insert(ops, T(x + w / 2, y + 16, tag, Theme.BOLD, 24, nil, nil, "center"))
        self.chips[#self.chips + 1] = { x = x, y = y, w = w, tag = tag }
        x = x + w + 18
    end
    return { ops = ops, height = y + 120 }
end

function SearchView:askKeyword()
    local dialog
    dialog = InputDialog:new{
        title = "搜索",
        input = "",
        input_hint = (self.tags and self.tags[1]) or "书名、作者",
        buttons = {{
            { text = "取消", id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = "搜索", is_enter_default = true,
                callback = function()
                    local kw = dialog:getInputText()
                    UIManager:close(dialog)
                    if kw == "" then kw = self.tags and self.tags[1] or "" end
                    if kw ~= "" and self.on_search then self.on_search(kw) end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SearchView:onTapHeader(pos)
    if pos.y >= 56 and pos.y <= 146 then self:askKeyword() end
end

function SearchView:onTapContent(x, y)
    for _, c in ipairs(self.chips or {}) do
        if x >= c.x and x < c.x + c.w and y >= c.y and y < c.y + 58 then
            if self.on_search then self.on_search(c.tag) end
            return
        end
    end
end

return SearchView
