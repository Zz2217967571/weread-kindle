-- 官方墨水屏版的版式：字体、颜色、素材路径。
-- 尺寸一律用 Oasis 3 屏幕像素，和 ref/official 里的参照截图（模拟器同分辨率）1:1，坐标直接取自截图的控件边界。
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Screen = Device.screen

local Config = require("weread/config")

local Theme = {}

Theme.WHITE = Blitbuffer.COLOR_WHITE
Theme.BLACK = Blitbuffer.COLOR_BLACK
-- 分割线、封面描边（截图里是 187）
Theme.LINE_GRAY = Blitbuffer.Color8(187)
-- 搜索框占位文字（119）
Theme.HINT_GRAY = Blitbuffer.Color8(119)

-- 官方界面用安卓系统字体（思源黑体）。从模拟器取出可变字重版本，导出了这三个固定字重
Theme.REGULAR = "Regular"
Theme.SERIF = "Serif"
Theme.MEDIUM = "Medium"
Theme.BOLD = "Bold"
-- 官方的大号数字（书评数、阅读时长等）用 APK 自带的 WeReadLS（DIN 风格，只有数字和少量符号）
Theme.DIN_BOLD = "DIN-Bold"
Theme.DIN_MEDIUM = "DIN-Medium"
local DIN_FILES = { ["DIN-Bold"] = "WeReadLS-Bold.otf", ["DIN-Medium"] = "WeReadLS-Medium.otf" }

-- Font:getFace 只在 KOReader 的字体目录（./fonts，进程当前目录是 /mnt/us/koreader）里找字体，
-- 所以给它一个从那里出发的相对路径。它还会把字号按 Screen:scaleBySize 放大（向上取整），这里先反算，
-- 保证最终正好是指定的像素字号
local font_scale
local FONT_REL = "../../weread/fonts/WRSans-"
function Theme.face(weight, px)
    if weight == Theme.SERIF then return Theme.serif(px) end
    if not font_scale then font_scale = Screen:scaleBySize(10000) / 10000 end
    if DIN_FILES[weight] then
        return Font:getFace("../../weread/fonts/" .. DIN_FILES[weight], (px - 0.5) / font_scale)
    end
    return Font:getFace(FONT_REL .. weight .. ".otf", (px - 0.5) / font_scale)
end

-- 衬线标题字（“最近阅读”“猜你喜欢”、用户名等）：APK 里的思源宋体
function Theme.serif(px)
    if not font_scale then font_scale = Screen:scaleBySize(10000) / 10000 end
    return Font:getFace("../../weread/fonts/SourceHanSerifCN-Medium.otf", (px - 0.5) / font_scale)
end

function Theme.res(name)
    return Config.appDir() .. "/weread/res/" .. name
end

-- 思源黑体的汉字墨迹顶部约在基线以上 0.86em：用来把“墨迹顶部”坐标换成文字框坐标
Theme.INK_ASCENT = 0.86

return Theme
