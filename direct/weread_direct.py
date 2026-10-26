# 直连微信读书 App 接口（i.weread.qq.com）的原型，验证 Kindle 不经代理独立取书的可行性。
# 协议细节来自墨水屏版 2.1.2 源码：
#   登录    loginservice/model/{WRLoginService,LoginService}.java、login/fragment/QRLoginDialogFragment.java
#   请求头  network/interceptor/{WRRequestInterceptor,LoginStateInterceptor}.java
#   章节    bookdownloadservice/model/{BaseBookDownloadService,ChapterResp}.java、reader/convert/ReaderConvert.java
import base64
import hashlib
import io
import json
import os
import random
import secrets
import sys
import time
import zipfile

import requests
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

HOST = "https://i.weread.qq.com"
DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".data")
SESSION_FILE = os.path.join(DATA_DIR, "session.json")

WX_APP_ID = "wxab9b71ad2b90ff34"
WX_SCOPE = "snsapi_userinfo,snsapi_friend,snsapi_favorites"
NONCE = "weread"  # LoginService.genNonceStr() 返回常量 WRLog.LOG_DIR
DEVICE_TYPE_EINK = 3  # LoginService.DEVICE_TYPE_EINK
DEVICE_NAME = "Kindle"

APP_VERSION = "2.1.2"
HEADERS = {
    "appver": f"{APP_VERSION}.10245900",
    "basever": f"{APP_VERSION}.10245900",
    "channelId": "900",  # APK 签名块 0x71777777：{"channel":"900"}
    "osver": "7.0",
    "baseapi": "24",
    "User-Agent": f"WeRead/{APP_VERSION} WRBrand/other Dalvik/2.1.0 (Linux; U; Android 7.0; Kindle)",
}


def load_session():
    try:
        with open(SESSION_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_session(s):
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    fd = os.open(SESSION_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(s, f)


def anti_replay(device_id):
    # AntiReplayAction.getAntiReplaySignature：sha256(时间戳 + deviceId + 随机数)
    ts = int(time.time() * 1000)
    rnd = random.randrange(1000)
    sig = hashlib.sha256(f"{ts}{device_id}{rnd}".encode()).hexdigest()
    return ts, rnd, sig


class Client:
    def __init__(self):
        self.s = load_session()
        if "deviceId" not in self.s:
            self.s["deviceId"] = secrets.token_hex(16)
            save_session(self.s)
        self.http = requests.Session()
        self.http.headers.update(HEADERS)

    def _auth_headers(self):
        if "accessToken" not in self.s:
            return {}
        return {"accessToken": self.s["accessToken"], "vid": str(self.s["vid"])}

    def request(self, method, path, retry=True, **kw):
        r = self.http.request(method, HOST + path, headers=self._auth_headers(), timeout=30, **kw)
        # 登录态失效时服务端返回 errcode -2012 一类的 JSON，用 refreshToken 续一次
        if retry and r.headers.get("content-type", "").startswith("application/json"):
            body = r.json()
            if isinstance(body, dict) and body.get("errcode") in (-2010, -2012, -2013) and self.s.get("refreshToken"):
                print("[auth] token 失效，刷新：", body.get("errcode"), body.get("errmsg"))
                self.refresh()
                return self.request(method, path, retry=False, **kw)
        return r

    # ---- 登录 ----

    def login_qr(self, qr_path):
        t = self.request("GET", "/wxticket", params={"nonceStr": NONCE}).json()
        if not t.get("signature"):
            raise RuntimeError(f"wxticket 失败：{t}")
        q = requests.get(
            "https://open.weixin.qq.com/connect/sdk/qrconnect",
            params={"appid": WX_APP_ID, "noncestr": NONCE, "timestamp": t["timeStamp"],
                    "scope": WX_SCOPE, "signature": t["signature"]},
            timeout=30,
        ).json()
        if q.get("errcode", 0) != 0:
            raise RuntimeError(f"获取二维码失败：{q}")
        with open(qr_path, "wb") as f:
            f.write(base64.b64decode(q["qrcode"]["qrcodebase64"]))
        print(f"QR {qr_path}", flush=True)

        last = 0
        while True:
            url = f"https://long.open.weixin.qq.com/connect/l/qrconnect?f=json&uuid={q['uuid']}"
            if last:
                url += f"&last={last}"
            p = requests.get(url, timeout=70).json()
            code = p.get("wx_errcode")
            if code == 405:
                wx_code = p["wx_code"]
                break
            if code == 404 and last != 404:
                print("已扫码，等待手机上确认…", flush=True)
            elif code in (402, 403):
                raise RuntimeError("二维码过期或被取消" if code == 402 else "用户拒绝授权")
            if code != 408:
                last = code

        ts, rnd, sig = anti_replay(self.s["deviceId"])
        info = self.request("POST", "/login", json={
            "code": wx_code, "deviceId": self.s["deviceId"], "trackId": "",
            "timestamp": ts, "random": rnd, "signature": sig,
            "isFromQrcode": 1, "isAutoLogout": 0,
            "deviceName": DEVICE_NAME, "deviceType": DEVICE_TYPE_EINK,
        }).json()
        self._take_login(info)
        print("登录成功 vid =", self.s["vid"])

    def refresh(self):
        ts, rnd, sig = anti_replay(self.s["deviceId"])
        info = self.request("POST", "/login", retry=False, json={
            "refreshToken": self.s["refreshToken"], "deviceId": self.s["deviceId"],
            "wxToken": 0, "inBackground": 0, "trackId": "", "kickType": 1, "refCgi": "",
            "timestamp": ts, "random": rnd, "signature": sig, "deviceName": DEVICE_NAME,
        }).json()
        self._take_login(info)

    def _take_login(self, info):
        if "accessToken" not in info:
            raise RuntimeError(f"登录失败：{ {k: v for k, v in info.items() if 'token' not in k.lower()} }")
        self.s.update(vid=info["vid"], accessToken=info["accessToken"], refreshToken=info.get("refreshToken"))
        save_session(self.s)


    # ---- 书架 / 章节 ----

    def shelf(self):
        return self.request("GET", "/shelf/sync", params={"synckey": 0, "lectureSynckey": 0}).json()

    def book_info(self, book_id):
        return self.request("GET", "/book/info", params={"bookId": book_id}).json()

    def chapters(self, book_id):
        r = self.request("POST", "/book/chapterInfos", json={"bookIds": [book_id], "synckeys": [0]}).json()
        return r["data"][0]["updated"]

    def download_chapters(self, book_id, uids, book_type="epub", version=0):
        # BookDownloadService.requestStream：EPUB 要把 0 号（公用样式等资源）一起带上
        r = self.request("GET", "/book/chapterdownload", params={
            "bookId": book_id, "chapters": ",".join(map(str, uids)),
            "pf": "wechat_wx-2001-android-100-weread", "pfkey": "pfKey", "zoneId": "1",
            "bookVersion": version, "bookType": book_type, "quote": "",
            "release": 1, "stopAutoPayWhenBNE": 1, "preload": 0, "preview": 0, "offline": 0,
        })
        return r


def content_key(encrypt_key_header, vid):
    # ChapterResp.aesDecryptKey：vid 重复到 32 字节，前 16 字节作 key、后 16 字节作 iv，AES-CBC 解 encryptkey
    v = str(vid).encode()
    kiv = (v * (32 // len(v) + 1))[:32]
    dec = Cipher(algorithms.AES(kiv[:16]), modes.CBC(kiv[16:])).decryptor()
    raw = dec.update(base64.b64decode(encrypt_key_header)) + dec.finalize()
    unpad = padding.PKCS7(128).unpadder()
    return unpad.update(raw) + unpad.finalize()


def main():
    c = Client()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "login":
        c.login_qr(sys.argv[2])
    elif cmd == "status":
        print("已登录" if "accessToken" in c.s else "未登录", "vid =", c.s.get("vid"))
    elif cmd == "shelf":
        sh = c.shelf()
        for b in sh.get("books", [])[:30]:
            print(b.get("bookId"), b.get("format"), b.get("payType"), b.get("title"), "/", b.get("author"))
        print("keys:", list(sh.keys()))
    elif cmd == "chapters":
        for ch in c.chapters(sys.argv[2])[:15]:
            print(ch.get("chapterUid"), ch.get("paid"), ch.get("price"), ch.get("wordCount"), ch.get("title"))
    elif cmd == "info":
        info = c.book_info(sys.argv[2])
        print({k: info.get(k) for k in ("title", "format", "version", "payType", "free", "price", "soldout", "finished")})
    elif cmd == "download":
        book_id, uid, out_dir = sys.argv[2], int(sys.argv[3]), sys.argv[4]
        info = c.book_info(book_id)
        uids = [0, uid] if info.get("format") == "epub" and uid != 0 else [uid]
        r = c.download_chapters(book_id, uids, info.get("format", "epub"), info.get("version", 0))
        print("HTTP", r.status_code, r.headers.get("content-type"), len(r.content), "bytes")
        ek = next((v for k, v in r.headers.items() if k.strip().lower() == "encryptkey"), None)
        if ek is None:
            print("没有 encryptkey，返回：", r.content[:300])
            return
        key = content_key(ek, c.s["vid"])
        # ReaderConvert.unzipEPUB：解出的密钥是 ZipCrypto 解压密码（ZipDecryptInputStream）。
        # GilbertVernam 只用于 App 自己的本地缓存，网络内容不涉及
        os.makedirs(out_dir, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(r.content)) as z:
            z.setpassword(key)
            for name in z.namelist():
                if name.endswith("/"):
                    continue
                data = z.read(name)
                path = os.path.join(out_dir, name)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as f:
                    f.write(data)
                print(f"  {name}  {len(data)}  {data[:60]!r}")


if __name__ == "__main__":
    main()
