-- 字体库：官方 ReaderFontService + DownloadFontProvider。
-- 字体清单来自 https://weread.qq.com/feconfig/font/list?type=einklauncher_new（带一份快照在 res/fontlist.json，没网也能显示），
-- 每个字体是一个 zip（cdn.weread.qq.com）。点没下载的字体就在子进程里下载、解压到 fonts/ 下，主进程每隔一会儿看一眼进度。
-- 顺序按 largeScreenIndex（墨水屏大屏）排，和官方字体面板一致；系统字体、方正兰亭黑是官方内置的，随 App 带着。
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")
local UIManager = require("ui/uimanager")

local Config = require("weread/config")

local F = {}

local MANIFEST_URL = "https://weread.qq.com/feconfig/font/list?type=einklauncher_new"
local TAG_ORDER = { ["仓耳"] = 1, ["方正"] = 2, ["其他"] = 3 }

-- 随 App 带的字体文件：id → 文件名。这几个不用下载
local BUNDLED = {
    system = "WRSans-Regular.otf",
    syst = "SourceHanSerifCN-Medium.otf",
    fzlth = "FZLTHProGBK-DB.ttf",
    syht = "WRSans-Regular.otf",
}
-- 旧版本存的字体名 → 现在的字体 id
local OLD_KEYS = {
    system = "system", siyuansong = "syst", fzlanting = "fzlth", siyuanhei = "syht",
    cangerjinkai04 = "cejk", cangerjinkai05 = "TsangerJinKai03-W05", jinghualaosong = "KingHwa_OldSong",
    cangerxuansan04 = "TsangerXuanSan01JF-W04", cangerxuansan05 = "cexs", hanchanhuosong = "ChillHuoSong_F_Regular",
    fzlantingyuan = "fzlty", cangeryunhei04 = "ceyh", cangeryunhei05 = "TsangerYunHei-W05", hanchanzhengkai = "ChillKai",
}

function F.dir() return Config.appDir() .. "/fonts/" end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function exists(path) return lfs.attributes(path, "mode") == "file" end

-- 字体文件至少有几十 KB；比这小的是下载或解压出了问题留下的坏文件，不算已下载
local MIN_FONT_SIZE = 50 * 1024
local function validFont(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file" and attr.size >= MIN_FONT_SIZE
end

local manifest_cache
local function loadManifest()
    if manifest_cache then return manifest_cache end
    local cached = Config.cacheDir() .. "/fontlist.json"
    for _, path in ipairs{ cached, Config.appDir() .. "/weread/res/fontlist.json" } do
        local s = readFile(path)
        local data = s and rapidjson.decode(s)
        if type(data) == "table" and type(data.items) == "table" then
            manifest_cache = data.items
            return manifest_cache
        end
    end
    manifest_cache = {}
    return manifest_cache
end

-- 从服务器更新字体清单（阻塞，约 1 秒；失败就继续用旧的）
function F.refresh()
    local Direct = require("weread/direct")
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local chunks = {}
    socketutil:set_timeout(8, 15)
    local ok, code = http.request{ url = MANIFEST_URL, sink = ltn12.sink.table(chunks), redirect = true }
    socketutil:reset_timeout()
    if not ok or code ~= 200 then
        logger.warn("weread fonts: manifest fetch failed", code)
        return false
    end
    local body = table.concat(chunks)
    local data = rapidjson.decode(body)
    if type(data) ~= "table" or type(data.items) ~= "table" then return false end
    local f = io.open(Config.cacheDir() .. "/fontlist.json", "wb")
    if f then f:write(body) f:close() end
    manifest_cache, F._entries = data.items, nil
    return true
end

-- 字体条目，按官方顺序：{ id, name, tag, single, url, zip_size, suffix, bundled, has_preview }
function F.entries()
    if F._entries then return F._entries end
    local list = {}
    for _, it in ipairs(loadManifest()) do
        list[#list + 1] = {
            id = it.font, name = it.fontName, tag = it.fontType, single = it.largeScreenSingleTypeIndex or it.singleTypeIndex or 0,
            order = it.largeScreenIndex or it.index or 99, url = it.url, zip_size = it.zipSize or 0,
            suffix = it.suffix or "ttf", has_preview = it.previewImageUrl ~= nil,
        }
    end
    -- 官方内置：系统字体排第一，方正兰亭黑在 5 号位（largeScreenIndex 空出来的那个）
    list[#list + 1] = { id = "system", name = "系统字体", order = 0, single = 0, bundled = true }
    list[#list + 1] = { id = "fzlth", name = "方正兰亭黑", tag = "方正", order = 5, single = 0, bundled = true }
    table.sort(list, function(a, b) return a.order < b.order end)
    for _, e in ipairs(list) do
        e.bundled_file = BUNDLED[e.id]
        e.preview_n = Config.appDir() .. "/weread/res/fontpreview/" .. e.id .. "_n.png"
        e.preview_s = Config.appDir() .. "/weread/res/fontpreview/" .. e.id .. "_s.png"
        if exists(e.preview_n) then
            -- PNG 头里有宽高（IHDR：第 16~23 字节）
            local f = io.open(e.preview_n, "rb")
            local head = f and f:read(24)
            if f then f:close() end
            if head and #head == 24 then
                local function u32(i) local a, b, c, d = head:byte(i, i + 3) return ((a * 256 + b) * 256 + c) * 256 + d end
                e.preview_w, e.preview_h = u32(17), u32(21)
            end
        end
        if not e.preview_w then e.preview_n, e.preview_s = nil, nil end
    end
    F._entries = list
    return list
end

-- 官方 FontTypeSettingTable.generateFontTypeTagList：第一个标签“全部”，后面按分类（仓耳 / 方正 / 其他）排，分类里按序号排
function F.tags()
    local entries = F.entries()
    local tags, by_tag = { { name = "全部", fonts = entries } }, {}
    for _, e in ipairs(entries) do
        if e.tag and e.tag ~= "" then
            by_tag[e.tag] = by_tag[e.tag] or {}
            table.insert(by_tag[e.tag], e)
        end
    end
    local names = {}
    for name in pairs(by_tag) do names[#names + 1] = name end
    table.sort(names, function(a, b) return (TAG_ORDER[a] or 9) < (TAG_ORDER[b] or 9) end)
    for _, name in ipairs(names) do
        table.sort(by_tag[name], function(a, b) return a.single < b.single end)
        tags[#tags + 1] = { name = name, fonts = by_tag[name] }
    end
    return tags
end

function F.byId(id)
    id = OLD_KEYS[id] or id
    for _, e in ipairs(F.entries()) do
        if e.id == id then return e end
    end
end

-- 本地字体文件名（在 fonts/ 下）；还没下载是 nil
function F.file(e)
    if e.bundled_file then
        if validFont(F.dir() .. e.bundled_file) then return e.bundled_file end
        return nil
    end
    local name = e.id .. "." .. e.suffix
    if validFont(F.dir() .. name) then return name end
end

function F.isReady(e) return F.file(e) ~= nil end

-- ---- 下载 ----

local function writeFile(path, s)
    local f = io.open(path, "wb")
    if f then f:write(s) f:close() end
end

-- 开始下载：下载、解压都在子进程里做；on_progress(e) 每隔一会儿调一次，on_done(e, ok) 在结束时调一次
function F.download(e, on_progress, on_done)
    if e.downloading or F.isReady(e) or not e.url then return end
    e.downloading, e.progress = true, 0
    local tmp = "/tmp/weread-font-" .. e.id
    local dest = F.dir() .. e.id .. "." .. e.suffix
    local url, total = e.url, e.zip_size
    os.remove(tmp .. ".result")
    local pid = ffiutil.runInSubProcess(function()
        local http = require("socket.http")
        local socketutil = require("socketutil")
        local out = io.open(tmp .. ".zip", "wb")
        if not out then return writeFile(tmp .. ".result", "fail") end
        local got, last = 0, 0
        local function sink(chunk)
            if chunk then
                out:write(chunk)
                got = got + #chunk
                if got - last >= 262144 then
                    last = got
                    writeFile(tmp .. ".progress", tostring(got))
                end
            end
            return 1
        end
        socketutil:set_timeout(15, 900)
        local ok, code = http.request{ url = url, sink = sink, redirect = true }
        out:close()
        if not ok or code ~= 200 then return writeFile(tmp .. ".result", "fail") end
        -- 解压后挑出里面的字体文件，挪到 fonts/ 下
        os.execute(string.format("rm -rf '%s.d'; mkdir -p '%s.d'; unzip -o -q '%s.zip' -d '%s.d'", tmp, tmp, tmp, tmp))
        -- zip 里常带 macOS 的 __MACOSX/._xxx.ttf（几百字节的资源叉），要跳过；有多个字体文件时取最大的
        local found, found_size = nil, 0
        local function scan(dir)
            for name in lfs.dir(dir) do
                if name ~= "." and name ~= ".." and name ~= "__MACOSX" and name:sub(1, 2) ~= "._" then
                    local path = dir .. "/" .. name
                    local attr = lfs.attributes(path)
                    if attr and attr.mode == "directory" then
                        scan(path)
                    elseif attr and attr.mode == "file" and name:lower():match("%.[to]tf$") and attr.size > found_size then
                        found, found_size = path, attr.size
                    end
                end
            end
        end
        scan(tmp .. ".d")
        local result = "fail"
        if found then
            os.execute(string.format("mv -f '%s' '%s.part' && mv -f '%s.part' '%s'", found, dest, dest, dest))
            if validFont(dest) then result = "ok" else os.remove(dest) end
        end
        os.execute(string.format("rm -rf '%s.d' '%s.zip' '%s.progress'", tmp, tmp, tmp))
        writeFile(tmp .. ".result", result)
    end)
    local function tick()
        local got = tonumber(readFile(tmp .. ".progress") or "")
        if got and total > 0 then e.progress = math.min(99, math.floor(got * 100 / total)) end
        if ffiutil.isSubProcessDone(pid) then
            local ok = readFile(tmp .. ".result") == "ok"
            os.remove(tmp .. ".result")
            e.downloading, e.progress = false, nil
            if not ok then logger.warn("weread fonts: download failed", e.id) end
            if on_done then on_done(e, ok) end
            return
        end
        if on_progress then on_progress(e) end
        UIManager:scheduleIn(0.8, tick)
    end
    UIManager:scheduleIn(0.8, tick)
end

return F
