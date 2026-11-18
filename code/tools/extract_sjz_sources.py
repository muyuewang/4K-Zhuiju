#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""三角洲影视(神马TV) 源提取：完整链路复现。

阶段：
  1) assets/server.json -> cos_main_url  -> GET app.json -> MIAN + Authorization
  2) POST {MIAN}/?app=10000 -> data   (RC4 key = md5 rules)
  3) Maink = RC4(data.Maink, NUMBERKEY)
     HOST = RC4(data.HOST, Maink)     -> BASE_HOST
     pg   = RC4(data.pg,   Maink)     -> Category 响应的 RC4 key
     MT   = RC4(data.MT,   Maink)     -> AES 用的 time 串
     pgUrl/yryUrl = AES-CBC 双层还原
  4) POST {pgUrl}/api.php/{HOST}/Category -> RC4 解 -> 分类树
  5) 继续抓列表/详情/搜索/播放
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
import time

from Crypto.Cipher import AES

APK = r"C:\Users\fengxin\Desktop\三角洲影视2.0.apk"
UA = " Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.11 (KHTML, like Gecko)"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_sjz_out")


def md5(s):
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


def dec_hex(h: str, key: str) -> str:
    if not h:
        return ""
    try:
        return rc4(bytes.fromhex(h), key).decode("utf-8", "replace")
    except Exception:
        return "<hexerr>"


def curl(url, data=None, headers=None, timeout=25):
    """走系统 curl，避免 python urllib 被本地代理卡住。"""
    cmd = ["curl", "-s", "-m", str(timeout), "-A", UA, url]
    if data is not None:
        cmd = ["curl", "-s", "-m", str(timeout), "-A", UA, "-X", "POST", url]
        for k, v in data.items():
            cmd += ["--data-urlencode", f"{k}={v}"]
    for k, v in (headers or {}).items():
        cmd += ["-H", f"{k}: {v}"]
    r = subprocess.run(cmd, capture_output=True)
    return r.stdout.decode("utf-8", "replace")


def aes_decrypt(key_str: str, ct_b64: str, iv_str: str) -> str:
    cipher = AES.new(key_str.encode("ascii"), AES.MODE_CBC, iv_str.encode("ascii"))
    raw = base64.b64decode(ct_b64)
    pt = cipher.decrypt(raw)
    # PKCS5 unpad
    pad = pt[-1] if pt else 0
    if 1 <= pad <= 16 and pt.endswith(bytes([pad]) * pad):
        pt = pt[:-pad]
    return pt.decode("utf-8", "replace")


def decode_pg_url(pg_url: str, yry_url: str, time_str: str) -> str:
    """pgUrl: key=base64(time+pgUrl[0:14])  iv=base64(time+yryUrl[0:2])  ct=pgUrl[32:]"""
    key = base64.b64encode((time_str + pg_url[0:14]).encode()).decode()
    iv = base64.b64encode((time_str + yry_url[0:2]).encode()).decode()
    inner = base64.b64decode(pg_url[32:]).decode("latin-1")
    return aes_decrypt(key, inner, iv)


def decode_yry_url(pg_url: str, yry_url: str, time_str: str) -> str:
    """yryUrl 复用 pgUrl 的 key，iv 同源，密文从下标 16 开始。"""
    key = base64.b64encode((time_str + pg_url[0:14]).encode()).decode()
    iv = base64.b64encode((time_str + yry_url[0:2]).encode()).decode()
    inner = base64.b64decode(yry_url[16:]).decode("latin-1")
    return aes_decrypt(key, inner, iv)


def unwrap_b64(s: str) -> str:
    """先整体 base64 解出「N字节盐 + 内层base64」，再扫内层找可解段。

    对应 Java: new String(Base64.decode(Base64.decode(S.substring(K), 1), 1))
    但盐长在前 12/16 字节（二进制），切字符串下标会错位，所以按可解性扫描。
    """
    b = base64.b64decode(s + "=" * (-len(s) % 4))
    t = b.decode("latin-1")
    for off in range(len(t)):
        seg = t[off:]
        try:
            d = base64.b64decode(seg + "=" * (-len(seg) % 4))
            u = d.decode("utf-8")
        except Exception:
            continue
        if len(u) >= 4 and all(32 <= ord(c) < 127 for c in u):
            return u
    raise ValueError("unwrap_b64 failed")


def main():
    os.makedirs(OUT, exist_ok=True)

    # ---- 1. 取 app.json ----
    import zipfile
    z = zipfile.ZipFile(APK)
    cfg = json.loads(z.read("assets/server.json").decode("utf-8"))
    cos_url = unwrap_b64(cfg["list"][0]["cos_main_url"])
    print("[1] cos_url =", cos_url)

    app_json = json.loads(curl(cos_url))
    notice = app_json["msg"]["notice"]
    mian = unwrap_b64(notice["content"])
    auth = unwrap_b64(notice["type"])
    print("[1] MIAN =", mian, "| AUTH =", repr(auth))

    # ---- 2. 主配置 ----
    key_param = rc4_hex(NUMBER.encode(), NUMBERKEY)
    body = {"key": key_param, "t": str(int(time.time()))}
    resp = json.loads(curl(mian.rstrip("/") + "/?app=10000", data=body, headers={"Authorization": auth}))
    data = resp["data"]
    print("[2] code =", resp.get("code"))

    maink = dec_hex(data["Maink"], NUMBERKEY)
    host = dec_hex(data["HOST"], maink)
    pgkey = dec_hex(data["pg"], maink)
    yrykey = dec_hex(data["yry"], maink)
    time_str = dec_hex(data["MT"], maink)
    print(f"[3] Maink={maink!r} HOST={host!r} pgkey={pgkey!r} MT={time_str!r}")

    pg_url = decode_pg_url(data["pgUrl"], data["yryUrl"], time_str)
    yry_url = decode_yry_url(data["pgUrl"], data["yryUrl"], time_str)
    print(f"[4] pgUrl  = {pg_url!r}")
    print(f"[4] yryUrl = {yry_url!r}")

    state = {
        "mian": mian, "auth": auth, "maink": maink, "host": host,
        "pgkey": pgkey, "yrykey": yrykey, "time": time_str,
        "pgUrl": pg_url, "yryUrl": yry_url, "raw": data,
    }
    with open(os.path.join(OUT, "state.json"), "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)

    # ---- 5. Category ----
    ts = str(int(time.time()))
    cat_url = f"{pg_url}/api.php/{host}/Category?key={rc4_hex(ts.encode(), ts)}&tt={ts}"
    print("[5] GET", cat_url)
    raw = curl(cat_url, headers={"Authorization": auth})
    print("[5] raw len", len(raw), raw[:160])
    if raw and not raw.strip().startswith("{"):
        plain = dec_hex(raw.strip(), pgkey)
        print("[5] decrypted len", len(plain))
        print(plain[:1200])
        with open(os.path.join(OUT, "category.json"), "w", encoding="utf-8") as f:
            f.write(plain)
        try:
            tree = json.loads(plain)
            print("\n[5] 顶层键:", list(tree)[:10] if isinstance(tree, dict) else f"list len {len(tree)}")
        except Exception as e:
            print("[5] not json:", e)
    else:
        print("[5] 未拿到 RC4 密文，可能是明文 JSON 或错误页")


if __name__ == "__main__":
    main()
