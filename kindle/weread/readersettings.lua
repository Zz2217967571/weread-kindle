-- 阅读设置：字号、字重、行距、边距、字体，档位和官方墨水屏版一致，存在 G_reader_settings 里。
--   字号：FontSizeService 大屏档位（dp），默认 22；字重：arrays.xml reader_content_font_weights，默认 0.5
--   行距、边距：源码里是运行时算的，这里先取五档，默认中间（之后对照官方再细调）
local logger = require("logger")

local Config = require("weread/config")
local Fonts = require("weread/fonts")

local S = {}

local DP = 1.875  -- Oasis 3：300dpi / 160
S.FONT_SIZES_DP = { 18, 20, 22, 23, 24, 25, 26, 28, 30, 33, 36, 40 }
S.FONT_WEIGHTS = { 0, 0.5, 1, 1.5, 2, 2.5, 3 }
S.LINE_SPACINGS = { 100, 115, 130, 150, 170 }      -- 行高百分比
S.PADDINGS = { 60, 88, 115, 145, 175 }             -- 左右页边距（像素）

S.DEFAULTS = { font_size = 3, font_weight = 2, line_spacing = 3, padding = 3, font = "system" }

function S.get(name)
    return G_reader_settings:readSetting("weread_" .. name) or S.DEFAULTS[name]
end

function S.set(name, value)
    G_reader_settings:saveSetting("weread_" .. name, value)
    G_reader_settings:flush()
end

-- 首行缩进（官方默认开）、段间距（官方默认关）
function S.indentOn() return G_reader_settings:nilOrTrue("weread_indent") end
function S.paraSpaceOn() return G_reader_settings:isTrue("weread_para_space") end

-- 当前字体条目（见 weread/fonts）：设置里存的是字体 id；没下载好（或旧版本存的名字找不到）就用系统字体
function S.font()
    local e = Fonts.byId(S.get("font"))
    if e and Fonts.isReady(e) then return e end
    return Fonts.byId("system")
end

-- crengine 的字体名：注册字体文件时记下新出现的字体名。字体文件大（几 MB 到几十 MB），用到时才注册
local face_names = {}
local cre_engine
function S.registerFile(file)
    if face_names[file] then return face_names[file] end
    if not cre_engine then return nil end
    local before = {}
    for _, n in ipairs(cre_engine.getFontFaces()) do before[n] = true end
    local ok, err = pcall(cre_engine.registerFont, Fonts.dir() .. file)
    if not ok then logger.warn("weread: register font failed", file, err) end
    for _, n in ipairs(cre_engine.getFontFaces()) do
        if not before[n] then face_names[file] = n end
    end
    logger.info("weread: font", file, "=", face_names[file])
    return face_names[file]
end

function S.registerFonts(cre)
    cre_engine = cre
    S.registerFile(Fonts.file(S.font()))
end

function S.fontSizePx(level)
    return math.floor(S.FONT_SIZES_DP[level or S.get("font_size")] * DP + 0.5)
end

-- 把当前设置应用到 crengine 文档。dimen 是正文区域，top/bottom 是上下边距
function S.apply(doc, dimen, top, bottom)
    local file = Fonts.file(S.font())
    doc:setFontFace(S.registerFile(file) or "Noto Sans CJK SC")
    doc:setFontSize(S.fontSizePx())
    -- 官方字重 0~3（默认 0.5）对应 crengine 基础字重 375~525
    doc:setFontBaseWeight((S.FONT_WEIGHTS[S.get("font_weight")] - 0.5) / 2)
    doc:setInterlineSpacePercent(S.LINE_SPACINGS[S.get("line_spacing")])
    -- 首行缩进和段间距（官方 CSSCursor.initPrefixForRawText）：缩进开 → 缩进 2em，“段间距”开则段后空 0.5em、关则不空；
    -- 缩进关 → 不缩进，段后固定空 1em
    if S.indentOn() then
        doc:setStyleSheet("", "p { text-indent: 2em !important; "
            .. (S.paraSpaceOn() and "margin-bottom: 0.5em" or "margin: 0") .. " !important; }")
    else
        doc:setStyleSheet("", "p { text-indent: 0 !important; margin-bottom: 1em !important; }")
    end
    local pad = S.PADDINGS[S.get("padding")]
    doc:setViewDimen(dimen)
    doc:setPageMargins(pad, top, pad, bottom)
end

return S
