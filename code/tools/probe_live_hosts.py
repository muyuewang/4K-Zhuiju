"""按域名抽样探活直播频道，用于定位「电脑能播、模拟器不能播」的差异。

核心问题：Windows 端 Dart 的 HttpOverrides 会读系统代理（Clash），
Android 端 net_proxy.dart 直接 _setOff() 走直连，且 ExoPlayer 的
DefaultHttpDataSource 也不读系统代理。所以两端看到的 DNS 结果不同。

本脚本做两件事：
  1. 统计每个域名的 DNS 解析结果 —— 判断是否被污染（落到 Facebook/其他
     明显不相关的 IP 段）。
  2. 每个域名抽 1 条地址直连探一次 —— 判断「不走代理时到底能不能播」。

用法：
    python code/tools/probe_live_hosts.py
"""

import json
import os
import socket
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse

ASSET = "code/flutter_app/assets/live_channels.json"

# 明显不是直播源的 IP 段 —— 命中即判定 DNS 被污染
SUSPECT_NETS = (
    "69.171.",      # Facebook
    "31.13.",       # Facebook
    "108.160.",     # Dropbox
    "2a03:2880",    # Facebook IPv6
    "2001::",       # Teredo 假前缀
    "0.0.0.0",
    "127.0.0.1",
)


def dns_lookup(host):
    """拿到该域名的全部 A/AAAA。失败返回空。"""
    try:
        infos = socket.getaddrinfo(host, None)
        return sorted({i[4][0] for i in infos})
    except Exception:
        return []


def _clean_env():
    """继承父进程环境，只剔掉代理变量。

    绝对不能自己拼一个 `{"NO_PROXY": "*", "PATH": ...}` 的最小环境：
    Windows 上 curl 依赖 SystemRoot 才能找到系统 DLL 与 DNS 解析器，
    剥掉之后每次调用都直接失败、返回空 —— 表现为「所有源都 000 不可达」，
    这个假数据比不测更危险，会把人引向完全错误的方向。
    """
    env = dict(os.environ)
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
              "http_proxy", "https_proxy", "all_proxy"):
        env.pop(k, None)
    env["NO_PROXY"] = "*"
    env["no_proxy"] = "*"
    return env


def probe(url, timeout=8):
    """直连拉一小段，返回 (状态码, 字节数, content-type)。"""
    try:
        p = subprocess.run(
            ["curl", "-s", "-m", str(timeout), "-o", os.devnull,
             "-w", "%{http_code}|%{size_download}|%{content_type}",
             "--max-redirs", "6", "-L", url],
            capture_output=True, text=True, timeout=timeout + 6,
            env=_clean_env(),
        )
        out = (p.stdout or "").strip()
        parts = (out.split("|") + ["", "", ""])[:3]
        code, size, ct = parts
        return code or "000", int(size or 0), ct
    except Exception as e:
        return "ERR", 0, str(e)[:40]


def main():
    with open(ASSET, encoding="utf-8") as f:
        chans = json.load(f)

    by_host = defaultdict(list)
    for c in chans:
        h = urlparse(c["url"]).hostname
        if h:
            by_host[h].append(c)

    print(f"频道总数 {len(chans)}，独立域名 {len(by_host)}\n")

    # 只对覆盖 >= 3 个频道的域名做，长尾域名合并成一条「其他」
    major = [(h, v) for h, v in by_host.items() if len(v) >= 3]
    major.sort(key=lambda kv: -len(kv[1]))

    print(f"{'域名':<32}{'频道':>6}  {'DNS 解析':<38}{'结果':<8}{'备注'}")
    print("-" * 108)

    polluted = 0
    dead = 0
    alive = 0

    for host, items in major:
        ips = dns_lookup(host)
        dns_s = ",".join(ips)[:36] if ips else "(解析失败)"
        is_polluted = any(any(ip.startswith(n) for n in SUSPECT_NETS) for ip in ips)

        sample = items[0]["url"]
        code, size, ct = probe(sample)

        if is_polluted:
            note = "DNS 污染"
            polluted += len(items)
        elif code == "200" and size > 0:
            note = "可用"
            alive += len(items)
        else:
            note = "不可达"
            dead += len(items)

        flag = "✗" if note != "可用" else "✓"
        print(f"{host:<32}{len(items):>6}  {dns_s:<38}{flag} {code:<6}{note}")

    covered = sum(len(v) for _, v in major)
    print("-" * 108)
    print(f"覆盖频道 {covered}/{len(chans)}")
    print(f"  DNS 污染：{polluted} 个频道")
    print(f"  不可达：  {dead} 个频道")
    print(f"  可用：    {alive} 个频道")

    # 长尾
    tail = [(h, len(v)) for h, v in by_host.items() if len(v) < 3]
    if tail:
        print(f"\n另有 {len(tail)} 个长尾域名，共 {sum(n for _, n in tail)} 个频道（未逐个探测）")


if __name__ == "__main__":
    sys.exit(main())