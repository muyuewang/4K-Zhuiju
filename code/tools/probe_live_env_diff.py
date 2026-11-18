"""对照测量：桌面环境 vs 模拟器环境 的直播可用率差异。

## 为什么要做对照

用户报「电脑上能播，雷电模拟器不能播」。两台设备看的是同一份
`assets/live_channels.json`，差异只可能出在**网络环境**上。本脚本把
两个真实差异各自量化：

  1. **IPv6**：雷电模拟器走 VirtualBox NAT，默认只有 IPv4。
     `curl -4` 精确模拟这一侧，`curl` 默认（有 IPv6）模拟桌面侧。
  2. **系统代理**：Windows 上 Dart 的 HttpOverrides 与 libmpv 都接了
     Clash；Android 上 `net_proxy.dart` 直接 `_setOff()`，
     ExoPlayer 也不读系统代理。所以模拟器永远是「裸直连」。

## 必须带 UA

频道自带 `ua` 字段，实测 `101.35.240.114:88/live.php?id=CCTV1`
不带指定 UA 直接 404、带了才 200。探测不带 UA 会把一批好台误判成死台。
"""

import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from urllib.parse import urlparse

ASSET = "code/flutter_app/assets/live_channels.json"


def _clean_env():
    env = dict(os.environ)
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
              "http_proxy", "https_proxy", "all_proxy"):
        env.pop(k, None)
    env["NO_PROXY"] = "*"
    env["no_proxy"] = "*"
    return env


def probe(url, ua, ipv4_only, timeout=9):
    """返回 (状态码, 是否拿到流量)。"""
    cmd = ["curl", "-s", "-m", str(timeout), "-o", os.devnull,
           "-L", "--max-redirs", "6",
           "-w", "%{http_code}|%{size_download}"]
    if ipv4_only:
        cmd.append("-4")
    if ua:
        cmd += ["-A", ua]
    cmd.append(url)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout + 6, env=_clean_env())
        out = (p.stdout or "").strip()
        code, size = (out.split("|") + ["", ""])[:2]
        return code or "000", int(size or 0)
    except Exception:
        return "ERR", 0


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

    print(f"{'源域名':<28}{'频道':>5} | {'桌面(含IPv6)':<14}{'模拟器(仅IPv4)':<16}{'UA'}")
    print("-" * 96)

    desk_ok = simu_ok = 0
    desk_tally, simu_tally = Counter(), Counter()

    for host, items in major:
        c0 = items[0]
        url, ua = c0["url"], c0.get("ua", "")

        dc, ds = probe(url, ua, ipv4_only=False)
        sc, ss = probe(url, ua, ipv4_only=True)

        d_ok = dc == "200" and ds > 0
        s_ok = sc == "200" and ss > 0

        if d_ok:
            desk_ok += len(items)
            desk_tally[host] = len(items)
        if s_ok:
            simu_ok += len(items)
            simu_tally[host] = len(items)

        dmark = "✓" if d_ok else "✗"
        smark = "✓" if s_ok else "✗"
        uan = "有" if ua else "-"
        print(f"{host:<28}{len(items):>5} | {dmark} {dc:<11}{smark} {sc:<13}{uan}")

    total = len(chans)
    print("-" * 96)
    print(f"总频道 {total}")
    print(f"  桌面侧（有 IPv6、有代理）可用：{desk_ok} ({desk_ok*100//total}%)")
    print(f"  模拟器侧（仅 IPv4、无代理）可用：{simu_ok} ({simu_ok*100//total}%)")
    print()
    print("桌面可用域名：", dict(desk_tally))
    print("模拟器可用域名：", dict(simu_tally))

    gap = desk_ok - simu_ok
    if gap > 0:
        print(f"\n差距 {gap} 个频道：桌面能播而模拟器播不了的量。")


if __name__ == "__main__":
    sys.exit(main())