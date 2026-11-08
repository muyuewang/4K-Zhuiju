#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""测试各业务接口：搜索 / 分类 / 热门 / 排行榜 / 详情"""
import urllib.parse
import proto_client2 as P


def show(name, path, params):
    try:
        r, kv = P.call(path, params, "plain")
        print(f"\n{'='*72}\n[{name}]  {path}")
        print(f"  params = {params}")
        print(f"  HTTP {r.status_code}  len={len(r.content)}")
        if len(r.content) < 120:
            for f, t, v in P.pb_fields(r.content):
                print(f"    {f} {t} = {v}")
        else:
            fs = P.pb_fields(r.content)
            for f, t, v in fs[:6]:
                if t == "s":
                    print(f"    {f} s len={len(v)} : {v[:100]}")
                elif t == "b":
                    print(f"    {f} b len={len(v)} : {v[:32].hex()}")
                else:
                    print(f"    {f} v = {v}")
        return r
    except Exception as e:
        print(f"[{name}] ERR {type(e).__name__}: {e}")
        return None


# 1. 搜索
show("搜索-尚公主", "/api/proto/v5/drama/search",
     {"searchKeys": urllib.parse.quote("尚公主", safe=""), "page": "1", "pagesize": "20"})

# 2. 热门
show("热门", "/api/proto/v5/drama/popular", {"page": "1", "pagesize": "20"})

# 3. 分类
show("分类", "/api/proto/v5/drama/category",
     {"typeId1": "1", "page": "1", "pagesize": "20"})

# 4. 排行榜
show("排行榜", "/api/proto/v5/rank/dramaList", {"page": "1", "pagesize": "20"})

# 5. 详情
show("详情", "/api/proto/v5/drama/getDetail", {"id": "761499"})