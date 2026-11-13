# -*- coding: utf-8 -*-
"""对比「走代理」与「国内直连」两种网络下的可用性。

App 用户实际在国内网络，代理能通不代表能用。
输出：dist/probe/maccms_direct.json
"""
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests
import urllib3

urllib3.disable_warnings()

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe")
IN_JSON = os.path.join(OUT_DIR, "maccms_deep.json")
OUT_JSON = os.path.join(OUT_DIR, "maccms_direct.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


def fetch(url, use_proxy, timeout=15):
    """use_proxy=False 时彻底绕过环境变量里的代理。"""
    s = requests.Session()
    if use_proxy:
        _p = (
            os.environ.get("HTTPS_PROXY")
            or os.environ.get("https_proxy")
            or os.environ.get("HTTP_PROXY")
            or os.environ.get("http_proxy")
        )
        s.proxies = {"http": _p, "https": _p} if _p else {}
        s.trust_env = True
    else:
        s.proxies = {}
        s.trust_env = False
    t0 = time.time()
    try:
        r = s.get(
            url,
            headers={"User-Agent": UA, "Accept": "application/json,*/*"},
            timeout=timeout,
            verify=False,
            allow_redirects=True,
        )
        # 注意：不能截断 body。ac=detail&pg=1 的响应实测可达 78 万字节，
        # 截到 20 万会让 json.loads 直接抛异常，误判成「站点不可用」。
        return r.status_code, r.text, int((time.time() - t0) * 1000), None
    except Exception as e:  # noqa: BLE001
        return None, "", int((time.time() - t0) * 1000), f"{type(e).__name__}: {e}"[:100]


def judge_api(status, body):
    if status != 200:
        return False, f"HTTP {status}"
    b = body.strip()
    if not b.startswith("{"):
        return False, "not json"
    try:
        d = json.loads(b)
    except Exception:  # noqa: BLE001
        return False, "bad json"
    lst = d.get("list") or []
    if d.get("code") != 1 or not lst:
        return False, "code!=1 or empty list"
    froms = [x for x in (lst[0].get("vod_play_from") or "").split("$") if x]
    if not froms:
        return False, "no vod_play_from"
    return True, f"total={d.get('total')}"


def check(rec):
    api = rec["api"]
    site = rec["site"]
    out = {
        "name": rec["name"],
        "api": api,
        "site": site,
        "score": rec["score"],
    }
    st, body, ms, err = fetch(api.rstrip("/") + "/?ac=detail&pg=1", False)
    ok, why = judge_api(st, body)
    out["direct_api"] = {"ok": ok, "why": why, "ms": ms, "err": err}

    st2, body2, ms2, err2 = fetch(site if site.startswith("http") else "https://" + site, False)
    out["direct_site"] = {
        "ok": st2 in (200, 301, 302),
        "http": st2,
        "ms": ms2,
        "err": err2,
    }
    return out


def main():
    with open(IN_JSON, encoding="utf-8") as f:
        recs = json.load(f)

    print(f"{'站名':<10} {'API直连':<22} {'首页直连':<16} 评分")
    print("-" * 62)
    results = []
    with ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(check, r): r for r in recs}
        done = {}
        for fut in as_completed(futs):
            o = fut.result()
            done[o["name"]] = o
    for r in recs:
        o = done[r["name"]]
        results.append(o)
        a = o["direct_api"]
        s = o["direct_site"]
        af = "OK " if a["ok"] else "FAIL"
        sf = (f"{s['http']}" if s["http"] else "ERR")
        print(
            f"{r['name']:<10} [{af}] {a['ms'] or 0:>5}ms {a['why'][:16]:<16} "
            f"[{sf:<4}] {s['ms'] or 0:>5}ms  {r['score']}"
        )

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    okn = sum(1 for r in results if r["direct_api"]["ok"])
    print(f"\n国内直连可用 {okn} / {len(results)}")
    print(f"写入 {os.path.abspath(OUT_JSON)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())