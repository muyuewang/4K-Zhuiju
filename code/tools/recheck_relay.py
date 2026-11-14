#!/usr/bin/env python3
"""复测剩下 5 个非 bilibili 的转发链接，判断是「源站临时抽风」还是「永久失效」。

背景
----
bilibili 那 14 个「确认死」，直接问 B 站官方接口后发现**房间全在**，
代理回 404 只是主播没开播。据此推断：live.ottiptv.cc 这个转发代理
自身的失败率不低，「代理连不上」不等于「频道没了」。

所以剩下 5 个 yy / douyu / huya 的转发链接不能凭日志两轮失败就删，
要分别做两件事：
  1) 隔开时间重试转发 URL 本身 —— 排除瞬时抖动；
  2) 问源平台自己的房间接口 —— 只要房间还在，就说明它还会开播，必须保留。

平台判据：
    huya   https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=<id>
           status=200 且有 data.liveStatus → 房间存在
    douyu  https://www.douyu.com/betard/<id>  （页面在=房间在）
    yy     无稳定公开房间接口 → 只做 URL 重试，重试全失败也保守保留
"""
import json
import os
import re
import ssl
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "dist", "probe", "relay_recheck.json")
SRC = os.path.join(ROOT, "dist", "probe", "bili_room_check.json")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

# 与 finalize 一致的日志解析（锚行尾 URL，避开列宽截断）
LINE_RE = re.compile(r"\[(\d+)/(\d+)\]\s*(救回|确认死)\s+(.*)$")
URL_RE = re.compile(r"(https?://\S+)\s*$")
LOGS = [os.path.join(ROOT, ".tmp", "prune_dry.log"),
        os.path.join(ROOT, ".tmp", "prune_final.log")]


def split_line(line):
    m = LINE_RE.search(line)
    if not m:
        return None
    rest = m.group(4).strip()
    u = URL_RE.search(rest)
    if not u:
        return None
    head = rest[:u.start()].split()
    return int(m.group(1)), (m.group(3) == "救回"), \
        (" ".join(head[:-1]) if len(head) > 1 else ""), u.group(1)


def two_rounds_dead():
    rounds = []
    for p in LOGS:
        d = {}
        if os.path.exists(p):
            for line in open(p, encoding="utf-8", errors="replace"):
                got = split_line(line.rstrip())
                if got:
                    d[got[0]] = got[1:]
        rounds.append(d)
    out = []
    for idx in sorted(set().union(*[set(r) for r in rounds])):
        v = [r[idx] for r in rounds if idx in r]
        if any(x[0] for x in v):
            continue
        out.append((idx, v[0][1], v[0][2]))
    return out


def fetch(url, timeout=12, referer=None):
    h = {"User-Agent": UA}
    if referer:
        h["Referer"] = referer
    req = urllib.request.Request(url, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return r.status, r.read(400)
    except urllib.error.HTTPError as e:
        return e.code, b""
    except Exception as e:
        return type(e).__name__, b""


def platform_alive(url):
    """问源平台房间还在不在。返回 (结论, 说明)。"""
    m = re.search(r"/huya/(\d+)", url)
    if m:
        api = ("https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=%s"
               % m.group(1))
        st, body = fetch(api)
        if st == 200:
            try:
                d = json.loads(body.decode("utf-8", "replace"))
                live = (d.get("data") or {}).get("liveStatus")
                if live is not None:
                    return "房间在", "huya liveStatus=%s" % live
            except Exception:
                pass
        return "未知", "huya api %s" % st
    m = re.search(r"/douyu/(\d+)", url)
    if m:
        st, _ = fetch("https://www.douyu.com/betard/%s" % m.group(1))
        return ("房间在" if st == 200 else "未知"), "douyu page %s" % st
    return "未知", "yy 无公开房间接口"


def main():
    dead = [x for x in two_rounds_dead()
            if "/bilibili/" not in x[2]]
    print("非 bilibili 的两轮死链: %d 个\n" % len(dead))

    rows = []
    for idx, name, url in dead:
        plat, note = platform_alive(url)
        tries = []
        for i in range(3):
            st, head = fetch(url, referer="https://live.ottiptv.cc/")
            tries.append(st)
            if isinstance(st, int) and st == 200 and head:
                break
            time.sleep(1.5)
        ok = any(isinstance(s, int) and s == 200 for s in tries)
        # 只要平台说房间还在，就保留：直播是状态，会回来的
        keep = ok or plat == "房间在"
        rows.append({"idx": idx, "name": name, "url": url,
                     "relay": [str(t) for t in tries],
                     "relay_ok": ok, "platform": plat,
                     "note": note, "keep": keep})
        print("  [%d] %-12s relay=%-18s 平台=%-6s %s" % (
            idx, name[:12], ",".join(str(t) for t in tries),
            plat, "→ 保留" if keep else "→ 可删"))

    keep_n = sum(1 for r in rows if r["keep"])
    print("\n=== 结论 ===")
    print("  保留 %d / 可删 %d" % (keep_n, len(rows) - keep_n))
    json.dump(rows, open(OUT, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("明细 %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())