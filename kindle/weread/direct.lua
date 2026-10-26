-- 直连微信读书 App 接口（i.weread.qq.com），不经过 Mac 上的代理。
-- 协议来自墨水屏版 2.1.2 源码，流程先在 Mac 上用 direct/weread_direct.py 验证过：
--   登录：wxticket → 微信开放平台扫码 → /login 换 vid + accessToken，过期用 refreshToken 续
--   章节：/book/chapterdownload 返回 ZipCrypto 加密的 zip，响应头 encryptkey 用 vid 派生的 AES 解出 zip 密码
local bit = require("bit")
local ffi = require("ffi")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local mime = require("mime")
local rapidjson = require("rapidjson")
local sha2 = require("ffi/sha2")
local socketutil = require("socketutil")
local util = require("ffi/util")

local crypto = require("ffi/crypto")
local libcrypto = ffi.loadlib("crypto", "57")
local libarchive = ffi.loadlib("archive", "13")
require("ffi/libarchive_h")
require("ffi/posix_h")
-- KOReader 的头文件里没有这两个，库里是有的
ffi.cdef[[
const EVP_CIPHER *EVP_aes_128_cbc(void);
int archive_read_add_passphrase(struct archive *, const char *);
]]

local Config = require("weread/config")

local HOST = "https://i.weread.qq.com"
local WX_APP_ID = "wxab9b71ad2b90ff34"
local WX_SCOPE = "snsapi_userinfo,snsapi_friend,snsapi_favorites"
local NONCE = "weread" -- LoginService.genNonceStr()
local DEVICE_TYPE_EINK = 3
local DEVICE_NAME = "Kindle"
local APP_VERSION = "2.1.2"
local HEADERS = {
    appver = APP_VERSION .. ".10245900",
    basever = APP_VERSION .. ".10245900",
    channelId = "900", -- APK 签名块里的渠道号
    osver = "7.0",
    baseapi = "24",
    ["User-Agent"] = "WeRead/" .. APP_VERSION .. " WRBrand/other Dalvik/2.1.0 (Linux; U; Android 7.0; Kindle)",
}
-- ErrorCode.java：-2012 会话超时，-2010 没有 vid，-2013 鉴权失败
local SESSION_ERRORS = { [-2010] = true, [-2012] = true, [-2013] = true }

local NETWORK_WAIT_SECONDS = 30
local NETWORK_RETRY_INTERVAL = 1.5

local Direct = {
    -- 断网等待时的界面提示，由 App 设置：on_network_wait(true) 开始等，(false) 结束
    on_network_wait = nil,
}

-- ---- 登录态 ----

local function sessionFile()
    return Config.appDir() .. "/session.json"
end

local session = nil

local function loadSession()
    if session then return session end
    local f = io.open(sessionFile(), "rb")
    session = f and rapidjson.decode(f:read("*a")) or {}
    if f then f:close() end
    if type(session) ~= "table" then session = {} end
    if not session.deviceId then
        local r = io.open("/dev/urandom", "rb")
        local bytes = r:read(16)
        r:close()
        session.deviceId = (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
        Direct.saveSession()
    end
    return session
end

-- 子进程里可能续了登录，主线程要重新读会话文件
function Direct.reloadSession()
    session = nil
end

function Direct.saveSession()
    local f = io.open(sessionFile(), "wb")
    if not f then return end
    f:write(rapidjson.encode(session))
    f:close()
end

function Direct.isLoggedIn()
    return loadSession().accessToken ~= nil
end

function Direct.logout()
    local s = loadSession()
    s.vid, s.accessToken, s.refreshToken = nil, nil, nil
    Direct.saveSession()
end

local function antiReplay()
    -- AntiReplayAction.getAntiReplaySignature：sha256(毫秒时间戳 .. deviceId .. 0~999 随机数)
    local sec, usec = util.gettime()
    local ts = string.format("%d%03d", sec, math.floor(usec / 1000))
    local rnd = math.random(0, 999)
    return ts, rnd, sha2.sha256(ts .. loadSession().deviceId .. rnd)
end

-- ---- HTTP ----

-- 发一次请求。成功返回 body, code, headers；网络层失败返回 nil, 错误字符串, true。
-- no_redirect 为真时不自动跟随跳转（调用方自己处理 Location）
local function requestOnce(method, url, body, use_auth, timeout, no_redirect)
    local headers = {}
    for k, v in pairs(HEADERS) do headers[k] = v end
    local s = loadSession()
    if use_auth and s.accessToken then
        headers.accessToken = s.accessToken
        headers.vid = tostring(s.vid)
    end
    if body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end
    local chunks = {}
    local w0 = require("socket").gettime()
    socketutil:set_timeout(timeout or 10, timeout or 30)
    local ok, code, resp_headers = http.request{
        url = url,
        method = method,
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(chunks),
        redirect = not no_redirect,
    }
    socketutil:reset_timeout()
    local w1 = require("socket").gettime()
    logger.info(string.format("weread perf http %s %s %.0fms", method, url:match("^[^?]*"):gsub("^https?://[^/]+", ""), (w1 - w0) * 1000))
    if not ok or type(code) ~= "number" then
        logger.warn("weread direct", method, url:match("^[^?]*"), "failed:", code)
        return nil, tostring(code), true
    end
    return table.concat(chunks), code, resp_headers or {}
end

-- Kindle 从休眠醒来后 Wi-Fi 要几秒才重新连上，这期间每隔一会儿重试，最多等 NETWORK_WAIT_SECONDS
local function request(method, url, body, use_auth, timeout)
    local resp, code, headers = requestOnce(method, url, body, use_auth, timeout)
    if resp or headers ~= true then return resp, code, headers end
    if Direct.on_network_wait then Direct.on_network_wait(true) end
    local waited = 0
    while waited < NETWORK_WAIT_SECONDS do
        util.usleep(math.floor(NETWORK_RETRY_INTERVAL * 1000000))
        waited = waited + NETWORK_RETRY_INTERVAL
        resp, code, headers = requestOnce(method, url, body, use_auth, timeout)
        if resp or headers ~= true then break end
    end
    if Direct.on_network_wait then Direct.on_network_wait(false) end
    if not resp then return nil, "网络连接失败，请确认 Kindle 已联网" end
    return resp, code, headers
end

local function encodeQuery(params)
    local parts = {}
    for k, v in pairs(params) do
        parts[#parts + 1] = k .. "=" .. tostring(v):gsub("[^%w%-_%.~,]", function(c)
            return string.format("%%%02X", c:byte())
        end)
    end
    return table.concat(parts, "&")
end

local function decodeJson(resp)
    local data = rapidjson.decode(resp)
    if type(data) ~= "table" then return nil, "数据解析失败" end
    return data
end

-- 调 App 接口：自动带登录态，会话过期时用 refreshToken 续一次再重试
function Direct.api(method, path, params, json_body, retried)
    local url = HOST .. path
    if params then url = url .. "?" .. encodeQuery(params) end
    local body = json_body and rapidjson.encode(json_body) or nil
    local resp, code = request(method, url, body, true)
    if not resp then return nil, code end
    local data, err = decodeJson(resp)
    if not data then return nil, err end
    if data.errcode and data.errcode ~= 0 then
        if SESSION_ERRORS[data.errcode] and not retried and loadSession().refreshToken then
            local ok, rerr = Direct.refresh()
            if not ok then return nil, rerr end
            return Direct.api(method, path, params, json_body, true)
        end
        logger.warn("weread direct", path, "errcode", data.errcode, data.errmsg)
        if SESSION_ERRORS[data.errcode] then return nil, "登录已失效，请重新扫码登录", "relogin" end
        return nil, data.errmsg or ("请求失败：" .. data.errcode)
    end
    return data
end

-- ---- 登录 ----

local function takeLogin(info)
    if type(info) ~= "table" or not info.accessToken then
        logger.warn("weread direct login failed", info and info.errcode, info and info.errmsg)
        return nil, "登录失败：" .. tostring(info and (info.errmsg or info.errcode))
    end
    local s = loadSession()
    s.vid, s.accessToken, s.refreshToken = info.vid, info.accessToken, info.refreshToken
    Direct.saveSession()
    return true
end

function Direct.refresh()
    local s = loadSession()
    local ts, rnd, sig = antiReplay()
    local resp, err = request("POST", HOST .. "/login", rapidjson.encode{
        refreshToken = s.refreshToken, deviceId = s.deviceId, wxToken = 0, inBackground = 0,
        trackId = "", kickType = 1, refCgi = "", timestamp = tonumber(ts), random = rnd,
        signature = sig, deviceName = DEVICE_NAME,
    }, false)
    if not resp then return nil, err end
    local ok, lerr = takeLogin(decodeJson(resp))
    if not ok then
        Direct.logout()
        return nil, "登录已失效，请重新扫码登录", "relogin"
    end
    return true
end

-- 第一步：拿二维码。返回 { png = 图片数据, uuid = ... }
function Direct.loginQrcode()
    local t, err = Direct.api("GET", "/wxticket", { nonceStr = NONCE })
    if not t then return nil, err end
    if not t.signature or t.signature == "" then return nil, "获取登录票据失败" end
    local resp, rerr = request("GET", "https://open.weixin.qq.com/connect/sdk/qrconnect?" .. encodeQuery{
        appid = WX_APP_ID, noncestr = NONCE, timestamp = t.timeStamp, scope = WX_SCOPE, signature = t.signature,
    }, nil, false)
    if not resp then return nil, rerr end
    local q = decodeJson(resp)
    if not q or (q.errcode or 0) ~= 0 or not q.qrcode then return nil, "获取二维码失败" end
    return { png = mime.unb64(q.qrcode.qrcodebase64), uuid = q.uuid, last = 0 }
end

-- 第二步：长轮询扫码状态。服务端会挂起一段时间才回，这里只等 LOGIN_POLL_SECONDS 就断开重发，
-- 因为等待期间界面不响应。返回 "waiting" / "scanned" / "done" / "expired"，或 nil, err
local LOGIN_POLL_SECONDS = 10
function Direct.loginPoll(qr)
    local url = "https://long.open.weixin.qq.com/connect/l/qrconnect?f=json&uuid=" .. qr.uuid
    if qr.last ~= 0 then url = url .. "&last=" .. qr.last end
    local resp = requestOnce("GET", url, nil, false, LOGIN_POLL_SECONDS)
    if not resp then return "waiting" end -- 长轮询超时属于正常情况，接着等
    local p = decodeJson(resp) or {}
    local code = p.wx_errcode
    if code ~= 408 and code then qr.last = code end
    if code == 404 then return "scanned" end
    if code == 402 or code == 403 then return "expired" end
    if code ~= 405 then return "waiting" end

    local s = loadSession()
    local ts, rnd, sig = antiReplay()
    local lresp, lerr = request("POST", HOST .. "/login", rapidjson.encode{
        code = p.wx_code, deviceId = s.deviceId, trackId = "", timestamp = tonumber(ts),
        random = rnd, signature = sig, isFromQrcode = 1, isAutoLogout = 0,
        deviceName = DEVICE_NAME, deviceType = DEVICE_TYPE_EINK,
    }, false)
    if not lresp then return nil, lerr end
    local ok, terr = takeLogin(decodeJson(lresp))
    if not ok then return nil, terr end
    return "done"
end

-- ---- 书架 / 书 / 章节 ----

-- 书架，和官方墨水屏版一致：
--   books 里是公开阅读的书；私密阅读的书只在 bookProgress 里有进度，信息要再用 /book/infos 查；
--   “文章收藏”在 mp 里，也算私密。按最近阅读时间排序（私密书没有 readUpdateTime，用进度的 updateTime）
function Direct.shelf()
    local data, err, kind = Direct.api("GET", "/shelf/sync", { synckey = 0, lectureSynckey = 0 })
    if not data then return nil, err, kind end
    local progress = {}
    for _, p in ipairs(data.bookProgress or {}) do progress[p.bookId] = p end
    local books, seen = {}, {}
    for _, b in ipairs(data.books or {}) do
        b.private = false
        books[#books + 1] = b
        seen[b.bookId] = true
    end
    local private_ids = {}
    for _, p in ipairs(data.bookProgress or {}) do
        if not seen[p.bookId] then private_ids[#private_ids + 1] = p.bookId end
    end
    if #private_ids > 0 then
        local infos = Direct.api("POST", "/book/infos", nil, { bookIds = private_ids })
        for _, b in ipairs(infos and infos.data or {}) do
            b.private = true
            books[#books + 1] = b
        end
    end
    if data.mp and data.mp.show == 1 and data.mp.book then
        local mp = data.mp.book
        mp.private, mp.kind = true, "mp"
        books[#books + 1] = mp
    end
    local function readTime(b)
        local p = progress[b.bookId]
        return b.readUpdateTime or (p and p.updateTime) or b.updateTime or 0
    end
    for _, b in ipairs(books) do
        local p = progress[b.bookId]
        b.progress = p and p.progress or 0
        b.reading = p
        b.sort_time = readTime(b)
    end
    table.sort(books, function(a, b) return a.sort_time > b.sort_time end)
    local public = #(data.books or {})
    return { books = books, public_count = public, private_count = #books - public }
end

function Direct.bookInfo(book_id)
    return Direct.api("GET", "/book/info", { bookId = book_id })
end

function Direct.chapterInfos(book_id)
    local data, err = Direct.api("POST", "/book/chapterInfos", nil, { bookIds = { book_id }, synckeys = { 0 } })
    if not data then return nil, err end
    return data.data and data.data[1] and data.data[1].updated or {}
end

-- 服务端的阅读进度（chapterUid、章内偏移等）
function Direct.progress(book_id)
    local data = Direct.api("GET", "/book/getProgress", { bookId = book_id })
    return data and data.book
end

-- ---- 阅读进度和阅读时长上报 ----
-- 官方 ReportService.updateProgress → /book/read。阅读时长需要签名，算法在 libencrypt.so 的
-- weread::GenSignature 里（REA 反编译还原，Mac 上实测上报后服务端累计时长按秒数增加）：
--   每个输入串逐字节查 REMAP 表替换，再加上常量 "5a6f1"，按字典序排序后拼接；
--   两轮：所有字节异或 % 11 作为循环右移位数 → SHA256 → 小写十六进制
local REMAP_HEX = "34ca55401db693c63130293532a7b811c2b516fa8bb124a4109004e908f83b8a9c8c44f9bc5c69e2a1dad2d37589f71e2d5056d77253bf22fb200f012e45876e6648f2e0cdfe67a943f49451cea54aee13268eccaa33145d0e39bbcf912b814dea99ec1a2c85c5d936744b18e1f13d9d419fb4170dd64cbedcaf972877f062ff71c1c8278f6c68a89be6591c1b1209984e3f063700ba1f0a192fc9d5d057496ffd25e4610c42cb96645fdbad60238d9a6dc3c45e3eb9926abd5b077f7695ed4fab847a80e778c7e5eb73836bfc38467d4765b352633a05d1efa3a6de9e3c02aeb27ba0f6f32ac0ac86035a540bf582d47ee3dfb0d8dd21e87c88a2795870b715"
local REMAP = {}
for i = 0, 255 do REMAP[i] = tonumber(REMAP_HEX:sub(i * 2 + 1, i * 2 + 2), 16) end

local function rotateSha(s)
    local n, k = #s, 0
    for i = 1, n do k = bit.bxor(k, s:byte(i)) end
    k = k % 11
    local t = {}
    for i = 0, n - 1 do t[(k + i) % n + 1] = s:sub(i + 1, i + 1) end
    return sha2.sha256(table.concat(t))
end

local function genSignature(keys)
    local items = {}
    for i, key in ipairs(keys) do
        items[i] = (key:gsub(".", function(c) return string.char(REMAP[c:byte()]) end))
    end
    items[#items + 1] = "5a6f1"
    table.sort(items)
    return rotateSha(rotateSha(table.concat(items)))
end

-- 测试用：和 Mac 上 Python 版（direct/）的结果比对
Direct._genSignature = genSignature

-- 签名用的 guest_token 在 /feature 下发的功能配置里，缓存一天
local function guestToken()
    local s = loadSession()
    if s.guest_token and (s.guest_token_time or 0) > os.time() - 86400 then return s.guest_token end
    local feat = Direct.api("GET", "/feature", { synckey = 0 })
    local token = feat and feat.feature and feat.feature.guest_token
    if token then
        s.guest_token, s.guest_token_time = tostring(token), os.time()
        s.max_reading_time = tonumber(feat.feature.MaxReadingTime) or s.max_reading_time
        Direct.saveSession()
    end
    return s.guest_token or ""
end

-- 两次翻页之间最多算多少秒（官方功能配置 MaxReadingTime，默认 130）
function Direct.maxReadingTime()
    return loadSession().max_reading_time or 130
end

-- 设备时区，格式和官方 Hour.generateCurrentTimeZone 一样："+08:00"
function Direct.timeZone()
    local z = os.date("%z") or "+0800"
    return z:sub(1, 3) .. ":" .. z:sub(4, 5)
end

-- 按小时分桶的起点：官方 hourBeginTime 固定按 GMT+8 取整点
function Direct.hourStart(t)
    return t - (t + 8 * 3600) % 3600
end

-- 上报阅读位置和这段时间实际的阅读时长。hours：{ { startOfHour, timeZone, readingTime, ttsTime }, … }，
-- reading_time 是各桶之和。chapter_offset 是章内字符偏移，progress 是全书百分比
function Direct.reportProgress(book_id, version, chapter_uid, chapter_idx, chapter_offset, progress, summary, reading_time, hours)
    local s = loadSession()
    local ts = util.gettime()
    local rnd = math.random(0, 999)
    local tz = Direct.timeZone()
    reading_time = reading_time or 0
    hours = hours or {}
    -- 官方 generatePayLoad：vid_deviceId_appId_bookId_risk_时区_阅读时长_听书时长_每个小时桶…，去掉末尾的 "_"
    local parts = { tostring(s.vid), s.deviceId, s.deviceId, book_id, "0", tz, tostring(reading_time), "0" }
    for _, h in ipairs(hours) do
        parts[#parts + 1] = string.format("%d_%s_%d_%d", h.startOfHour, h.timeZone, h.readingTime, h.ttsTime)
    end
    local payload = table.concat(parts, "_")
    local signature = genSignature{ guestToken(), tostring(rnd), tostring(ts), payload }
    return Direct.api("POST", "/book/read", nil, {
        bookId = book_id, chapterUid = chapter_uid, chapterIdx = chapter_idx, reviewId = "",
        chapterOffset = chapter_offset, readingTime = reading_time, ttsTime = 0, lectureTime = 0, lectureTextTime = 0,
        novalTime = 0, chapterProgress = 0, progress = progress,
        appId = s.deviceId, installId = s.deviceId, bookVersion = version or 0, summary = summary or "",
        isLecture = 0, voiceType = 0, timestamp = ts, random = rnd, signature = signature,
        autoTime = 0, isStoryFeed = 0, wordCount = 0, hours = hours, deviceId = s.deviceId, risk = 0,
        recordCreateTimeZone = tz,
    })
end

-- 这本书的阅读统计：readingTime（秒）、readingProgress、totalReadDay 等
function Direct.readInfo(book_id)
    return Direct.api("GET", "/book/readinfo", { bookId = book_id, readingDetail = 1, readingBookIndex = 1 })
end

-- ---- 书城 ----

-- 猜你喜欢：/market/list 的 23 号栏目，max_idx 往后翻就是“换一批”
function Direct.guessYouLike(count, max_idx)
    local data, err = Direct.api("GET", "/market/list", { synckey = 0, type = 23, count = count or 6, maxIdx = max_idx or 0, rn = 1 })
    if not data then return nil, err end
    local sec = data.data and data.data[1]
    local books = {}
    for _, b in ipairs(sec and sec.books or {}) do books[#books + 1] = b.bookInfo or b end
    return books
end

-- 榜单里的书：categoryId 如 "rising"（飙升·出版）、"newbook"（新书·出版），见 Direct.rankLists
function Direct.rankBooks(category_id, count, max_idx)
    local data, err = Direct.api("GET", "/market/category", {
        categoryId = category_id, synckey = 0, count = count or 20, maxIdx = max_idx or 0, rank = 1,
    })
    if not data then return nil, err end
    local books = {}
    for i, b in ipairs(data.books or {}) do
        local info = b.bookInfo or {}
        info.rank = b.searchIdx or ((max_idx or 0) + i)
        info.readingCount = b.readingCount
        books[#books + 1] = info
    end
    return books, data.totalCount, data.hasMore == 1
end

function Direct.rankLists()
    local data, err = Direct.api("GET", "/market/categories", { ranklist = 1, synckey = 0, type = 0 })
    if not data then return nil, err end
    return data.categories or {}
end

-- 热门搜索词（搜索框占位、搜索页的标签）
function Direct.searchTags()
    local data = Direct.api("GET", "/searchtags", {})
    local tags = {}
    for _, t in ipairs(data and data.tags or {}) do tags[#tags + 1] = t.tag or t.originalText end
    return tags
end

function Direct.search(keyword, count, max_idx)
    local data, err = Direct.api("GET", "/store/search", {
        keyword = keyword, count = count or 20, maxIdx = max_idx or 0, type = 0, outer = 0, fromBookId = "",
    })
    if not data then return nil, err end
    local books = {}
    for _, b in ipairs(data.books or {}) do
        if b.bookInfo then books[#books + 1] = b.bookInfo end
    end
    return books, data.hasMore == 1
end

-- 移出书架（官方 ShelfService.DeleteBook：POST /shelf/delete）
function Direct.removeFromShelf(book_ids)
    return Direct.api("POST", "/shelf/delete", nil,
        { bookIds = book_ids, albumIds = rapidjson.array({}), archiveIds = rapidjson.array({}) })
end

-- 开启 / 关闭私密阅读（官方 BookService.AddSecretBook：POST /book/secret，private 1 开 0 关）
function Direct.setSecret(book_ids, secret)
    return Direct.api("POST", "/book/secret", nil,
        { bookIds = book_ids, albumIds = rapidjson.array({}), private = secret and 1 or 0 })
end

function Direct.addToShelf(book_id)
    return Direct.api("POST", "/shelf/add", nil, { bookIds = { book_id }, albumIds = rapidjson.array({}) })
end

-- ---- 笔记：划线、想法、热门划线 ----
-- range 是“起-止”，按字符计数，指向章节原始 XHTML 文件（换行是 \r\n），见 Book:noteIntervals

-- 我在这本书里的划线（type 1）和书签（type 0），以及想法（/review/list listType=11 mine=1）
function Direct.myNotes(book_id)
    local marks = Direct.api("GET", "/book/bookmarklist", { bookId = book_id })
    local reviews = Direct.api("GET", "/review/list", { bookId = book_id, listType = 11, mine = 1, synckey = 0, listMode = 0 })
    if not marks then return nil end
    local thoughts = {}
    for _, r in ipairs(reviews and reviews.reviews or {}) do
        local rv = r.review or r
        if rv.range and rv.range ~= "" then
            thoughts[#thoughts + 1] = {
                reviewId = r.reviewId or rv.reviewId, chapterUid = rv.chapterUid, range = rv.range,
                abstract = rv.abstract, content = rv.content, createTime = rv.createTime,
            }
        end
    end
    return { marks = marks.updated or {}, thoughts = thoughts }
end

-- 一章里别人的热门划线：{ { range, count }, … }
function Direct.hotUnderlines(book_id, chapter_uid)
    local data = Direct.api("GET", "/book/underlines", { bookId = book_id, chapterUid = chapter_uid, synckey = 0 })
    return data and data.underlines or {}
end

-- 某条划线下书友的想法（官方 SyncBookUnderLineReview：/book/readreviews 按 range 查）。
-- 返回 { total, items = { { author, content, likes }, … } }
function Direct.underlineReviews(book_id, chapter_uid, range, count, max_idx)
    local data = Direct.api("POST", "/book/readreviews", nil, {
        bookId = book_id, chapterUid = chapter_uid, cht2sMode = "",
        reviews = { { range = range, count = count or 5, maxIdx = max_idx or 0, synckey = 0 } },
    })
    local block = data and data.reviews and data.reviews[1] or {}
    local items = {}
    for _, r in ipairs(block.pageReviews or {}) do
        local rv = r.review or {}
        local author = rv.author or {}
        items[#items + 1] = {
            reviewId = r.reviewId or rv.reviewId, author = author.name or "", avatar = author.avatar,
            content = rv.content or "", likes = r.likesCount or 0, comments = r.commentsCount or 0,
            liked = (r.isLike or rv.isLike) == 1,
        }
    end
    return { total = block.totalCount or 0, items = items }
end

-- 点赞 / 取消点赞一条想法或书评（官方 SingleReviewService.LikeReview）
function Direct.likeReview(review_id, like)
    local data = Direct.api("POST", "/review/like", nil, { reviewId = review_id, isUnlike = like and 0 or 1 })
    return data ~= nil
end

-- 书评（/review/list listType=3，整本书的点评）：{ { author, content, likes }, … }, has_more
function Direct.bookReviews(book_id, max_idx, count)
    local data = Direct.api("GET", "/review/list", { bookId = book_id, listType = 3, synckey = 0, listMode = 0,
        maxIdx = max_idx or 0, count = count or 10 })
    local list = {}
    for _, r in ipairs(data and data.reviews or {}) do
        local rv = r.review or {}
        list[#list + 1] = { author = rv.author and rv.author.name or "", content = rv.content or "", likes = r.likesCount or 0 }
    end
    return list, data and data.hasMore == 1, data and data.totalCount
end

-- 全书热门划线（/book/bestbookmarks）：{ { text, count, chapterUid, range }, … }, has_more, totalCount
function Direct.bestBookmarks(book_id, max_idx, count)
    local data = Direct.api("GET", "/book/bestbookmarks", { bookId = book_id, synckey = 0, maxIdx = max_idx or 0, count = count or 20 })
    local list = {}
    for _, it in ipairs(data and data.items or {}) do
        list[#list + 1] = { text = it.markText, count = it.totalCount, chapterUid = it.chapterUid, range = it.range }
    end
    return list, #list > 0 and (max_idx or 0) + #list < (data and data.totalCount or 0), data and data.totalCount
end

-- 划线（type 1）。返回 bookmarkId
function Direct.addHighlight(book_id, chapter_uid, range, text, version)
    local data, err = Direct.api("POST", "/book/addBookmark", nil, {
        bookId = book_id, chapterUid = chapter_uid, type = 1, range = range, markText = text,
        bookVersion = version or 0, style = 0,
    })
    return data and data.bookmarkId, err
end

-- 书签（type 0，官方 NoteService.addBookMark）：range 是这一页开头在原始 XHTML 里的字符位置，
-- markText 是这一页开头的一段文字。返回 bookmarkId
function Direct.addPageBookmark(book_id, chapter_uid, pos, text, version)
    local data, err = Direct.api("POST", "/book/addBookmark", nil, {
        bookId = book_id, chapterUid = chapter_uid, type = 0, range = tostring(pos), markText = text,
        bookVersion = version or 0, style = 0,
    })
    return data and data.bookmarkId, err
end

function Direct.removeBookmark(bookmark_id)
    return Direct.api("POST", "/book/removeBookmark", nil, { bookmarkId = bookmark_id })
end

-- 写想法（/review/add type 1，挂在 range 上）。返回 reviewId
function Direct.addThought(book_id, chapter_uid, range, abstract, content, version, is_private)
    local data, err = Direct.api("POST", "/review/add", nil, {
        bookId = book_id, chapterUid = chapter_uid, range = range, abstract = abstract, content = content,
        type = 1, bookVersion = version or 0, isPrivate = is_private and 1 or 0, friendship = 0, contextAbstract = "",
    })
    return data and data.reviewId, err
end

function Direct.deleteThought(review_id)
    return Direct.api("POST", "/review/delete", nil, { reviewId = review_id })
end

-- ---- 付款 ----
-- 墨水屏设备上不直接付款：官方是显示一个二维码，手机微信扫码后在网页里买会员卡 / 充书币
-- （QRMemCardDialogFragment、QRRechargeDialogFragment）。链接里的 vid 用 VidEncrpyt.encrypt 编码

local function md5(s) return sha2.md5(s) end

-- VidEncrpyt.encrypt：md5 前三位 + 类型(纯数字为 3) + "2" + md5 末两位 + 每 9 位数字转十六进制（带两位长度，"g" 分隔），
-- 不足 20 位用 md5 补齐，最后再接上整串 md5 的前三位
function Direct.encryptVid(vid)
    vid = tostring(vid)
    local m = md5(vid)
    local parts = {}
    for i = 1, #vid, 9 do parts[#parts + 1] = string.format("%x", tonumber(vid:sub(i, i + 8))) end
    local sb = m:sub(1, 3) .. "3" .. "2" .. m:sub(-2)
    for i, p in ipairs(parts) do
        sb = sb .. string.format("%02x", #p) .. p
        if i < #parts then sb = sb .. "g" end
    end
    if #sb < 20 then sb = sb .. m:sub(1, 20 - #sb) end
    return sb .. md5(sb):sub(1, 3)
end

function Direct.memberCardUrl()
    return "https://weread.qq.com/web/redirect?type=memCard&memCardExpand=1&eink=1&vid=" .. Direct.encryptVid(loadSession().vid)
end

function Direct.rechargeUrl()
    return "https://weread.qq.com/reload?from=elink&vid=" .. Direct.encryptVid(loadSession().vid)
end

-- 用书币买章节（官方 BuyChapters）。chapter_ids 用逗号分隔
function Direct.buyChapters(book_id, chapter_ids, total_price, pay_type, autopay)
    return Direct.api("POST", "/pay/buyChapters", nil, {
        bookId = book_id, chapterIds = chapter_ids, isautopay = autopay and "1" or "0", totalprice = total_price,
        pf = "wechat_wx-2001-android-100-weread", zoneid = "1", release = 1, payType = pay_type or 0, isMCard = 0,
    })
end

-- ---- 我 ----

-- 用户名、累计阅读（totalReadingTime）、本周阅读（currentReadingTime，rankWeek=1 时有效），单位秒
function Direct.profile()
    local s = loadSession()
    local data, err = Direct.api("GET", "/user/profile", {
        userVid = s.vid, gender = 1, signature = 1, vDesc = 1, totalReadingTime = 1, currentReadingTime = 1,
        isBlackMe = 1, isInBlackList = 1,
    })
    return data, err
end

function Direct.memberCard()
    return Direct.api("GET", "/pay/memberCardSummary", { pf = "wechat_wx-2001-android-100-weread" })
end

function Direct.balance()
    return Direct.api("POST", "/pay/balance", nil, { pf = "wechat_wx-2001-android-100-weread", zoneId = "1" })
end

-- 下载公开资源（插图、封面），不带登录态
-- 插图、封面会 302 跳到腾讯云的带签名地址（换了主机），自动跳转在 Kindle 上会失败，这里手动跟随
function Direct.fetch(url)
    url = url:gsub("^http:", "https:")
    for _ = 1, 3 do
        local body, code, headers = requestOnce("GET", url, nil, false, 20, true)
        if not body then return nil end
        if code == 200 then return body end
        local location = type(headers) == "table" and headers.location
        if not (code >= 300 and code < 400 and location) then return nil end
        url = location
    end
    return nil
end

-- 下载封面到本地缓存，返回文件路径；已缓存就直接返回
local function coverPath(book)
    return Config.cacheDir() .. "/cover_" .. book.bookId .. ".jpg"
end

-- 头像：下载小图（微信头像地址末尾的 /0 是原图，换成 /132）缓存到 cache/avatars/
function Direct.avatarFile(url)
    if not url or url == "" then return nil end
    local dir = Config.cacheDir() .. "/avatars"
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local path = dir .. "/" .. url:gsub("^https?://", ""):gsub("[^%w]", "_"):sub(-120) .. ".jpg"
    if lfs.attributes(path, "mode") == "file" then return path end
    local body = Direct.fetch((url:gsub("/0$", "/132")))
    if not body or #body < 100 then return nil end
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(body)
    f:close()
    return path
end

-- 已经缓存的封面路径，没有就返回 nil（不联网）
function Direct.cachedCover(book)
    local path = coverPath(book)
    return lfs.attributes(path, "mode") == "file" and path or nil
end

function Direct.coverFile(book)
    local path = coverPath(book)
    if lfs.attributes(path, "mode") == "file" then return path end
    if not book.cover or book.cover == "" then return nil end
    -- 书架给的是小图（s_ 前缀），换成中图（t6_）清楚一些
    local url = book.cover:gsub("/s_", "/t6_"):gsub("^http:", "https:")
    local body = Direct.fetch(url)
    if not body or #body < 100 then return nil end
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(body)
    f:close()
    return path
end

-- ---- 章节下载与解密 ----

local function contentKey(encrypt_key, vid)
    -- ChapterResp.aesDecryptKey：vid 重复拼到 32 字节，前 16 字节作 AES key、后 16 字节作 iv
    local v = tostring(vid)
    local kiv = string.rep(v, math.ceil(32 / #v)):sub(1, 32)
    local out, len = crypto.evp_decrypt(libcrypto.EVP_aes_128_cbc(), mime.unb64(encrypt_key),
        kiv:sub(1, 16), kiv:sub(17, 32))
    if not out then return nil end
    return crypto.pkcs7_unpad(out, len, 16)
end

local function mkdirs(path)
    local acc = ""
    for part in path:gmatch("[^/]+") do
        acc = acc .. "/" .. part
        if lfs.attributes(acc, "mode") ~= "directory" then lfs.mkdir(acc) end
    end
end

-- 解开章节包（EPUB 是带密码的 zip，TXT 是不加密的 tar，password 为 nil），所有文件写到 dest 下。zip 里只有相对路径，跳过任何 .. 以防写出目录
local function unzipWithPassword(zip_path, password, dest)
    local a = ffi.gc(libarchive.archive_read_new(), libarchive.archive_free)
    libarchive.archive_read_support_format_all(a)
    if password then libarchive.archive_read_add_passphrase(a, password) end
    if libarchive.archive_read_open_filename(a, zip_path, 10240) ~= libarchive.ARCHIVE_OK then
        return nil, "章节文件损坏"
    end
    local entry = libarchive.archive_entry_new()
    local files = {}
    while libarchive.archive_read_next_header2(a, entry) == libarchive.ARCHIVE_OK do
        local name = ffi.string(libarchive.archive_entry_pathname(entry))
        local size = tonumber(libarchive.archive_entry_size(entry))
        if not name:find("/$") and not name:find("%.%.") then
            local buf = ffi.C.malloc(math.max(size, 1))
            local n = libarchive.archive_read_data(a, buf, size)
            if n ~= size then
                ffi.C.free(buf)
                libarchive.archive_entry_free(entry)
                return nil, "章节解密失败"
            end
            local path = dest .. "/" .. name
            mkdirs(path:match("^(.*)/[^/]*$"))
            local f = io.open(path, "wb")
            f:write(ffi.string(buf, size))
            f:close()
            ffi.C.free(buf)
            files[name] = size
        end
    end
    libarchive.archive_entry_free(entry)
    return files
end

function Direct.bookDir(book_id)
    return Config.cacheDir() .. "/books/" .. book_id
end

-- 下载若干章（EPUB 会带上 0 号公用资源），解密到 bookDir。返回 info.txt 里的章节列表
-- stopAutoPayWhenBNE=1：余额不足时不自动购买
function Direct.downloadChapters(book_id, uids, book_type, version)
    local s = loadSession()
    local url = HOST .. "/book/chapterdownload?" .. encodeQuery{
        bookId = book_id, chapters = table.concat(uids, ","),
        pf = "wechat_wx-2001-android-100-weread", pfkey = "pfKey", zoneId = "1",
        bookVersion = version or 0, bookType = book_type or "epub", quote = "",
        release = 1, stopAutoPayWhenBNE = 1, preload = 0, preview = 0, offline = 0,
    }
    local resp, code, headers = request("GET", url, nil, true, 60)
    if not resp then return nil, code end
    local ek = headers and headers.encryptkey
    -- TXT 书返回不加密的 tar（UntarTXT），里面是 info.txt 和每章一个纯文本文件 <bookId>_<chapterUid>_o
    local is_tar = type(headers) == "table" and (headers["content-type"] or ""):find("tar")
    if not ek and not is_tar then
        -- 不是 zip，多半是 JSON 错误（未购买、会话过期等）
        local data = rapidjson.decode(resp)
        if type(data) == "table" and SESSION_ERRORS[data.errcode] then
            local ok, rerr = Direct.refresh()
            if not ok then return nil, rerr end
            return Direct.downloadChapters(book_id, uids, book_type, version)
        end
        logger.warn("weread direct chapterdownload", code, type(data) == "table" and data.errcode, type(data) == "table" and data.errmsg)
        -- -2223：付费章节还没买。返回里带着试读内容（info.summary），官方就是显示这段试读加购买面板
        if type(data) == "table" and data.errcode == -2223 then
            return nil, "需要购买", "locked", data.info or {}
        end
        return nil, (type(data) == "table" and data.errmsg) or "章节下载失败", "unavailable"
    end
    local key
    if ek then
        key = contentKey(ek, s.vid)
        if not key then return nil, "章节密钥解析失败" end
    end

    local dest = Direct.bookDir(book_id)
    mkdirs(dest)
    -- 压缩包先放内存盘，解完就删
    local tmp = "/tmp/weread_chapter.zip"
    local f = io.open(tmp, "wb")
    f:write(resp)
    f:close()
    local files, uerr = unzipWithPassword(tmp, key, dest)
    os.remove(tmp)
    if not files then return nil, uerr end
    local info_f = io.open(dest .. "/info.txt", "rb")
    local info = info_f and rapidjson.decode(info_f:read("*a"))
    if info_f then info_f:close() end
    return info and info.chapters or {}
end

return Direct
