-- App 顶层：登录、底部栏三个标签（书城 / 书架 / 我）和阅读页之间的切换。
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Direct = require("weread/direct")
local LoginView = require("weread/loginview")
local ReaderView = require("weread/readerview")
local AccountView = require("weread/accountview")
local BookDetailView = require("weread/bookdetailview")
local BookPreviewView = require("weread/bookpreviewview")
local BookListView = require("weread/booklistview")
local MeView = require("weread/meview")
local SearchView = require("weread/searchview")
local SettingsView = require("weread/settingsview")
local StoreView = require("weread/storeview")
local ShelfView = require("weread/shelfview")

local App = {}

-- 断网重试期间显示“正在连接网络…”
local function setupNetworkWait()
    local msg
    Direct.on_network_wait = function(waiting)
        if waiting and not msg then
            msg = InfoMessage:new{ text = "正在连接网络…" }
            UIManager:show(msg)
            UIManager:forceRePaint()
        elseif not waiting and msg then
            UIManager:close(msg)
            msg = nil
        end
    end
end

-- 开发用远程输入：电脑上 tools/ktap 往 /tmp/weread-input 写指令，这里每半秒读一次并当作真实触摸分发。
-- 一行一条：tap x y | hold x y | hold_pan x y | hold_release x y | swipe east|west|north|south x y | key NextPage|PrevPage
local DEV_INPUT = "/tmp/weread-input"
local function startDevInput()
    -- 上次运行崩溃时没来得及执行的指令不要再执行
    os.remove(DEV_INPUT)
    local Event = require("ui/event")
    local Geom = require("ui/geometry")
    local time = require("ui/time")
    local function poll()
        local f = io.open(DEV_INPUT, "rb")
        if f then
            local cmds = f:read("*a")
            f:close()
            os.remove(DEV_INPUT)
            for line in cmds:gmatch("[^\n]+") do
                local kind, a, b, c = line:match("^([%a_]+)%s*(%S*)%s*(%S*)%s*(%S*)")
                logger.info("weread dev input:", line)
                if kind == "tap" or kind == "hold" or kind == "hold_pan" or kind == "hold_release" then
                    UIManager:sendEvent(Event:new("Gesture", {
                        ges = kind, pos = Geom:new{ x = tonumber(a), y = tonumber(b), w = 0, h = 0 }, time = time.now(),
                    }))
                elseif kind == "swipe" then
                    UIManager:sendEvent(Event:new("Gesture", {
                        ges = "swipe", direction = a, distance = 300,
                        pos = Geom:new{ x = tonumber(b), y = tonumber(c), w = 0, h = 0 }, time = time.now(),
                    }))
                elseif kind == "key" then
                    UIManager:sendEvent(Event:new(a))
                end
            end
        end
        UIManager:scheduleIn(0.5, poll)
    end
    UIManager:scheduleIn(0.5, poll)
end

-- 开发期：存在 dev.flag 时，App 运行期间不让 Kindle 自动休眠（休眠后 Wi-Fi 断开，电脑就连不上了）
local function keepAwakeForDev()
    local Config = require("weread/config")
    local f = io.open(Config.appDir() .. "/dev.flag", "rb")
    if not f then return end
    f:close()
    os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
    logger.info("weread dev: screensaver disabled while running")
end

-- 性能日志：事件处理和重绘超过 60ms 的记一行（grep "weread perf"）
local function installPerfLog()
    local socket = require("socket")
    local function wrap(name, label)
        local orig = UIManager[name]
        UIManager[name] = function(self, ev, ...)
            local t0 = socket.gettime()
            local r = orig(self, ev, ...)
            local ms = (socket.gettime() - t0) * 1000
            if ms > 60 then
                local what = type(ev) == "table" and (ev.handler or (ev.args and ev.args[1] and ev.args[1].ges)) or ""
                logger.info(string.format("weread perf %s %s %.0fms", label, tostring(what), ms))
            end
            return r
        end
    end
    wrap("sendEvent", "event")
    wrap("_repaint", "repaint")
end

function App.stop()
    os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
end

-- 键盘默认用中文拼音（zh_CN），地球键可切到英文
local function setupKeyboard()
    if not G_reader_settings:has("keyboard_layouts") then
        G_reader_settings:saveSetting("keyboard_layouts", { "zh_CN", "en" })
        G_reader_settings:saveSetting("keyboard_layout_default", "zh_CN")
        G_reader_settings:saveSetting("keyboard_layout", "zh_CN")
    end
end

function App:start()
    setupNetworkWait()
    setupKeyboard()
    keepAwakeForDev()
    App.hookScreensaver()
    installPerfLog()
    if os.getenv("WEREAD_DEV_INPUT") ~= "0" then startDevInput() end
    if Direct.isLoggedIn() then
        self:showTab("shelf")
    else
        self:showLogin()
    end
end

function App:showLogin()
    local login = LoginView:new{
        on_done = function() self:showTab("shelf") end,
    }
    UIManager:show(login, "full")
end

-- 底部栏的三个标签：书城 / 书架 / 我。切换时关掉当前页、打开目标页
function App:showTab(name)
    if self.current_tab then UIManager:close(self.current_tab) end
    local on_tab = function(target) self:showTab(target) end
    local page
    if name == "shelf" then
        page = self:makeShelf(on_tab)
    elseif name == "store" then
        page = StoreView:new{
            on_tab = on_tab,
            on_open_book = function(book, on_shelf)
                if on_shelf then self:openReader(book) else self:showDetail(book) end
            end,
            on_search = function() self:showSearch() end,
            on_rank = function(id, rank_name)
                self:showBookList("TOP50 / " .. rank_name, true, function(max_idx)
                    return Direct.rankBooks(id, 20, max_idx)
                end)
            end,
        }
    else
        page = MeView:new{
            on_tab = on_tab,
            on_row = function(id) self:showMeRow(id, page) end,
        }
    end
    self.current_tab = page
    UIManager:show(page, "full")
    page:refresh()
    if page.load and name ~= "shelf" then UIManager:nextTick(function() page:load() end) end
end

-- 二级页面：先显示骨架，再在下一轮拉数据
local function showLoaded(view)
    UIManager:show(view, "full")
    view:refresh()
    if view.load then UIManager:nextTick(function() view:load() end) end
    return view
end

-- preview：从书城点进来的还没加书架的书（预览模式，见 ReaderView）
function App:openReader(book, on_close, preview)
    local reader = ReaderView:new{ book = book, on_close = on_close, preview = preview }
    self:prepareSleepImage(book)
    UIManager:show(reader, "full")
    reader:open()
    return reader
end

-- 息屏画面：正在读的那本书的封面信息页。每本书存一张图在缓存里（下次打开直接用），
-- 打开书后在子进程里重画一遍保持最新（息屏当口不能联网，主线程也不能卡）
function App:prepareSleepImage(book)
    local Config = require("weread/config")
    local path = string.format("%s/sleep_%s.png", Config.cacheDir(), book.bookId)
    if require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then App.sleep_file = path end
    UIManager:scheduleIn(8, function()
        require("weread/async").run(function()
            local bb = BookPreviewView.snapshot(book)
            if not bb then return nil end
            bb:writePNG(path .. ".tmp")
            os.rename(path .. ".tmp", path)
            return path
        end, function(file)
            if file then App.sleep_file = file else logger.warn("weread sleep image failed") end
        end)
    end)
end

-- 让 KOReader 的息屏流程显示这张图。App 里没有 ReaderUI / FileManager，原版 setup 会直接跳过
function App.hookScreensaver()
    local Screensaver = require("ui/screensaver")
    local orig_setup = Screensaver.setup
    Screensaver.setup = function(self, ...)
        if not App.sleep_file then return orig_setup(self, ...) end
        self.ui = true
        self.show_message = false
        self.overlay_message = nil
        self.screensaver_type = "cover"
        self.image = nil
        self.image_file = App.sleep_file
        self.screensaver_background = "white"
    end
end

-- 新书介绍：封面信息页 → 简介页 → 正文（预览阅读器）。翻过简介页就进入正文，正文里返回回到封面信息页
function App:showDetail(book, page)
    local view
    view = BookPreviewView:new{
        book = book,
        page = page,
        on_read = function(b)
            UIManager:close(view, "full")
            local reader = self:openReader(b, nil, true)
            -- 正文第一页再往回翻：关掉阅读页，回到简介页
            reader.on_front = function(r)
                r:close()
                self:showDetail(b, 2)
            end
        end,
    }
    showLoaded(view)
end

function App:showBookList(title, ranked, fetch)
    showLoaded(BookListView:new{
        title = title, ranked = ranked, fetch = fetch,
        on_open_book = function(b) self:showDetail(b) end,
    })
end

function App:showSearch()
    showLoaded(SearchView:new{
        on_search = function(keyword)
            self:showBookList("搜索：" .. keyword, false, function(max_idx)
                return Direct.search(keyword, 20, max_idx)
            end)
        end,
    })
end

function App:showMeRow(id, me)
    if id == "account" then
        showLoaded(AccountView:new{ balance = me.balance, card = me.card })
    elseif id == "settings" then
        showLoaded(SettingsView:new{
            user_name = me.profile and me.profile.name,
            on_logout = function()
                Direct.logout()
                UIManager:close(self.current_tab)
                self.current_tab = nil
                -- 关掉设置页等二级页面，回到登录
                local widgets = {}
                for _, w in ipairs(UIManager._window_stack) do widgets[#widgets + 1] = w.widget end
                for _, w in ipairs(widgets) do UIManager:close(w) end
                self:showLogin()
            end,
        })
    elseif id == "articles" then
        UIManager:show(InfoMessage:new{ text = "微信文章稍后支持", timeout = 2 })
    end
end

function App:makeShelf(on_tab)
    local shelf
    shelf = ShelfView:new{
        on_tab = on_tab,
        on_open_book = function(book)
            if book.kind == "mp" then
                UIManager:show(InfoMessage:new{ text = "文章收藏稍后支持", timeout = 2 })
                return
            end
            local reader = ReaderView:new{
                book = book,
                -- 回到书架时重新拉一次，进度和排序会更新
                on_close = function() shelf:load() end,
            }
            self:prepareSleepImage(book)
            UIManager:show(reader, "full")
            reader:open()
            return reader
        end,
        on_relogin = function()
            UIManager:close(shelf)
            self.current_tab = nil
            self:showLogin()
        end,
        on_search = function() self:showSearch() end,
    }
    shelf:refresh()
    -- 先把空页面画出来，再去拉数据，避免启动时黑屏太久
    UIManager:nextTick(function()
        shelf:load()
        self:devAutoOpen(shelf)
    end)
    return shelf
end

-- 开发用：WEREAD_AUTOOPEN=书名关键字 启动后自动打开这本书，WEREAD_AUTOTURN=n 再自动往后翻 n 页
function App:devAutoOpen(shelf)
    local key = os.getenv("WEREAD_AUTOOPEN")
    if not key or key == "" or not shelf.books then return end
    for _, book in ipairs(shelf.books) do
        if book.title:find(key, 1, true) or book.bookId == key then
            local reader = shelf.on_open_book(book)
            local n = tonumber(os.getenv("WEREAD_AUTOTURN") or "") or 0
            local action = os.getenv("WEREAD_AUTOACTION")
            -- 书打开后再执行：先翻 n 页，再按 WEREAD_AUTOACTION 呼出菜单（menu）或打开目录（toc）
            reader.on_opened = function()
                for i = 1, n do
                    UIManager:scheduleIn(i * 2, function() reader:onNextPage() end)
                end
                logger.info("weread dev: opened, action", action, "turns", n)
                UIManager:scheduleIn(n * 2 + 2, function()
                    if action == "menu" then reader.menu = "menu" reader:redraw()
                    elseif action == "toc" then reader:openToc() end
                end)
            end
            return
        end
    end
end

return App
