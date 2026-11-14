#!/usr/bin/env python3
"""全量复探 assets/live_channels.json 里每个频道，产出精确的存活表。

为什么不用抽样
--------------
2026-11-14 首轮只抽了 450 个（央卫视全测、其余每栏抽 60）就得出
「整体 88.9% 可播」。抽样能回答「大概能不能看」，**不能用来决定删谁**：
「主播原创」1459 个只抽 60 个，抽样里判死的那个台，可能在没抽到的
1400 个里有更好的镜像。要瘦身就必须逐个测。

两个必须避开的坑
----------------
1. **URL 含中文必须 percent-encode**。`live.php?id=浙江卫视` 这种地址
   不编码直接丢给 urllib 会抛 UnicodeEncodeError —— 那是探测脚本的
   缺陷，不是频道挂了。首轮 20 个假阴性就是这么来的（复测 25/26 都活）。
2. **RTMP 不参与 HTTP 探测**。probe_live.py 里写着「直接视为可用」，
   但 Dart 侧注释明说「rtmp 在移动端基本不能播」。打包时没验证过，
   等于 15 个频道是「未经验证就进包」的占位。本脚本直接标记 drop。

判活标准与打包脚本一致（看响应体而非状态码）：
    FLV   前 3 字节 b'FLV'
    M3U8  含 '#EXTM3U'
    MP4   前 64 字节含 b'ftyp'

用法：
    python tools/recheck_live_all.py            # 全量
    python tools/recheck_live_all.py --limit 50 # 冒烟
"""
import argparse
import collections
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(os.path.dirname(HERE), "flutter_app")
ASSET = os.path.join(APP, "assets", "live_channels.json")
OUT = os.path.join(os.path.dirname(os.path.dirname(HERE)),
                   "dist", "probe", "live_full.json")

_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE

UA_DEFAULT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
              "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36")

TIMEOUT = 10
WORKERS = 48
RETRY_WORKERS = 4
RETRY_ATTEMPTS = 2


def fix_url(u):
    """中文/空格路径必须百分号编码，否则 urllib 抛 UnicodeEncodeError。"""
    try:
        p = urllib.parse.urlsplit(u)
        return urllib.parse.urlunsplit((
            p.scheme, p.netloc,
            urllib.parse.quote(p.path, safe="/%:@&=+$,~!*'()"),
            urllib.parse.quote(p.query, safe="=&%:@+,/?~!*'()"),
            p.fragment,
        ))
    except Exception:
        return u


def probe(ch):
    """返回 (ok, kind, ms, err)。kind 是实测到的真实流类型。"""
    url = ch["url"]
    if url.lower().startswith(("rtmp://", "rtsp://")):
        return False, "", 0, "RTMP_UNSUPPORTED"
    h = {"User-Agent": ch.get("ua") or UA_DEFAULT, "Accept": "*/*"}
    t0 = time.time()
    try:
        req = urllib.request.Request(fix_url(url), headers=h)
        op = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=_SSL))
        with op.open(req, timeout=TIMEOUT) as r:
            head = r.read(4096)
        ms = round((time.time() - t0) * 1000)
        if head[:3] == b"FLV":
            return True, "FLV", ms, ""
        if "#EXTM3U" in head.decode("utf-8", "replace"):
            return True, "M3U8", ms, ""
        if b"ftyp" in head[:64]:
            return True, "MP4", ms, ""
        return False, "", ms, "BAD_BODY"
    except urllib.error.HTTPError as e:
        return False, "", round((time.time() - t0) * 1000), "HTTP%d" % e.code
    except Exception as e:
        return False, "", round((time.time() - t0) * 1000), type(e).__name__


TRANSIENT = {"URLError", "TimeoutError", "RemoteDisconnected",
             "ConnectionResetError", "http.client.RemoteDisconnected"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--workers", type=int, default=WORKERS)
    args = ap.parse_args()

    chans = json.load(open(ASSET, encoding="utf-8"))
    if args.limit:
        chans = chans[:args.limit]
    print("待测 %d 个频道（%d 并发，%ds 超时）…" % (
        len(chans), args.workers, TIMEOUT), flush=True)

    rows, done = [], 0
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(probe, c): c for c in chans}
        for f in as_completed(futs):
            c = futs[f]
            ok, kind, ms, err = f.result()
            rows.append({"id": c["id"], "name": c["name"],
                         "section": c["section"], "group": c.get("group", ""),
                         "url": c["url"], "declared": c.get("kind", ""),
                         "kind": kind, "ok": ok, "ms": ms, "err": err})
            done += 1
            if done % 200 == 0:
                alive = sum(1 for r in rows if r["ok"])
                print("  %d/%d  活 %d  %.0fs" % (
                    done, len(chans), alive, time.time() - t0), flush=True)

    # ── 二次重试：只重试瞬时失败 ──────────────────────────────
    # 部分 IPTV 源站对同 IP 高频请求返回瞬时限流（实测 101.35.240.114:88
    # 返回 HTTP 602）。48 并发打过去，这类台会被误判成永久失效。
    cand = [r for r in rows if not r["ok"] and r["err"] in TRANSIENT]
    if cand:
        print("\n二次重试 %d 个瞬时失败（%d 并发，最多 %d 次）…" % (
            len(cand), RETRY_WORKERS, RETRY_ATTEMPTS), flush=True)
        byid = {c["id"]: c for c in chans}

        def retry(r):
            for _ in range(RETRY_ATTEMPTS):
                time.sleep(0.6)
                ok, kind, ms, err = probe(byid[r["id"]])
                if ok:
                    r.update(ok=True, kind=kind, ms=ms, err="")
                    return True
            return False

        got = 0
        with ThreadPoolExecutor(max_workers=RETRY_WORKERS) as ex:
            for hit in ex.map(retry, cand):
                got += 1 if hit else 0
        print("  救回 %d 个" % got, flush=True)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(rows, open(OUT, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)

    # ── 汇总 ──────────────────────────────────────────────────
    alive = [r for r in rows if r["ok"]]
    print("\n=== 全量结果 %d 个，可播 %d（%.1f%%）===" % (
        len(rows), len(alive), len(alive) * 100.0 / max(len(rows), 1)))

    print("\n按栏目：")
    by = collections.defaultdict(list)
    for r in rows:
        by[r["section"]].append(r)
    for s in ["央卫视", "港澳台", "影视", "地方台", "一起看", "主播原创", "其他"]:
        rs = by.get(s) or []
        if not rs:
            continue
        ok = sum(1 for r in rs if r["ok"])
        print("  %-8s 总%-5d 可播%-5d %5.1f%%" % (
            s, len(rs), ok, ok * 100.0 / len(rs)))

    print("\n按流类型（实测，非声明）：")
    byk = collections.defaultdict(list)
    for r in alive:
        byk[r["kind"]].append(r)
    for k, v in sorted(byk.items(), key=lambda x: -len(x[1])):
        print("  %-6s %d" % (k, len(v)))

    print("\n失败原因：")
    for e, c in collections.Counter(
            r["err"] for r in rows if not r["ok"]).most_common():
        print("  %-22s %d" % (e, c))

    print("\n声明 vs 实测不一致（kind 变了）：")
    diff = [r for r in alive if r["declared"] and r["declared"] != r["kind"]]
    for r in diff[:10]:
        print("  %-16s 声明%-5s 实测%-5s" % (
            r["name"][:16], r["declared"], r["kind"]))
    if len(diff) > 10:
        print("  …共 %d 个" % len(diff))

    print("\n输出 %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())