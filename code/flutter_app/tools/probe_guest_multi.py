#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""带游客会话，跨多集验证官方线可用率。

前置结论（tools/probe_guest.py）：
    POST /v1/users/anonymous  {anonymous_id}  → HTTP 201
    Set-Cookie: ai_movie_session=...
    带着该 Cookie，第 10 集官方线从 0/2 → 2/2

本脚本扩大样本，确认「游客会话 + 官方线」是否整剧稳定可播。
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

COOKIE_JAR = {}


def encode_query(params):
    if not params:
        return ""
    return "&".join(
        f"{urllib.parse.quote(str(k), safe='')}={urllib.parse.quote(str(v), safe='')}"
        for k, v in params.items()
    )


def headers(method, full):
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
    if COOKIE_JAR:
        h["Cookie"] = "; ".join(f"{k}={v}" for k, v in COOKIE_JAR.items())
    return h


def absorb(resp):
    for raw in resp.headers.get_all("Set-Cookie") or []:
        first = raw.split(";")[0]
        if "=" in first:
            k, v = first.split("=", 1)
            COOKIE_JAR[k.strip()] = v.strip()


def call(method, path, params=None, body=None):
    q = encode_query(params or {})
    full = path if not q else f"{path}?{q}"
    data = None
    hdr = headers(method, full)
    if body is not None:
        data = json.dumps(body).encode()
        hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(HOST + full, data=data, headers=hdr, method=method)
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            absorb(r)
            raw = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(raw)
            except Exception:
                return r.status, {"_raw": raw[:300]}
    except urllib.error.HTTPError as e:
        absorb(e)
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"_raw": raw[:300]}


def episode_tokens(m):
    for key in ("episodes", "playback_episodes", "episode_list"):
        arr = m.get(key)
        if isinstance(arr, list) and arr:
            out = []
            for i, e in enumerate(arr):
                if not isinstance(e, dict):
                    continue
                tok = (e.get("playback_id") or e.get("token")
                       or e.get("episode_token") or e.get("id") or "")
                num = e.get("episode_number") or e.get("number") or (i + 1)
                if tok:
                    out.append((int(num), str(tok)))
            if out:
                return out
    return []


def main():
    keyword = sys.argv[1] if len(sys.argv) > 1 else "沙海"
    max_eps = int(sys.argv[2]) if len(sys.argv) > 2 else 8

    st, m = call("GET", "/v1/browse/catalog", {"page": "1", "limit": "5", "q": keyword})
    did = None
    for c in (m.get("cards") or []):
        if c.get("title") == keyword:
            did = c.get("id")
            break
    if not did:
        cards = m.get("cards") or []
        did = cards[0].get("id") if cards else None
    print(f"剧集: {keyword}  id={did}")

    st, d = call("GET", f"/v1/catalog/{did}")
    eps = episode_tokens(d)
    print(f"集数: {len(eps)}")

    # 先建立游客会话
    anon = {"anonymous_id": uuid.uuid4().hex}
    st, m = call("POST", "/v1/users/anonymous", None, anon)
    print(f"游客会话: HTTP {st}  cookie={list(COOKIE_JAR.keys())}")

    if len(eps) <= max_eps:
        picked = eps
    else:
        step = max(1, len(eps) // max_eps)
        picked = eps[::step][:max_eps]

    print(f"抽样 {len(picked)} 集: {[n for n, _ in picked]}")
    print("=" * 78)

    tot = ok = sess = unavail = other = 0
    for num, tok in picked:
        st1, m1 = call("GET", f"/v1/playback/resolve/{tok}")
        if st1 != 200:
            print(f"第 {num:3d} 集 resolve HTTP {st1}")
            continue
        official = [l for l in (m1.get("line_options") or [])
                    if l.get("resolve_required") is True]
        print(f"第 {num:3d} 集: 官方线 {len(official)} 条")
        for l in official:
            tot += 1
            url = str(l.get("url") or "")
            ticket = url[len("resolve://"):].strip() if url.startswith("resolve://") else ""
            label = l.get("label") or "?"
            if not ticket:
                other += 1
                print(f"      [{label}] 无 ticket")
                continue
            st2, m2 = call("POST", "/v1/playback/resolve-line",
                           {"view": "compact"}, {"ticket": ticket})
            if st2 in (200, 201):
                ok += 1
                u = str((m2.get("line") or {}).get("url") or "")
                print(f"      [{label}] OK  {u[:55]}")
            else:
                code = str(m2.get("code") or "")
                if code == "playback_user_session_required":
                    sess += 1
                    print(f"      [{label}] 401 需登录")
                elif code == "playback_line_unavailable":
                    unavail += 1
                    print(f"      [{label}] 不可用")
                else:
                    other += 1
                    print(f"      [{label}] HTTP {st2} {code}")
            time.sleep(0.12)

    print("=" * 78)
    print(f"官方线 {tot} 次：成功 {ok} / 需登录 {sess} / 不可用 {unavail} / 其他 {other}")
    if tot:
        print(f"可播率: {ok * 100.0 / tot:.1f}%")


if __name__ == "__main__":
    main()