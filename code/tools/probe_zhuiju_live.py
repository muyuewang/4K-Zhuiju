#!/usr/bin/env python3
"""实测橘汁源 typeId=25「直播」到底返回什么、能不能播。

要回答三个问题，不能靠猜：
  1) category(typeId1=25) 有没有内容？返回的条目长什么样？
  2) 这些条目拿去查 detail，videos 里的 path 是什么形态？
     （直链 m3u8/mp4？还是转发地址？还是空？）
  3) 拿最前面几条去换 videoUsableUrl，换出来的地址能不能真的播？

判定标准与 probe_live 一致：看响应体前 64 字节，
#EXTM3U = HLS 清单，ftyp = MP4，FLV = 流，别只看 HTTP 200。
"""
import json
import os
import re
import ssl
import sys
import urllib.parse
import urllib.request

HOST = "http://juziapp.hzhcbkj.cn"
UA = "okhttp/3.12.1"

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "dist", "probe", "zhuiju_live_probe.json")


def get(path, params=None):
    url = HOST + path
    if params:
        url += "?" + urllib.parse.urlencode(params, encoding="utf-8")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=15, context=CTX) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()[:400]
        except Exception as e:
            if attempt == 2:
                return type(e).__name__, str(e)[:200].encode()
    return "?", b""


def sniff(url, timeout=12):
    """看响应体判断能不能播，不只看状态码。"""
    if not url.lower().startswith(("http://", "https://")):
        return {"ok": False, "why": "非 http 地址", "head": url[:60]}
    req = urllib.request.Request(
        url, headers={"User-Agent": "okhttp/3.12.1",
                      "Accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            head = r.read(64)
            status = r.status
    except urllib.error.HTTPError as e:
        return {"ok": False, "why": "HTTP%d" % e.code}
    except Exception as e:
        return {"ok": False, "why": type(e).__name__}
    if status != 200:
        return {"ok": False, "why": "HTTP%d" % status}
    txt = head.lstrip()
    if txt.startswith(b"#EXTM3U"):
        return {"ok": True, "kind": "M3U8", "head": head[:40].decode("utf-8", "replace")}
    if b"ftyp" in head[:16]:
        return {"ok": True, "kind": "MP4"}
    if txt[:3] in (b"FLV", b"flv"):
        return {"ok": True, "kind": "FLV"}
    if txt[:1] in (b"{", b"<"):
        return {"ok": False, "why": "返回的是数据不是流",
                "head": head[:60].decode("utf-8", "replace")}
    return {"ok": False, "why": "内容不是媒体流", "head": repr(head[:24])}


def main():
    report = {}

    # ---- 1. 分类列表 ----
    st, body = get("/api/proto/v5/drama/category",
                   {"typeId1": "25", "page": "1", "pagesize": "20"})
    print("[1] category(25) HTTP %s，%d 字节" % (st, len(body)))
    try:
        d = json.loads(body.decode("utf-8", "replace"))
    except Exception as e:
        print("    不是 JSON: %s" % e)
        print("    前 200 字节: %r" % body[:200])
        report["category_raw"] = body[:400].decode("utf-8", "replace")
        json.dump(report, open(OUT, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=1)
        return 0

    data = d.get("data") or {}
    items = data.get("list") or data.get("data") or []
    if isinstance(items, dict):
        items = items.get("list") or []
    print("    字段: %s" % list(d.keys()))
    print("    条目数: %d" % len(items))
    if not items:
        print("    原始: %s" % json.dumps(d, ensure_ascii=False)[:400])
        report["empty"] = d
        json.dump(report, open(OUT, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=1)
        print("\n结论: 分类 25 返回空 → 该分类无内容")
        return 0

    print("    前 3 条:")
    for x in items[:3]:
        print("      id=%-8s name=%-22s type=%s clazz=%s" % (
            x.get("id") or x.get("vodId"), (x.get("name") or "")[:20],
            x.get("type"), x.get("clazz")))
    report["count"] = len(items)
    report["sample"] = items[:5]

    # ---- 2. 详情里的 videos ----
    print("\n[2] 抽查前 5 条的 detail")
    details = []
    for x in items[:5]:
        vid = x.get("id") or x.get("vodId")
        if vid is None:
            continue
        st2, body2 = get("/api/proto/v5/drama/getDetail", {"id": str(vid)})
        if st2 != 200:
            print("    id=%-8s HTTP %s" % (vid, st2))
            continue
        # detail 是 protobuf，非文本；这里只做存在性判断，
        # 真正的字段结构由 Dart 侧 DramaDetail.fromBytes 解析
        print("    id=%-8s HTTP200 %d 字节 (protobuf)" % (vid, len(body2)))
        details.append({"id": vid, "bytes": len(body2),
                        "is_text": body2[:1] in (b"{", b"<")})
    report["details"] = details

    json.dump(report, open(OUT, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("\n明细 %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())