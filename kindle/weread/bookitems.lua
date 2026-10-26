-- 书城、榜单、搜索里通用的“书”绘制：封面（带官方的边缘压暗描边）、横排的书条目。
local Canvas = require("weread/canvas")
local Direct = require("weread/direct")
local Theme = require("weread/theme")

local T = Canvas.text

local Items = {}

-- 封面：还没下载的先画空框，下载完由页面重画
function Items.cover(ops, book, x, y, w, h)
    local file = Direct.cachedCover(book)
    if file then table.insert(ops, { "image", x, y, file, w, h }) end
    table.insert(ops, { "shade", x, y, w, h, 2, 0.267 })
end

-- 推荐值文字：newRating 是千分制（902 → 90.2%），后面带标签（神作、好评如潮…）
function Items.ratingText(book)
    if not book.newRating or book.newRating <= 0 then return nil end
    local s = string.format("推荐值 %.1f%%", book.newRating / 10)
    local tag = book.newRatingDetail and book.newRatingDetail.title
    if tag and tag ~= "" then s = s .. "（" .. tag .. "）" end
    return s
end

-- 横排条目：左封面 143×205，右边书名 / 作者 / 附加信息。官方“猜你喜欢”和榜单就是这种两列排版
-- 返回条目高度。rank 不为空时书名前加排名
function Items.row(ops, book, x, y, width, rank)
    local cw, ch = 143, 205
    Items.cover(ops, book, x, y, cw, ch)
    local tx, tw = x + cw + 26, width - cw - 26
    local title = (rank and (rank .. "  ") or "") .. (book.title or "")
    table.insert(ops, T(tx, y + 54, title, Theme.BOLD, 32, nil, tw))
    table.insert(ops, T(tx, y + 110, book.author or "", Theme.BOLD, 25, nil, tw))
    local extra = Items.ratingText(book)
    if extra then table.insert(ops, T(tx, y + 158, extra, Theme.REGULAR, 21, nil, tw)) end
    return ch
end

return Items
