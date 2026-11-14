# -*- coding: utf-8 -*-
"""复测 2026-11-13 清单里「标了可播但没接入」的 6 个候选站。

为什么单独写一个脚本而不是复用 probe_maccms_deep.py：
那个脚本是「34 个候选全量初筛」，跑一遍要十几分钟且会覆盖 dist/probe
下的既有结论。这里只关心 6 个域的**当下**状态（资源站域名寿命只有
几周到几个月，13 号能通的 17 号未必还通），所以：

  1. 只测这 6 个，不碰别的；
  2. 每个域只打 3 个请求：ac=list（分类树）+ ac=detail&pg=1（封面）
     + 抽 1 条 m3u8 验真可播；
  3. 结果写成独立文件，不与旧结论混在一起。

判定标准（与接入决策直接对应）：
    - ac=list 返回 JSON 且 list 非空        → 接口活
    - ac=detail&pg=1 的 vod_pic 有值        → 封面可用（不走二次批量补）
    - m3u8 直连 200 且内容以 #EXTM3U 开头   → 片源可播

三项全过的才值得接入。只有前两项过、第三项挂的，接了也是「能搜到
剧、点开全黑」，比不接更糟。
"""
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe",
                   "maccms_recheck.json")

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

# 上一轮清单里未接入的 6 个
CANDIDATES = [
    ("索尼资源", "https://suoniapi.com/api.php/provide/vod/"),
    ("闪电资源", "https://sdzyapi.com/api.php/provide/vod/"),
    ("无尽资源", "https://api.wujinapi.com/api.php/provide/vod/"),
    ("金鹰资源", "https://jyzyapi.com/provide/vod/"),
    ("豪华资源", "https://hhzyapi.com/api.php/provide/vod/"),
    ("百度资源", "https://api.apibdzy.com/api.php/provide/vod/"),
]

# 忽略证书：这些站大量用自签/过期证书，验证书等于把能用的站误杀
_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def get(url, timeout=20, read=200_000):
    """直连 GET，返回 (http状态, 文本, 耗时ms)。失败不抛异常，转成状态串。"""
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as r:
            raw = r.read(read)
            ms = int((time.time() - t0) * 1000)
            # 这些站混用 gbk / utf-8，且 json 里偶有非法字节
            for enc in ("utf-8", "gbk", "latin-1"):
                try:
                    return r.status, raw.decode(enc), ms
                except UnicodeDecodeError:
                    continue
            return r.status, raw.decode("utf-8", "replace"), ms
    except urllib.error.HTTPError as e:
        return e.code, "", int((time.time() - t0) * 1000)
    except Exception as e:  # noqa: BLE001  网络层什么都能抛，统一记账
        return type(e).__name__, "", int((time.time() - t0) * 1000)


def probe(name, api):
    r = {"name": name, "api": api}

    # ① 分类树
    st, txt, ms = get(f"{api}?ac=list")
    r["list_http"] = st
    r["list_ms"] = ms
    cats = []
    if isinstance(st, int) and st == 200 and txt.strip().startswith("{"):
        try:
            j = json.loads(txt)
            cats = j.get("class") or []
            r["list_json"] = True
        except json.JSONDecodeError:
            r["list_json"] = False
    else:
        r["list_json"] = False
        r["list_head"] = txt[:80]
    r["cat_count"] = len(cats)
    r["cats"] = [{"id": str(c.get("type_id")), "name": c.get("type_name")}
                 for c in cats][:20]

    # 提前返回的路径也必须把这三个键补齐。
    # 第一版漏了，结果「闪电资源」返回空分类时 dict 里没有 m3u8_ok，
    # 汇总那行 `{True:..}[r["m3u8_ok"]]` 直接 KeyError 把整轮打断——
    # 而且崩在最后一个站，前四个的结论全靠 stdout 抢救。
    # 结构化成「返回前先把字段填满」，比调用处逐个 get 更不容易漏。
    if not cats:
        r.setdefault("pic_ratio", "-")
        r["m3u8_ok"] = None
        r["m3u8_url"] = ""
        return r

    # ② 首页详情（看封面是否直出，决定要不要二次补图）
    st2, txt2, ms2 = get(f"{api}?ac=detail&pg=1")
    r["detail_http"] = st2
    r["detail_ms"] = ms2
    r["detail_kb"] = len(txt2) // 1024
    pics = plays = 0
    total = 0
    sample_play = ""
    if isinstance(st2, int) and st2 == 200:
        try:
            j2 = json.loads(txt2)
            for v in (j2.get("list") or [])[:20]:
                total += 1
                if (v.get("vod_pic") or "").strip():
                    pics += 1
                pf = (v.get("vod_play_from") or "")
                pu = (v.get("vod_play_url") or "")
                if pf and pu and not sample_play:
                    # vod_play_url 形如 `第1集$http://...m3u8#第2集$http://...`
                    m = re.search(r"(https?://[^#$\s]+\.m3u8)", pu)
                    if m:
                        sample_play = m.group(1)
                        plays = pf
        except json.JSONDecodeError:
            r["detail_json"] = False
    r["pic_ratio"] = f"{pics}/{total}"
    r["lines"] = plays

    # ③ 抽 1 条 m3u8 验真
    if sample_play:
        st3, txt3, ms3 = get(sample_play, read=4096)
        r["m3u8_http"] = st3
        r["m3u8_ok"] = isinstance(st3, int) and st3 == 200 and \
            "#EXTM3U" in txt3[:1024]
        r["m3u8_ms"] = ms3
        r["m3u8_url"] = sample_play
    else:
        r["m3u8_ok"] = None
        r["m3u8_url"] = ""

    return r


def main():
    out = []
    for name, api in CANDIDATES:
        sys.stdout.write(f"[..] {name} … ")
        sys.stdout.flush()
        r = probe(name, api)
        out.append(r)
        verdict = "接口活" if r["cat_count"] else "接口死"
        m3u8 = {True: "可播", False: "挂", None: "未测"}.get(r.get("m3u8_ok"), "?")
        print(f"{verdict}（{r['cat_count']} 分类, {r.get('list_ms')}ms）"
              f" / 封面 {r.get('pic_ratio','-')} / 片源 {m3u8}")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"\n写入 {os.path.normpath(OUT)}")

    # 汇总：三项全过的才推荐接入
    print("\n=== 可接入（接口活 + 封面有 + 片源可播）===")
    ok = [r for r in out if r["cat_count"] and r["m3u8_ok"]]
    for r in ok:
        print(f"  ★ {r['name']}  {r['api']}  {r['cat_count']} 分类  "
              f"{r.get('detail_kb','?')}KB  封面 {r.get('pic_ratio')}")
    if not ok:
        print("  （无）")


if __name__ == "__main__":
    main()