# -*- coding: utf-8 -*-
"""用**真实 vod_id** 验证详情页链路，这是接入与否的决定性测试。

## 为什么必须单独做这一步

上一轮 probe_retry.py 用 `ac=detail&ids=1,2,3` 得到空列表，看起来像
「详情接口不支持按 ids 查」。这个结论很可能是错的：

无尽资源 total=125,081，金鹰 total=118,332 —— 这种量级的 MacCMS 站，
`vod_id` 通常从某个较大的数字开始（采集器自增，中间有大量删除），
**id=1/2/3 往往根本不存在**。拿不存在的 id 去查，返回空是正确行为，
不能推出「接口不支持」。

区分这两件事的办法只有一个：从 `ac=list` 里取**确实存在的 id**，
再用它去 `ac=detail&ids=`。空 = 接口不支持按 ids 查；有货 = 一切正常。

## App 实际会走的三条链路，这里逐条验

  1. 列表页   `ac=list&pg=N`            → 卡片（要名称/备注；封面可能没有）
  2. 详情页   `ac=detail&ids=<真实id>`   → 简介/线路/分集
  3. 分类页   `ac=detail&t=<子分类>&pg=N` → 翻页（父分类可能是空壳）

第 3 条要特意测**子分类**而不是 t=1：金山/优子两个站的 t=1 是空壳，
而起点资源反过来（7 个父分类相加正好等于全站）。不能凭一个站的经验
推断另一个站。
"""
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.request

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe",
                   "maccms_realid.json")

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def get(url, timeout=25, read=600_000):
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
        return None, st, ms
    try:
        return json.loads(txt), st, ms
    except json.JSONDecodeError:
        return None, st, ms


def m3u8_of(vod_play_url):
    """从 vod_play_url 里抠第一条 m3u8。格式 `第1集$http://...#第2集$...`"""
    m = re.search(r"(https?://[^#$\s]+\.m3u8)", vod_play_url or "")
    return m.group(1) if m else ""


def verify(site):
    name, api = site
    print(f"\n{'=' * 68}\n{name}  {api}\n{'=' * 68}")
    rec = {"name": name, "api": api}

    # ---- 链路 1：列表页（取真实 id） ----
    # 用 ac=list；个别站 list 无封面，但一定有 id
    j, st, ms = jget(f"{api}?ac=list&pg=1")
    if not j:
        print(f"  ✗ ac=list 拿不到 JSON（http={st}, {ms}ms）")
        rec["ok"] = False
        return rec

    lst = j.get("list") or []
    total = j.get("total")
    print(f"  列表页 ac=list        {len(lst)} 条 / total={total} / {ms}ms")
    if not lst:
        print("  ✗ ac=list 空列表，无法继续")
        rec["ok"] = False
        return rec

    v0 = lst[0]
    real_id = str(v0.get("vod_id"))
    rec["real_id"] = real_id
    rec["list_total"] = total
    rec["list_pic"] = sum(1 for v in lst if (v.get("vod_pic") or "").strip())
    print(f"  列表首条             id={real_id} 「{v0.get('vod_name')}」"
          f" 封面有 {rec['list_pic']}/{len(lst)}")
    if lst and "vod_play_url" in lst[0]:
        rec["list_has_playurl"] = bool(lst[0].get("vod_play_url"))

    # ---- 链路 2：详情页（真实 id） ----
    j2, st2, ms2 = jget(f"{api}?ac=detail&ids={real_id}")
    ok_detail = bool(j2 and (j2.get("list") or []))
    print(f"  详情 ac=detail&ids={real_id:<6s} "
          f"{'✓' if ok_detail else '✗'} http={st2} {ms2}ms", end="")
    if ok_detail:
        d = j2["list"][0]
        play_from = d.get("vod_play_from") or ""
        play_url = d.get("vod_play_url") or ""
        # $$$ 是线路分隔符，# 是分集分隔符 —— 不能反
        lines = play_from.split("$$$") if play_from else []
        eps = play_url.split("#") if play_url else []
        url0 = m3u8_of(play_url)
        print(f" ·「{d.get('vod_name')}」")
        print(f"      封面 {(d.get('vod_pic') or '(空)')[:60]}")
        print(f"      线路 {len(lines)} 条: {lines}")
        print(f"      分集 {len(eps)} 条")
        rec["detail"] = {
            "name": d.get("vod_name"),
            "pic": (d.get("vod_pic") or "")[:100],
            "lines": lines,
            "ep_count": len(eps),
            "sample": url0,
        }
        if url0:
            st3, t3, ms3 = get(url0, read=4096)
            m3ok = isinstance(st3, int) and st3 == 200 and "#EXTM3U" in t3[:1024]
            print(f"      m3u8 {'✓ 可播' if m3ok else '✗ 挂'} "
                  f"http={st3} {ms3}ms")
            rec["m3u8_ok"] = m3ok
        else:
            print("      ✗ 抠不出 m3u8 地址")
            rec["m3u8_ok"] = False
    else:
        print(" 详情返回空 —— 该接口不支持按 ids 查")
        rec["detail"] = None

    # ---- 链路 3：分类翻页（挑 3 个有货的子分类） ----
    cats = j.get("class") or []
    # 跳过 t=1/2/3 这类顶层大类，优先测带具体名字的
    picks = [c for c in cats if str(c.get("type_id")) not in ("1",)][:3]
    rec["cats_ok"] = []
    for c in picks:
        tid = str(c.get("type_id"))
        j3, st3, ms3 = jget(f"{api}?ac=detail&t={tid}&pg=1")
        n3 = len((j3 or {}).get("list") or [])
        t3 = (j3 or {}).get("total")
        flag = "✓" if n3 else "✗"
        print(f"  分类 t={tid:<4s}「{c.get('type_name')}」 {flag} "
              f"{n3} 条 total={t3} {ms3}ms")
        if n3:
            rec["cats_ok"].append(
                {"id": tid, "name": c.get("type_name"), "n": n3, "total": t3})

    rec["ok"] = bool(rec.get("detail")) and bool(rec.get("m3u8_ok"))
    return rec


SITES = [
    ("索尼资源", "https://suoniapi.com/api.php/provide/vod/"),
    ("无尽资源", "https://api.wujinapi.com/api.php/provide/vod/"),
    ("金鹰资源", "https://jyzyapi.com/provide/vod/"),
    ("百度资源", "https://api.apibdzy.com/api.php/provide/vod/"),
]

out = []
for s in SITES:
    out.append(verify(s))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)

print(f"\n{'=' * 68}")
print("最终结论")
print("=" * 68)
for r in out:
    if r.get("ok"):
        d = r["detail"]
        print(f"  ★ 可接入  {r['name']} 片库 {r['list_total']}  "
              f"{len(d['lines'])} 线路  {d['ep_count']} 分集  "
              f"{len(r['cats_ok'])} 个分类可用")
    else:
        why = []
        if not r.get("detail"):
            why.append("详情查不到")
        elif not r.get("m3u8_ok"):
            why.append("片源不可播")
        if not r.get("cats_ok"):
            why.append("分类全空")
        print(f"  ✗ 不接    {r['name']}  {' / '.join(why) or '未知'}")
print(f"\n写入 {os.path.normpath(OUT)}")