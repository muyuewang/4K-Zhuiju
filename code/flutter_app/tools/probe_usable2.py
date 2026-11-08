"""用真实 source/path 验证 videoUsableUrl：
- 连续多次调用，看 token 是否变化
- 立即拉 m3u8，判断是否一次性
"""
import sys, time, urllib.parse, urllib.request

sys.path.insert(0, ".")
from proto_client2 import call, pb_fields

SOURCE = "pylg"
PATH = "v025aag10002dbdocqnog65mjsdog4p0"   # 第01集


def usable(tag):
    r, _ = call("/api/proto/v5/videoUsableUrl",
                {"vodPlayFrom": SOURCE,
                 "playUrl": urllib.parse.quote(PATH, safe="")}, "plain")
    fs = pb_fields(r.content)
    url = ""
    other = []
    for f, t, v in fs:
        if f == 1 and t == "s" and not url:
            url = str(v)
        else:
            other.append((f, t, str(v)[:60]))
    print(f"[{tag}] HTTP {r.status_code} len={len(r.content)} url_len={len(url)}")
    if other:
        print(f"      其他字段: {other}")
    return url


def fetch(url, tag):
    hdr = {"User-Agent": "Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36",
           "Referer": "https://yun2.jiexicn.top/"}
    try:
        req = urllib.request.Request(url, headers=hdr)
        with urllib.request.urlopen(req, timeout=20) as r:
            data = r.read()
            print(f"  [{tag}] HTTP {r.status} size={len(data)}")
            print(f"       {data[:120]!r}")
            return data
    except urllib.error.HTTPError as e:
        print(f"  [{tag}] HTTP {e.code} body={e.read()[:60]!r}")
    except Exception as e:
        print(f"  [{tag}] ERR {type(e).__name__}: {e}")
    return b""


if __name__ == "__main__":
    print("=" * 72)
    u1 = usable("第1次")
    print("  ", u1)
    time.sleep(2)
    u2 = usable("第2次")
    print("  ", u2)
    print("=" * 72)
    print("两次 token 相同:", u1 == u2)

    if u1:
        print("立即拉 u1：")
        d = fetch(u1, "u1-首次")
        if d.startswith(b"#EXTM3U") or b"#EXT" in d[:200]:
            print("  -> playlist 内容正常")
            body = d.decode("utf-8", "replace")
            segs = [l for l in body.splitlines() if l and not l.startswith("#")]
            print(f"  -> 分片数 {len(segs)}，首片: {segs[0] if segs else 'NONE'}")
        else:
            print("  -> 返回非 playlist:", d[:60])

        if u1 == u2:
            print("再拉一次 u1（验证是否一次性）：")
            fetch(u1, "u1-第二次")