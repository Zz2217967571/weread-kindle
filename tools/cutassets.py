# 从官方截图（模拟器分辨率与 Kindle 相同，1264×1680）裁出界面素材，放到 kindle/weread/res/。
# 坐标来自 ref/official/*.xml 的控件边界。重新截图后再跑一次即可更新。
import os
from PIL import Image

REF = "ref/official"
OUT = "kindle/weread/res"
os.makedirs(OUT, exist_ok=True)

CUTS = {
    # 底部栏三个标签：未选中 / 选中
    "tab_store": ("10-shelf", (56, 1542, 109, 1595)),
    "tab_store_on": ("20-store", (56, 1542, 109, 1595)),
    "tab_shelf": ("20-store", (221, 1542, 274, 1595)),
    "tab_shelf_on": ("10-shelf", (221, 1542, 274, 1595)),
    "tab_me": ("10-shelf", (386, 1542, 439, 1595)),
    "tab_me_on": ("30-me", (386, 1542, 439, 1595)),
    # 翻页按钮四种状态：paging_<上一页可用><下一页可用>
    "paging_01": ("10-shelf", (994, 1517, 1264, 1620)),
    "paging_10": ("11-shelf-p2", (994, 1517, 1264, 1620)),
    "paging_11": ("21-store-p3", (994, 1517, 1264, 1620)),
    "paging_00": ("31-settings", (994, 1517, 1264, 1620)),
    # 书架顶部
    "icon_search": ("10-shelf", (66, 79, 108, 121)),
    "icon_import": ("10-shelf", (973, 203, 1013, 245)),
    "icon_select": ("10-shelf", (1120, 203, 1160, 245)),
    # 登录页
    "login_logo": ("01-login", (470, 405, 800, 490)),
    # “我”页面每行左边的圆形图标、右边的箭头（30-me，行高 180，第一行图标 y=363）
    "me_account": ("30-me", (37, 362, 107, 432)),
    "me_article": ("30-me", (37, 542, 107, 612)),
    "me_device": ("30-me", (37, 722, 107, 792)),
    "me_settings": ("30-me", (37, 902, 107, 972)),
    "me_update": ("30-me", (37, 1082, 107, 1152)),
    "me_chevron": ("30-me", (1198, 378, 1230, 416)),
    # 阅读页左上角的圆形返回按钮
    "reading_back": ("40-reader", (52, 46, 90, 84)),
    # “已阅读并同意 用户协议 & 隐私政策”整行：未勾选 / 勾选
    "login_agree": ("01-login", (424, 1200, 840, 1244)),
    "login_agree_on": ("02-login-qr", (424, 1200, 840, 1244)),
}

for name, (shot, box) in CUTS.items():
    Image.open(f"{REF}/{shot}.png").convert("L").crop(box).save(f"{OUT}/{name}.png")
    print(name, box[2] - box[0], "x", box[3] - box[1])

# 登录页的灰色占位二维码：官方截图里的那张压着“获取二维码”按钮，这里拿真二维码淡化成同样的灰（230），
# 按钮另外画，这样过期、重试等状态也能用
qr = Image.open(f"{REF}/02-login-qr.png").convert("L").crop((408, 652, 856, 1100))
qr.point(lambda v: 230 if v < 128 else 255).save(f"{OUT}/login_qr_placeholder.png")
print("login_qr_placeholder 448 x 448")
