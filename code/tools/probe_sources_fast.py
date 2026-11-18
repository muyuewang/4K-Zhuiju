#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""快速探活：并发打每个插件的 list 接口，判断源是否还活着。

比 probe_all_sources.py 快得多（那个串行跑 4 类接口 + 25s 超时），
只测一件事：list 接口能不能返回真实数据。用于排查「某些源超时」。
用法：
    python probe_sources_fast.py            # 全量
    python probe_sources_fast.py feifan suoni
环境：本机有代理变量时会干扰直连，脚本内部强制绕过代理（trust_env=False）。
"""
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = os.path.join(HERE, "..", "..", "config", "plugins", "index.json")
TIMEOUT = 8
UA = "okhttp/3.12.0"


def build_url(plugin):
    """把 list 模板拼成真实 URL；{category} 取第一个非空分类。"""
    base = plugin.get("baseUrl", "").rstrip("/")
    spec = plugin.get("list") or {}
    path = spec.get("path", "/")
    cat = ""
    for c in plugin.get("categories", []):
        if c.get("id"):
            cat = c["id"]
            break
    q = {}
    for k, v in (spec.get("query") or {}).items():
        v = str(v)
        v = v.replace("{category}", cat).replace("{page}", "1")
        q[k] = v
    qs = urllib.parse.urlencode(q)
    return base + path + ("?" + qs if qs else "")


def probe(plugin):
    """按插件脚本类型判定，别拿 JSON 标准去量 XML 站和网页源。"""
    url = build_url(plugin)
    script = (plugin.get("script") or "").rsplit("/", 1)[-1]
    is_json = script == "maccms-json.js"
    is_xml = script == "maccms-xml.js"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    t0 = time.time()
    try:
        with opener.open(req, timeout=TIMEOUT) as r:
            body = r.read()
        dt = time.time() - t0
        text = body.decode("utf-8", "replace")
        if is_json:
            try:
                j = json.loads(text)
            except Exception:
                return plugin, "BAD", dt, "非 JSON (%d 字节)" % len(body)
            n = len(j.get("list") or [])
            total = j.get("total")
            if n == 0 and not total:
                return plugin, "EMPTY", dt, "200 但列表为空"
            return plugin, "OK", dt, "total=%s n=%d" % (total, n)
        if is_xml:
            n = text.count("<video>")
            if n == 0:
                return plugin, "EMPTY", dt, "XML 但无 <video>"
            return plugin, "OK", dt, "XML %d 条" % n
        # 自定义脚本（网页模板源）：只看有没有拿到页面，解析正确性归插件自己管
        if len(body) < 200:
            return plugin, "EMPTY", dt, "仅 %d 字节" % len(body)
        return plugin, "OK", dt, "HTML %d 字节" % len(body)
    except urllib.error.HTTPError as e:
        return plugin, "HTTP%d" % e.code, time.time() - t0, str(e.reason)[:40]
    except Exception as e:
        dt = time.time() - t0
        name = type(e).__name__
        if "timed out" in str(e).lower() or "timeout" in str(e).lower():
            return plugin, "TIMEOUT", dt, "%ds 无响应" % TIMEOUT
        return plugin, "FAIL", dt, "%s %s" % (name, str(e)[:40])


def main():
    want = set(sys.argv[1:])
    data = json.load(open(CFG, encoding="utf-8"))
    plugins = [p for p in data["plugins"] if p.get("enabled", True)]
    if want:
        plugins = [p for p in plugins if p["id"] in want]
    print("探测 %d 个源（超时 %ds）\n" % (len(plugins), TIMEOUT))
    rows = []
    with ThreadPoolExecutor(max_workers=19) as ex:
        futs = [ex.submit(probe, p) for p in plugins]
        for f in as_completed(futs):
            rows.append(f.result())
    order = {p["id"]: i for i, p in enumerate(plugins)}
    rows.sort(key=lambda r: (order.get(r[0]["id"], 99)))
    ok = 0
    for p, st, dt, note in rows:
        if st == "OK":
            ok += 1
        flag = "✅" if st == "OK" else "❌"
        print("%s %-8s %-9s %5.2fs  %-24s %s"
              % (flag, p["id"], st, dt, p.get("name", ""), note))
        print("      %s" % build_url(p))
    print("\n可达 %d/%d" % (ok, len(rows)))


if __name__ == "__main__":
    main()
