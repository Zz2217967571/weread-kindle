# 从官方截图里测出文字的字重和字号：在给定区域内取墨迹外框，用 WRSans 各字重、各字号渲染同样文字，
# 找宽高最接近的。用法：python3 tools/fitfont.py 截图 x0 y0 x1 y1 文字
import sys
from PIL import Image, ImageDraw, ImageFont
shot, x0, y0, x1, y1, text = sys.argv[1], *map(int, sys.argv[2:6]), sys.argv[6]
img = Image.open(shot).convert('L').crop((x0, y0, x1, y1))
ink = img.point(lambda v: 255 if v < 160 else 0).getbbox()
tw, th = ink[2] - ink[0], ink[3] - ink[1]
best = []
for w in ('Regular', 'Medium', 'Bold'):
    for px in range(16, 90):
        f = ImageFont.truetype(f'build/fonts/WRSans-{w}.otf', px)
        c = Image.new('L', (px * len(text) * 2, px * 2), 0)
        ImageDraw.Draw(c).text((px // 2, px // 2), text, font=f, fill=255)
        b = c.getbbox()
        # 同字号下比较笔画粗细：墨迹像素占比
        crop = c.crop(b)
        dens = sum(crop.point(lambda v: 1 if v > 95 else 0).getdata()) / (crop.width * crop.height)
        best.append((abs(b[2] - b[0] - tw) + abs(b[3] - b[1] - th), w, px, b[2] - b[0], b[3] - b[1], dens))
ref = img.crop(ink)
rdens = sum(ref.point(lambda v: 1 if v < 160 else 0).getdata()) / (ref.width * ref.height)
best.sort(key=lambda r: (r[0], abs(r[5] - rdens)))
print(f'{text}: ink {tw}x{th} at ({x0 + ink[0]},{y0 + ink[1]}) density {rdens:.3f}')
for r in best[:4]:
    print(f'   {r[1]:8s} {r[2]}px  -> {r[3]}x{r[4]}  density {r[5]:.3f}')
