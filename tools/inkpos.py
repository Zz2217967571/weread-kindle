# 比较官方截图和我们截图里同一块区域的墨迹外框，输出偏差。用法：python3 tools/inkpos.py 官方 我们 x0 y0 x1 y1 [我们的 y 偏移] [名字]
import sys
from PIL import Image
ref, ours = sys.argv[1:3]
x0, y0, x1, y1 = map(int, sys.argv[3:7])
dy = int(sys.argv[7]) if len(sys.argv) > 7 else 0
name = sys.argv[8] if len(sys.argv) > 8 else ""
def ink(p, oy):
    b = Image.open(p).convert("L").crop((x0, y0 + oy, x1, y1 + oy)).point(lambda v: 255 if v < 128 else 0).getbbox()
    return (b[0] + x0, b[1] + y0, b[2] + x0, b[3] + y0) if b else None
a, b = ink(ref, 0), ink(ours, dy)
print(f"{name:6s} 官方 {a}  我们 {b}  偏差 dx={b[0]-a[0]} dy={b[1]-a[1]} dw={(b[2]-b[0])-(a[2]-a[0])} dh={(b[3]-b[1])-(a[3]-a[1])}")
