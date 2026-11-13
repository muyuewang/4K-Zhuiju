# -*- coding: utf-8 -*-
"""测出每个源「每个子分类的真实 total」，供挑选栏目代表分类。

为什么要真实 total：
    上一版只记了首页条数（恒为 20），无法排序。
    而父分类（电影/电视剧/综艺/动漫）在采集接口下恒为 0 条，
    栏目必须由若干子分类拼出来，得知道谁的量最大。

输出：dist/probe/maccms_totals.json
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
OUT_JSON = os.path.join(OUT_DIR, "maccms_totals.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


def sess():
    s = requests.Session()
    s.proxies = {}
    s.trust_env = False
    return s


def one(api, tid, s):
    try:
        r = s.get(
            api + f"?ac=list&t={tid}&pg=1",
            headers={"User-Agent": UA},
            timeout=20,
            verify=False,
        )
        d = r.json()
        return int(d.get("total") or 0)
    except Exception:  # noqa: BLE001
        return -1


def probe(rec):
    api = rec["api"].rstrip("/") + "/"
    classes = rec["deep"].get("classes") or []
    s = sess()
    rows = []
    for c in classes:
        rows.append({"id": c["id"], "name": c["name"], "total": one(api, c["id"], s)})
    rows.sort(key=lambda x: -x["total"])
    return {"name": rec["name"], "api": rec["api"], "site": rec["site"], "classes": rows}


def main():
    with open(IN_JSON, encoding="utf-8") as f:
        recs = json.load(f)
    keep = [r for r in recs if "bfzyapi" not in r["api"] and "lziapi" not in r["api"]]
    print(f"测 {len(keep)} 个源的全部分类 total\n")

    out = []
    with ThreadPoolExecutor(max_workers=4) as ex:
        futs = {ex.submit(probe, r): r for r in keep}
        done = {}
        for fut in as_completed(futs):
            o = fut.result()
            done[o["name"]] = o
    for r in keep:
        o = done[r["name"]]
        out.append(o)
        top = [c for c in o["classes"] if c["total"] > 0][:12]
        print(f"=== {o['name']}   (有数据 {sum(1 for c in o['classes'] if c['total']>0)} 类)")
        print("  top:", ", ".join(f"{c['id']}:{c['name']}={c['total']}" for c in top))
        print()

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"写入 {os.path.abspath(OUT_JSON)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())