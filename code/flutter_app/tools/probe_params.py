#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""试探列表接口的正确参数组合"""
import proto_client2 as P


def brief(r):
    fs = P.pb_fields(r.content)
    out = []
    for f, t, v in fs[:5]:
        if t == "s":
            out.append(f"{f}:s({len(v)})")
        elif t == "b":
            out.append(f"{f}:b({len(v)})")
        else:
            out.append(f"{f}:{v}")
    return " ".join(out)


def t(name, path, params):
    try:
        r, _ = P.call(path, params, "plain")
        print(f"  {name:28s} len={len(r.content):6d}  {brief(r)}")
        return r
    except Exception as e:
        print(f"  {name:28s} ERR {type(e).__name__}: {e}")
        return None


print("### 搜索：searchKeys 编码方式对比")
t("原文", "/api/proto/v5/drama/search", {"searchKeys": "尚公主", "page": "1", "pagesize": "20"})
t("原文+typeId1", "/api/proto/v5/drama/search", {"searchKeys": "尚公主", "typeId1": "", "page": "1", "pagesize": "20"})
t("仅typeId1", "/api/proto/v5/drama/search", {"typeId1": "1", "page": "1", "pagesize": "20"})
t("空参数", "/api/proto/v5/drama/search", {"page": "1", "pagesize": "20"})

print("\n### 分类：typeId1 取值")
for tid in ("0", "1", "2", "21"):
    t(f"typeId1={tid}", "/api/proto/v5/drama/category",
      {"typeId1": tid, "page": "1", "pagesize": "10"})

print("\n### 热门：需要 vodIds")
t("vodIds=空", "/api/proto/v5/drama/popular", {"vodIds": "", "page": "1", "pagesize": "10"})
t("vodIds=761499", "/api/proto/v5/drama/popular", {"vodIds": "761499", "page": "1", "pagesize": "10"})

print("\n### 推荐")
t("推荐 cate=0", "/api/proto/v5/drama/recommend", {"cate_type1": "0", "page": "1", "pagesize": "10"})
t("推荐 id=761499", "/api/proto/v5/drama/recommend", {"id": "761499", "page": "1", "pagesize": "10"})