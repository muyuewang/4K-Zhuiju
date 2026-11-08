#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
橘汁 App 协议完整复现
- publicParams 请求头（native 层等价实现：直接 pickle 成 JSON 明文上报，服务端不校验加密）
- SecureRequest 请求体 AES-256-ECB 加密
"""
import base64, json, time, random, urllib.parse, sys
import requests
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

BASE = "http://juziapp.hzhcbkj.cn"

# 从动态调试抓到的运行时密钥
SAFE_CODE = "ZU1DSFFWNENKMDYXVUQRN0ZJDUC4PQ=="       # 32字符 = AES-256，用于请求体加密
SAFE_SECRET = "OC1A06E197EF10CF3F6058CA7A803B5E"     # 32字符，用于 sig 签名

CHARS = "1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def rand_alnum(n_minus_1):
    """OooO0Oo(i): i-1 位不重复随机 + '='"""
    s = ""
    while len(s) < n_minus_1:
        c = random.choice(CHARS)
        if c not in s:
            s += c
    return s + "="


def aes_encrypt_b64(key_str, plaintext):
    """AES/ECB/PKCS7 + Base64(NO_WRAP)"""
    key = key_str.encode("utf-8")
    cipher = AES.new(key, AES.MODE_ECB)
    ct = cipher.encrypt(pad(plaintext.encode("utf-8"), 16))
    return base64.b64encode(ct).decode("ascii")


# ---------- protobuf 手写编码（只用到 string/int64） ----------
def varint(v):
    out = b""
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out += bytes([b | 0x80])
        else:
            out += bytes([b])
            return out


def pb_str(field, s):
    if s is None:
        return b""
    b = s.encode("utf-8")
    return varint(field << 3 | 2) + varint(len(b)) + b


def pb_int(field, v):
    return varint(field << 3 | 0) + varint(v)


def build_secure_request(params: dict):
    """
    等价于 o00O.OooO00o.OooOO0(String str)
    str = "k=v&k=v"（OooO0oo 的产物）
    """
    # OooO0oo: 按插入顺序拼 k=v&k=v，值不做额外编码（调用方已 encode）
    kv = "&".join(f"{k}={v}" for k, v in params.items())

    ts = int(time.time() * 1000)
    r8 = rand_alnum(7)    # OooO0o0() -> 8 字符
    fake20 = rand_alnum(19)  # OooO0O0() -> 20 字符

    # 明文 = kv + timestamp
    b64 = aes_encrypt_b64(SAFE_CODE, kv + str(ts))
    merged = r8 + b64
    enc1 = merged[:20]
    enc2 = merged[20:]

    body = (pb_str(1, enc1) + pb_str(2, enc2) +
            pb_str(3, fake20) + pb_int(4, ts) + pb_str(5, r8))
    return body, {"enc1": enc1, "enc2": enc2, "fake": fake20,
                  "ts": ts, "rand": r8, "kv": kv, "b64": b64}


def build_public_params():
    """
    publicParams 请求头。
    native method01 是加密的，但服务端只在部分接口校验；
    这里直接给明文 JSON（等价结构），实测是否被接受。
    注意：原 APK 对所有值做了 Uri.encode，HTTP header 必须是 latin-1，
    所以中文/空格必须 URL 编码，否则 requests 会抛 UnicodeEncodeError。
    """
    raw = {
        "country": "CN", "vName": "3.0.7.0",
        "cpuId": "Qualcomm Technologies, Inc MSM8998",
        "young": "0", "facturer": "samsung",
        "pkg": "com.asjdhjhd.mgd.p3",
        "uuid": "3342CF6E5B34747029419DBA6B159A35",
        "resolution": "720x1280",
        "mac": "00:db:1e:1b:a8:e8", "abid": "4365",
        "model": "SM-N9700", "plat": "android",
        "udid": "3342CF6E5B34747029419DBA6B159A35",
        "dpi": "320", "net": "1", "lang": "zh",
        "brand": "samsung", "density": "2.0", "appName": "橘汁",
        "cpu": "x86_64", "chid": "10000", "carrier": "移动",
        "v": "1", "tenantId": "", "_vOsCode": "28", "vOs": "9",
        "vApp": "3070", "device": "0",
        "androidID": "f00b0e69983f85a9",
    }
    enc = {k: urllib.parse.quote(str(v), safe="") for k, v in raw.items()}
    return json.dumps(enc, ensure_ascii=True, separators=(",", ":"))


def call(path, params, use_pp=True):
    body, meta = build_secure_request(params)
    hdr = {
        "Content-Type": "application/x-protobuf",
        "Accept": "application/x-protobuf",
        "User-Agent": "okhttp/3.12.1",
    }
    if use_pp:
        hdr["publicParams"] = build_public_params()
    r = requests.post(BASE + path, data=body, headers=hdr, timeout=25)
    return r, meta


def pb_decode_fields(data):
    """极简 protobuf 顶层解码"""
    def rv(b, i):
        r = s = 0
        while True:
            x = b[i]; i += 1
            r |= (x & 0x7F) << s; s += 7
            if not x & 0x80:
                return r, i
    out = []
    i = 0
    while i < len(data):
        try:
            k, i = rv(data, i)
        except Exception:
            break
        f, wt = k >> 3, k & 7
        if f == 0:
            break
        if wt == 0:
            v, i = rv(data, i); out.append((f, "v", v))
        elif wt == 2:
            ln, i = rv(data, i)
            seg = data[i:i + ln]; i += ln
            try:
                out.append((f, "s", seg.decode("utf-8")))
            except Exception:
                out.append((f, "b", seg))
        elif wt == 5:
            i += 4
        elif wt == 1:
            i += 8
        else:
            break
    return out


if __name__ == "__main__":
    print("=" * 70)
    print("测试 1: videoUsableUrl（自建 m3u8 源）")
    print("=" * 70)
    src = "bfzym3u8"
    path = "https://v.fengbao14.com/video/shanggongzhu/718bee4a1b47/index.m3u8"
    params = {"vodPlayFrom": src, "playUrl": urllib.parse.quote(path, safe="")}
    r, meta = call("/api/proto/v5/videoUsableUrl", params)
    print("HTTP", r.status_code, "len", len(r.content))
    print("enc1:", meta["enc1"])
    print("kv  :", meta["kv"][:100])
    for f, t, v in pb_decode_fields(r.content):
        if t == "s":
            print(f"  {f} s = {v[:150]}")
        elif t == "b":
            print(f"  {f} b = {v[:40].hex()}")
        else:
            print(f"  {f} v = {v}")