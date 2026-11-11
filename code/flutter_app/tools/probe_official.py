#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""实测 kanju 官方线在各集的可解析率。

用途：验证「官方线优先」策略是否可行。
上一轮只测了第 1 集（9/10 成功）与第 11 集（8/8 全 401），
样本太少，无法判断是「靠后集数普遍要登录」还是「个别集的问题」。
本脚本按等距抽样逐集 resolve，统计每条官方线的成败。

签名规则与 App 内 lib/core/source/kanju_source.dart 完全一致：
    HMAC-SHA256(key, "{METHOD}\n{PATH?QUERY}\n{TS}\n{NONCE}")
"""
import hashlib
import hmac
import json
import sys
import time
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
    return {
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
            return r.status, json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"_raw": raw[:200]}


def search(keyword):
    st, m = call("GET", "/v1/browse/catalog",
                 {"page": "1", "limit": "5", "q": keyword})
    if st != 200:
        print(f"搜索失败 HTTP {st}: {m}")
        return None
    cards = m.get("cards") or []
    for c in cards:
        if c.get("title") == keyword:
            return c.get("id")
    return cards[0].get("id") if cards else None


def detail(drama_id):
    st, m = call("GET", f"/v1/catalog/{drama_id}")
    if st != 200:
        print(f"详情失败 HTTP {st}: {m}")
        return None
    return m


def episode_tokens(m):
    """从详情里取出 [(集号, token)]。"""
    out = []
    for key in ("episodes", "playback_episodes", "episode_list"):
        arr = m.get(key)
        if isinstance(arr, list) and arr:
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
    return out


def resolve_lines(token):
    st, m = call("GET", f"/v1/playback/resolve/{token}")
    if st != 200:
        return st, m, []
    return st, m, (m.get("line_options") or [])


def resolve_line(ticket):
    st, m = call("POST", "/v1/playback/resolve-line", {"view": "compact"},
                 {"ticket": ticket})
    return st, m


def main():
    keyword = sys.argv[1] if len(sys.argv) > 1 else "沙海"
    max_eps = int(sys.argv[2]) if len(sys.argv) > 2 else 6

    did = search(keyword)
    if not did:
        print("找不到剧集")
        return
    print(f"剧集: {keyword}  id={did}")

    d = detail(did)
    if not d:
        return
    eps = episode_tokens(d)
    print(f"集数: {len(eps)}")

    if not eps:
        print("详情里没有取到集 token，字段名需重新确认")
        print("详情顶层字段:", list(d.keys())[:30])
        return

    # 等距抽样
    if len(eps) <= max_eps:
        picked = eps
    else:
        step = max(1, len(eps) // max_eps)
        picked = eps[::step][:max_eps]

    print(f"抽样 {len(picked)} 集: {[n for n, _ in picked]}")
    print("=" * 78)

    total_off = 0
    ok_off = 0
    session_required = 0
    unavailable = 0
    other_err = 0

    for num, tok in picked:
        st, m, lines = resolve_lines(tok)
        if st != 200:
            print(f"第 {num} 集: resolve 失败 HTTP {st}")
            continue
        official = [l for l in lines if l.get("resolve_required") is True]
        direct = [l for l in lines if not l.get("resolve_required")]
        print(f"第 {num:3d} 集: 共 {len(lines)} 条（官方 {len(official)} / 直出 {len(direct)}）")

        for l in official:
            total_off += 1
            url = str(l.get("url") or "")
            ticket = url[len("resolve://"):].strip() if url.startswith("resolve://") else ""
            label = l.get("label") or l.get("display_label") or "?"
            if not ticket:
                other_err += 1
                print(f"      [{label}] 无 ticket")
                continue
            st2, m2 = resolve_line(ticket)
            if st2 == 200:
                ok_off += 1
                u = str((m2.get("line") or {}).get("url") or "")
                print(f"      [{label}] OK  {u[:60]}")
            else:
                code = str(m2.get("code") or "")
                if code == "playback_user_session_required":
                    session_required += 1
                    print(f"      [{label}] 401 需登录")
                elif code == "playback_line_unavailable":
                    unavailable += 1
                    print(f"      [{label}] 线路不可用")
                else:
                    other_err += 1
                    print(f"      [{label}] HTTP {st2} code={code} msg={m2.get('message')}")
            time.sleep(0.15)

    print("=" * 78)
    print(f"官方线总计 {total_off} 次尝试：成功 {ok_off} / 需登录 {session_required} "
          f"/ 不可用 {unavailable} / 其他 {other_err}")
    if total_off:
        print(f"官方线可播率: {ok_off * 100.0 / total_off:.1f}%")


if __name__ == "__main__":
    main()