#!/usr/bin/env python3
"""对被判「失败」的频道做最后一轮串行复测，然后按结果裁剪资产。

为什么要单独一轮
----------------
全量探测是 48 并发打过去的，URLError / TimeoutError 这类失败**天然可疑**：
可能是源站临时抖动、也可能是本机网络瞬断，而不是频道真的死了。
`live.ottiptv.cc` 这类单点聚合服务尤其明显，同一时刻打 48 个请求过去
它自己就扛不住。

删掉一个能播的频道，比留下一个死链糟糕得多 —— 前者是功能缺失，
后者只是点进去黑屏。所以裁剪前必须用**串行 + 退避**再确认一遍，
只把「连续 N 次都失败」的才认定为死。

RTMP 是另一回事：不是探测失败，是播放器不支持（见 kDropKinds），
不需要复测，直接判死。

用法：
    python tools/prune_live.py            # 复测 + 裁剪
    python tools/prune_live.py --dry-run  # 只看会删什么，不写文件
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import ssl

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(os.path.dirname(HERE), "flutter_app")
ASSET = os.path.join(APP, "assets", "live_channels.json")
FULL = os.path.join(ROOT, "dist", "probe", "live_full.json")

_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE

UA_DEFAULT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
              "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36")

# 播放器不支持的协议。RTMP 在移动端基本不能播（libmpv 虽支持，
# 但 ExoPlayer 不支持，Android 上必然黑屏），打包时也没验证过 ——
# 留着只会制造「点开就黑屏」的差评。
DROP_SCHEMES = ("rtmp://", "rtsp://")

CONFIRM_ATTEMPTS = 3
CONFIRM_GAP = 1.2


def fix_url(u):
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


def probe_once(ch, timeout=12):
    h = {"User-Agent": ch.get("ua") or UA_DEFAULT, "Accept": "*/*"}
    try:
        req = urllib.request.Request(fix_url(ch["url"]), headers=h)
        op = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=_SSL))
        with op.open(req, timeout=timeout) as r:
            head = r.read(4096)
        if head[:3] == b"FLV":
            return True, "FLV"
        if "#EXTM3U" in head.decode("utf-8", "replace"):
            return True, "M3U8"
        if b"ftyp" in head[:64]:
            return True, "MP4"
        return False, "BAD_BODY"
    except urllib.error.HTTPError as e:
        return False, "HTTP%d" % e.code
    except Exception as e:
        return False, type(e).__name__


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    chans = json.load(open(ASSET, encoding="utf-8"))
    full = {r["id"]: r for r in json.load(open(FULL, encoding="utf-8"))}
    byid = {c["id"]: c for c in chans}

    failed = [r for r in full.values() if not r["ok"]]
    print("全量探测判定失败 %d 个" % len(failed))

    # ① RTMP/RTSP：协议不支持，不复测，直接删
    scheme_drop = [r for r in failed
                   if r["url"].lower().startswith(DROP_SCHEMES)]
    print("  ├ 协议不支持（RTMP/RTSP）: %d  ← 直接删，不复测" % len(scheme_drop))

    # ② 其余：串行复测确认
    suspect = [r for r in failed
               if not r["url"].lower().startswith(DROP_SCHEMES)]
    print("  └ 疑似死链: %d  ← 串行复测 %d 次确认" % (
        len(suspect), CONFIRM_ATTEMPTS))

    confirmed_dead, rescued = [], []
    for i, r in enumerate(suspect, 1):
        ch = byid.get(r["id"])
        if not ch:
            continue
        ok_final, kind_final = False, ""
        for attempt in range(CONFIRM_ATTEMPTS):
            if attempt:
                time.sleep(CONFIRM_GAP * attempt)
            ok, kind = probe_once(ch)
            if ok:
                ok_final, kind_final = True, kind
                break
        if ok_final:
            rescued.append(r)
            print("  [%d/%d] 救回 %-16s %-6s %s" % (
                i, len(suspect), r["name"][:16], kind_final,
                r["url"][:46]), flush=True)
        else:
            confirmed_dead.append(r)
            print("  [%d/%d] 确认死 %-16s %-10s %s" % (
                i, len(suspect), r["name"][:16], r["err"],
                r["url"][:46]), flush=True)

    drop_ids = {r["id"] for r in scheme_drop} | {r["id"] for r in confirmed_dead}
    keep = [c for c in chans if c["id"] not in drop_ids]

    print("\n=== 裁剪结果 ===")
    print("  原 %d → 保留 %d（删 %d）" % (len(chans), len(keep), len(chans) - len(keep)))
    print("    协议不支持 %d" % len(scheme_drop))
    print("    确认死链   %d" % len(confirmed_dead))
    print("    复测救回   %d（保留）" % len(rescued))

    if args.dry_run:
        print("\n--dry-run，未写文件")
        return 0

    with open(ASSET, "w", encoding="utf-8") as f:
        json.dump(keep, f, ensure_ascii=False, separators=(",", ":"))
    size = os.path.getsize(ASSET) / 1024
    print("\n写入 %s  (%.0f KB)" % (ASSET, size))

    # 裁剪后各栏目
    import collections
    c = collections.Counter(x["section"] for x in keep)
    for s in ["央卫视", "港澳台", "影视", "地方台", "一起看", "主播原创", "其他"]:
        if c[s]:
            print("  %5d  %s" % (c[s], s))

    # 留一份裁剪明细，出问题好回溯
    log = os.path.join(ROOT, "dist", "probe", "live_pruned.json")
    json.dump({"drop": [r for r in failed if r["id"] in drop_ids],
               "rescued": rescued},
              open(log, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("\n明细 %s" % log)
    return 0


if __name__ == "__main__":
    sys.exit(main())