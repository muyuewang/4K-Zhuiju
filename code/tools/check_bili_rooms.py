#!/usr/bin/env python3
"""核实「确认死」的 bilibili 房间号到底是房间没了，还是主播当前没开播。

为什么必须单独查这一层
--------------------
live.ottiptv.cc/bilibili/<room_id> 是转发代理。主播未开播时它回 HTTP 404，
但这个 404 是**状态**不是**死亡**：主播一开播，同一个 URL 立刻能播。
直播资产是打包时的快照，如果把「此刻没开播」当成死链删掉，
删掉的是将来能看的频道 —— 正是之前抽样误判的同类错误。

判据（直接问 B 站官方接口，不走代理）：
    api.live.bilibili.com/room/v1/Room/get_info?room_id=<id>
    code=0 且 room_id 回显一致 → 房间存在
        live_status=1 → 正在直播（那 404 只是代理抽风，必须保留）
        live_status=0 → 未开播（保留，开播即可看）
        live_status=2 → 轮播（保留）
    code!=0 / room_id 不一致 → 房间真的没了，可删
"""
import json
import os
import re
import ssl
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LOGS = [os.path.join(ROOT, ".tmp", "prune_dry.log"),
        os.path.join(ROOT, ".tmp", "prune_final.log")]
OUT = os.path.join(ROOT, "dist", "probe", "bili_room_check.json")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

# 日志的列宽是格式化输出的：名字超过 25 字会被截断，
# 截断后名字和错误类型之间只剩 1 个空格，靠 \s{2,} 分列会漏掉这些行
# （实测 27 行只匹配到 24 行）。所以改成锚定行尾的 URL 反向解析。
LINE_RE = re.compile(r"\[(\d+)/(\d+)\]\s*(救回|确认死)\s+(.*)$")
URL_RE = re.compile(r"(https?://\S+)\s*$")
BILI_RE = re.compile(r"/bilibili/(\d+)")


def split_line(line):
    """-> (序号, 是否救回, 频道名, url)；解析不了返回 None。"""
    m = LINE_RE.search(line)
    if not m:
        return None
    rest = m.group(4).strip()
    u = URL_RE.search(rest)
    if not u:
        return None
    head = rest[:u.start()].split()      # 名字 + 错误类型
    name = " ".join(head[:-1]) if len(head) > 1 else ""
    return int(m.group(1)), (m.group(3) == "救回"), name, u.group(1)


def collect_dead_rooms():
    """从两轮日志里取「两轮都判死」的 bilibili 房间号（与 finalize 口径一致）。"""
    rounds = []
    for p in LOGS:
        d = {}
        if os.path.exists(p):
            for line in open(p, encoding="utf-8", errors="replace"):
                got = split_line(line.rstrip())
                if got:
                    idx, rescued, name, url = got
                    d[idx] = (rescued, name, url)
        rounds.append(d)
    rooms = {}
    for idx in sorted(set().union(*[set(r) for r in rounds])):
        verdicts = [r[idx] for r in rounds if idx in r]
        if any(v[0] for v in verdicts):
            continue                      # 任一轮救回 → 保留，不查
        url = verdicts[0][2]
        m = BILI_RE.search(url)
        if m:
            rooms[m.group(1)] = {"idx": idx, "name": verdicts[0][1], "url": url}
    return rooms


def query(room_id):
    url = ("https://api.live.bilibili.com/room/v1/Room/get_info?room_id=%s"
           % room_id)
    req = urllib.request.Request(url, headers={
        "User-Agent": UA, "Referer": "https://live.bilibili.com/",
        "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=12, context=CTX) as r:
            d = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:
        return {"err": type(e).__name__, "msg": str(e)[:120]}
    return {
        "code": d.get("code"),
        "msg": d.get("message") or d.get("msg"),
        "room_id": (d.get("data") or {}).get("room_id"),
        "live_status": (d.get("data") or {}).get("live_status"),
        "title": (d.get("data") or {}).get("title"),
    }


def main():
    rooms = collect_dead_rooms()
    print("待核实的 bilibili 房间: %d 个\n" % len(rooms))

    exists, gone, unknown = [], [], []
    for rid in sorted(rooms, key=lambda k: rooms[k]["idx"]):
        info = rooms[rid]
        r = query(rid)
        if "err" in r:
            verdict = "查询失败"
            unknown.append((rid, info, r))
        elif r["code"] == 0 and str(r["room_id"]) == str(rid):
            live = r["live_status"]
            verdict = {0: "房间在·未开播", 1: "房间在·直播中",
                       2: "房间在·轮播"}.get(live, "房间在·状态%s" % live)
            exists.append((rid, info, r))
        else:
            verdict = "房间不存在"
            gone.append((rid, info, r))
        print("  [%d] %-9s %-14s %s" % (
            info["idx"], rid, verdict, r.get("title") or r.get("msg") or ""))

    print("\n=== 结论 ===")
    print("  房间仍在（保留）  %d" % len(exists))
    print("  房间已不存在（删）%d" % len(gone))
    print("  查询失败（保留）  %d" % len(unknown))

    json.dump({
        "exists_keep": [{"id": k, "info": v, "api": r} for k, v, r in exists],
        "gone_drop": [{"id": k, "info": v, "api": r} for k, v, r in gone],
        "unknown_keep": [{"id": k, "info": v, "api": r} for k, v, r in unknown],
    }, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("\n明细 %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())