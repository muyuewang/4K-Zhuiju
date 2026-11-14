# -*- coding: utf-8 -*-
"""逐类遍历，找出哪些 type_id 真的有货。

## 为什么必须做这一步

索尼 / 无尽两个站 `ac=list&pg=1` 有货（total 14.9 万 / 12.5 万），
但 `t=2` `t=3` `t=4` 三个父分类全是 0 条。这有两种可能：

  (a) 父分类是空壳，货全在子分类里（金山 / 优子就是这种）
  (b) 这两站压根不支持 t 参数，只能搜索

两者的接入价值天差地别：
  (a) 可以正常做分类浏览，是个完整可用的源；
  (b) 用户只能靠搜索找剧，首页会是空的，接了等于半个残废。

不能凭猜。把 `class` 数组里**每一个** type_id 都打一遍，看谁有货。

## 顺带确认一件容易踩的事

分类树是**两级**的（父 id + 子 id 混在一个数组里，靠 type_pid 区分）。
如果只测父级，会误判成「全站没分类」；只测子级，又会把父级漏掉。
这里把两级都测，并记录 type_pid，输出时按父子归位。
"""
import json
import os
import ssl
import time
import urllib.error
import urllib.request

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe",
                   "maccms_cats.json")

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def get(url, timeout=25, read=800_000):
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


def walk(name, api):
    print(f"\n{'=' * 68}\n{name}  {api}\n{'=' * 68}")
    j, st, ms = jget(f"{api}?ac=list")
    if not j:
        print(f"  ✗ class 拿不到（http={st}）")
        return {"name": name, "api": api, "cats": []}

    cats = j.get("class") or []
    print(f"  分类树共 {len(cats)} 项")

    rows = []
    for c in cats:
        tid = str(c.get("type_id"))
        pid = str(c.get("type_pid") or "0")
        tname = c.get("type_name") or "?"
        # 每个分类只打 1 页，只关心「有没有货」
        jj, st2, ms2 = jget(f"{api}?ac=detail&t={tid}&pg=1")
        lst = (jj or {}).get("list") or []
        total = (jj or {}).get("total")
        n = len(lst)
        rows.append({"id": tid, "pid": pid, "name": tname,
                     "n": n, "total": total, "ms": ms2})
        flag = "✓" if n else "·"
        print(f"  {flag} t={tid:<5s} pid={pid:<3s} 「{tname}」 {n:2d} 条 "
              f"total={total} {ms2}ms")

    alive = [r for r in rows if r["n"] > 0]
    print(f"\n  有货的分类：{len(alive)}/{len(rows)}")
    return {"name": name, "api": api, "cats": rows, "alive": len(alive)}


SITES = [
    ("索尼资源", "https://suoniapi.com/api.php/provide/vod/"),
    ("无尽资源", "https://api.wujinapi.com/api.php/provide/vod/"),
    ("金鹰资源", "https://jyzyapi.com/provide/vod/"),
]

out = []
for s in SITES:
    out.append(walk(*s))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)

print(f"\n{'=' * 68}\n结论\n{'=' * 68}")
for r in out:
    alive = [c for c in r["cats"] if c["n"] > 0]
    tops = sorted(alive, key=lambda x: -(x["total"] or 0))[:6]
    print(f"  {r['name']}: {len(alive)} 个分类有货")
    for c in tops:
        print(f"      t={c['id']:<5s} 「{c['name']}」 total={c['total']}")
print(f"\n写入 {os.path.normpath(OUT)}")