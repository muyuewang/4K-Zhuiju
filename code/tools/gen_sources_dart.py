# -*- coding: utf-8 -*-
"""从实测数据生成 Dart 配置代码（site_sources.dart 的新增片段）。

为什么要自动生成而不是手抄：
    12 个源 × 6 个栏目 × 平均 8 个子分类 id，手抄必错，且错了的现象是
    「点某栏目空白」——很难在代码里看出来。这里按真实 total 排序、
    自动过滤成人向分类，产出可直接粘贴的 Dart 片段。

输出：
    dist/probe/generated_sources.dart   可直接粘贴的 Dart
    dist/probe/generated_sources.json   结构化中间态（供核对）
"""
import json
import os
import sys

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe")
IN_JSON = os.path.join(OUT_DIR, "maccms_totals.json")
OUT_DART = os.path.join(OUT_DIR, "generated_sources.dart")
OUT_JSON = os.path.join(OUT_DIR, "generated_sources.json")

# 不适配本 App（全年龄向追剧）的分类关键词，直接剔除
ADULT = ["伦理", "三级", "写真", "两性", "里番", "擦边", "写真热舞"]

# 栏目定义：栏目名 → (匹配关键词列表, 最多少个子分类)
COLUMNS = [
    ("电影", [
        "动作片", "喜剧片", "爱情片", "科幻片", "恐怖片", "剧情片", "战争片",
        "犯罪片", "悬疑片", "惊悚片", "灾难片", "奇幻片", "历史片", "家庭篇",
        "古装片", "西部片", "纪录片", "记录片", "4K电影", "邵氏电影",
        "Netflix电影", "动画电影", "短片",
    ]),
    ("剧集", [
        "国产剧", "大陆剧", "欧美剧", "香港剧", "港剧", "韩国剧", "韩剧",
        "台湾剧", "台剧", "日本剧", "日剧", "海外剧", "泰国剧", "泰剧",
        "马泰剧", "其他剧", "Netflix自制剧", "连续剧", "美国剧",
    ]),
    ("综艺", ["综艺"]),
    ("动漫", [
        "国产动漫", "日本动漫", "日韩动漫", "欧美动漫", "港台动漫",
        "海外动漫", "动画片", "动画电影", "漫剧", "有声动漫", "AI漫剧",
    ]),
    ("短剧", [
        "短剧", "爽文短剧", "擦边短剧", "AI短剧", "ai短剧", "反转爽剧",
        "古装仙侠", "现代都市", "年代穿越", "穿越年代", "脑洞悬疑",
        "女频恋爱", "重生民国", "言情总裁", "悬疑烧脑", "穿越现代", "成长逆袭",
    ]),
    ("体育", ["篮球", "足球", "NBA", "斯诺克", "台球", "网球", "其他赛事", "体育赛事"]),
]

# 每个栏目最多取几个子分类（太多会让单页请求数暴涨：6 栏目 × 8 = 48 并发）
MAX_PER_COLUMN = 8
# 单个子分类至少多少条才值得纳入（太小的会让交错后某栏目大半是它）
MIN_TOTAL = 20


def is_adult(name):
    return any(a in name for a in ADULT)


def build(rec):
    alive = [c for c in rec["classes"] if c["total"] >= MIN_TOTAL]
    alive = [c for c in alive if not is_adult(c["name"])]

    cols = []
    used = set()
    for col_name, kws in COLUMNS:
        hit = []
        for c in alive:
            if c["id"] in used:
                continue
            if any(kw in c["name"] for kw in kws):
                hit.append(c)
        # 按数据量降序，取前 N 个
        hit.sort(key=lambda x: -x["total"])
        hit = hit[:MAX_PER_COLUMN]
        if not hit:
            continue
        for c in hit:
            used.add(c["id"])
        cols.append(
            {
                "name": col_name,
                "t": ",".join(c["id"] for c in hit),
                "detail": [f"{c['id']}:{c['name']}={c['total']}" for c in hit],
                "total_sum": sum(c["total"] for c in hit),
            }
        )
    return cols


def dart_escape(s):
    return s.replace("\\", "\\\\").replace("'", "\\'")


def main():
    with open(IN_JSON, encoding="utf-8") as f:
        recs = json.load(f)

    # 排除：已在用（暴风/量子）、m3u8 播不了的（茅台）
    skip_api = ["bfzyapi", "lziapi", "maotaizy"]
    recs = [r for r in recs if not any(s in r["api"] for s in skip_api)]

    out = []
    for rec in recs:
        cols = build(rec)
        out.append({"name": rec["name"], "api": rec["api"], "site": rec["site"], "columns": cols})

    # ---- 打印核对表 ----
    for o in out:
        print(f"=== {o['name']}")
        for c in o["columns"]:
            print(f"  {c['name']:<4} sum={c['total_sum']:>6}  {c['t']}")
            print(f"        {', '.join(c['detail'])}")
        print()

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"结构化写入 {os.path.abspath(OUT_JSON)}")
    print("\n" + "=" * 70)
    print("Dart 片段已写入", os.path.abspath(OUT_DART))
    return 0


if __name__ == "__main__":
    sys.exit(main())