#!/usr/bin/env python3
"""从 site_sources.dart 提取 MacCMS 采集站配置，生成 index.json 的插件条目。

为什么不手抄：12 个源、每个 5~9 组分类、每组 3~9 个 id，手抄必错。
而错一个 id 的表现是「点进去一片空白」，靠人眼看不出来。

用法：
    python gen_plugin_index.py            # 打印生成的 JSON 片段
    python gen_plugin_index.py --write    # 直接写回 index.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "code" / "flutter_app" / "lib" / "core" / "source" / "site_sources.dart"
INDEX = ROOT / "config" / "plugins" / "index.json"


def parse_blocks(src: str) -> list[dict]:
    """把每个 `MacCmsApiConfig(...)` 拆成字段字典。"""
    # 每个源以 `final DataSource kXxxSource = MacCmsApiSource(` 开头
    chunks = re.split(r"\nfinal DataSource k", src)
    out: list[dict] = []

    for chunk in chunks[1:]:
        if "MacCmsApiConfig(" not in chunk:
            continue

        def grab(field: str) -> str:
            m = re.search(rf"{field}:\s*'([^']*)'", chunk)
            return m.group(1) if m else ""

        pid = grab("id")
        if not pid:
            continue

        # 分类：SourceCategory('id', '名字')
        cats = []
        cat_block = re.search(
            r"categories:\s*\[(.*?)\n\s*\],", chunk, re.S)
        if cat_block:
            for cid, cname in re.findall(
                    r"SourceCategory\('([^']*)',\s*'([^']*)'\)", cat_block.group(1)):
                cats.append({"id": cid, "name": cname})

        # 线路中文名映射
        lines: dict[str, str] = {}
        line_block = re.search(r"lineNameCn:\s*\{(.*?)\n\s*\},", chunk, re.S)
        if line_block:
            for k, v in re.findall(
                    r"'([^']+)':\s*'([^']+)'", line_block.group(1)):
                lines[k] = v

        out.append({
            "id": pid,
            "name": grab("displayName"),
            "apiUrl": grab("apiUrl"),
            "description": grab("description"),
            "categories": cats,
            "lineNameCn": lines,
            "listNeedsDetail": "listNeedsDetail: true" in chunk,
            "listNeedsBatchDetail": "listNeedsBatchDetail: true" in chunk,
            "derivePlayIndex": "derivePlayIndex: true" in chunk,
            "format": "xml" if "MacCmsFormat.xml" in chunk else "json",
        })
    return out


def to_plugin(s: dict) -> dict:
    """转成 index.json 的插件条目。"""
    api = s["apiUrl"]
    # baseUrl 取协议+主机，path 取剩余部分。这样站点换域名只改 baseUrl。
    m = re.match(r"(https?://[^/]+)(/.*)?$", api)
    if not m:
        raise SystemExit(f"接口地址不合法：{api}")
    base, path = m.group(1), (m.group(2) or "/")

    xml = s["format"] == "xml"
    script = ("config/plugins/maccms-xml.js" if xml
              else "config/plugins/maccms-json.js")

    # XML 站不能走 detail：优子资源的 `ac=detail&ids=21` 实测返回随机
    # 20 条最新（把 ids 完全忽略），详情页会打开成一部不相干的片子。
    # 所以 xml 一律锁死 ac=list。
    list_ac = "list" if (xml or not s["listNeedsDetail"]) else "detail"

    p: dict = {
        "id": s["id"],
        "name": s["name"],
        "baseUrl": base,
        "script": script,
        "version": 1,
        "enabled": True,
    }
    if s["description"]:
        p["description"] = s["description"]
    # 12 个采集站都是国内直连，统一归到「采集站（直连）」。
    # 写出来而不是留空，是为了让「这个源该在哪个组」成为一个
    # 配置里能查到的显式事实，而不是靠宿主猜。
    p["group"] = "采集站（直连）"
    if s["lineNameCn"]:
        p["lineNameCn"] = s["lineNameCn"]
    if s["derivePlayIndex"]:
        p["derivePlayIndex"] = True
    # 两阶段回查：先 ac=list 拿最新 id，再 ac=videolist&ids= 批量补封面。
    # 只有优子这类「list 无封面、videolist 按 id 升序」的站需要。
    if s["listNeedsBatchDetail"]:
        p["batchDetail"] = True
    if not s["categories"]:
        raise SystemExit(f"{s['id']} 没有解析到分类，正则可能失效了")
    p["categories"] = s["categories"]

    if xml:
        # 优子资源需要两段式：先 ac=list 拿最新 id、再批量回查详情。
        # 这里只声明基础请求，两段式由脚本内部的 listNeedsBatchDetail
        # 语义处理（见 maccms-xml.js）。
        p["list"] = {"path": path,
                     "query": {"ac": "list", "t": "{category}", "pg": "{page}"}}
        p["search"] = {"path": path,
                       "query": {"ac": "list", "wd": "{keyword}", "pg": "{page}"}}
        p["detail"] = {"path": path,
                       "query": {"ac": "videolist", "ids": "{id}"}}
    else:
        p["list"] = {"path": path,
                     "query": {"ac": list_ac, "t": "{category}", "pg": "{page}"}}
        p["search"] = {"path": path,
                       "query": {"ac": list_ac, "wd": "{keyword}", "pg": "{page}"}}
        p["detail"] = {"path": path,
                       "query": {"ac": "detail", "ids": "{id}"}}
    return p


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    src = SRC.read_text(encoding="utf-8")
    sites = parse_blocks(src)
    if not sites:
        raise SystemExit("没解析到任何源，正则失效了")

    plugins = [to_plugin(s) for s in sites]
    print(f"解析到 {len(plugins)} 个采集站：", file=sys.stderr)
    for s, p in zip(sites, plugins):
        print(f"  {p['id']:<10} {len(p['categories'])} 类 "
              f"{len(p.get('lineNameCn', {}))} 线 "
              f"{'XML' if s['format'] == 'xml' else 'JSON'}", file=sys.stderr)

    if not args.write:
        json.dump(plugins, sys.stdout, ensure_ascii=False, indent=2)
        return

    data = json.loads(INDEX.read_text(encoding="utf-8"))
    # 保留手工维护的条目（非本次生成的 id），让脚本可反复运行而不丢东西。
    # 用 id 集合判断而不是匹配脚本名：脚本名会变（不同站用不同脚本），
    # id 才是稳定标识。
    generated = {p["id"] for p in plugins}
    keep = [e for e in data.get("plugins", [])
            if e.get("id") not in generated
            # 演示条目（白杜）是早期验证插件机制用的，已被真实站点取代
            and not str(e.get("id", "")).startswith(("js_bdzy",))]
    data["plugins"] = plugins + keep
    INDEX.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n",
                     encoding="utf-8")
    print(f"已写入 {INDEX}（{len(data['plugins'])} 条，"
          f"保留手工条目 {len(keep)} 条）", file=sys.stderr)


if __name__ == "__main__":
    main()