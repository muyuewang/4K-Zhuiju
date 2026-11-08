"""从 getDetail 里导出真实的 source / path 组合，用于验证 videoUsableUrl。"""
import sys, urllib.parse

sys.path.insert(0, ".")
from proto_client2 import call, pb_fields


def rv(b, i):
    r = 0
    sh = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7F) << sh
        sh += 7
        if not (x & 0x80):
            return r, i


def parse(b):
    """返回 (field, wiretype, value) 列表，递归展开 length-delimited。"""
    out = []
    i = 0
    n = len(b)
    while i < n:
        try:
            k, i = rv(b, i)
        except Exception:
            break
        f, wt = k >> 3, k & 7
        if f == 0:
            break
        if wt == 0:
            v, i = rv(b, i)
            out.append((f, 0, v))
        elif wt == 2:
            ln, i = rv(b, i)
            seg = b[i:i + ln]
            i += ln
            out.append((f, 2, seg))
        elif wt == 5:
            i += 4
        elif wt == 1:
            i += 8
        else:
            break
    return out


def s(seg):
    try:
        return seg.decode("utf-8")
    except Exception:
        return None


def main():
    vod = sys.argv[1] if len(sys.argv) > 1 else "761499"
    r, _ = call("/api/proto/v5/drama/getDetail", {"id": vod}, "plain")
    print("HTTP", r.status_code, "len", len(r.content))
    top = parse(r.content)
    data = [v for f, wt, v in top if f == 3 and wt == 2]
    if not data:
        print("无 data 段")
        return
    d = data[0]
    inner = parse(d)
    print("data 内字段:", [(f, wt) for f, wt, _ in inner][:40])

    # field 29 是 repeated DramaVideo
    vids = [v for f, wt, v in inner if f == 29 and wt == 2]
    print("视频条目数:", len(vids))
    for idx, vb in enumerate(vids[:6]):
        sub = parse(vb)
        row = {}
        for f, wt, v in sub:
            if wt == 2:
                t = s(v)
                if t is not None:
                    row[f] = t
            elif wt == 0:
                row[f] = v
        print(f"\n--- video[{idx}] ---")
        for k in sorted(row, key=lambda x: (isinstance(x, str), x)):
            val = row[k]
            print(f"  f{k}: {str(val)[:120]!r}")


if __name__ == "__main__":
    main()