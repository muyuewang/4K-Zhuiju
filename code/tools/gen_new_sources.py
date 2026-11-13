# -*- coding: utf-8 -*-
"""生成 site_sources.dart 的新源 Dart 代码。

输入：dist/probe/generated_sources.json（栏目定义，含实测数据量）
       dist/probe/maccms_speed.json（测速结果，决定顺序）
输出：dist/probe/new_sources.dart（可直接粘贴）
"""
import json
import os
import sys

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe")
COLS_JSON = os.path.join(OUT_DIR, "generated_sources.json")
SPEED_JSON = os.path.join(OUT_DIR, "maccms_speed.json")
OUT_DART = os.path.join(OUT_DIR, "new_sources.dart")

# 手工订正的速度中位数（首轮 5 次采样被单次抖动污染，已用 10 次复测纠正）
SPEED_FIX = {
    "樱花资源": 600,
    "闪电资源": 413,
    "猫眼资源": 264,
}

# 站名 → (dart 变量名, id, 展示名, 线路标识中文映射)
META = {
    "金鹰资源": ("kJinyingSource", "jinying", "金鹰资源", {"jinyingm3u8": "金鹰线路", "jinyingyun": "金鹰云"}),
    "电影天堂": ("kDyttSource", "dytt", "电影天堂", {"dyttm3u8": "天堂线路", "dytt": "天堂线路"}),
    "无尽资源": ("kWujinSource", "wujin", "无尽资源", {"wjm3u8": "无尽线路"}),
    "光速资源": ("kGuangsuSource", "guangsu", "光速资源", {"gsm3u8": "光速线路", "gsyun": "光速云"}),
    "豪华资源": ("kHaohuaSource", "haohua", "豪华资源", {"hhm3u8": "豪华线路", "hhyun": "豪华云"}),
    "非凡资源": ("kFeifanSource", "feifan", "非凡资源", {"ffm3u8": "非凡线路", "feifan": "非凡线路"}),
    "索尼资源": ("kSuoniSource", "suoni", "索尼资源", {"snm3u8": "索尼线路"}),
    "极速资源": ("kJszySource", "jszy", "极速资源", {"jsm3u8": "极速线路", "jsyun": "极速云"}),
    "猫眼资源": ("kMaoyanSource", "maoyan", "猫眼资源", {"mym3u8": "猫眼线路"}),
    "百度资源": ("kBaiduSource", "baidu", "百度资源", {"dbm3u8": "百度线路"}),
    "闪电资源": ("kShandianSource", "shandian", "闪电资源", {"sdm3u8": "闪电线路"}),
    "樱花资源": ("kYinghuaSource", "yinghua", "樱花资源", {"yhm3u8": "樱花线路"}),
}

# 每个源的栏目排序（默认按此顺序展示，'' 推荐位恒最前由代码加）
COL_ORDER = ["电影", "剧集", "综艺", "动漫", "短剧", "体育"]


def esc(s):
    return s.replace("\\", "\\\\").replace("'", "\\'")


def main():
    with open(COLS_JSON, encoding="utf-8") as f:
        cols_by_name = {r["name"]: r for r in json.load(f)}
    with open(SPEED_JSON, encoding="utf-8") as f:
        speeds = {r["name"]: r for r in json.load(f)}

    # 只保留有 META 的源（茅台等被跳过）
    items = []
    for name, meta in META.items():
        if name not in cols_by_name:
            print(f"WARN 缺栏目定义: {name}", file=sys.stderr)
            continue
        sp = speeds.get(name, {})
        ms = SPEED_FIX.get(name) or sp.get("home_ms") or 9999
        items.append((ms, name, meta, cols_by_name[name]))

    items.sort(key=lambda x: x[0])

    lines = []
    lines.append("// ============================================================")
    lines.append("// 以下 12 个源由 `code/tools/gen_sources_dart.py` 生成")
    lines.append("// 数据来自 2026-11-13 实测：栏目子分类 id 与数据量都是真测的，")
    lines.append("// 顺序按实测首页响应中位数排列（快的在前）。")
    lines.append("// 不要手改 id：父分类(1/2/3/4)在采集接口下恒为 0 条，")
    lines.append("// 栏目必须由带真实数据的子分类拼成。")
    lines.append("// ============================================================")
    lines.append("")

    for ms, name, meta, coldef in items:
        var, sid, disp, linemap = meta
        lines.append(f"/// {disp} —— 实测首页 {ms}ms")
        lines.append(f"final DataSource {var} = MacCmsApiSource(")
        lines.append(f"  const MacCmsApiConfig(")
        lines.append(f"    id: '{sid}',")
        lines.append(f"    displayName: '{esc(disp)}',")
        lines.append(f"    apiUrl: '{esc(coldef['api'])}',")
        # 栏目：推荐 + 各栏目
        cats = ["      SourceCategory('', '推荐'),"]
        total = 0
        for c in coldef["columns"]:
            if c["name"] not in COL_ORDER:
                continue
            cats.append(f"      SourceCategory('{c['t']}', '{c['name']}'),")
            total += c["total_sum"]
        desc = f"直连采集接口、无弹幕；片库 {total:,} 条、{len(cats)-1} 个栏目"
        lines.append(f"    description: '{esc(desc)}',")
        lines.append("    categories: [")
        lines.extend(cats)
        lines.append("    ],")
        lines.append("    lineNameCn: {")
        for k, v in linemap.items():
            lines.append(f"      '{k}': '{v}',")
        lines.append("    },")
        lines.append("  ),")
        lines.append(");")
        lines.append("")

    dart = "\n".join(lines)
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_DART, "w", encoding="utf-8") as f:
        f.write(dart)

    print(f"生成 {len(items)} 个源，顺序（快→慢）：")
    for ms, name, _, _ in items:
        print(f"  {ms:>5}ms  {name}")
    print(f"\n写入 {os.path.abspath(OUT_DART)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())