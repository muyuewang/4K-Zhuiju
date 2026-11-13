# -*- coding: utf-8 -*-
"""测各采集源的真实响应速度，用于决定接入顺序。

测什么：
    1. 首页推荐位（ac=list&pg=1）—— 用户打开 App 第一眼就要等这个
    2. 栏目页（取该源数据量最大的子分类）—— 点分类后要等这个
各测 5 次取**中位数**（首次有 DNS/TLS 握手，单次均值会被首包拖偏）。

判定：
    只看「网络耗时不包含解析」，因为解析在客户端是毫秒级，
    站间差异完全由网络决定。

输出：dist/probe/maccms_speed.json
"""
import json
import os
import statistics
import sys
import time

import requests
import urllib3

urllib3.disable_warnings()

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe")
IN_JSON = os.path.join(OUT_DIR, "maccms_totals.json")
OUT_JSON = os.path.join(OUT_DIR, "maccms_speed.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

ROUNDS = 5

# 已在用的两个源一起测，作为「新源是否比老源慢」的参照
EXTRA = [
    ("暴风资源(在用)", "https://bfzyapi.com/api.php/provide/vod/"),
    ("量子资源(在用)", "https://cj.lziapi.com/api.php/provide/vod/"),
]

# 茅台 m3u8 全挂，不参与排序
SKIP = ["maotaizy"]


def sess():
    s = requests.Session()
    s.proxies = {}
    s.trust_env = False
    s.headers.update({"User-Agent": UA})
    return s


def timed(s, url):
    t0 = time.time()
    r = s.get(url, timeout=20, verify=False)
    ms = int((time.time() - t0) * 1000)
    if r.status_code != 200:
        raise RuntimeError(f"HTTP {r.status_code}")
    d = r.json()
    if d.get("code") != 1:
        raise RuntimeError(f"code={d.get('code')}")
    return ms, len(d.get("list") or [])


def bench(name, api, warm_tid):
    api = api.rstrip("/") + "/"
    s = sess()
    rec = {"name": name, "api": api}
    # 预热一次：首个请求包含 DNS + TLS 握手，不预热会把中位数抬高一截
    try:
        timed(s, api + "?ac=list&pg=1")
    except Exception as e:  # noqa: BLE001
        rec["error"] = str(e)[:80]
        return rec

    home, cat = [], []
    for _ in range(ROUNDS):
        try:
            ms, n = timed(s, api + "?ac=list&pg=1")
            if n:
                home.append(ms)
        except Exception:  # noqa: BLE001
            pass
        if warm_tid:
            try:
                ms, n = timed(s, api + f"?ac=list&t={warm_tid}&pg=1")
                if n:
                    cat.append(ms)
            except Exception:  # noqa: BLE001
                pass

    if not home:
        rec["error"] = "no successful home sample"
        return rec
    rec["home_ms"] = int(statistics.median(home))
    rec["home_min"] = min(home)
    rec["cat_ms"] = int(statistics.median(cat)) if cat else None
    rec["score_ms"] = rec["home_ms"]
    return rec


def main():
    with open(IN_JSON, encoding="utf-8") as f:
        recs = json.load(f)

    targets = []
    for r in recs:
        if any(s in r["api"] for s in SKIP):
            continue
        alive = [c for c in r["classes"] if c["total"] > 0]
        alive.sort(key=lambda x: -x["total"])
        targets.append((r["name"], r["api"], alive[0]["id"] if alive else None))
    for name, api in EXTRA:
        targets.append((name, api, None))

    print(f"测速 {len(targets)} 个源，每源 {ROUNDS} 轮取中位数\n")
    out = []
    for name, api, tid in targets:
        rec = bench(name, api, tid)
        out.append(rec)
        if rec.get("error"):
            print(f"{name:<16} ERR {rec['error']}")
        else:
            print(
                f"{name:<16} 首页={rec['home_ms']:>5}ms "
                f"(最快{rec['home_min']:>4}) 栏目={rec.get('cat_ms') or '-':>5}ms"
            )

    ok = [r for r in out if not r.get("error")]
    ok.sort(key=lambda r: r["home_ms"])
    print("\n--- 按首页响应从快到慢 ---")
    for i, r in enumerate(ok, 1):
        print(f"{i:>2}. {r['name']:<16} {r['home_ms']:>5}ms")

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"\n写入 {os.path.abspath(OUT_JSON)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())