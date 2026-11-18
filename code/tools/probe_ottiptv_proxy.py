"""量化 live.ottiptv.cc 在「经代理」与「直连」两种网络下的可播率。

## 背景

该域名覆盖 2402/2676 = 90% 的频道。实测：
  - 本地 DNS 把它解析到 Facebook 的 IP 段（69.171.x / 2a03:2880::）
  - DoH 查到的真实地址是 128.242.240.253，直连同样不通
  - 经 Clash(7897) 能拿到 200 + 正常 FLV 流量

也就是说：**这批频道能不能播，完全取决于客户端有没有代理。**

Windows 端有（net_proxy.dart 读注册表 + MpvProxyEnv 写进程环境变量），
Android 端没有（net_proxy.dart 直接 _setOff()，ExoPlayer 也不读系统代理）。

本脚本抽样 N 个频道，分别在「直连」与「经代理」下探一遍，把差异量化出来。
"""

import json
import os
import random
import subprocess
import sys

ASSET = "code/flutter_app/assets/live_channels.json"
PROXY = "http://127.0.0.1:7897"
SAMPLE = 24


def _clean_env():
    env = dict(os.environ)
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
              "http_proxy", "https_proxy", "all_proxy"):
        env.pop(k, None)
    env["NO_PROXY"] = "*"
    env["no_proxy"] = "*"
    return env


def probe(url, proxy=None, timeout=12):
    cmd = ["curl", "-s", "-m", str(timeout), "-o", os.devnull,
           "-L", "--max-redirs", "5",
           "-w", "%{http_code}|%{size_download}"]
    if proxy:
        cmd += ["--proxy", proxy]
    cmd.append(url)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout + 8, env=_clean_env())
        out = (p.stdout or "").strip()
        code, size = (out.split("|") + ["", ""])[:2]
        return code or "000", int(size or 0)
    except Exception:
        return "ERR", 0


def main():
    with open(ASSET, encoding="utf-8") as f:
        chans = json.load(f)

    pool = [c for c in chans if "ottiptv" in c["url"]]
    print(f"live.ottiptv.cc 频道总数：{len(pool)}")

    random.seed(20261118)
    sample = random.sample(pool, min(SAMPLE, len(pool)))

    print(f"抽样 {len(sample)} 个，分别测「直连」与「经代理 {PROXY}」\n")
    print(f"{'频道':<24}{'类型':<8}{'直连':<16}{'经代理':<16}")
    print("-" * 68)

    direct_ok = proxy_ok = 0
    for c in sample:
        name = (c["name"] or "?")[:20]
        kind = c.get("kind", "")
        dc, ds = probe(c["url"])
        pc, ps = probe(c["url"], PROXY)

        dok = dc == "200" and ds > 0
        pok = pc == "200" and ps > 0
        direct_ok += 1 if dok else 0
        proxy_ok += 1 if pok else 0

        print(f"{name:<24}{kind:<8}"
              f"{('✓' if dok else '✗') + ' ' + dc + '/' + str(ds):<16}"
              f"{('✓' if pok else '✗') + ' ' + pc + '/' + str(ps):<16}")

    n = len(sample)
    print("-" * 68)
    print(f"直连可用：  {direct_ok}/{n}")
    print(f"经代理可用：{proxy_ok}/{n}")
    if proxy_ok > direct_ok:
        rate = proxy_ok / n
        est = int(len(pool) * rate)
        print(f"\n如按同样比例推算，全部 {len(pool)} 个频道经代理约有 {est} 个可播。")


if __name__ == "__main__":
    sys.exit(main())