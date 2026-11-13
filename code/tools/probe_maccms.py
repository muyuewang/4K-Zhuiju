# -*- coding: utf-8 -*-
"""批量探测 MacCMS V10 采集接口（/api.php/provide/vod/）可用性。

用法：
    python code/tools/probe_maccms.py
输出：
    dist/probe/maccms_report.json  +  终端汇总表

判定标准（按 App 实际需要）：
    1. HTTP 200 且 body 是 JSON
    2. code == 1
    3. list 非空，条目里有 vod_play_url
    4. vod_play_from 里出现过 m3u8 系线路标识（否则播放器打不开）
"""
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests
import urllib3

urllib3.disable_warnings()

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe")
OUT_JSON = os.path.join(OUT_DIR, "maccms_report.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

# (显示名, 接口地址, 门户网址)
CANDIDATES = [
    ("非凡资源", "http://cj.ffzyapi.com/api.php/provide/vod/", "https://ffzy.tv"),
    ("光速资源", "https://api.guangsuapi.com/api.php/provide/vod/", "https://www.guangsuzy.com"),
    ("快车资源", "https://caiji.kczyapi.com/api.php/provide/vod/", "https://kczy.cc"),
    ("天空资源", "http://m3u8.tiankongapi.com/api.php/provide/vod/", "http://tiankongapi.com"),
    ("红牛资源", "https://www.hongniuzy2.com/api.php/provide/vod/", "https://www.hongniuzy.com"),
    ("卧龙资源", "https://collect.wolongzyw.com/api.php/provide/vod/", "https://wolongzyw.com"),
    ("极速资源", "https://jszyapi.com/api.php/provide/vod/", "https://jszyapi.com"),
    ("豪华资源", "https://hhzyapi.com/api.php/provide/vod/", "https://hhzyapi.com"),
    ("索尼资源", "https://suoniapi.com/api.php/provide/vod/", "https://suonizy.net"),
    ("无尽资源", "https://api.wujinapi.com/api.php/provide/vod/", "https://wujinapi.com"),
    ("魔都资源", "https://caiji.moduapi.cc/api.php/provide/vod/", "https://moduapi.cc"),
    ("百度资源", "https://api.apibdzy.com/api.php/provide/vod/", "https://apibdzy.com"),
    ("1080资源", "http://api.1080zyku.com/inc/api.php/provide/vod/", "http://1080zyku.com"),
    ("360资源", "https://360zy.com/api.php/provide/vod/", "https://360zy.com"),
    ("电影天堂", "http://caiji.dyttzyapi.com/api.php/provide/vod/", "https://www.dyttzy.com"),
    ("樱花资源", "https://m3u8.apiyhzy.com/api.php/provide/vod/", "https://yhzy.cc"),
    ("猫眼资源", "https://api.maoyanapi.top/api.php/provide/vod", "https://www.maoyanzy.com"),
    ("茅台资源", "https://caiji.maotaizy.cc/api.php/provide/vod/", "https://mtzy.me"),
    ("闪电资源", "https://sdzyapi.com/api.php/provide/vod/", "https://sdzyapi.com"),
    ("金鹰资源", "https://jyzyapi.com/provide/vod/", "https://jyzyapi.com"),
    ("影库资源", "https://api.ykapi.net/api.php/provide/vod/", "https://ykapi.net"),
    ("老鸭资源", "https://api.apilyzy.com/api.php/provide/vod/", "https://apilyzy.com"),
    ("探探资源", "https://apittzy.com/api.php/provide/vod/", "https://apittzy.com"),
    ("奥斯卡资源", "https://aosikazy.com/api.php/provide/vod/", "https://aosikazy.com"),
    ("海外看", "https://haiwaikan.com/api.php/provide/vod/", "https://haiwaikan.com"),
    ("39影视", "https://www.39kan.com/api.php/provide/vod/", "https://www.39kan.com"),
    ("乐活影视", "https://lehootv.com/api.php/provide/vod/", "https://lehootv.com"),
    ("优质资源", "https://api.1080zyku.com/api.php/provide/vod/", "https://1080zyku.com"),
    ("卧龙备用", "https://wolongzyw.com/api.php/provide/vod/", "https://wolongzyw.com"),
    ("快帆资源", "https://api.kuaifanapi.com/api.php/provide/vod/", "https://kuaifanapi.com"),
    ("华为资源", "https://api.huaweiapi.com/api.php/provide/vod/", "https://huaweiapi.com"),
    ("新视觉资源", "https://api.xinshijueapi.com/api.php/provide/vod/", "https://xinshijueapi.com"),
    ("极速备用", "http://jszyapi.com/api.php/provide/vod/", "https://jszyapi.com"),
    ("非凡备用", "https://cj.ffzyapi.com/api.php/provide/vod/", "https://ffzy.tv"),
]

PROXIES = None
_p = (
    os.environ.get("HTTPS_PROXY")
    or os.environ.get("https_proxy")
    or os.environ.get("HTTP_PROXY")
    or os.environ.get("http_proxy")
)
if _p:
    PROXIES = {"http": _p, "https": _p}


def probe(item):
    name, api, site = item
    rec = {
        "name": name,
        "api": api,
        "site": site,
        "ok": False,
        "http": None,
        "code": None,
        "total": None,
        "page_items": 0,
        "class_count": 0,
        "classes": [],
        "play_from": [],
        "m3u8_line": False,
        "sample_title": None,
        "sample_m3u8": None,
        "latency_ms": None,
        "err": None,
    }
    url = api.rstrip("/") + "/?ac=detail&pg=1"
    t0 = time.time()
    try:
        r = requests.get(
            url,
            headers={"User-Agent": UA, "Accept": "application/json,*/*"},
            proxies=PROXIES,
            timeout=15,
            verify=False,
        )
        rec["latency_ms"] = int((time.time() - t0) * 1000)
        rec["http"] = r.status_code
        if r.status_code != 200:
            rec["err"] = f"HTTP {r.status_code}"
            return rec
        body = r.text.strip()
        # 有些站返回 html 首页（接口路径错误），先粗判
        if not body.startswith("{"):
            rec["err"] = "not json: " + body[:60].replace("\n", " ")
            return rec
        data = r.json()
        rec["code"] = data.get("code")
        rec["total"] = data.get("total")
        lst = data.get("list") or []
        rec["page_items"] = len(lst)
        cls = data.get("class") or []
        rec["class_count"] = len(cls)
        rec["classes"] = [
            {"id": str(c.get("type_id")), "name": c.get("type_name")}
            for c in cls[:60]
        ]
        if lst:
            first = lst[0]
            rec["sample_title"] = first.get("vod_name")
            rec["play_from"] = [
                s for s in (first.get("vod_play_from") or "").split("$") if s
            ]
            rec["m3u8_line"] = any(
                ("m3u8" in f.lower()) or ("m3u8" in (first.get("vod_play_url") or "").lower())
                for f in rec["play_from"]
            )
            urls = (first.get("vod_play_url") or "").split("#")
            for u in urls:
                m = re.search(r"(https?://[^\s$#]+?\.m3u8)", u)
                if m:
                    rec["sample_m3u8"] = m.group(1)
                    break
        rec["ok"] = (
            rec["code"] == 1
            and rec["page_items"] > 0
            and bool(rec["play_from"])
        )
    except Exception as e:  # noqa: BLE001
        rec["latency_ms"] = int((time.time() - t0) * 1000)
        rec["err"] = f"{type(e).__name__}: {e}"[:160]
    return rec


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"proxy = {PROXIES}")
    print(f"candidates = {len(CANDIDATES)}\n")

    results = []
    with ThreadPoolExecutor(max_workers=10) as ex:
        futs = {ex.submit(probe, c): c for c in CANDIDATES}
        for fut in as_completed(futs):
            rec = fut.result()
            results.append(rec)
            flag = "OK " if rec["ok"] else "FAIL"
            print(
                f"[{flag}] {rec['name']:<10} http={rec['http']} "
                f"total={rec['total']} items={rec['page_items']} "
                f"cls={rec['class_count']} m3u8={rec['m3u8_line']} "
                f"{rec['latency_ms']}ms {rec['err'] or ''}"
            )

    order = {c[0]: i for i, c in enumerate(CANDIDATES)}
    results.sort(key=lambda r: (not r["ok"], order.get(r["name"], 99)))

    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)

    ok = [r for r in results if r["ok"]]
    print(f"\n可用 {len(ok)} / {len(results)}，报告写入 {os.path.abspath(OUT_JSON)}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())