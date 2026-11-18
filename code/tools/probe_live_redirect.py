"""抽样探测「可用频道」的取流终点是 IPv4 还是 IPv6。

## 为什么这件事决定「电脑能播、模拟器不能播」

实测 `live.metshop.top` 的取流是一次 302，Location 指向虎牙 CDN，
而且**跳转终点直接写成 IPv6 字面量**：

    http://[2409:8c20:8ab1:6:603::8]/al.flv.huya.com/src/xxx.flv?...

- Windows 主机有全局 IPv6 → libmpv/FFmpeg 正常拉流
- 雷电模拟器默认 VirtualBox NAT 只有 IPv4，**没有 IPv6** → 地址解析不了

本脚本量化这个比例：逐域名抽样，记录最终 URL 的 host 形态。
"""

import json
import os
import re
import socket
import subprocess
import sys
from collections import Counter, defaultdict
from urllib.parse import urlparse

ASSET = "code/flutter_app/assets/live_channels.json"

IPV6_LITERAL = re.compile(r"^\[[0-9a-fA-F:]+\]$")


def _clean_env():
    env = dict(os.environ)
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
              "http_proxy", "https_proxy", "all_proxy"):
        env.pop(k, None)
    env["NO_PROXY"] = "*"
    env["no_proxy"] = "*"
    return env


def final_url(url, timeout=10):
    """跟随重定向，只要最终 URL，不下载正文。"""
    try:
        p = subprocess.run(
            ["curl", "-s", "-m", str(timeout), "-o", os.devnull,
             "-L", "--max-redirs", "6",
             "-w", "%{url_effective}\\n%{http_code}",
             url],
            capture_output=True, text=True, timeout=timeout + 6,
            env=_clean_env(),
        )
        lines = (p.stdout or "").strip().split("\n")
        if len(lines) >= 2:
            return lines[0], lines[1]
        return url, "000"
    except Exception:
        return url, "ERR"


def classify(href):
    """把 host 归类成 IPv6 字面量 / IPv4 字面量 / 域名。"""
    try:
        h = urlparse(href).hostname or ""
    except Exception:
        return "解析失败"
    if IPV6_LITERAL.match(h) or (":" in h):
        return "IPv6 字面量"
    if re.match(r"^\d+\.\d+\.\d+\.\d+$", h):
        return "IPv4 字面量"
    if h:
        return "域名"
    return "空"


def main():
    with open(ASSET, encoding="utf-8") as f:
        chans = json.load(f)

    by_host = defaultdict(list)
    for c in chans:
        h = urlparse(c["url"]).hostname
        if h:
            by_host[h].append(c)

    major = sorted(
        ((h, v) for h, v in by_host.items() if len(v) >= 3),
        key=lambda kv: -len(kv[1]),
    )

    print(f"{'源域名':<30}{'频道':>6}  {'终点类型':<14}{'最终 host':<34}{'码'}")
    print("-" * 92)

    tally = Counter()
    weights = Counter()

    for host, items in major:
        url = items[0]["url"]
        fin, code = final_url(url)
        kind = classify(fin)
        try:
            fh = urlparse(fin).hostname or ""
        except Exception:
            fh = ""

        tally[kind] += 1
        if code == "200":
            weights[kind] += len(items)

        print(f"{host:<30}{len(items):>6}  {kind:<14}{fh[:32]:<34}{code}")

    print("-" * 92)
    print("按域名计数：", dict(tally))
    print("可播(200)域名所覆盖的频道数：", dict(weights))
    print()

    if weights.get("IPv6 字面量", 0):
        n = weights["IPv6 字面量"]
        print(f"⚠ {n} 个频道最终落到 IPv6 字面量地址上。")
        print("  有 IPv6 的设备（Windows 主机常见）可播；")
        print("  仅有 IPv4 的设备（雷电模拟器默认 NAT）必然播不了。")


if __name__ == "__main__":
    sys.exit(main())