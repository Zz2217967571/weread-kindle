-- 设置，按官方墨水屏版（ref/official/31-settings.png）：三个开关（点击左侧翻到下一页、正文首行缩进、
-- 阅读时显示时间），下面字体大小、清理缓存、隐私、意见反馈、退出登录。
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Canvas = require("weread/canvas")
local Config = require("weread/config")
local PagedView = require("weread/pagedview")
local Settings = require("weread/readersettings")
local Theme = require("weread/theme")

local T = Canvas.text

local ROW_TOP, ROW_H = 105, 165

local SettingsView = PagedView:extend{
    tab = "back",
    viewport_top = 45,
    user_name = "",
    on_logout = nil,
}

local function dirSize(path)
    local total = 0
    if lfs.attributes(path, "mode") ~= "directory" then return 0 end
    for f in lfs.dir(path) do
        if f ~= "." and f ~= ".." then
            local p = path .. "/" .. f
            local a = lfs.attributes(p)
            if a then total = total + (a.mode == "directory" and dirSize(p) or a.size) end
        end
    end
    return total
end

local function removeTree(path)
    if lfs.attributes(path, "mode") == "directory" then
        for f in lfs.dir(path) do
            if f ~= "." and f ~= ".." then removeTree(path .. "/" .. f) end
        end
        lfs.rmdir(path)
    else
        os.remove(path)
    end
end

function SettingsView:rows()
    local size = dirSize(Config.cacheDir()) / 1024 / 1024
    local font = Settings.FONT_SIZES_DP[Settings.get("font_size")]
    return {
        { id = "tap_left_next", title = "阅读", sub = "点击左侧翻到下一页", toggle = true },
        { id = "indent", title = "正文首行缩进", sub = "开启后，书籍正文将会首行缩进", toggle = true, default_on = true },
        { id = "show_time", title = "阅读时显示时间", sub = "开启后，阅读时会显示当前系统时间", toggle = true },
        { id = "font", title = "字体大小", sub = font == Settings.FONT_SIZES_DP[Settings.DEFAULTS.font_size] and "默认" or tostring(font) },
        { id = "cache", title = "清理缓存", sub = string.format("%.2fM", size) },
        { id = "privacy", title = "隐私", sub = "关闭个性化推荐  |  微信公众号文章  |  隐私政策  |  用户协议" },
        { id = "feedback", title = "意见反馈", sub = "微信读书团队" },
        { id = "logout", title = "退出登录", sub = "当前账号：" .. (self.user_name or "") },
    }
end

-- 开关：88×44 的胶囊，开是黑底白点在右，关是白底黑框圆点在左
local function toggleOps(ops, on, y)
    local x = 1138
    if on then
        table.insert(ops, { "rect", x, y, 88, 44, Theme.BLACK })
        table.insert(ops, { "rect", x + 50, y + 6, 32, 32, Theme.WHITE })
    else
        table.insert(ops, { "frame", x, y, 88, 44, 3, Theme.BLACK, 22 })
        table.insert(ops, { "frame", x + 8, y + 8, 28, 28, 3, Theme.BLACK, 14 })
    end
end

function SettingsView:buildContent()
    local ops = { T(632, 33, "设置", Theme.BOLD, 34, nil, nil, "center") }
    for i, r in ipairs(self:rows()) do
        local y = ROW_TOP + (i - 1) * ROW_H
        table.insert(ops, T(38, y + 24, r.title, Theme.BOLD, 32))
        table.insert(ops, T(38, y + 78, r.sub, Theme.REGULAR, 25, nil, 1060))
        if r.toggle then
            toggleOps(ops, self:isOn(r), y + 50)
        else
            table.insert(ops, { "image", 1198, y + 62, Theme.res("me_chevron.png"), 32, 38 })
        end
        table.insert(ops, { "hline", 38, y + ROW_H - 2, 1188, 2, Theme.LINE_GRAY })
    end
    return { ops = ops, height = ROW_TOP + 8 * ROW_H + 40, anchors = { ROW_TOP, ROW_TOP + ROW_H } }
end

-- 开关当前状态；没设置过时用默认值（首行缩进和官方 AccountSets 一样默认开）
function SettingsView:isOn(r)
    local v = G_reader_settings:readSetting("weread_" .. r.id)
    if v == nil then return r.default_on == true end
    return v == true
end

function SettingsView:onTapContent(x, y)
    if y < ROW_TOP then return end
    local r = self:rows()[math.floor((y - ROW_TOP) / ROW_H) + 1]
    if not r then return end
    if r.toggle then
        G_reader_settings:saveSetting("weread_" .. r.id, not self:isOn(r))
        G_reader_settings:flush()
        self:refresh(true)
    elseif r.id == "cache" then
        UIManager:show(ConfirmBox:new{
            text = "清理已下载的章节和封面？\n阅读进度和书签不受影响。",
            ok_text = "清理",
            ok_callback = function()
                local dir = Config.cacheDir()
                for f in lfs.dir(dir) do
                    if f:match("^cover_") then os.remove(dir .. "/" .. f) end
                end
                -- 书目录里只删章节文件，保留进度和书签
                local books = dir .. "/books"
                if lfs.attributes(books, "mode") == "directory" then
                    for id in lfs.dir(books) do
                        if id ~= "." and id ~= ".." then
                            for _, sub in ipairs{ "epub", "Text", "Styles", "Images" } do removeTree(books .. "/" .. id .. "/" .. sub) end
                        end
                    end
                end
                self:refresh(true)
            end,
        })
    elseif r.id == "font" then
        UIManager:show(InfoMessage:new{ text = "在阅读页的“字体”面板里调整字号", timeout = 2 })
    elseif r.id == "logout" then
        UIManager:show(ConfirmBox:new{
            text = "退出登录？",
            ok_text = "退出登录",
            ok_callback = function() if self.on_logout then self.on_logout() end end,
        })
    else
        UIManager:show(InfoMessage:new{ text = "请在手机微信读书里设置", timeout = 2 })
    end
end

return SettingsView
