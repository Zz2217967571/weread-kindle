-- 一本书的本地数据：章节列表、按需下载章节、把每章打包成独立的小 EPUB 交给 crengine 排版。
-- 目录结构（cache/books/<bookId>/）：
--   chapters.json  章节列表（/book/chapterInfos）
--   Text/ Styles/ Images/  解密出来的原始文件，路径和服务端 zip 一致
--   epub/<chapterUid>.epub  打包好的单章
local Archiver = require("ffi/archiver")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")

local Direct = require("weread/direct")

local Book = {}
Book.__index = Book

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, s)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

local function xmlEscape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- book：书架里的那条记录（bookId、title、format …）
function Book.open(book)
    local self = setmetatable({ meta = book, id = book.bookId }, Book)
    self.dir = Direct.bookDir(self.id)
    for _, sub in ipairs{ "", "/epub" } do
        if lfs.attributes(self.dir .. sub, "mode") ~= "directory" then
            local acc = ""
            for part in (self.dir .. sub):gmatch("[^/]+") do
                acc = acc .. "/" .. part
                if lfs.attributes(acc, "mode") ~= "directory" then lfs.mkdir(acc) end
            end
        end
    end
    return self
end

-- 拉书的信息和章节列表。联网失败时用上次缓存的，能离线接着读已下载的章节
local function checkFormat(self)
    if self.info.format ~= "epub" and self.info.format ~= "txt" then
        return nil, "暂时不支持这种格式的书：" .. tostring(self.info.format)
    end
    -- 封面这类没有正文的章节也保留，跟官方目录一致
    self.index_of = {}
    for i, ch in ipairs(self.chapters) do self.index_of[ch.chapterUid] = i end
    return true
end

-- 用上次存在本地的书籍信息、章节、笔记直接打开（不联网）。没有缓存返回 nil
function Book:loadCache()
    local cached = readFile(self.dir .. "/chapters.json")
    cached = cached and rapidjson.decode(cached)
    if type(cached) ~= "table" or not cached.info or not cached.chapters then return nil end
    self.info, self.chapters = cached.info, cached.chapters
    local s = readFile(self.dir .. "/notes.json")
    self.notes = s and rapidjson.decode(s) or { marks = {}, thoughts = {} }
    return checkFormat(self)
end

-- 打开一本书要联网拿的东西，放在子进程里一次取完（Async.run 的 fn）
function Book.fetchFresh(book_id)
    local info = Direct.bookInfo(book_id)
    local chapters = Direct.chapterInfos(book_id)
    return {
        info = info, chapters = chapters, notes = Direct.myNotes(book_id),
        progress = Direct.progress(book_id), read_info = Direct.readInfo(book_id), card = Direct.memberCard(),
    }
end

-- 取回新数据：写进本地缓存；章节数没变就换上新的，笔记变了返回 true（调用方重新排版标记）
function Book:applyFresh(res)
    local notes_changed = false
    if res and res.info and res.chapters then
        writeFile(self.dir .. "/chapters.json", rapidjson.encode{ info = res.info, chapters = res.chapters })
        if not self.chapters or #self.chapters == #res.chapters then
            self.info, self.chapters = res.info, res.chapters
            checkFormat(self)
        end
    end
    if res and res.notes then
        local new_json = rapidjson.encode(res.notes)
        notes_changed = self.notes ~= nil and new_json ~= rapidjson.encode(self.notes)
        writeFile(self.dir .. "/notes.json", new_json)
        self.notes = res.notes
    end
    return notes_changed
end

-- 没有缓存时用取回的数据直接建起来
function Book:loadFresh(res)
    if not (res and res.info and res.chapters) then return nil, "无法获取章节列表" end
    self.info, self.chapters = res.info, res.chapters
    local ok, err = checkFormat(self)
    if not ok then return nil, err end
    self:applyFresh(res)
    self.notes = self.notes or { marks = {}, thoughts = {} }
    return true
end

-- 同步版（书架批量下载用）：联网取，取不到就用缓存
function Book:load()
    local ok, err = self:loadFresh(Book.fetchFresh(self.id))
    if ok then return true end
    return self:loadCache() or nil, err
end

function Book:chapterCount()
    return #self.chapters
end

function Book:chapter(i)
    return self.chapters[i]
end

-- 是否可能需要付费：价格大于 0 且没有买过（会员也会显示成这样，实际下载时服务端会判断）
function Book:mayNeedPay(i)
    local ch = self.chapters[i]
    return ch and (ch.price or 0) > 0 and (ch.paid or 0) == 0
end

function Book:epubPath(i)
    return string.format("%s/epub/%d.epub", self.dir, self.chapters[i].chapterUid)
end

function Book:isCached(i)
    return self.chapters[i] ~= nil and lfs.attributes(self:epubPath(i), "mode") == "file"
end

-- 全书进度百分比：按字数估算，章内按页数比例
function Book:progressPercent(i, page, page_count)
    if not self.total_words then
        self.total_words = 0
        for _, ch in ipairs(self.chapters) do self.total_words = self.total_words + (ch.wordCount or 0) end
    end
    if self.total_words == 0 then return math.floor((i - 1) / #self.chapters * 100) end
    local before = 0
    for k = 1, i - 1 do before = before + (self.chapters[k].wordCount or 0) end
    local within = (self.chapters[i].wordCount or 0) * page / math.max(page_count, 1)
    return math.floor((before + within) / self.total_words * 100)
end

-- 下载第 i 章（如果还没有），并打包成 EPUB。返回 epub 路径
function Book:ensureChapter(i)
    local ch = self.chapters[i]
    if not ch then return nil, "没有这一章" end
    local epub = self:epubPath(i)
    if lfs.attributes(epub, "mode") == "file" then return epub end

    local files_path = string.format("%s/epub/%d.files", self.dir, ch.chapterUid)
    local files = readFile(files_path)
    files = files and rapidjson.decode(files)
    if not files and self.info.format == "txt" then
        local ok, err, kind, extra = self:downloadTxtChapter(ch)
        if kind == "locked" then return self:buildPreview(ch, extra) end
        if not ok then return nil, err, kind end
        files = ok
        writeFile(files_path, rapidjson.encode(files))
    end
    if not files then
        -- 0 号是全书公用的样式等资源，第一次下载时一起要
        local uids = { ch.chapterUid }
        if lfs.attributes(self.dir .. "/Styles", "mode") ~= "directory" then table.insert(uids, 1, 0) end
        local got, err, kind, extra = Direct.downloadChapters(self.id, uids, self.info.format, self.info.version)
        if kind == "locked" then return self:buildPreview(ch, extra) end
        if not got then return nil, err, kind end
        for _, g in ipairs(got) do
            if g.chapterUid == ch.chapterUid then files = g.files end
        end
        if not files or #files == 0 then return nil, "这一章没有内容" end
        writeFile(files_path, rapidjson.encode(files))
    end
    local ok, err = self:buildEpub(ch, files, epub)
    if not ok then return nil, err end
    return epub
end

-- TXT 书的样式：段首缩进两字、段间留一点空，标题居中加粗
local TXT_CSS = [[
h1 { font-size: 1.4em; font-weight: bold; text-align: center; margin: 1em 0 1.2em 0; }
p { text-indent: 2em; margin: 0 0 0.4em 0; text-align: justify; }
]]

local function htmlEscape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- TXT 章节：服务端给的是纯文本（段首是全角空格），转成一章 XHTML 放在 Text/<chapterUid>.xhtml
function Book:downloadTxtChapter(ch)
    local got, err, kind, extra = Direct.downloadChapters(self.id, { ch.chapterUid }, "txt", self.info.version)
    if not got then return nil, err, kind, extra end
    local raw_path = string.format("%s/%s_%d_o", self.dir, self.id, ch.chapterUid)
    local raw = readFile(raw_path)
    if not raw then return nil, "这一章没有内容" end
    os.remove(raw_path)
    local paras = { "<h1>" .. htmlEscape(ch.title or "") .. "</h1>" }
    for line in raw:gsub("\r", ""):gmatch("[^\n]+") do
        -- 去掉段首的全角空格（U+3000）和普通空白，段首缩进交给样式表
        -- （Lua 的模式按字节匹配，全角空格是三个字节，只能逐个去）
        line = line:gsub("^[ \t]+", "")
        while line:sub(1, 3) == "\227\128\128" do line = line:sub(4) end
        line = line:gsub("%s+$", "")
        if line ~= "" then paras[#paras + 1] = "<p>" .. htmlEscape(line) .. "</p>" end
    end
    for _, sub in ipairs{ "/Text", "/Styles" } do
        if lfs.attributes(self.dir .. sub, "mode") ~= "directory" then lfs.mkdir(self.dir .. sub) end
    end
    writeFile(self.dir .. "/Styles/txt.css", TXT_CSS)
    local name = string.format("Text/%d.xhtml", ch.chapterUid)
    writeFile(self.dir .. "/" .. name, table.concat{
        '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>',
        htmlEscape(ch.title or ""), '</title><link href="../Styles/txt.css" rel="stylesheet" type="text/css"/></head><body>',
        table.concat(paras, "\n"), "</body></html>",
    })
    return { name }
end

-- 没买的付费章节：用服务端给的试读（info.summary）做一个试读版 EPUB。放在另一个文件名下，
-- 不算“已下载”，在手机上买了之后再打开会重新下载完整内容。
-- 返回 epub 路径, nil, "locked", 锁定信息
function Book:buildPreview(ch, info)
    local paras = { "<h1>" .. htmlEscape(ch.title or "") .. "</h1>" }
    for line in (info.summary or ""):gmatch("[^\n]+") do
        paras[#paras + 1] = "<p>" .. htmlEscape(line) .. "</p>"
    end
    for _, sub in ipairs{ "/Text", "/Styles" } do
        if lfs.attributes(self.dir .. sub, "mode") ~= "directory" then lfs.mkdir(self.dir .. sub) end
    end
    writeFile(self.dir .. "/Styles/txt.css", TXT_CSS)
    local name = string.format("Text/%d.preview.xhtml", ch.chapterUid)
    writeFile(self.dir .. "/" .. name, table.concat{
        '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>',
        htmlEscape(ch.title or ""), '</title><link href="../Styles/txt.css" rel="stylesheet" type="text/css"/></head><body>',
        table.concat(paras, "\n"), "</body></html>",
    })
    local epub = string.format("%s/epub/%d.preview.epub", self.dir, ch.chapterUid)
    local ok, err = self:buildEpub(ch, { name }, epub)
    if not ok then return nil, err end
    return epub, nil, "locked", { price = ch.price, payType = info.payType }
end

-- 把一章的 xhtml、全书样式、这一章用到的图片打成一个 EPUB
function Book:buildEpub(ch, files, epub_path)
    local entries = {}   -- 路径 → 内容
    local manifest = {}
    local spine = {}
    local function add(path, media_type, content)
        if entries[path] then return end
        entries[path] = content
        local id = "f" .. (#manifest + 1)
        manifest[#manifest + 1] = string.format('<item id="%s" href="%s" media-type="%s"/>', id, xmlEscape(path), media_type)
        return id
    end

    local media_types = { jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", gif = "image/gif", svg = "image/svg+xml" }
    for fi, name in ipairs(files) do
        local content = readFile(self.dir .. "/" .. name)
        if content then
            -- 插图多半不在 zip 里，而是 res.weread.qq.com 上的远程地址：下载到 Images/ 并改成相对路径
            content = content:gsub('([sS][rR][cC]%s*=%s*")(https?://[^"]+)"', function(prefix, url)
                local base = url:match("([^/?#]+)$") or "img"
                local local_name = "Images/r_" .. base:gsub("[^%w%._-]", "_")
                local local_path = self.dir .. "/" .. local_name
                if lfs.attributes(self.dir .. "/Images", "mode") ~= "directory" then lfs.mkdir(self.dir .. "/Images") end
                if lfs.attributes(local_path, "mode") ~= "file" then
                    local data = Direct.fetch(url)
                    if not data or not writeFile(local_path, data) then return prefix .. url .. '"' end
                end
                return prefix .. "../" .. local_name .. '"'
            end)
            local id = add(name, "application/xhtml+xml", content)
            if id then spine[#spine + 1] = string.format('<itemref idref="%s"/>', id) end
            -- 这一章引用的图片
            for src in content:gmatch('[sS][rR][cC]%s*=%s*"([^"]+)"') do
                local img = src:gsub("^%.%./", "")
                local data = not img:find("^https?:") and readFile(self.dir .. "/" .. img)
                if data then
                    local ext = img:match("%.(%w+)$") or ""
                    add(img, media_types[ext:lower()] or "application/octet-stream", data)
                end
            end
        end
    end
    if #spine == 0 then return nil, "章节文件缺失" end
    -- 全书公用的样式目录可能还没下到（上次下载中断），没有就不带样式
    if lfs.attributes(self.dir .. "/Styles", "mode") == "directory" then
        for f in lfs.dir(self.dir .. "/Styles") do
            if f:match("%.css$") then add("Styles/" .. f, "text/css", readFile(self.dir .. "/Styles/" .. f)) end
        end
    end

    local opf = table.concat{
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">',
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">',
        '<dc:title>', xmlEscape(ch.title or ""), '</dc:title>',
        '<dc:language>zh</dc:language>',
        '<dc:identifier id="id">weread-', self.id, '-', ch.chapterUid, '</dc:identifier>',
        '</metadata><manifest>', table.concat(manifest), '</manifest>',
        '<spine>', table.concat(spine), '</spine></package>',
    }
    local container = '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        .. '<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'

    local tmp = epub_path .. ".tmp"
    local w = Archiver.Writer:new()
    if not w:open(tmp, "epub") then return nil, "无法写入章节缓存" end
    w:setZipCompression("store")
    w:addFileFromMemory("mimetype", "application/epub+zip")
    w:addFileFromMemory("META-INF/container.xml", container)
    w:addFileFromMemory("content.opf", opf)
    for path, content in pairs(entries) do
        w:addFileFromMemory(path, content)
    end
    w:close()
    os.rename(tmp, epub_path)
    logger.info("weread book: built", epub_path)
    return true
end

function Book:allCached()
    for i = 1, #self.chapters do
        if not self:isCached(i) then return false end
    end
    return true
end

-- ---- 页码估算 ----
-- 官方目录里的页码是整本排版后得出的；这里只排了读过的章节，用“每页字数”估算其余章节

-- 记下某章在当前排版下的页数，用来估算每页字数
function Book:notePageCount(i, pages)
    self.page_counts = self.page_counts or {}
    self.page_counts[i] = pages
end

function Book:charsPerPage()
    local words, pages = 0, 0
    for i, n in pairs(self.page_counts or {}) do
        local w = self.chapters[i] and self.chapters[i].wordCount or 0
        if w > 200 then words, pages = words + w, pages + n end
    end
    return pages > 0 and words / pages or 300
end

local function chapterPages(ch, cpp)
    return math.max(1, math.ceil((ch.wordCount or 0) / cpp))
end

-- 第 i 章从全书第几页开始
function Book:estimatedPage(i)
    local cpp, page = self:charsPerPage(), 1
    for k = 1, i - 1 do
        page = page + (self.page_counts and self.page_counts[k] or chapterPages(self.chapters[k], cpp))
    end
    return page
end

function Book:remainingWords(i, page, page_count)
    local left = (self.chapters[i].wordCount or 0) * (1 - page / math.max(page_count, 1))
    for k = i + 1, #self.chapters do left = left + (self.chapters[k].wordCount or 0) end
    return left
end

-- 全书百分比对应的章节
function Book:chapterAtPercent(pct)
    self:progressPercent(1, 1, 1) -- 算出 total_words
    local target, acc = self.total_words * pct / 100, 0
    for i, ch in ipairs(self.chapters) do
        acc = acc + (ch.wordCount or 0)
        if acc >= target then return i end
    end
    return #self.chapters
end

-- ---- 书签（先存本地，同步到服务端放在后面做） ----

function Book:bookmarks()
    if not self.bookmark_list then
        local s = readFile(self.dir .. "/bookmarks.json")
        self.bookmark_list = s and rapidjson.decode(s) or {}
    end
    return self.bookmark_list
end

-- 目录里的书签列表：本机的，加上服务端有、本机没有的（别的设备加的，只有章节和字符位置）
function Book:allBookmarks()
    local list, known = {}, {}
    for _, bm in ipairs(self:bookmarks()) do
        list[#list + 1] = bm
        if bm.bookmarkId then known[bm.bookmarkId] = true end
    end
    for _, m in ipairs(self.notes and self.notes.marks or {}) do
        local i = self.index_of and self.index_of[m.chapterUid]
        if m.type == 0 and i and not known[m.bookmarkId] then
            local pos = tonumber(m.range) or 0
            local src = self:chapterSource(i)
            local chars = src and select(2, src:gsub("[^\128-\191]", "")) or 0
            list[#list + 1] = {
                index = i, title = self.chapters[i].title, text = m.markText, bookmarkId = m.bookmarkId,
                fraction = chars > 0 and math.min(1, pos / chars) or 0, percent = self:progressPercent(i, 1, 1),
            }
        end
    end
    table.sort(list, function(a, b)
        if a.index ~= b.index then return a.index < b.index end
        return (a.percent or 0) < (b.percent or 0)
    end)
    return list
end

function Book:saveBookmarks()
    writeFile(self.dir .. "/bookmarks.json", rapidjson.encode(self.bookmark_list))
end

-- 按在书中的位置排序：章节序号，再按全书百分比
function Book:addBookmark(bm)
    local list = self:bookmarks()
    list[#list + 1] = bm
    table.sort(list, function(a, b)
        if a.index ~= b.index then return a.index < b.index end
        return (a.percent or 0) < (b.percent or 0)
    end)
    self:saveBookmarks()
end

function Book:removeBookmark(i)
    table.remove(self:bookmarks(), i)
    self:saveBookmarks()
end

-- ---- 笔记：划线、想法、热门划线 ----
-- 服务端的 range 是“起-止”，按字符（不是字节）计数，指向章节原始 XHTML 文件（含标签，换行是 \r\n）。
-- 显示：用区间里的文字在排好版的文档里搜出位置，由阅读页叠画（热门划线虚线、自己的划线灰底），不改章节内容。
-- 新建：拿选中的文字回到原始 XHTML 里找位置，换算成 range。

-- UTF-8 字符长度
local function charLen(b)
    if b < 0x80 then return 1 elseif b < 0xE0 then return 2 elseif b < 0xF0 then return 3 else return 4 end
end

-- 读我的笔记（网络），失败时用上次缓存的
function Book:loadNotes()
    local notes = Direct.myNotes(self.id)
    local path = self.dir .. "/notes.json"
    if notes then
        writeFile(path, rapidjson.encode(notes))
    else
        local s = readFile(path)
        notes = s and rapidjson.decode(s) or { marks = {}, thoughts = {} }
    end
    self.notes = notes
    return notes
end

-- 一章的热门划线（缓存在本地，只拉一次）
function Book:hotUnderlines(ch)
    local path = string.format("%s/hot_%d.json", self.dir, ch.chapterUid)
    local s = readFile(path)
    if s then return rapidjson.decode(s) or {} end
    local list = Direct.hotUnderlines(self.id, ch.chapterUid)
    writeFile(path, rapidjson.encode(list))
    return list
end

local function parseRange(r)
    local a, b = tostring(r or ""):match("^(%d+)%-(%d+)$")
    return tonumber(a), tonumber(b)
end

-- 这一章要标出来的区间：{ a, b, cls, pri, note }，pri 大的盖住小的
function Book:noteIntervals(ch)
    local list = {}
    if self:showHot() then
        for _, u in ipairs(self:hotUnderlines(ch)) do
            local a, b = parseRange(u.range)
            if a then list[#list + 1] = { a = a, b = b, cls = "wr-hot", pri = 1, note = { hot = true, count = u.count, range = u.range } } end
        end
    end
    local notes = self.notes or { marks = {}, thoughts = {} }
    for _, m in ipairs(notes.marks or {}) do
        if m.type == 1 and m.chapterUid == ch.chapterUid then
            local a, b = parseRange(m.range)
            if a then list[#list + 1] = { a = a, b = b, cls = "wr-mark", pri = 2, note = m } end
        end
    end
    for _, t in ipairs(notes.thoughts or {}) do
        if t.chapterUid == ch.chapterUid then
            local a, b = parseRange(t.range)
            if a then list[#list + 1] = { a = a, b = b, cls = "wr-thought", pri = 3, note = t } end
        end
    end
    return list
end

-- 给原始 XHTML 的文字区间包上 span。区间按字符计数；遇到标签、换行就先关掉 span，避免破坏结构
local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

-- 原始 XHTML 去掉标签和空白后的文字，以及每个文字在原始文件里的字符位置（起、止）
local function plainIndex(content, keep_space)
    local chars, starts, ends = {}, {}, {}
    local in_tag, ci, i, n = false, 0, 1, #content
    while i <= n do
        local len = charLen(content:byte(i))
        local ch = content:sub(i, i + len - 1)
        if ch == "<" then
            in_tag = true
        elseif ch == ">" then
            in_tag = false
        elseif not in_tag then
            if ch == "&" then
                local name = content:match("^&([#%w]+);", i)
                if name then
                    local dec = ENTITIES[name] or (name:match("^#(%d+)$") and require("util").unicodeCodepointToUtf8(tonumber(name:sub(2)))) or "?"
                    chars[#chars + 1], starts[#starts + 1], ends[#ends + 1] = dec, ci, ci + #name + 2
                    ci = ci + #name + 2
                    i = i + #name + 2
                    goto continue
                end
            end
            if not ch:match("^%s$") then
                chars[#chars + 1], starts[#starts + 1], ends[#ends + 1] = ch, ci, ci + 1
            elseif keep_space and #chars > 0 and chars[#chars] ~= " " then
                -- 连续的空白合成一个空格，和排版后的文字一致
                chars[#chars + 1], starts[#starts + 1], ends[#ends + 1] = " ", ci, ci + 1
            end
        end
        ci = ci + 1
        i = i + len
        ::continue::
    end
    return chars, starts, ends
end

-- 第 i 章的原始 XHTML（取第一个文件）
function Book:chapterSource(i)
    local ch = self.chapters[i]
    local files = readFile(string.format("%s/epub/%d.files", self.dir, ch.chapterUid))
    files = files and rapidjson.decode(files)
    if not files or not files[1] then return nil end
    return readFile(self.dir .. "/" .. files[1])
end

-- 选中的文字在第 i 章原始 XHTML 里的 range（"起-止"）。frac 是选区在章节里的大致位置（0~1），
-- 同一段文字出现多次时取最近的
function Book:findRange(i, text, frac)
    local content = self:chapterSource(i)
    if not content then return nil end
    local chars, starts, ends = plainIndex(content)
    local want = {}
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if not ch:match("^%s$") then want[#want + 1] = ch end
    end
    if #want == 0 then return nil end
    local best, best_d
    local target = (frac or 0) * #chars
    for s = 1, #chars - #want + 1 do
        if chars[s] == want[1] then
            local ok = true
            for k = 2, #want do
                if chars[s + k - 1] ~= want[k] then ok = false break end
            end
            if ok then
                local d = math.abs(s - target)
                if not best or d < best_d then best, best_d = s, d end
            end
        end
    end
    if not best then return nil end
    return string.format("%d-%d", starts[best], ends[best + #want - 1])
end

-- 第 i 章 range a~b（原始 XHTML 字符位置）里的文字，去掉标签和空白
-- keep_space 为真时保留空格（空白合成一个，去掉两头的），用来在排版后的文字里搜这段
function Book:textOfRange(i, a, b, keep_space)
    -- 整章原文逐字解析很慢，一章里的划线又很多（几百条），所以按章缓存解析结果
    self.plain_cache = self.plain_cache or {}
    local key = i .. (keep_space and "s" or "")
    local c = self.plain_cache[key]
    if not c then
        local content = self:chapterSource(i)
        if not content then return nil end
        local chars, starts = plainIndex(content, keep_space)
        c = { chars = chars, starts = starts }
        self.plain_cache[key] = c
    end
    local chars, starts = c.chars, c.starts
    -- starts 递增：二分找到第一个 >= a 的字
    local lo, hi = 1, #chars + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if starts[mid] >= a then hi = mid else lo = mid + 1 end
    end
    local out = {}
    for k = lo, #chars do
        if starts[k] >= b then break end
        out[#out + 1] = chars[k]
    end
    return (table.concat(out):gsub("^ +", ""):gsub(" +$", ""))
end

-- 是否显示书友想法（热门划线）。官方 BookHelper.isHideReview：每本书单独设置，
-- /book/info 的 hideReview：1 隐藏、2 显示、0 没设置过（跟随账号设置，默认显示）
function Book:showHot()
    return (self.info and self.info.hideReview) ~= 1
end

-- 切换显示 / 隐藏：存进本书信息缓存，并同步到服务端（官方 BookService.bookShowReview → /book/setting）
function Book:setShowHot(show)
    self.info.hideReview = show and 2 or 1
    writeFile(self.dir .. "/chapters.json", rapidjson.encode{ info = self.info, chapters = self.chapters })
    Direct.api("POST", "/book/setting", nil, { bookIds = { self.id }, hideReview = self.info.hideReview })
end

-- 笔记变了：删掉这一章打包好的 EPUB，下次打开时按新的笔记重新打包（不重新下载）
function Book:invalidateChapter(i)
    local ch = self.chapters[i]
    if not ch then return end
    if self.plain_cache then self.plain_cache[i] = nil self.plain_cache[i .. "s"] = nil end
    os.remove(self:epubPath(i))
end

-- ---- 本地阅读进度 ----

function Book:loadPosition()
    local s = readFile(self.dir .. "/position.json")
    return s and rapidjson.decode(s)
end

-- index：章节序号；xpointer：章内位置（crengine）；time：保存时间，用来和服务端进度比谁新
function Book:savePosition(index, xpointer)
    writeFile(self.dir .. "/position.json", rapidjson.encode{ index = index, xpointer = xpointer, time = os.time() })
end

return Book
