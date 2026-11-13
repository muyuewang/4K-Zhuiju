# -*- coding: utf-8 -*-
"""直连实测 m3u8：每个源抽 3 部不同影片的首条 m3u8，看能否拉到 #EXTM3U。

这是最终判据 —— 接口通、m3u8 403 的源对 App 毫无价值（金牌影院前车之鉴）。
输出：dist/probe/maccms_play.json
"""
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests
import urllib3

urllib3.disable_warnings()

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe")
IN_JSON = os.path.join(OUT_DIR, "maccms_direct.json")
OUT_JSON = os.path.join(OUT_DIR, "maccms_play.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


def raw_get(url, referer=None, timeout=15):
    s = requests.Session()
    s.proxies = {}
    s.trust_env = False
    h = {"User-Agent": UA}
    if referer:
        h["Referer"] = referer
    r = s.get(url, headers=h, timeout=timeout, verify=False, stream=True)
    buf = b""
    for piece in r.iter_content(4096):
        buf += piece
        if len(buf) >= 8192:
            break
    r.close()
    return r.status_code, buf


def pick_m3u8s(vod_play_url, limit=3):
    out = []
    for seg in (vod_play_url or "").split("#"):
        m = re.search(r"(https?://[^\s$#]+?\.m3u8)", seg)
        if m:
            out.append(m.group(1))
            if len(out) >= limit:
                break
    return out


def test_play(rec):
    api = rec["api"].rstrip("/") + "/"
    item = {"name": rec["name"], "api": rec["api"], "site": rec["site"]}
    s = requests.Session()
    s.proxies = {}
    s.trust_env = False

    # 拿 3 部片子（分页取不同条目，避免同一 CDN）
    samples = []
    for pg in (1, 3):
        try:
            r = s.get(
                api + f"?ac=detail&pg={pg}",
                headers={"User-Agent": UA},
                timeout=15,
                verify=False,
            )
            d = r.json()
            for v in (d.get("list") or [])[:6]:
                urls = pick_m3u8s(v.get("vod_play_url"), 1)
                if urls:
                    samples.append((v.get("vod_name"), urls[0]))
                if len(samples) >= 3:
                    break
        except Exception:  # noqa: BLE001
            pass
        if len(samples) >= 3:
            break

    ref = rec["site"] if rec["site"].startswith("http") else "https://" + rec["site"]
    results = []
    for name, url in samples[:3]:
        try:
            st, buf = raw_get(url, referer=ref + "/")
            head = buf.decode("utf-8", "ignore")
            ok = st == 200 and "#EXTM3U" in head
            enc = "#EXT-X-STREAM-INF" in head  # 多码率 master
            results.append(
                {
                    "title": name,
                    "url": url,
                    "http": st,
                    "ok": ok,
                    "master": enc,
                    "bytes": len(buf),
                }
            )
        except Exception as e:  # noqa: BLE001
            results.append(
                {
                    "title": name,
                    "url": url,
                    "http": None,
                    "ok": False,
                    "bytes": 0,
                    "err": f"{type(e).__name__}",
                }
            )

    okn = sum(1 for x in results if x["ok"])
    item["samples"] = results
    item["play_ok"] = okn
    item["play_total"] = len(results)
    item["play_rate"] = round(okn / len(results) * 100) if results else 0
    return item


def main():
    with open(IN_JSON, encoding="utf-8") as f:
        recs = json.load(f)
    recs = [r for r in recs if r["direct_api"]["ok"]]
    print(f"仅验证直连可通的 {len(recs)} 个源\n")

    results = []
    with ThreadPoolExecutor(max_workers=5) as ex:
        futs = {ex.submit(test_play, r): r for r in recs}
        done = {}
        for fut in as_completed(futs):
            o = fut.result()
            done[o["name"]] = o
    for r in recs:
        o = done[r["name"]]
        results.append(o)
        det = " / ".join(
            f"{'Y' if x['ok'] else 'N'}{x['http'] or 'E'}" for x in o["samples"]
        )
        print(
            f"{o['name']:<8} {o['play_ok']}/{o['play_total']} "
            f"({o['play_rate']:>3}%)  {det}"
        )

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"\n写入 {os.path.abspath(OUT_JSON)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())