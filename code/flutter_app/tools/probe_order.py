#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证假设：resolve 拿到的 ticket 是否绑定会话。

Dart 侧现象：先 GET /v1/playback/resolve/{token} 拿 ticket，
再 POST /v1/users/anonymous 建会话，最后 resolve-line → 401。
Python 侧成功：先建会话，再 resolve、再 resolve-line。

如果 ticket 在服务端绑定了「发起 resolve 时的会话」，
那么顺序不同结果就不同。本脚本控制变量验证。
"""
import hashlib
import hmac
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

HOST = "https://kanju.ai"
SIGN_KEY = "557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0"
CLIENT_NAME = "dianyingtiantang-frontend"
CLIENT_VERSION = "1.0.0"
PROTO_VER = "2026-07-05.library-v2.playback-v1"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

JAR = {}


def enc_q(p):
    if not p:
        return ""
    return "&".join(
        f"{urllib.parse.quote(str(k), safe='')}={urllib.parse.quote(str(v), safe='')}"
        for k, v in p.items())


def hdrs(method, full):
    ts = str(int(time.time() * 1000))
    nonce = uuid.uuid4().hex
    msg = f"{method.upper()}\n{full}\n{ts}\n{nonce}"
    sig = hmac.new(SIGN_KEY.encode(), msg.encode(), hashlib.sha256).hexdigest()
    h = {
        "x-ai-movie-timestamp": ts,
        "x-ai-movie-nonce": nonce,
        "x-ai-movie-signature": sig,
        "x-ai-movie-client-name": CLIENT_NAME,
        "x-ai-movie-client-version": CLIENT_VERSION,
        "x-ai-movie-protocol-version": PROTO_VER,
        "Accept": "application/json",
        "Origin": HOST,
        "Referer": HOST + "/",
        "User-Agent": UA,
    }
    if JAR:
        h["Cookie"] = "; ".join(f"{k}={v}" for k, v in JAR.items())
    return h


def absorb(r):
    for raw in r.headers.get_all("Set-Cookie") or []:
        f = raw.split(";")[0]
        if "=" in f:
            k, v = f.split("=", 1)
            JAR[k.strip()] = v.strip()


def call(method, path, params=None, body=None):
    q = enc_q(params or {})
    full = path if not q else f"{path}?{q}"
    data = None
    h = hdrs(method, full)
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(HOST + full, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            absorb(r)
            raw = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(raw)
            except Exception:
                return r.status, {"_raw": raw[:200]}
    except urllib.error.HTTPError as e:
        absorb(e)
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"_raw": raw[:200]}


def find_ep(keyword, ep_index):
    st, m = call("GET", "/v1/browse/catalog", {"page": "1", "limit": "5", "q": keyword})
    did = None
    for c in (m.get("cards") or []):
        if c.get("title") == keyword:
            did = c.get("id")
            break
    if not did:
        cards = m.get("cards") or []
        did = cards[0].get("id") if cards else None
    st, d = call("GET", f"/v1/catalog/{did}")
    eps = []
    for key in ("episodes", "playback_episodes", "episode_list"):
        arr = d.get(key)
        if isinstance(arr, list) and arr:
            for i, e in enumerate(arr):
                if isinstance(e, dict) and e.get("token"):
                    eps.append((int(e.get("number") or i + 1), e["token"]))
            break
    return eps[ep_index] if len(eps) > ep_index else (eps[-1] if eps else None)


def pick_official_ticket(tok):
    st, m = call("GET", f"/v1/playback/resolve/{tok}")
    if st != 200:
        print(f"  resolve HTTP {st}")
        return None, None
    for l in (m.get("line_options") or []):
        if l.get("resolve_required") is True:
            u = str(l.get("url") or "")
            if u.startswith("resolve://"):
                return u[len("resolve://"):].strip(), l.get("label")
    return None, None


def main():
    order = sys.argv[1] if len(sys.argv) > 1 else "session_first"

    ep = find_ep("沙海", 9)  # 第 10 集
    if not ep:
        print("找不到集")
        return
    num, tok = ep
    print(f"第 {num} 集")

    if order == "session_first":
        print("【顺序 A】先建会话 → 再 resolve → 再 resolve-line")
        JAR.clear()
        st, m = call("POST", "/v1/users/anonymous", None,
                     {"anonymous_id": uuid.uuid4().hex})
        print(f"  会话 HTTP {st}, cookie={list(JAR.keys())}")
        ticket, label = pick_official_ticket(tok)
        print(f"  ticket 线路：{label}")
    else:
        print("【顺序 B】先 resolve 拿 ticket → 再建会话 → 再 resolve-line")
        JAR.clear()
        ticket, label = pick_official_ticket(tok)
        print(f"  ticket 线路：{label}（此时无会话）")
        st, m = call("POST", "/v1/users/anonymous", None,
                     {"anonymous_id": uuid.uuid4().hex})
        print(f"  会话 HTTP {st}, cookie={list(JAR.keys())}")

    if not ticket:
        print("  没拿到官方 ticket")
        return

    st2, m2 = call("POST", "/v1/playback/resolve-line",
                   {"view": "compact"}, {"ticket": ticket})
    if st2 in (200, 201):
        u = str((m2.get("line") or {}).get("url") or "")
        print(f"  resolve-line OK({st2}) {u[:60]}")
    else:
        print(f"  resolve-line FAIL HTTP {st2} code={m2.get('code')} "
              f"msg={m2.get('message')}")

    # 顺手验证：用会话重新 resolve 拿到的 ticket 能不能用
    print("  --- 重新 resolve（带会话）后再试 ---")
    ticket2, label2 = pick_official_ticket(tok)
    if ticket2:
        st3, m3 = call("POST", "/v1/playback/resolve-line",
                       {"view": "compact"}, {"ticket": ticket2})
        if st3 in (200, 201):
            u = str((m3.get("line") or {}).get("url") or "")
            print(f"  重取 ticket OK({st3}) {u[:60]}")
        else:
            print(f"  重取 ticket FAIL HTTP {st3} code={m3.get('code')}")


if __name__ == "__main__":
    main()