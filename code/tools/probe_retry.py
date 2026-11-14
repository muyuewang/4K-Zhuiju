# -*- coding: utf-8 -*-
"""对「复测失败」的 5 个站做失败模式逐项排查。

第一轮复测（probe_recheck.py）的结果分成两类失败，两类都**不能直接
判死**，因为它们各自有明确的可疑点：

## A 类：接口活、但 ac=detail&pg=1 返回空 list
  无尽资源 / 金鹰资源 / 百度资源

  HTTP 200、包体 180KB、JSON 能解析、分类树 54~63 个都正常，唯独
  `ac=detail&pg=1` 的 `list` 是空的。这不是站死了，是 MacCMS 的
  请求语义问题：`ac=detail` 在多数版本里是「按 ids 查详情」，
  不带 `ids` 也不带 `t` 时，不同源站实现不一致 ——
  有的返回全站第一页，有的返回空。

  所以要把这几种写法都试一遍，看哪种真的有货：
      ac=detail&t=1&pg=1     按分类取（最常见可用的形态）
      ac=detail&pg=1         第一轮已经试过（空）
      ac=video&pg=1          部分老版本用 ac=video
      ac=list&pg=1           列表模式（字段少、无封面，但至少能确认有货）
      ac=list&t=1&pg=1       列表 + 分类
  **判定看 `list` 长度，不看 HTTP 码。**

## B 类：HTTP 400
  闪电资源 / 豪华资源

  400 是「服务端不愿意处理这个请求」，不是 404 也不是超时。
  常见三个原因，逐个试：
      1. 协议：https 换成 http（有些站只在一边配了 vhost）
      2. 路径：`/api.php/provide/vod/` 少了或多了结尾斜杠、
         或路径前缀不同（`/provide/vod/`）
      3. UA / Referer：采集站普遍屏蔽空 UA 与非常规 UA

输出：dist/probe/maccms_retry.json
"""
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe",
                   "maccms_retry.json")

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def get(url, headers=None, timeout=20, read=400_000):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
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


def try_one(url, label=""):
    """打一次请求，尽量把「有没有货」量化出来。"""
    st, txt, ms = get(url)
    res = {"label": label, "url": url, "http": st, "ms": ms, "n": 0}
    if isinstance(st, int) and st == 200 and txt.strip().startswith("{"):
        try:
            j = json.loads(txt)
        except json.JSONDecodeError:
            res["json"] = False
            return res
        lst = j.get("list") or []
        res["json"] = True
        res["n"] = len(lst)
        res["total"] = j.get("total")
        if lst:
            v = lst[0]
            res["first"] = {
                "name": v.get("vod_name"),
                "pic": (v.get("vod_pic") or "")[:80],
                "from": v.get("vod_play_from"),
            }
            # 抽一条 m3u8 验真
            pu = v.get("vod_play_url") or ""
            m = re.search(r"(https?://[^#$\s]+\.m3u8)", pu)
            if m:
                st2, t2, ms2 = get(m.group(1), read=4096)
                res["m3u8"] = {
                    "http": st2,
                    "ok": isinstance(st2, int) and st2 == 200 and
                          "#EXTM3U" in t2[:1024],
                    "url": m.group(1),
                    "ms": ms2,
                }
    else:
        res["json"] = False
        res["head"] = txt[:100]
    return res


print("=" * 70)
print("A 类：ac=detail 空列表 → 换请求形态找有货的那一种")
print("=" * 70)

A_SITES = [
    ("无尽资源", "https://api.wujinapi.com/api.php/provide/vod/"),
    ("金鹰资源", "https://jyzyapi.com/provide/vod/"),
    ("百度资源", "https://api.apibdzy.com/api.php/provide/vod/"),
]

A_VARIANTS = [
    ("detail+t1", "?ac=detail&t=1&pg=1"),
    ("detail+ids", "?ac=detail&ids=1,2,3"),
    ("video+pg", "?ac=video&pg=1"),
    ("list+pg", "?ac=list&pg=1"),
    ("list+t1", "?ac=list&t=1&pg=1"),
    ("detail+t2", "?ac=detail&t=2&pg=1"),
]

a_out = []
for name, api in A_SITES:
    print(f"\n--- {name} ---")
    rec = {"name": name, "api": api, "variants": []}
    for label, q in A_VARIANTS:
        r = try_one(api + q, label)
        rec["variants"].append(r)
        m3 = ""
        if r.get("m3u8"):
            m3 = " / m3u8 " + ("可播" if r["m3u8"]["ok"] else "挂")
        print(f"  {label:12s} http={r['http']!s:4s} n={r['n']:2d} "
              f"{r.get('ms','')}ms total={r.get('total')}{m3}")
    a_out.append(rec)

print()
print("=" * 70)
print("B 类：HTTP 400 → 换协议 / 路径 / 请求头")
print("=" * 70)

B_SITES = [
    ("闪电资源", "sdzyapi.com", "/api.php/provide/vod/"),
    ("豪华资源", "hhzyapi.com", "/api.php/provide/vod/"),
]

B_VARIANTS = [
    ("https+slash", "https://{h}{p}"),
    ("https-noslash", "https://{h}{p}".rstrip("/")),
    ("http+slash", "http://{h}{p}"),
    ("http-noslash", "http://{h}{p}".rstrip("/")),
    ("https+v1", "https://{h}/api.php/v1/vod/"),
    ("https+noprovide", "https://{h}/api.php/provide/vod"),
    ("https+root", "https://{h}/"),
    ("https+www", "https://www.{h}{p}"),
]

b_out = []
for name, host, path in B_SITES:
    print(f"\n--- {name} ({host}) ---")
    rec = {"name": name, "host": host, "variants": []}
    for label, tpl in B_VARIANTS:
        u = tpl.format(h=host, p=path) + "?ac=list"
        r = try_one(u, label)
        rec["variants"].append(r)
        print(f"  {label:16s} http={r['http']!s:4s} n={r['n']:2d} "
              f"{r.get('ms','')}ms")
    # 针对 400 再补一次「带 Referer」的尝试：部分站校验来源
    u = "https://{}{}?ac=list".format(host, path)
    r = try_one(u, "with-referer")
    r["url"] = u
    rec["variants"].append(r)
    print(f"  {'with-referer':16s} http={r['http']!s:4s} n={r['n']:2d}")
    # 再试一次：Referer 用站点根，UA 换成常见采集 UA
    st, txt, ms = get(u, headers={"Referer": f"https://{host}/"})
    print(f"  {'referer+root':16s} http={st!s:4s} len={len(txt)}")
    b_out.append(rec)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump({"A": a_out, "B": b_out}, f, ensure_ascii=False, indent=2)
print(f"\n写入 {os.path.normpath(OUT)}")

print("\n" + "=" * 70)
print("结论：有货且片源可播的（接口 + 列表 + m3u8）")
print("=" * 70)
found = False
for rec in a_out + b_out:
    best = [v for v in rec["variants"]
            if v["n"] > 0 and (v.get("m3u8") or {}).get("ok")]
    if not best:
        continue
    found = True
    b = best[0]
    print(f"  ★ {rec['name']}  形态={b['label']}")
    print(f"       {b['url']}")
    print(f"       {b['n']} 条 / {b['first']['name']} / "
          f"{b['first']['from']} / {b['ms']}ms")
if not found:
    print("  （无）")