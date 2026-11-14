#!/usr/bin/env python3
"""给直播资产聚合「同一频道的多条线路」，输出 lines 字段。

为什么不按 tvg-id 聚合（那是第一直觉，但是错的）
================================================
原始 m3u 里 tvg-id 的填充率只有 7.1%，而且语义并不统一：实测
`tvg-id="咪咕体育"` 下有 38 条，它们是咪咕 1/19/30/4K-1 等 **38 个不同
频道**，不是同一个台的 38 条线路。按 tvg-id 聚合会把 38 个频道并成 1 个。
所以 tvg-id 在这里是「分类 id」而非「频道 id」，不能当归一化键。

为什么按「栏目 + 规范化台名」聚合
================================
同一个台的多条线路在资产里的差异只有：
    · 域名不同（0472.org / 官方 CDN / 各种转发）
    · 名字后缀不同（CCTV1 / CCTV-1 / CCTV1综合 / 浙江卫视HD）
栏目（section）必须参与 key，否则「影视」里的《笑傲江湖》会和
「主播原创」里同名的轮播频道合并 —— 那是两个完全不同的东西。

为什么只对官方台聚合，不碰主播类
==============================
「主播原创」里 `YY用户` 有 69 条、「我是一颗小虎牙」有 18 条，那是
**69 个不同的主播**，不是 69 条线路。把它们聚成一个频道，用户点开
就会在 69 个陌生人之间乱跳 —— 这是比"不能自动切换"严重得多的事故。
所以主播类（主播原创 / 一起看）整类跳过，只保留单线路。

规范化规则刻意保守
==================
去掉的是「确定不代表频道身份」的东西：
    · 空白、全角/半角差异
    · HD / 高清 / 4K / 超清 / 蓝光 后缀
    · CCTV 的 1 / -1 / 综合 写法差异
不敢做的是「模糊匹配」：把《笑傲江湖》和《笑傲江湖HD》并成一个可以，
但把《笑傲江湖》和《新笑傲江湖》并成一个就是错的。宁可少并一组，
不能错并一组 —— 错并的后果是用户点 CCTV1 看到 CCTV2。

用法：
    python tools/merge_live_lines.py --dry-run
    python tools/merge_live_lines.py
"""
import argparse
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(os.path.dirname(HERE), "flutter_app")
ASSET = os.path.join(APP, "assets", "live_channels.json")
ROOT = os.path.dirname(os.path.dirname(HERE))
LOG = os.path.join(ROOT, "dist", "probe", "live_lines_merge.json")

# 只对这些栏目做多线路聚合。
# 主播原创 / 一起看 整类跳过：同名不等于同一路，见文件头说明。
OFFICIAL_SECTIONS = {"央卫视", "港澳台", "影视", "地方台", "其他"}

# 频道名里「确定不代表身份」的后缀，反复剥离直到稳定
_NOISE = [
    r"[（(]\s*(高清|超清|蓝光|4K|8K|HD|SD|标清)\s*[)）]",
    r"(高清|超清|蓝光|4K|8K|HD|SD|标清)$",
]
_NOISE_RE = [re.compile(p, re.I) for p in _NOISE]

# CCTV 系列统一：CCTV-1 / CCTV1综合 / CCTV 1 → cctv1
_CCTV_RE = re.compile(r"^cctv[-\s]*0*(\d+)\s*(综合|财经|综艺|中文国际|体育|电影|"
                      r"军事农业|军事|农业农村|电视剧|纪录|科教|戏曲|社会与法|"
                      r"新闻|少儿|音乐|奥林匹克|农业农村|4k|8k)?$", re.I)


def norm(name: str) -> str:
    """把频道名规范化成聚合键。返回空串表示「这个台不参与聚合」。"""
    s = name.strip()
    # 全角空格 → 半角，方便后续匹配
    s = s.replace("\u3000", " ").replace(" ", "")
    # 咪咕那种带圈数字的占位名（「咪咕直播 𝟛𝟜「移动」」）每条都不同，
    # 它们其实是不同频道，规范化后也不该相等 —— 直接原样返回
    if "「" in s or "」" in s:
        return s

    low = s.lower()
    # 反复剥后缀：'浙江卫视HD超清' → '浙江卫视'
    for _ in range(3):
        before = low
        for r in _NOISE_RE:
            low = r.sub("", low)
        if low == before:
            break
    low = low.strip()
    if not low:
        return s

    if low.startswith("cctv"):
        m = _CCTV_RE.match(low)
        if m:
            return "cctv%s" % int(m.group(1))
        # CCTV5+/CCTV5PLUS 这类没编号规律的，统一加号写法后原样用
        return re.sub(r"cctv[-\s]*(\d+)\s*\+", r"cctv\1plus", low)
    return low


def build(channels):
    """返回 (新频道列表, 合并统计)。"""
    # key = (section, 规范化台名) → 该组所有频道
    groups = collections.OrderedDict()
    for c in channels:
        section = c.get("section", "")
        if section not in OFFICIAL_SECTIONS:
            continue
        k = norm(c.get("name", "") or "")
        if not k:
            continue
        groups.setdefault((section, k), []).append(c)

    # 每个频道 → 所属的线路组（只保留 len>1 的组）
    multi = {k: v for k, v in groups.items() if len({x["url"] for x in v}) > 1}
    url2group = {}
    for k, items in multi.items():
        for x in items:
            url2group[x["url"]] = k

    out = []
    emitted_groups = set()
    for c in channels:
        k = url2group.get(c["url"])
        if k is None:
            # 单线路频道：lines 留空，播放器按单条处理
            out.append(c)
            continue
        if k in emitted_groups:
            # 这一组的卡片已经发过了，同组其余条目不再单独出现
            continue
        emitted_groups.add(k)
        items = multi[k]
        # 主条目取组内第一条（打包脚本已按 section/kind 排过序，
        # m3u8 优先，所以第一条通常是兼容性最好的那条）
        head = dict(items[0])
        # lines **必须排除主地址自己**：
        # 运行期的 allLines 会把 url 拼在最前面，若这里再放一份，
        # 播放器失败切换时会对同一个地址重试两遍，白等一轮超时。
        head["lines"] = [
            {"url": x["url"], "kind": x.get("kind", ""), "ua": x.get("ua", "")}
            for x in items
            if x["url"] != head["url"]
        ]
        # 名字取组内最短的那个：'CCTV1' 比 'CCTV-1综合高清' 更适合当卡片标题
        head["name"] = min((x.get("name", "") for x in items), key=len)
        out.append(head)

    return out, multi


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    channels = json.load(open(ASSET, encoding="utf-8"))
    print("原频道数 %d" % len(channels))

    out, multi = build(channels)
    print("聚合后 %d（减少 %d）" % (len(out), len(channels) - len(out)))
    print("多线路组 %d 个，涉及原条目 %d 条" % (
        len(multi), sum(len(v) for v in multi.values())))

    # 分组大小分布
    dist = collections.Counter(len({x["url"] for x in v}) for v in multi.values())
    print("\n每组线路数分布:")
    for n in sorted(dist):
        print("  %2d 条线路: %d 组" % (n, dist[n]))

    print("\n线路数最多的 10 组（人工确认不会把不同频道并到一起）:")
    for k, items in sorted(multi.items(),
                           key=lambda kv: -len({x["url"] for x in kv[1]}))[:10]:
        names = sorted({x.get("name", "") for x in items})
        print("  [%s] %s  → %d 条线路" % (k[0], k[1], len({x["url"] for x in items})))
        print("      原名: %s" % " | ".join(names[:4]))

    # 合并后各栏目
    print("\n聚合后栏目:")
    for s, n in collections.Counter(x.get("section", "") for x in out).most_common():
        print("  %5d  %s" % (n, s))

    # 安全校验：同一组里不允许出现「规范化后相同但原名差异很大」的情况
    warn = 0
    for k, items in multi.items():
        names = {x.get("name", "") for x in items}
        if len(names) > 6:
            print("\n  ⚠ 疑似误并 [%s] %s：%d 种不同名字" % (k[0], k[1], len(names)))
            warn += 1
    if warn == 0:
        print("\n安全校验: 没有发现需要人工怀疑的组")
    else:
        print("\n安全校验: %d 组需要人工看一眼（见上）" % warn)

    json.dump({"groups": {f"{k[0]}|{k[1]}": [x["url"] for x in v]
                          for k, v in multi.items()}},
              open(LOG, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    if args.dry_run:
        print("\n--dry-run，未写文件")
        return 0
    with open(ASSET, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print("\n写入 %s (%.0f KB)" % (ASSET, os.path.getsize(ASSET) / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())