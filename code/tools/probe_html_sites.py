"""探测 csp_MacCMS 给出的 HTML 网页站，挑出真正的 AppleCMS（maccms）影视站。

与纯 API 探测的差别：
  上一轮只测 `?ac=list` 返回 JSON，返回 HTML 的一律判死（137 个）。
  但 HTML 站本身是可接入的 —— 项目里已有 MacCmsSource（正则解析
  voddetail / vodplay / player_aaaa），过去却只用在「片库」一个站上。

判定链（分两阶段，前一阶段失败即出局）：
  阶段一 根路径：200 且 HTML 里有 maccms 特征 -> 进入阶段二
  阶段二 搜索 / 详情 / 播放：拿到 voddetail -> vodplay -> player_aaaa
        -> 该 url 返回 #EXTM3U 才算真正可播

并发：20 线程。100 个域名串行 + 12s 超时最坏要 20 分钟，用户等不了。
"""
import json
import re
import ssl
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")

_TIMEOUT = 10


def http(url, timeout=_TIMEOUT, referer=None, read=200000):
    h = {"User-Agent": UA, "Accept": "*/*",
         "Accept-Language": "zh-CN,zh;q=0.9"}
    if referer:
        h["Referer"] = referer
    req = urllib.request.Request(url, headers=h)
    op = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=CTX))
    t = time.time()
    try:
        with op.open(req, timeout=timeout) as r:
            body = r.read(read)
            return {"ok": True, "code": r.status,
                    "ms": round((time.time() - t) * 1000),
                    "text": body.decode("utf-8", "ignore"),
                    "final": r.geturl()}
    except urllib.error.HTTPError as e:
        return {"ok": False, "code": e.code,
                "ms": round((time.time() - t) * 1000),
                "text": "", "err": "HTTP%d" % e.code, "final": url}
    except Exception as e:
        return {"ok": False, "code": 0,
                "ms": round((time.time() - t) * 1000),
                "text": "", "err": type(e).__name__, "final": url}


MACCMS_MARKS = [
    r'/voddetail/', r'/vodplay/', r'vodsearch', r'maccms', r'苹果CMS',
    r'mxpro', r'/vodtype/', r'template/', r'mac_',
]


def maccms_score(html):
    low = html.lower()
    return sum(1 for m in MACCMS_MARKS if re.search(m, low))


def stage_root(url):
    """阶段一：根路径是不是 maccms 站"""
    r = http(url + '/')
    rec = {"url": url, "root_code": r["code"], "root_ms": r["ms"],
           "err": r.get("err"), "final": r.get("final"), "score": 0,
           "title": "", "verdict": "", "search_ok": False,
           "detail_url": "", "play_url": "", "m3u8_ok": False,
           "m3u8_url": "", "m3u8_ms": 0, "lines": [], "ep_count": 0}
    if not r["ok"]:
        rec["verdict"] = "root_fail"
        return rec
    html = r["text"]
    m = re.search(r'<title[^>]*>(.*?)</title>', html, re.S | re.I)
    rec["title"] = (m.group(1).strip()[:40] if m else '')
    rec["score"] = maccms_score(html)
    rec["verdict"] = "maybe_maccms" if rec["score"] >= 2 else "not_maccms"
    return rec


# 搜索页几种常见写法，按概率排序
SEARCH_PATHS = [
    '/vodsearch/-------------.html?wd={kw}',
    '/index.php/vod/search.html?wd={kw}',
    '/vodsearch/{kw}----------1---.html',
    '/index.php/vod/search/wd/{kw}.html',
]
KW = '庆余年'
DETAIL_RE = re.compile(r'href="(/voddetail/(\d+)\.html)"')
PLAY_RE = re.compile(r'href="(/vodplay/(\d+)-(\d+)-(\d+)\.html)"')
PLAYER_RE = re.compile(r'player_aaaa\s*=\s*(\{.*?\})\s*</script>', re.S)


def stage_search(url):
    from urllib.parse import quote
    kw = quote(KW)
    for p in SEARCH_PATHS:
        r = http(url + p.format(kw=kw), referer=url + '/')
        if not r["ok"]:
            continue
        m = DETAIL_RE.search(r["text"])
        if m:
            return True, r["final"], m.group(1)
    return False, "", ""


def stage_detail(url, detail_path):
    r = http(url + detail_path, referer=url + '/')
    if not r["ok"]:
        return None
    html = r["text"]
    plays = PLAY_RE.findall(html)
    if not plays:
        return None
    # 线路名：source-tab-item 的 data-target + 文本
    tabs = re.findall(
        r'data-target="(playlist-\d+)"[^>]*>([^<]+)</span>', html)
    lines = [t[1].strip() for t in tabs]
    first = plays[0]
    return {"play_path": first[0], "ep_count": len(plays),
            "lines": lines[:8], "line_count": len(lines)}


def stage_play(url, play_path):
    r = http(url + play_path, referer=url + '/')
    if not r["ok"]:
        return None
    m = PLAYER_RE.search(r["text"])
    if not m:
        m2 = re.search(r'player_aaaa\s*=\s*(\{.*?\})\s*;', r["text"], re.S)
        if not m2:
            return None
        raw = m2.group(1)
    else:
        raw = m.group(1)
    try:
        cfg = json.loads(raw)
    except Exception:
        try:
            cfg = json.loads(raw.replace('\\"', '"'))
        except Exception:
            return None
    pu = (cfg.get("url") or "").strip()
    fr = (cfg.get("from") or "").strip()
    if not pu.startswith("http"):
        return None
    return {"url": pu, "from": fr, "encrypt": cfg.get("encrypt")}


def probe_one(item):
    url, meta = item
    rec = stage_root(url)
    rec["name"] = meta.get("name", "")
    if rec["verdict"] != "maybe_maccms":
        return rec
    ok, final, dpath = stage_search(url)
    rec["search_ok"] = ok
    if not ok:
        rec["verdict"] = "no_search"
        return rec
    det = stage_detail(url, dpath)
    if not det:
        rec["verdict"] = "no_detail"
        return rec
    rec["detail_url"] = url + dpath
    rec["ep_count"] = det["ep_count"]
    rec["lines"] = det["lines"]
    play = stage_play(url, det["play_path"])
    rec["play_url"] = url + det["play_path"]
    if not play:
        rec["verdict"] = "no_player_aaaa"
        return rec
    rec["m3u8_url"] = play["url"]
    rec["play_from"] = play["from"]
    r = http(play["url"], referer=url + '/', read=4000)
    rec["m3u8_ms"] = r["ms"]
    txt = r["text"]
    if r["ok"] and "#EXTM3U" in txt:
        rec["m3u8_ok"] = True
        rec["verdict"] = "PLAYABLE"
    else:
        rec["m3u8_ok"] = False
        rec["verdict"] = "m3u8_fail"
        rec["m3u8_err"] = r.get("err") or ("code%d" % r["code"])
    return rec


def main():
    cands = json.load(open('/tmp/html_cands.json', encoding='utf-8'))
    items = list(cands.items())
    out = []
    done = 0
    with ThreadPoolExecutor(max_workers=20) as ex:
        futs = {ex.submit(probe_one, it): it[0] for it in items}
        for f in as_completed(futs):
            done += 1
            try:
                rec = f.result()
            except Exception as e:
                rec = {"url": futs[f], "verdict": "exception",
                       "err": "%s" % type(e).__name__}
            out.append(rec)
            print("[%3d/%d] %-40s %-14s score=%s m3u8=%s" % (
                done, len(items), rec.get("url", "")[:40],
                rec.get("verdict", ""), rec.get("score", 0),
                rec.get("m3u8_ok")), flush=True)

    order = {"PLAYABLE": 0, "m3u8_fail": 1, "no_player_aaaa": 2,
             "no_detail": 3, "no_search": 4, "maybe_maccms": 5,
             "not_maccms": 6, "root_fail": 7, "exception": 8}
    out.sort(key=lambda r: (order.get(r.get("verdict"), 9),
                            r.get("root_ms", 9999)))
    json.dump(out, open('dist/probe/html_sites_root.json', 'w',
                        encoding='utf-8'), ensure_ascii=False, indent=1)

    from collections import Counter
    c = Counter(r.get("verdict") for r in out)
    print("\n=== 汇总 %d 个域名 ===" % len(out))
    for k, v in c.most_common():
        print("  %-16s %d" % (k, v))
    playable = [r for r in out if r.get("verdict") == "PLAYABLE"]
    print("\n=== 可播 %d 个 ===" % len(playable))
    for r in playable:
        print("  %-34s %-16s 集%-4d 线路%d  %s" % (
            r["url"][:34], r.get("title", "")[:16], r.get("ep_count", 0),
            len(r.get("lines", [])), r.get("m3u8_url", "")[:50]))


if __name__ == '__main__':
    main()