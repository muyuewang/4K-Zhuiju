#!/usr/bin/env python3
"""按两轮复测 + 两层核实的结果裁剪 live_channels.json（不重新联网）。

为什么不重跑 prune_live.py
-------------------------
prune_live.py 的确认阶段是**串行 + 退避**（27 个 × 3 次 × 12s 超时），
最坏要十几分钟，实测触发了 550s 超时被 kill，文件没写成。
但决策信息其实已经拿到了：dry-run 和正式跑各产出一份完整日志，
里面逐条记着「救回 / 确认死」。直接读日志比再等一轮联网更准也更快。

裁剪口径：**三层过滤，越往下越保守**
------------------------------------
第一层 协议不支持（RTMP/RTSP）→ 删。
    不是探测失败，是播放器不支持（Android 端 ExoPlayer 不认 rtmp），
    打包时也没验证过，属于占位数据。

第二层 两轮日志里「都判死」→ 候选死链。
    直播流本来就抖（27 个串行打过去，源站自己都会限流）。
    任一轮救回就说明只是抖动，保留。

第三层 候选死链必须再过一遍「源站核实」，见 bili_room_check.json
    和 relay_recheck.json —— 这一步是本脚本最重要的部分：
      · bilibili 的 404 是**状态**不是**死亡**。主播没开播时转发代理回 404，
        但房间还在，主播一开播同一个 URL 立刻能播。资产是静态快照、
        URL 在运行期才解析，保留它 = 将来能看；删掉 = 永久失去。
      · 转发代理 live.ottiptv.cc 自身失败率不低（实测 4/5 复测就活了），
        所以「代理连不上」不能直接当死链。
    核实话术：只要源平台房间还在，或转发 URL 复测有一次 200，就保留。

一句话：删掉能播的频道是功能缺失，留下一个死链只是点开黑屏，
两害相权，宁可留着。

用法：
    python tools/finalize_live.py            # 写文件
    python tools/finalize_live.py --dry-run
"""
import argparse
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(os.path.dirname(HERE), "flutter_app")
ASSET = os.path.join(APP, "assets", "live_channels.json")
FULL = os.path.join(ROOT, "dist", "probe", "live_full.json")
LOGS = [os.path.join(ROOT, ".tmp", "prune_dry.log"),
        os.path.join(ROOT, ".tmp", "prune_final.log")]
# 第三层核实结果（由 check_bili_rooms.py / recheck_relay.py 产出）
BILI_CHK = os.path.join(ROOT, "dist", "probe", "bili_room_check.json")
RELAY_CHK = os.path.join(ROOT, "dist", "probe", "relay_recheck.json")

DROP_SCHEMES = ("rtmp://", "rtsp://")

# [3/27] 救回 别和陌生人说话 FLV https://...
# 注意：日志列宽会截断长频道名，截断后名字与错误类型之间只剩 1 个空格，
# 用 \s{2,} 分列会漏行（实测 27 行只匹配到 24 行）。故改为锚行尾 URL 反向解析。
LINE_RE = re.compile(r"\[(\d+)/(\d+)\]\s*(救回|确认死)\s+(.*)$")
URL_RE = re.compile(r"(https?://\S+)\s*$")


def split_line(line):
    """-> (序号, 是否救回, url)；解析不了返回 None。"""
    m = LINE_RE.search(line)
    if not m:
        return None
    u = URL_RE.search(m.group(4).strip())
    if not u:
        return None
    return int(m.group(1)), (m.group(3) == "救回"), u.group(1)


def parse_log(path):
    """返回 {序号: (是否救回, url)}。序号对应 suspect 列表下标 +1。"""
    out = {}
    if not os.path.exists(path):
        print("  跳过（不存在）: %s" % path)
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        got = split_line(line.rstrip())
        if got:
            out[got[0]] = got[1:]
    print("  %s → %d 条决策" % (os.path.basename(path), len(out)))
    return out


def load_verified_keep():
    """从两层核实结果里取出「必须保留」的频道 URL 集合。"""
    keep = set()
    if os.path.exists(BILI_CHK):
        d = json.load(open(BILI_CHK, encoding="utf-8"))
        for x in d.get("exists_keep", []) + d.get("unknown_keep", []):
            keep.add(x["info"]["url"])
        print("  bilibili 核实: 房间仍在 %d 个 → 保留" % len(
            d.get("exists_keep", [])))
    else:
        print("  缺少 %s，bilibili 频道全部按保守策略保留"
              % os.path.basename(BILI_CHK))
    if os.path.exists(RELAY_CHK):
        d = json.load(open(RELAY_CHK, encoding="utf-8"))
        n = 0
        for x in d:
            if x.get("keep"):
                keep.add(x["url"])
                n += 1
        print("  转发链复测: 仍可访问 %d 个 → 保留" % n)
    else:
        print("  缺少 %s，非 bilibili 死链全部按保守策略保留"
              % os.path.basename(RELAY_CHK))
    return keep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    chans = json.load(open(ASSET, encoding="utf-8"))
    full = json.load(open(FULL, encoding="utf-8"))
    # dict 保序，与 live_full.json 文件顺序一致 —— 两个日志里的
    # 序号就是 suspect 列表下标，靠这个对齐，不依赖被截断的频道名
    failed = [r for r in full if not r["ok"]]
    suspect = [r for r in failed
               if not r["url"].lower().startswith(DROP_SCHEMES)]
    scheme_drop = [r for r in failed
                   if r["url"].lower().startswith(DROP_SCHEMES)]

    print("全量探测: 失败 %d = 协议不支持 %d + 疑似死链 %d" % (
        len(failed), len(scheme_drop), len(suspect)))

    print("\n读取复测日志:")
    rounds = [parse_log(p) for p in LOGS]

    # 逐条对齐：任何一轮救回 → 保留；所有轮次都判死 → 进第三层核实
    dead_idx, rescued_idx, unknown_idx = [], [], []
    for i, r in enumerate(suspect):
        idx = i + 1
        verdicts = [rd[idx][0] for rd in rounds if idx in rd]
        if not verdicts:
            unknown_idx.append(idx)
        elif any(verdicts):
            rescued_idx.append(idx)
        else:
            dead_idx.append(idx)

    print("\n第二轮判定:")
    print("  复测救回（保留）     %d" % len(rescued_idx))
    print("  两轮都判死（待核实） %d" % len(dead_idx))
    print("  未复测到（保守保留） %d" % len(unknown_idx))

    print("\n第三层 源站核实:")
    verified_keep = load_verified_keep()

    final_drop, saved_by_verify = [], []
    for i in dead_idx:
        r = suspect[i - 1]
        if r["url"] in verified_keep:
            saved_by_verify.append(i)
        else:
            final_drop.append(i)
    print("  核实后确认删除 %d，因源站仍在而保留 %d" % (
        len(final_drop), len(saved_by_verify)))

    drop_ids = {r["id"] for r in scheme_drop}
    drop_ids |= {suspect[i - 1]["id"] for i in final_drop}
    keep = [c for c in chans if c["id"] not in drop_ids]

    print("\n=== 结果 ===")
    print("  原 %d → 保留 %d（删 %d）" % (
        len(chans), len(keep), len(chans) - len(keep)))
    print("    协议不支持 RTMP  %d" % len(scheme_drop))
    print("    确认永久失效     %d" % len(final_drop))
    print("    核实后救回       %d" % len(saved_by_verify))

    if args.dry_run:
        print("\n--dry-run，未写文件")
        return 0

    with open(ASSET, "w", encoding="utf-8") as f:
        json.dump(keep, f, ensure_ascii=False, separators=(",", ":"))
    print("\n写入 %s (%.0f KB)" % (
        ASSET, os.path.getsize(ASSET) / 1024))

    print("\n裁剪后各栏目:")
    c = collections.Counter(x["section"] for x in keep)
    for s in ["央卫视", "港澳台", "影视", "地方台", "一起看", "主播原创", "其他"]:
        if c[s]:
            print("  %5d  %s" % (c[s], s))

    print("\n裁剪后流类型:")
    for k, v in collections.Counter(
            x.get("kind", "") for x in keep).most_common():
        print("  %-6s %d" % (k, v))

    log = os.path.join(ROOT, "dist", "probe", "live_pruned.json")
    json.dump({
        "dropped_scheme": scheme_drop,
        "dropped_dead": [suspect[i - 1] for i in final_drop],
        "rescued_by_retest": [suspect[i - 1] for i in rescued_idx],
        "rescued_by_verify": [suspect[i - 1] for i in saved_by_verify],
        "unverified_kept": [suspect[i - 1] for i in unknown_idx],
    }, open(log, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("\n明细 %s" % log)
    return 0


if __name__ == "__main__":
    sys.exit(main())