# -*- coding: utf-8 -*-
"""为新源生成「聚合栏目」分类串，并逐条实测有数据。

背景（这是本次接入最关键的一条）：
    几乎所有采集站的父分类（type_id=1 电影 / 2 电视剧 / 3 综艺 / 4 动漫）
    在 ac=list 下都返回 0 条 —— 数据全挂在子分类上。
    直接填父分类 → 用户点「电影」看到空白 → 以为源坏了。
    （暴风源 bfzyapi 早就踩过这个坑：父分类实测只有 14 / 7 条。）

解法：
    MacCMS 的 t 参数支持逗号拼接多个 type_id，`t=6,7,8,9,10,11,12`
    会聚合这些子分类，翻页也正常（实测 p1/p2 无重复 id）。
    所以每个栏目都用一串子分类 id 来表示。

输出：
    dist/probe/maccms_columns.json  每个源的聚合栏目 + 实测条数
"""
import json
import os
import sys

import requests
import urllib3

urllib3.disable_warnings()

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "dist", "probe")
IN_JSON = os.path.join(OUT_DIR, "maccms_classes.json")
OUT_JSON = os.path.join(OUT_DIR, "maccms_columns.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

# 分类名 → 栏目归属。按「名字里含关键词」匹配，顺序有意义（先具体后宽泛）。
RULES = [
    ("体育", ["篮球", "足球", "NBA", "斯诺克", "台球", "其他赛事"]),
    ("短剧", [
        "短剧", "爽文短剧", "擦边短剧", "AI短剧", "ai短剧", "反转爽剧",
        "古装仙侠", "现代都市", "年代穿越", "脑洞悬疑", "女频恋爱",
        "重生民国", "言情总裁", "穿越年代", "悬疑烧脑",
    ]),
    ("动漫", [
        "国产动漫", "日韩动漫", "日本动漫", "欧美动漫", "港台动漫",
        "海外动漫", "动画片", "动画电影", "漫剧", "有声动漫", "里番动漫",
    ]),
    ("综艺", ["综艺"]),
    ("电影", [
        "动作片", "爱情片", "喜剧片", "科幻片", "恐怖片", "剧情片",
        "战争片", "纪录片", "记录片", "犯罪片", "悬疑片", "惊悚片",
        "灾难片", "奇幻片", "历史片", "家庭篇", "古装片", "西部片",
        "4K电影", "邵氏电影", "Netflix电影", "伦理片", "港台三级",
    ]),
    ("剧集", [
        "国产剧", "大陆剧", "欧美剧", "香港剧", "港剧", "韩国剧", "韩剧",
        "台湾剧", "台剧", "日本剧", "日剧", "海外剧", "泰国剧", "泰剧",
        "马泰剧", "其他剧", "Netflix自制剧", "连续剧",
    ]),
]

# 候选项里若出现「资讯/公告/头条」这类非影视栏目，直接丢弃
DROP = ["资讯", "公告", "头条", "新闻", "预告", "预告片", "解说", "预告解说", "未分类"]


def sess():
    s = requests.Session()
    s.proxies = {}
    s.trust_env = False
    return s


def classify(name):
    for col, kws in RULES:
        for kw in kws:
            if kw in name:
                return col
    return None


def verify(api, tids, s):
    """返回 (首页条数, total)"""
    if not tids:
        return 0, 0
    try:
        r = s.get(
            api + "?ac=list&t=" + ",".join(tids) + "&pg=1",
            headers={"User-Agent": UA},
            timeout=20,
            verify=False,
        )
        d = r.json()
        return len(d.get("list") or []), d.get("total") or 0
    except Exception:  # noqa: BLE001
        return -1, 0


def main():
    with open(IN_JSON, encoding="utf-8") as f:
        recs = json.load(f)

    out = []
    for rec in recs:
        # 只用「实测有数据」的分类，空分类会稀释聚合结果
        alive = [c for c in rec["classes"] if c["items"] and c["items"] > 0]
        buckets = {}
        used = set()
        for c in alive:
            col = classify(c["name"])
            if col is None:
                continue
            buckets.setdefault(col, []).append(c["id"])
            used.add(c["id"])
        # 有数据但没归类的分类，单独列出供人工判断
        orphans = [c for c in alive if c["id"] not in used
                   and not any(d in c["name"] for d in DROP)]

        api = rec["api"].rstrip("/") + "/"
        s = sess()
        cols = []
        for name in ("电影", "剧集", "综艺", "动漫", "短剧", "体育"):
            tids = buckets.get(name, [])
            if not tids:
                continue
            n, total = verify(api, tids, s)
            cols.append(
                {
                    "name": name,
                    "t": ",".join(tids),
                    "ids": tids,
                    "first_page": n,
                    "total": total,
                    "ok": n > 0,
                }
            )
        out.append(
            {
                "name": rec["name"],
                "api": rec["api"],
                "site": rec["site"],
                "columns": cols,
                "orphans": [{"id": c["id"], "name": c["name"]} for c in orphans],
            }
        )
        print(f"=== {rec['name']}")
        for c in cols:
            flag = "OK " if c["ok"] else "FAIL"
            print(f"  [{flag}] {c['name']:<4} t={c['t']:<44} total={c['total']}")
        if orphans:
            print("  未归类:", ", ".join(f"{c['id']}:{c['name']}" for c in orphans))
        print()

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"写入 {os.path.abspath(OUT_JSON)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())