# 把 APK 里的 Android VectorDrawable（res/drawable/*.xml）转成 SVG，给 Kindle 端直接用官方图标。
# 支持 vector / group（平移、缩放、旋转）/ path / clip-path，颜色引用 @color/xxx 从 values/colors.xml 取。
# 用法：python3 tools/vd2svg.py 图标名 [图标名…] 输出目录
import os
import re
import sys
import xml.etree.ElementTree as ET

RES = os.environ.get("WEREAD_APK_RES", "weread_eink_2.1.2/resources/res")  # 反编译出的 APK res 目录
A = "{http://schemas.android.com/apk/res/android}"


def load_colors():
    colors = {}
    for path in (f"{RES}/values/colors.xml",):
        for c in ET.parse(path).getroot().iter("color"):
            colors[c.get("name")] = (c.text or "").strip()
    return colors


COLORS = load_colors()
DIMENS = {d.get("name"): (d.text or "").strip() for d in ET.parse(f"{RES}/values/dimens.xml").getroot().iter("dimen")}


def color(value, alpha=None):
    """返回 (rgb, opacity)。Android 的 #AARRGGBB 要拆出透明度。"""
    if not value:
        return None, None
    for _ in range(5):
        if value.startswith("@color/") or value.startswith("@android:color/"):
            value = COLORS.get(value.split("/")[-1], "#000000")
        else:
            break
    if value.startswith("@"):
        value = "#000000"
    v = value.lstrip("#")
    op = 1.0
    if len(v) == 8:
        op = int(v[:2], 16) / 255
        v = v[2:]
    elif len(v) == 4:
        op = int(v[0] * 2, 16) / 255
        v = "".join(ch * 2 for ch in v[1:])
    elif len(v) == 3:
        v = "".join(ch * 2 for ch in v)
    if alpha is not None:
        op *= float(alpha)
    return "#" + v, op


def dim(value):
    while value.startswith("@dimen/"):
        value = DIMENS[value.split("/")[-1]]
    return float(re.match(r"[-\d.]+", value).group(0))


def convert(node, out):
    tag = node.tag
    if tag == "group":
        t = []
        px, py = float(node.get(A + "pivotX", 0)), float(node.get(A + "pivotY", 0))
        tx, ty = float(node.get(A + "translateX", 0)), float(node.get(A + "translateY", 0))
        sx, sy = float(node.get(A + "scaleX", 1)), float(node.get(A + "scaleY", 1))
        rot = float(node.get(A + "rotation", 0))
        # Android 的顺序：先绕 pivot 缩放、旋转，再平移
        t.append(f"translate({tx + px},{ty + py})")
        if rot:
            t.append(f"rotate({rot})")
        if sx != 1 or sy != 1:
            t.append(f"scale({sx},{sy})")
        t.append(f"translate({-px},{-py})")
        out.append(f'<g transform="{" ".join(t)}">')
        for child in node:
            convert(child, out)
        out.append("</g>")
    elif tag == "path":
        d = node.get(A + "pathData")
        fill, fop = color(node.get(A + "fillColor"), node.get(A + "fillAlpha"))
        stroke, sop = color(node.get(A + "strokeColor"), node.get(A + "strokeAlpha"))
        attrs = [f'd="{d}"']
        attrs.append(f'fill="{fill}"' if fill and fop > 0 else 'fill="none"')
        if fill and fop < 1:
            attrs.append(f'fill-opacity="{fop:.3f}"')
        if node.get(A + "fillType") == "evenOdd":
            attrs.append('fill-rule="evenodd"')
        sw = float(node.get(A + "strokeWidth", 0))
        if stroke and sop > 0 and sw > 0:
            attrs.append(f'stroke="{stroke}" stroke-width="{sw}"')
            if sop < 1:
                attrs.append(f'stroke-opacity="{sop:.3f}"')
            cap = node.get(A + "strokeLineCap")
            join = node.get(A + "strokeLineJoin")
            if cap:
                attrs.append(f'stroke-linecap="{cap}"')
            if join:
                attrs.append(f'stroke-linejoin="{join}"')
        out.append(f'<path {" ".join(attrs)}/>')
    elif tag == "clip-path":
        pass  # 官方图标里用得极少，忽略


def vd2svg(name):
    path = f"{RES}/drawable/{name}.xml"
    root = ET.parse(path).getroot()
    if root.tag != "vector":
        raise ValueError(f"{name} 不是 vector（是 {root.tag}）")
    vw, vh = float(root.get(A + "viewportWidth")), float(root.get(A + "viewportHeight"))
    w, h = dim(root.get(A + "width")), dim(root.get(A + "height"))
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {vw} {vh}">']
    for child in root:
        convert(child, out)
    out.append("</svg>")
    return "\n".join(out)


if __name__ == "__main__":
    *names, out_dir = sys.argv[1:]
    os.makedirs(out_dir, exist_ok=True)
    for n in names:
        with open(os.path.join(out_dir, n + ".svg"), "w") as f:
            f.write(vd2svg(n))
        print(n)
