#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""三角洲影视(神马TV换皮) 后端 API 复现：RC4 + base64 解密，取出源配置。

链路：
  assets/server.json -> cos_main_url (base64, 前16字节盐)
  GET  cos -> app.json { notice.content=base64(2x) -> MAIN, notice.type=base64(2x) -> Authorization }
  POST {MAIN}/?app=10000  form: key=RC4hex(md5("No00000"), md5("No00000SmtEk1")), t=unix
       header: Authorization
  resp.data -> Maink=RC4(., numberkey); FKUrl/HOST/pg/yry = RC4(., Maink)
"""
import base64
import hashlib
import json
import sys
import time
import urllib.parse
import urllib.request

UA = " Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.11 (KHTML, like Gecko)"


def md5(s: str) -> str:
    return hashlib.md5(s.encode()).hexdigest()


NUMBER1 = "No00000"
NUMBERKEY1 = "SmtEk1"
NUMBER = md5(NUMBER1)
NUMBERKEY = md5(NUMBER1 + NUMBERKEY1)


def rc4(data: bytes, key: str) -> bytes:
    kb = key.encode()
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (kb[i % len(kb)] + s[i] + j) & 255
        s[i], s[j] = s[j], s[i]
    out = bytearray()
    x = y = 0
    for b in data:
        x = (x + 1) & 255
        y = (s[x] + y) & 255
        s[x], s[y] = s[y], s[x]
        out.append(b ^ s[(s[x] + s[y]) & 255])
    return bytes(out)


def rc4_hex(data: bytes, key: str) -> str:
    return rc4(data, key).hex()


def de_hex(s: str, key: str) -> str:
    """Rc4.decry_RC4：输入十六进制串，输出 UTF-8 明文（容错）。"""
    if not s:
        return ""
    raw = rc4(bytes.fromhex(s), key)
    return raw.decode("utf-8", "replace")


def b64_skip(s: str, skip: int = 16) -> str:
    return base64.b64decode(s[skip:] + "=" * (-len(s[skip:]) % 4)).decode("utf-8", "replace")


def http(url, data=None, headers=None, timeout=20):
    body = None
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=body, headers=h, method="POST" if body else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


APK = r"C:\Users\fengxin\Desktop\三角洲影视2.0.apk"


def load_cos_raw():
    """从 assets/server.json 直接取原始 cos_main_url（含二进制混淆前缀）。"""
    import zipfile
    z = zipfile.ZipFile(APK)
    d = json.loads(z.read("assets/server.json").decode("utf-8"))
    return d["list"][0]["cos_main_url"]


def main():
    cos = load_cos_raw()
    cos_url = b64_skip(cos, 12)
    while not cos_url.startswith("http"):
        cos_url = cos_url[1:]
    print("cos_url =", cos_url)

    st, raw = http(cos_url)
    print("app.json HTTP", st)
    cfg = json.loads(raw)
    notice = cfg["msg"]["notice"]
    mian = b64_skip(notice["content"])
    print("MIAN   =", mian)
    try:
        auth = b64_skip(notice["type"])
    except Exception as e:
        print("auth decode fail", e)
        auth = ""
    print("AUTH   =", repr(auth))

    api = mian.rstrip("/") + "/?app=10000"
    key = rc4_hex(NUMBER.encode(), NUMBERKEY)
    print("key    =", key)
    st, raw = http(api, data={"key": key, "t": str(int(time.time()))},
                   headers={"Authorization": auth})
    print("api HTTP", st, "len", len(raw))
    obj = json.loads(raw)
    print("code =", obj.get("code"), "msg =", obj.get("msg"))
    data = obj.get("data") or {}
    if isinstance(data, str):
        data = json.loads(data)

    maink = de_hex(data.get("Maink", ""), NUMBERKEY)
    print("Maink  =", maink)
    for f in ("FKUrl", "HOST", "pg", "yry", "newClient", "url_ad", "blacklist", "Categorytxt", "MT"):
        v = data.get(f)
        if v:
            print(f"{f:12}= {de_hex(v, maink)}")

    print("\n--- 明文可读字段 ---")
    for k, v in data.items():
        if isinstance(v, (int, float, bool)) or (isinstance(v, str) and len(v) < 40):
            print(f"{k:12}= {v}")

    out = "/tmp/sj3/api_data.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    print("\nsaved", out)


if __name__ == "__main__":
    main()
