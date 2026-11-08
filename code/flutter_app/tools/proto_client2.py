#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
橘汁 App 协议完整复现 v2
sig 算法确认：
  sig  = Base64_NO_WRAP( RSA/ECB/PKCS1Padding( pubKey, ts + rand16 + vApp ) )
  sigA = Base64_NO_WRAP( AES-256-ECB( safeSecretKey, ts + rand16 ) )
  sig2 = sigA[0:8]
  sig3 = sigA[8:]
"""
import base64, json, time, random, urllib.parse, hashlib
import requests
from Crypto.Cipher import AES, PKCS1_v1_5
from Crypto.PublicKey import RSA
from Crypto.Util.Padding import pad

BASE = "http://juziapp.hzhcbkj.cn"

SAFE_CODE = "ZU1DSFFWNENKMDYXVUQRN0ZJDUC4PQ=="     # 32char AES-256 请求体加密key
SAFE_SECRET = "OC1A06E197EF10CF3F6058CA7A803B5E"   # 32char 用于 sig2/sig3
PUBKEY_B64 = ("MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCp9Ek4wIlQAtwFnuBRlsFiow2t"
              "r+4UOciGeNKbY7nL74etUqUb6fvpOSOHhFEfaWlfwUpOB17x3JEL3No19nfjCeVY"
              "rYPjlJcgoqUWH/tfIfFAQWvtxBIBlKazkhw8d3ChysWmeWRikKqkBsVRY4oqNPuj"
              "4sjm6Zult0U4I4prRQIDAQAB")

CHARS = "1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def rand_alnum(n_minus_1):
    s = ""
    while len(s) < n_minus_1:
        c = random.choice(CHARS)
        if c not in s:
            s += c
    return s + "="


def aes_ecb_b64(key_str, plaintext):
    cipher = AES.new(key_str.encode("utf-8"), AES.MODE_ECB)
    return base64.b64encode(cipher.encrypt(pad(plaintext.encode("utf-8"), 16))).decode()


def rsa_b64(data: str):
    key = RSA.importKey(base64.b64decode(PUBKEY_B64))
    ct = PKCS1_v1_5.new(key).encrypt(data.encode("utf-8"))
    return base64.b64encode(ct).decode()


# ---------------- protobuf 手写编码 ----------------
def varint(v):
    out = b""
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def pb_str(f, s):
    if s is None:
        return b""
    b = s.encode("utf-8")
    return varint(f << 3 | 2) + varint(len(b)) + b


def pb_int(f, v):
    return varint(f << 3 | 0) + varint(v)


def build_secure_body(params: dict):
    kv = "&".join(f"{k}={v}" for k, v in params.items())
    ts = int(time.time() * 1000)
    r8 = rand_alnum(7)
    fake20 = rand_alnum(19)
    b64 = aes_ecb_b64(SAFE_CODE, kv + str(ts))
    merged = r8 + b64
    enc1, enc2 = merged[:20], merged[20:]
    body = (pb_str(1, enc1) + pb_str(2, enc2) + pb_str(3, fake20)
            + pb_int(4, ts) + pb_str(5, r8))
    return body, kv


def build_public_params(vapp="3070", with_sig=True):
    """等价 o00o.OooO00o.OooO00o(map) + native method01 的输入 JSON"""
    base = {
        "country": "CN", "vName": "3.0.7.0",
        "cpuId": "Qualcomm%20Technologies%2C%20Inc%20MSM8998",
        "young": 0, "facturer": "samsung", "pkg": "com.asjdhjhd.mgd.p3",
        "uuid": "3342CF6E5B34747029419DBA6B159A35",
        "resolution": "720x1280", "mac": "00%3Adb%3A1e%3A1b%3Aa8%3Ae8",
        "abid": "4365", "model": "SM-N9700", "plat": "android",
        "udid": "3342CF6E5B34747029419DBA6B159A35", "dpi": "320",
        "net": "1", "lang": "zh", "brand": "samsung", "density": "2.0",
        "appName": "%E6%A9%98%E6%B1%81", "cpu": "x86_64", "chid": "10000",
        "carrier": "%E7%A7%BB%E5%8A%A8", "v": "1", "tenantId": "",
        "_vOsCode": "28", "vOs": "9", "vApp": vapp, "device": "0",
        "androidID": "f00b0e69983f85a9",
    }
    if with_sig:
        ts = int(time.time() * 1000)
        r16 = rand_alnum(15)
        base["timestamp"] = ts
        base["random_str"] = r16
        base["sig"] = rsa_b64(str(ts) + r16 + vapp)
        siga = aes_ecb_b64(SAFE_SECRET, str(ts) + r16)
        base["sig2"] = siga[:8]
        base["sig3"] = siga[8:]
    return json.dumps(base, ensure_ascii=True, separators=(",", ":"))


def call(path, params, mode="plain"):
    """mode: plain=明文publicParams / raw=不带 / wrapped=包在paramsData里"""
    body, kv = build_secure_body(params)
    hdr = {"Content-Type": "application/x-protobuf",
           "Accept": "application/x-protobuf",
           "User-Agent": "okhttp/3.12.1"}
    if mode == "plain":
        hdr["publicParams"] = build_public_params()
    elif mode == "wrapped":
        hdr["publicParams"] = json.dumps({"paramsData": build_public_params()},
                                         separators=(",", ":"))
    r = requests.post(BASE + path, data=body, headers=hdr, timeout=25)
    return r, kv


def pb_fields(data):
    def rv(b, i):
        r = s = 0
        while True:
            x = b[i]; i += 1
            r |= (x & 0x7F) << s; s += 7
            if not x & 0x80:
                return r, i
    out, i = [], 0
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
    tests = [
        ("videoUsableUrl", "/api/proto/v5/videoUsableUrl",
         {"vodPlayFrom": "bfzym3u8",
          "playUrl": urllib.parse.quote(
              "https://v.fengbao14.com/video/shanggongzhu/718bee4a1b47/index.m3u8", safe="")}),
    ]
    for name, path, params in tests:
        for mode in ("raw", "plain", "wrapped"):
            try:
                r, kv = call(path, params, mode)
                fs = pb_fields(r.content)
                summary = " | ".join(
                    f"{f}:{v[:60]}" if t == "s" else f"{f}:{v}" for f, t, v in fs[:4])
                print(f"[{name}][{mode:8s}] HTTP {r.status_code} len={len(r.content):5d}  {summary}")
            except Exception as e:
                print(f"[{name}][{mode:8s}] ERR {type(e).__name__}: {e}")