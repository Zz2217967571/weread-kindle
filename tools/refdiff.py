# 把 Kindle 截图和官方参照截图的同一块区域做逐像素对比，输出差异图（红色 = 只在官方里有，蓝色 = 只在我们这有）。
# 用法：python3 tools/refdiff.py 官方.png 我们.png 输出.png  x y w h [我们这边的 y 偏移]
import sys
from PIL import Image, ImageChops
ref, ours, out = sys.argv[1:4]
x, y, w, h = map(int, sys.argv[4:8])
dy = int(sys.argv[8]) if len(sys.argv) > 8 else 0
a = Image.open(ref).convert("L").crop((x, y, x + w, y + h))
b = Image.open(ours).convert("L").crop((x, y + dy, x + w, y + dy + h))
ta = a.point(lambda v: 255 if v < 128 else 0)
tb = b.point(lambda v: 255 if v < 128 else 0)
only_a = ImageChops.subtract(ta, tb)
only_b = ImageChops.subtract(tb, ta)
diff = sum(1 for v in ImageChops.difference(ta, tb).getdata() if v)
ink = sum(1 for v in ta.getdata() if v)
print(f"差异像素 {diff} / 官方墨迹 {ink}")
rgb = Image.merge("RGB", (a, a, a)).point(lambda v: 160 + v * 95 // 255)
red = Image.new("RGB", rgb.size, (230, 0, 0))
blue = Image.new("RGB", rgb.size, (0, 60, 230))
rgb.paste(red, mask=only_a)
rgb.paste(blue, mask=only_b)
rgb.save(out)
