# -*- coding: utf-8 -*-
"""逐分类探测每个新源的可用分类（哪些 type_id 真有数据）。

为什么必须逐条测：
    暴风源（bfzyapi）的父分类 20 电影片 / 30 连续剧 实测只有 14 / 7 条，
    真正内容全在 21~29、31~38 子分类下。凭直觉填父分类，
    用户点进去就是一片空白，会以为源坏了。

输出：dist/probe/maccms_classes.json
"""
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests
import urllib3

urllib3.disable_warnings()

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe")
IN_JSON = os.path.join(OUT_DIR, "maccms_deep.json")
OUT_JSON = os.path.join(OUT_DIR, "maccms_classes.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

# 要在 App 里露出的「一级栏目」候选名，命中即优先
PREFER = [
    "电影", "电影片", "电视剧", "连续剧", "剧集", "综艺", "综艺片",
    "动漫", "动漫片", "动画片", "纪录片", "记录片", "短剧", "体育赛事",
    "影视解说", "爽文短剧", "ai短剧",
]


def sess():
    s = requests.Session()
    s.proxies = {}
    s.trust_env = False
    return s


def count_of(api, tid, s):
    """返回该分类第一页条目数；0 表示这个分类没数据。"""
    try:
        r = s.get(
            api + f"?ac=list&t={tid}&pg=1",
            headers={"User-Agent": UA},
            timeout=15,
            verify=False,
        )
        if r.status_code != 200:
            return -1
        d = r.json()
        return len(d.get("list") or [])
    except Exception:  # noqa: BLE001
        return -1


def probe_source(rec):
    api = rec["api"].rstrip("/") + "/"
    classes = rec["deep"].get("classes") or []
    s = sess()
    out = []
    for c in classes:
        n = count_of(api, c["id"], s)
        out.append({"id": c["id"], "name": c["name"], "items": n})
    return {"name": rec["name"], "api": rec["api"], "site": rec["site"], "classes": out}


def main():
    with open(IN_JSON, encoding="utf-8") as f:
        recs = json.load(f)
    # 只测新源（排除已在用的 暴风/量子）
    keep = [r for r in recs if "bfzyapi" not in r["api"] and "lziapi" not in r["api"]]
    print(f"逐分类探测 {len(keep)} 个源的分类数据量（每个源 ~60 次请求）\n")

    results = []
    with ThreadPoolExecutor(max_workers=4) as ex:
        futs = {ex.submit(probe_source, r): r for r in keep}
        done = {}
        for fut in as_completed(futs):
            o = fut.result()
            done[o["name"]] = o
    for r in keep:
        o = done[r["name"]]
        results.append(o)
        alive = [c for c in o["classes"] if c["items"] and c["items"] > 0]
        dead = [c for c in o["classes"] if c["items"] == 0]
        print(f"=== {o['name']}  ({len(alive)}/{len(o['classes'])} 有数据)")
        print("  有数据:", ", ".join(f"{c['id']}:{c['name']}={c['items']}" for c in alive))
        if dead:
            print("  空分类:", ", ".join(f"{c['id']}:{c['name']}" for c in dead))
        print()

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"写入 {os.path.abspath(OUT_JSON)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())