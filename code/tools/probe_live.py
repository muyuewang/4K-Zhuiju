#!/usr/bin/env python3
"""直播频道全量探活 → 生成 flutter_app/assets/live_channels.json

为什么需要这个脚本
------------------
App 里没有「直播接口」可打。包内给的是 7 个 .m3u 文件、4180 个去重频道，
其中能连上的只有一半左右，且分布极不均匀（yylunbo 97%、Gather 27%、
ipv4 20%）。如果运行时才逐个探测，用户点开「直播」要等十几秒。

所以策略是「构建期探活、运行期零网络」：这个脚本把 4180 个全探一遍，
只把**当前可播**的连同名称/分组/台标/流类型打包进 JSON，App 启动时
读本地资源，打开直播页没有任何网络等待。

代价是频道会比源站旧 —— 这是刻意接受的取舍。想刷新时重跑本脚本即可：

    python tools/probe_live.py

判活标准（这里踩过坑，别改回去）
--------------------------------
不能只看 HTTP 200。这些 CDN 对失效地址会返回 200 + 一个 HTML 错误页，
只看状态码会把一堆死链当成活的。必须看**响应体前 4 KB**：

    FLV    以 b'FLV' 开头           （嗷呜系 2260 个频道全是这种）
    M3U8   含 '#EXTM3U'
    MP4    前 64 字节含 b'ftyp'
    RTMP   协议本身不做 HTTP 探测，直接视为可用

**FLV 这一条是必须的**：第一版探针只认 #EXTM3U，把 2260 个 FLV 直播流
全判成「HTML 失效」，导致嗷呜那三套源的可播率显示为 0%。
实际上 `live.ottiptv.cc/{douyu,huya,yy}/<房间号>` 返回的就是裸 FLV 流
（含 onMetaData / Lavf / CloudStream 元信息），完全能播。

id 必须确定性
-------------
用 zlib.crc32(url) 而不是 Python 内置 hash()：内置 hash 对字符串加了
每进程随机种子，重跑一次 id 全变，用户收藏会全部指向错误的台。
Dart 侧 live_tv_source.dart 的 stableIdOf() 手写了同一套 CRC32，
test/live_tv_parse_test.dart 里有交叉断言。改算法要两边一起改。
"""

import collections
import json
import os
import random
import re
import socket
import ssl
import sys
import time
import urllib.parse
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(os.path.dirname(HERE), "flutter_app")
OUT = os.path.join(APP, "assets", "live_channels.json")

# 源 .m3u 的位置（相对于包内解压目录）。换包时改这里。
SRC_DIR = os.environ.get("LIVE_SRC_DIR", "C:/tmp/baofenxi")
M3U_FILES = [
    ("东篱/live/Gather.m3u", "东篱"),
    ("东篱/live/ipv4.m3u", "东篱"),
    ("肥猫/live/iptv.m3u", "肥猫"),
    ("嗷呜/live/bililive.m3u", "嗷呜"),
    ("嗷呜/live/douyuyqk.m3u", "嗷呜"),
    ("嗷呜/live/huyayqk.m3u", "嗷呜"),
    ("嗷呜/live/yylunbo.m3u", "嗷呜"),
]

TIMEOUT = 7
WORKERS = 64
# 重试阶段用低并发，理由见主流程里的说明
RETRY_WORKERS = 4
RETRY_ATTEMPTS = 3
UA = {"User-Agent": "AptvPlayer/1.4.1", "Accept": "*/*"}

# 44 个原始 group-title 归并成 7 个栏目。
# 源里的分组名有 'zonghe' / '原创IP' 这种，直接给用户看等于没分类。
SECTION_OF = {
    "央视频道": "央卫视", "央视IPV4": "央卫视", "卫视频道": "央卫视",
    "卫视IPV4": "央卫视", "•咪咕「移动」": "央卫视", "数字频道": "央卫视",
    "4K频道": "央卫视", "APTV专享": "央卫视", "国际频道": "央卫视",
    "港澳台频道": "港澳台", "港澳代理": "港澳台", "埋堆堆频道": "港澳台",
    "电视剧频道": "影视", "点播电影": "影视", "虎牙影视": "影视",
    "春晚频道": "影视", "历年春晚": "影视", "动画频道": "影视",
    "一起看": "一起看",
    "原创IP": "主播原创", "原创": "主播原创", "zonghe": "主播原创",
}
SECTION_ORDER = ["央卫视", "港澳台", "影视", "地方台", "一起看", "主播原创", "其他"]
KIND_ORDER = {"M3U8": 0, "MP4": 1, "FLV": 2, "RTMP": 3}


def section_of(group: str) -> str:
    if group in SECTION_OF:
        return SECTION_OF[group]
    if group.startswith("☘️"):          # ☘️辽宁频道 / ☘️河北频道 …
        return "地方台"
    return "其他"


def stable_id(url: str) -> str:
    """与 Dart 侧 stableIdOf() 完全一致。"""
    return "live_%08x" % (zlib.crc32(url.encode("utf-8")) & 0xFFFFFFFF)


def parse_m3u(path: str):
    out, cur = [], None
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#EXTINF"):
                g = re.search(r'group-title="([^"]*)"', line)
                l = re.search(r'tvg-logo="([^"]*)"', line)
                i = re.search(r'tvg-id="([^"]*)"', line)
                ua = re.search(r'http-user-agent="([^"]*)"', line)
                # 频道名 = 第一个不在引号内的逗号之后（与 Dart 的 _titleOf 一致）
                in_q, name = False, ""
                for k, ch in enumerate(line):
                    if ch == '"':
                        in_q = not in_q
                    elif ch == "," and not in_q:
                        name = line[k + 1:].strip()
                        break
                cur = {
                    "name": name,
                    "group": g.group(1) if g else "",
                    "logo": l.group(1) if l else "",
                    "tvgid": i.group(1) if i else "",
                    "ua": ua.group(1) if ua else "",
                    "file": path,
                }
            elif line.startswith("#"):
                continue
            elif line.lower().startswith(("http://", "https://", "rtmp://", "rtsp://")):
                if cur is not None:
                    cur["url"] = line
                    out.append(cur)
                    cur = None
    return out


def fix_url(u: str) -> str:
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


def probe(item):
    url = item["url"]
    if url.lower().startswith("rtmp"):
        return item, "RTMP"
    try:
        # 必须用条目自带的 http-user-agent
        ua = item.get("ua") or UA["User-Agent"]
        headers = {"User-Agent": ua, "Accept": "*/*"}
        req = urllib.request.Request(fix_url(url), headers=headers)
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=_SSL) as r:
            head = r.read(4096)
        if head[:3] == b"FLV":
            return item, "FLV"
        if "#EXTM3U" in head.decode("utf-8", "replace"):
            return item, "M3U8"
        if b"ftyp" in head[:64]:
            return item, "MP4"
        return item, "OTHER"
    except Exception as e:
        return item, type(e).__name__


_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE


def main():
    allc, seen = [], set()
    for rel, _tag in M3U_FILES:
        p = os.path.join(SRC_DIR, rel)
        if not os.path.exists(p):
            print(f"  跳过（不存在）: {p}")
            continue
        for it in parse_m3u(p):
            u = it["url"].strip()
            if not u or u in seen:
                continue
            seen.add(u)
            it["url"] = u
            allc.append(it)

    print(f"去重后 {len(allc)} 个频道，开始探活（{WORKERS} 并发，{TIMEOUT}s 超时）…")
    t0, res, alive, done = time.time(), collections.Counter(), [], 0
    failed = []
    res_kind = {}
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for it, kind in ex.map(probe, allc):
            res[kind] += 1
            done += 1
            if kind in KIND_ORDER:
                it["kind"] = kind
                alive.append(it)
            else:
                failed.append(it)
                res_kind[id(it)] = kind
            if done % 500 == 0:
                print(f"  {done}/{len(allc)}  存活 {len(alive)}  {time.time()-t0:.0f}s")

    print(f"首轮耗时 {time.time()-t0:.0f}s，结果: {dict(res.most_common())}")

    # ── 二次重试 ────────────────────────────────────────────────
    # 为什么必须有这一轮：部分 IPTV 源站会对**同一 IP 的高频请求**返回
    # 瞬时限流码（实测 101.35.240.114:88 返回 HTTP 602），
    # 单条重复 6 次里就有 2 次被拒。首轮 64 并发打过去，这类频道会被
    # 整批误判成「永久失效」—— 表现是央视 CCTV1/3/4/5/6/8 这些主力频道
    # 全部消失、只剩 CCTV2/7/9 这些「当时运气好」的。
    #
    # 重试改成**串行 + 退避**（并发降到 1，间隔逐渐拉长），
    # 让源站看到的是一个正常客户端，而不是 64 个同时扑上来的请求。
    if failed:
        # 只重试「有可能是瞬时失败」的那些。`OTHER` 是「连上了但内容不对」
        # （HTML 错误页等），重试没有意义，纯粹浪费时间。
        transient = {"HTTPError", "TimeoutError", "URLError",
                     "RemoteDisconnected", "ConnectionResetError"}
        cand = [it for it in failed if res_kind.get(id(it), "OTHER") in transient]
        print(f"\n二次重试 {len(cand)}/{len(failed)} 个首轮失败频道"
              f"（{RETRY_WORKERS} 并发，最多 {RETRY_ATTEMPTS} 次）…")
        t1 = time.time()
        recovered = 0
        done2 = 0

        def retry_one(it):
            for attempt in range(RETRY_ATTEMPTS):
                if attempt:
                    time.sleep(0.8 * attempt + random.random() * 0.4)
                _item, kind = probe(it)
                if kind in KIND_ORDER:
                    it["kind"] = kind
                    return it
            return None

        # 为什么是低并发而不是串行：
        #   串行最稳（源站看到的就是正常客户端），但 1500 个频道 × 数次重试
        #   最坏要跑十几小时，工具就没法用了。
        #   4 并发是实测出来的平衡点 —— 对该限流 host 做过 1/4/16/64 四档
        #   对照，1 和 4 的命中率完全一致（37~39/68），16 和 64 开始掉。
        with ThreadPoolExecutor(max_workers=RETRY_WORKERS) as ex:
            for got in ex.map(retry_one, cand):
                done2 += 1
                if got is not None:
                    alive.append(got)
                    recovered += 1
                if done2 % 200 == 0:
                    print(f"  {done2}/{len(cand)}  救回 {recovered}  {time.time()-t1:.0f}s")
        print(f"重试耗时 {time.time()-t1:.0f}s，救回 {recovered} 个")
        print(f"重试后存活 {len(alive)} / {len(allc)}")
    pct = len(alive) * 100 // max(len(allc), 1)
    print(f"存活 {len(alive)} / {len(allc)} = {pct}%")

    out, seen2 = [], set()
    for it in alive:
        u = it["url"]
        if u in seen2:
            continue
        seen2.add(u)
        g = it.get("group", "")
        out.append({
            "id": stable_id(u),
            "name": it["name"].strip(),
            "url": u,
            "group": g,
            "section": section_of(g),
            "logo": it.get("logo", "") or "",
            "kind": it.get("kind", ""),
            # 必须一起打包：不带这个 UA，播放时同样 404
            "ua": it.get("ua", "") or "",
        })
    out.sort(key=lambda x: (
        SECTION_ORDER.index(x["section"]) if x["section"] in SECTION_ORDER else 99,
        KIND_ORDER.get(x["kind"], 9),
        x["name"],
    ))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    size = os.path.getsize(OUT) / 1024
    print(f"\n写入 {OUT}")
    print(f"{len(out)} 个频道，{size:.0f} KB")

    c = collections.Counter(x["section"] for x in out)
    for s in SECTION_ORDER:
        if c[s]:
            print(f"  {c[s]:5d}  {s}")
    return 0


if __name__ == "__main__":
    sys.exit(main())