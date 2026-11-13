# -*- coding: utf-8 -*-
"""对已初筛通过的 MacCMS 采集接口做深度验证。

验证四件事：
    1. 分类树（ac=list 拿 class）
    2. 搜索命中（wd=凡人修仙传）
    3. 真实 m3u8 可播性（GET 首个地址，看 HTTP 200 + #EXTM3U）
    4. 更新速度（看最近 vod_time）

用法：python code/tools/probe_maccms_deep.py
输出：dist/probe/maccms_deep.json
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
OUT_JSON = os.path.join(OUT_DIR, "maccms_deep.json")
IN_JSON = os.path.join(OUT_DIR, "maccms_report.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

_p = (
    os.environ.get("HTTPS_PROXY")
    or os.environ.get("https_proxy")
    or os.environ.get("HTTP_PROXY")
    or os.environ.get("http_proxy")
)
PROXIES = {"http": _p, "https": _p} if _p else None

SEARCH_WD = "凡人修仙传"


def jget(url, timeout=20):
    r = requests.get(
        url,
        headers={"User-Agent": UA, "Accept": "application/json,*/*"},
        proxies=PROXIES,
        timeout=timeout,
        verify=False,
    )
    if r.status_code != 200:
        raise RuntimeError(f"HTTP {r.status_code}")
    body = r.text.strip()
    if not body.startswith("{"):
        raise RuntimeError("not json: " + body[:50].replace("\n", " "))
    return r.json()


def check_m3u8(url, referer=None):
    """返回 (可播 bool, 状态, 字节数/说明)"""
    h = {"User-Agent": UA}
    if referer:
        h["Referer"] = referer
    try:
        r = requests.get(
            url,
            headers=h,
            proxies=PROXIES,
            timeout=20,
            verify=False,
            stream=True,
        )
        chunk = b""
        for piece in r.iter_content(2048):
            chunk += piece
            if len(chunk) >= 4096:
                break
        r.close()
        head = chunk.decode("utf-8", "ignore")
        playable = r.status_code == 200 and "#EXTM3U" in head
        return playable, r.status_code, len(chunk)
    except Exception as e:  # noqa: BLE001
        return False, None, f"{type(e).__name__}"


def deep(rec):
    api = rec["api"].rstrip("/") + "/"
    out = dict(rec)
    out["deep"] = {}
    d = out["deep"]

    # 1) 分类树
    try:
        data = jget(api + "?ac=list")
        cls = data.get("class") or []
        d["class_total"] = len(cls)
        d["classes"] = [
            {"id": str(c.get("type_id")), "name": c.get("type_name")}
            for c in cls
        ]
        d["class_ok"] = True
    except Exception as e:  # noqa: BLE001
        d["class_ok"] = False
        d["class_err"] = str(e)[:120]
        d["classes"] = []

    # 2) 搜索
    try:
        data = jget(api + "?ac=detail&wd=" + requests.utils.quote(SEARCH_WD))
        lst = data.get("list") or []
        d["search_hits"] = len(lst)
        if lst:
            first = lst[0]
            d["search_first"] = first.get("vod_name")
            d["search_first_from"] = [
                s for s in (first.get("vod_play_from") or "").split("$") if s
            ]
            d["search_first_time"] = first.get("vod_time")
    except Exception as e:  # noqa: BLE001
        d["search_hits"] = None
        d["search_err"] = str(e)[:120]

    # 3) 最新更新（按时间倒序第一条）+ 真实 m3u8 抽验
    try:
        data = jget(api + "?ac=detail&pg=1")
        lst = data.get("list") or []
        d["total"] = data.get("total")
        d["pagecount"] = data.get("pagecount")
        d["limit"] = data.get("limit")
        if lst:
            fresh = lst[0]
            d["newest_title"] = fresh.get("vod_name")
            d["newest_time"] = fresh.get("vod_time")
            d["newest_remarks"] = fresh.get("vod_remarks")
            froms = [s for s in (fresh.get("vod_play_from") or "").split("$") if s]
            d["newest_from"] = froms
            # 抽验首个 m3u8
            urls = (fresh.get("vod_play_url") or "").split("#")
            tested = 0
            for u in urls:
                m = re.search(r"(https?://[^\s$#]+?\.m3u8)", u)
                if not m:
                    continue
                url = m.group(1)
                playable, st, n = check_m3u8(url, site_ref(api))
                d["m3u8_sample"] = url
                d["m3u8_playable"] = playable
                d["m3u8_status"] = st
                d["m3u8_size"] = n
                tested += 1
                break
            if not tested:
                d["m3u8_playable"] = False
                d["m3u8_err"] = "no m3u8 in newest item"
    except Exception as e:  # noqa: BLE001
        d["newest_err"] = str(e)[:120]
        d["m3u8_playable"] = False

    # 总评分
    score = 0
    if d.get("m3u8_playable"):
        score += 50
    if d.get("search_hits"):
        score += 20
    if d.get("class_ok") and d.get("class_total", 0) > 3:
        score += 15
    if (d.get("total") or 0) > 80000:
        score += 15
    elif (d.get("total") or 0) > 30000:
        score += 10
    out["score"] = score
    return out


def site_ref(api):
    m = re.match(r"(https?://[^/]+)", api)
    return (m.group(1) + "/") if m else None


def main():
    with open(IN_JSON, encoding="utf-8") as f:
        allrec = json.load(f)
    cands = [r for r in allrec if r["ok"]]
    # 去重：同一域名只留第一个
    seen, uniq = set(), []
    for r in cands:
        host = re.sub(r"^https?://", "", r["api"]).split("/")[0]
        if host in seen:
            continue
        seen.add(host)
        uniq.append(r)
    print(f"深度验证 {len(uniq)} 个（去重前 {len(cands)}）\n")

    results = []
    with ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(deep, r): r for r in uniq}
        for fut in as_completed(futs):
            rec = fut.result()
            results.append(rec)
            d = rec["deep"]
            print(
                f"[{rec['score']:>3}] {rec['name']:<8} total={d.get('total')} "
                f"cls={d.get('class_total')} search={d.get('search_hits')} "
                f"m3u8={'Y' if d.get('m3u8_playable') else 'N'} "
                f"({d.get('m3u8_status')}) newest={d.get('newest_time')}"
            )

    results.sort(key=lambda r: -r["score"])
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"\n写入 {os.path.abspath(OUT_JSON)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())