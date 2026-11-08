"""验证播放地址的实际可用性：
1. 同一 source+path 连续调 videoUsableUrl 两次，看 token 是否变化
2. 拿到地址后立刻请求 m3u8，试不同 UA / Referer
3. 打印完整的 PlayInfo 字段（含可能被忽略的 headers）
"""
import sys, time, urllib.parse, urllib.request, json

sys.path.insert(0, ".")
from proto_client2 import call, pb_fields

# 之前抓到的 key 型源
SOURCE = "banyun"
PATH = "620518579f9c7df9"


def usable(source, path, tag=""):
    r, kv = call("/api/proto/v5/videoUsableUrl",
                 {"vodPlayFrom": source,
                  "playUrl": urllib.parse.quote(path, safe="")}, "plain")
    fs = pb_fields(r.content)
    print(f"[{tag}] HTTP {r.status_code} len={len(r.content)}")
    for f, t, v in fs:
        s = str(v)
        print(f"    field{f} ({t}) len={len(s)}: {s[:110]}")
    url = ""
    for f, t, v in fs:
        if f == 1 and t == "s":
            url = v
            break
    return url


def try_fetch(url, ua, referer=None, tag=""):
    hdr = {"User-Agent": ua}
    if referer:
        hdr["Referer"] = referer
    req = urllib.request.Request(url, headers=hdr)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = r.read()
            print(f"  [{tag}] HTTP {r.status} size={len(data)}")
            head = data[:200].decode("utf-8", "replace")
            print(f"       首部: {head[:150]!r}")
            return r.status, data
    except urllib.error.HTTPError as e:
        body = e.read()[:80]
        print(f"  [{tag}] HTTP {e.code} body={body!r}")
        return e.code, b""
    except Exception as e:
        print(f"  [{tag}] ERR {type(e).__name__}: {e}")
        return -1, b""


if __name__ == "__main__":
    print("=" * 70)
    u1 = usable(SOURCE, PATH, "第1次")
    time.sleep(1.5)
    u2 = usable(SOURCE, PATH, "第2次")
    print("=" * 70)
    print("token 是否相同:", u1 == u2)
    print("u1:", u1[:100])
    print("u2:", u2[:100])
    print("=" * 70)

    if u1:
        print("立即请求 u1：")
        try_fetch(u1, "Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36",
                  "https://yun2.jiexicn.top/", "browser-UA+referer")
        try_fetch(u1, "okhttp/3.12.1", None, "okhttp")
        try_fetch(u1, "Mozilla/5.0 (Linux; Android 9; SM-N9700)", "https://yun2.jiexicn.top/",
                  "again-同URL")
        # 用第2个 token 试
        if u2 and u2 != u1:
            print("请求 u2：")
            try_fetch(u2, "Mozilla/5.0", None, "u2")