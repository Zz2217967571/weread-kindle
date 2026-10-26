"""生成书库里“微信读书”入口的封面图：kindle/launcher/cover.png（灰度，墨水屏友好）。

用法：python3 tools/make-cover.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "kindle" / "launcher" / "cover.png"

W, H = 938, 1432  # 和 KOReader 入口封面同尺寸
SONGTI = "/System/Library/Fonts/Supplemental/Songti.ttc"
HEITI = "/System/Library/Fonts/STHeiti Medium.ttc"

BG = 24
FG = 255
DIM = 150


def text_center(draw, y, text, font, fill, spacing=0):
    if spacing:
        widths = [draw.textlength(ch, font=font) for ch in text]
        total = sum(widths) + spacing * (len(text) - 1)
        x = (W - total) / 2
        for ch, w in zip(text, widths):
            draw.text((x, y), ch, font=font, fill=fill)
            x += w + spacing
    else:
        w = draw.textlength(text, font=font)
        draw.text(((W - w) / 2, y), text, font=font, fill=fill)


def open_book(draw, cx, top, page_w, page_h, sag):
    """两页向中缝微微下沉的展开书本。"""
    gap = 14
    left = [
        (cx - gap, top + sag), (cx - gap - page_w, top),
        (cx - gap - page_w, top + page_h), (cx - gap, top + page_h + sag),
    ]
    right = [(2 * cx - x, y) for x, y in left]
    draw.polygon(left, fill=FG)
    draw.polygon(right, fill=FG)
    # 书页上的几行“文字”
    for i in range(5):
        y = top + 46 + i * 30
        draw.line([(cx - gap - page_w + 34, y), (cx - gap - 30, y + sag * 0.8)], fill=BG, width=6)
        if i < 4:
            # 前两行让出右上角书签的位置
            end = cx + gap + page_w - (100 if i < 2 else 34)
            draw.line([(cx + gap + 30, y + sag * 0.8), (end, y)], fill=BG, width=6)
    # 右页上的书签丝带
    rx = cx + gap + page_w - 70
    draw.polygon([(rx, top - 6), (rx + 34, top - 6), (rx + 34, top + 96), (rx + 17, top + 78), (rx, top + 96)], fill=DIM)


def main():
    img = Image.new("L", (W, H), BG)
    d = ImageDraw.Draw(img)

    open_book(d, W / 2, 330, 250, 240, 26)

    title = ImageFont.truetype(SONGTI, 150, index=0)  # Songti SC Black
    text_center(d, 720, "微信读书", title, FG, spacing=10)

    d.line([(W / 2 - 120, 940), (W / 2 + 120, 940)], fill=DIM, width=3)

    sub = ImageFont.truetype(HEITI, 44, index=1)
    text_center(d, 985, "Kindle 版", sub, DIM, spacing=4)

    foot = ImageFont.truetype(HEITI, 34, index=1)
    text_center(d, H - 140, "W E R E A D", foot, DIM)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT, optimize=True)
    print(OUT, OUT.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
