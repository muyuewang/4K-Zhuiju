#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 /v1/users/anonymous 游客会话能否解锁官方线。

上一轮实测（不带会话）：
    第 1 集官方线 HTTP 201 成功；第 10 集起全部 401 playback_user_session_required

本脚本尝试用 anonymous_id 换取会话 Cookie，再带着 Cookie 去 resolve-line，
看 401 是否消失。这是决定「官方线优先」能否真正落地的唯一验证。
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


def headers(method, full, with_cookie=True):
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
    if with_cookie and COOKIE_JAR:
        h["Cookie"] = "; ".join(f"{k}={v}" for k, v in COOKIE_JAR.items())
    return h


def absorb_cookies(resp):
    for raw in resp.headers.get_all("Set-Cookie") or []:
        first = raw.split(";")[0]
        if "=" in first:
            k, v = first.split("=", 1)
            COOKIE_JAR[k.strip()] = v.strip()


def call(method, path, params=None, body=None, with_cookie=True):
    q = encode_query(params or {})
    full = path if not q else f"{path}?{q}"
    data = None
    hdr = headers(method, full, with_cookie)
    if body is not None:
        data = json.dumps(body).encode()
        hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(HOST + full, data=data, headers=hdr, method=method)
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            absorb_cookies(r)
            raw = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(raw)
            except Exception:
                return r.status, {"_raw": raw[:300]}
    except urllib.error.HTTPError as e:
        absorb_cookies(e)
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"_raw": raw[:300]}


def search(keyword):
    st, m = call("GET", "/v1/browse/catalog", {"page": "1", "limit": "5", "q": keyword})
    if st != 200:
        return None
    cards = m.get("cards") or []
    for c in cards:
        if c.get("title") == keyword:
            return c.get("id")
    return cards[0].get("id") if cards else None


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

    did = search(keyword)
    if not did:
        print("找不到剧集")
        return
    print(f"剧集: {keyword}  id={did}")

    st, d = call("GET", f"/v1/catalog/{did}")
    if st != 200:
        print(f"详情失败 HTTP {st}")
        return
    eps = episode_tokens(d)
    print(f"集数: {len(eps)}")

    # 先测「无会话」基准（清空 Cookie）
    def try_ep(num, tok, tag):
        st1, m1 = call("GET", f"/v1/playback/resolve/{tok}")
        if st1 != 200:
            print(f"  [{tag}] 第 {num} 集 resolve HTTP {st1}")
            return None
        official = [l for l in m1.get("line_options") or []
                    if l.get("resolve_required") is True]
        results = []
        for l in official:
            url = str(l.get("url") or "")
            ticket = url[len("resolve://"):].strip() if url.startswith("resolve://") else ""
            label = l.get("label") or "?"
            if not ticket:
                results.append((label, "NO-TICKET", ""))
                continue
            st2, m2 = call("POST", "/v1/playback/resolve-line",
                           {"view": "compact"}, {"ticket": ticket})
            if st2 in (200, 201):
                u = str((m2.get("line") or {}).get("url") or "")
                results.append((label, f"OK({st2})", u[:50]))
            else:
                code = str(m2.get("code") or "")
                results.append((label, f"{st2} {code}", ""))
            time.sleep(0.1)
        for label, r, u in results:
            print(f"  [{tag}] 第 {num:3d} 集 [{label}] {r} {u}")
        return results

    # 挑一集靠后的（第 10 集之后必然 401）
    target = None
    for num, tok in eps:
        if num >= 10:
            target = (num, tok)
            break
    if not target:
        target = eps[-1]
    num, tok = target

    print("=" * 78)
    print("【阶段 1】不建立会话，直接请求（预期 401）")
    COOKIE_JAR.clear()
    before = try_ep(num, tok, "无会话")

    print("=" * 78)
    print("【阶段 2】POST /v1/users/anonymous 换游客会话")
    anon_id = uuid.uuid4().hex
    print(f"  anonymous_id = {anon_id}")
    st, m = call("POST", "/v1/users/anonymous", None,
                 {"anonymous_id": anon_id}, with_cookie=False)
    print(f"  HTTP {st}  body={json.dumps(m, ensure_ascii=False)[:300]}")
    print(f"  拿到 Cookie: {list(COOKIE_JAR.keys()) or '无'}")

    print("=" * 78)
    print("【阶段 3】带会话再请求同一集（看 401 是否消失）")
    after = try_ep(num, tok, "有会话")

    print("=" * 78)
    if before and after:
        b_ok = sum(1 for _, r, _ in before if r.startswith("OK"))
        a_ok = sum(1 for _, r, _ in after if r.startswith("OK"))
        print(f"结果对比：无会话成功 {b_ok}/{len(before)}  →  有会话成功 {a_ok}/{len(after)}")


if __name__ == "__main__":
    main()