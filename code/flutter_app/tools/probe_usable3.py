"""正确解析 PlayInfo（data 在 field3，url 在 data 内 field1），
并验证 token 是否一次性 / 是否需要特定请求头。
"""
import sys, time, urllib.parse, urllib.request

sys.path.insert(0, ".")
from proto_client2 import call, pb_fields

SOURCE = "pylg"
PATH = "v025aag10002dbdocqnog65mjsdog4p0"


def usable(tag):
    r, _ = call("/api/proto/v5/videoUsableUrl",
                {"vodPlayFrom": SOURCE,
                 "playUrl": urllib.parse.quote(PATH, safe="")}, "plain")
    top = pb_fields(r.content)
    code = [v for f, t, v in top if f == 1 and t == "v"]
    data = [v for f, t, v in top if f == 3 and t == "b"]
    print(f"[{tag}] code={code}  data段={len(data)}")
    if not data:
        return ""
    inner = pb_fields(data[0])
    print(f"      PlayInfo 字段: {[(f, t, str(v)[:50]) for f, t, v in inner]}")
    url = ""
    for f, t, v in inner:
        if f == 1 and t == "s":
            url = v
            break
    return url


def fetch(url, tag, ua=None, ref=None, rng=None):
    hdr = {"User-Agent": ua or "Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36"}
    if ref:
        hdr["Referer"] = ref
    if rng:
        hdr["Range"] = rng
    try:
        req = urllib.request.Request(url, headers=hdr)
        with urllib.request.urlopen(req, timeout=25) as r:
            data = r.read(400)
            total = r.headers.get("Content-Length", "?")
            print(f"  [{tag}] HTTP {r.status}  len={total}  head={data[:90]!r}")
            return data
    except urllib.error.HTTPError as e:
        print(f"  [{tag}] HTTP {e.code}  body={e.read()[:60]!r}")
    except Exception as e:
        print(f"  [{tag}] ERR {type(e).__name__}: {e}")
    return b""


if __name__ == "__main__":
    print("=" * 74)
    u1 = usable("第1次")
    print("  URL:", u1)
    time.sleep(2)
    u2 = usable("第2次")
    print("  URL:", u2)
    print("=" * 74)
    print("两次相同:", u1 == u2)

    if u1:
        print("\n--- 用 u1 反复请求 ---")
        fetch(u1, "第1次请求")
        fetch(u1, "第2次请求")
        fetch(u1, "第3次请求-带Referer", ref="https://v3-forum.picovr.com/")
        fetch(u1, "第4次请求-okhttp", ua="okhttp/3.12.1")
        print("\n--- 用 u2 请求 ---")
        if u2:
            fetch(u2, "u2请求")