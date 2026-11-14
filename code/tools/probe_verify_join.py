# -*- coding: utf-8 -*-
"""接入前的最后一道验证：逗号拼接分类 + 封面来源。

## 为什么必须验「逗号拼接」

本项目所有采集源的 `categories` 都写成 `SourceCategory('11,7,6,10', '电影')`
—— 用一个 Tab 合并多个原始分类。这套写法依赖 MacCMS 对 `t=11,7,6,10`
的解析，而**这个行为不是标准的一部分**：有的站支持，有的只认单个 id、
遇到逗号直接返回空。若源站不支持，写进去的结果就是「分类 Tab 点开全空」，
而且不会报错，最容易被当成「这站没资源」。

## 为什么同时要看封面来源

`ac=list` 若无 `vod_pic`，必须开 `listNeedsDetail: true` 改走 `ac=detail`。
代价是包体大十几倍（详见 site_sources.dart 里各源的注释），
所以要先量清楚到底缺不缺，不能凭经验一律打开。
"""
import json
import os
import ssl
import time
import urllib.error
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def get(url, timeout=25, read=900_000):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as r:
            raw = r.read(read)
            ms = int((time.time() - t0) * 1000)
            for enc in ("utf-8", "gbk", "latin-1"):
                try:
                    return r.status, raw.decode(enc), ms
                except UnicodeDecodeError:
                    continue
            return r.status, raw.decode("utf-8", "replace"), ms
    except urllib.error.HTTPError as e:
        return e.code, "", int((time.time() - t0) * 1000)
    except Exception as e:  # noqa: BLE001
        return type(e).__name__, "", int((time.time() - t0) * 1000)


def jget(url):
    st, txt, ms = get(url)
    if not (isinstance(st, int) and st == 200) or not txt.strip().startswith("{"):
        return None, st, ms, len(txt)
    try:
        return json.loads(txt), st, ms, len(txt)
    except json.JSONDecodeError:
        return None, st, ms, len(txt)


SITES = [
    ("索尼资源", "https://suoniapi.com/api.php/provide/vod/",
     [("6,7,8,9,10,11,12", "电影"), ("13,14,15,16,17,18,19", "剧集")]),
    ("无尽资源", "https://api.wujinapi.com/api.php/provide/vod/",
     [("6,7,8,9,10,11,12", "电影"), ("13,14,15,16,22,23,24", "剧集")]),
    ("金鹰资源", "https://jyzyapi.com/provide/vod/",
     [("9,10,11,12,13,14,15,16", "电影"), ("3,4,5,6,7,20,28", "剧集")]),
]

print("=" * 72)
print("① 逗号拼接多分类是否有效")
print("=" * 72)
for name, api, groups in SITES:
    print(f"\n--- {name} ---")
    for joined, label in groups:
        j, st, ms, ln = jget(f"{api}?ac=detail&t={joined}&pg=1")
        n = len((j or {}).get("list") or [])
        total = (j or {}).get("total")
        mark = "✓" if n else "✗"
        print(f"  {mark} t={joined:<24s}「{label}」 {n:2d} 条 total={total} "
              f"{ms}ms {ln // 1024}KB")
        if j and n:
            v = j["list"][0]
            print(f"      首条「{v.get('vod_name')}」pic={(v.get('vod_pic') or '')[:50]}")

print()
print("=" * 72)
print("② 列表页封面覆盖率（决定要不要开 listNeedsDetail）")
print("=" * 72)
for name, api, _ in SITES:
    for mode in ("list", "detail"):
        j, st, ms, ln = jget(f"{api}?ac={mode}&pg=1")
        lst = (j or {}).get("list") or []
        pics = sum(1 for v in lst if (v.get("vod_pic") or "").strip())
        print(f"  {name}  ac={mode:<7s} {len(lst):2d} 条 / 封面 {pics:2d} / "
              f"{ln // 1024:4d}KB / {ms}ms")

print()
print("=" * 72)
print("③ 详情页线路与分集（用真实 id）")
print("=" * 72)
for name, api, _ in SITES:
    j, _, _, _ = jget(f"{api}?ac=list&pg=1")
    lst = (j or {}).get("list") or []
    if not lst:
        print(f"  {name}: ac=list 无数据，跳过")
        continue
    rid = str(lst[0].get("vod_id"))
    j2, st2, ms2, _ = jget(f"{api}?ac=detail&ids={rid}")
    d = ((j2 or {}).get("list") or [{}])[0]
    pf = d.get("vod_play_from") or ""
    pu = d.get("vod_play_url") or ""
    lines = pf.split("$$$") if pf else []
    eps = pu.split("#") if pu else []
    print(f"  {name} id={rid} 线路 {len(lines)} 条 {lines} 分集 {len(eps)}")

print()
print("=" * 72)
print("④ 推荐位（无 t 参数）—— 首页首屏用")
print("=" * 72)
for name, api, _ in SITES:
    j, st, ms, ln = jget(f"{api}?ac=detail&pg=1")
    n = len((j or {}).get("list") or [])
    print(f"  {name}  ac=detail&pg=1  {n:2d} 条 / {ln // 1024}KB / {ms}ms")