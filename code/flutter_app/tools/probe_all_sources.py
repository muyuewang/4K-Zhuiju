"""遍历 getDetail 里所有播放源，对每个源取第一集，
调用 videoUsableUrl 解析真实地址，然后实测该地址：
  - 返回的是 MP4 还是 m3u8
  - 是否带时效 token（重复请求是否仍 200）
  - 是否支持 Range（断点续传前提）
输出一张可直接决定下载策略的结论表。
"""
import sys, time, urllib.parse, urllib.request, urllib.error

sys.path.insert(0, ".")
from proto_client2 import call, pb_fields
from dump_videos import parse

UA = ("Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36")


def utf8(seg):
    try:
        return seg.decode("utf-8")
    except Exception:
        return None


def get_sources(vod="761499"):
    """返回 [(sourceCn, source, path), ...]，每个源取第一集"""
    r, _ = call("/api/proto/v5/drama/getDetail", {"id": vod}, "plain")
    top = parse(r.content)
    data = [v for f, wt, v in top if f == 3 and wt == 2]
    if not data:
        return []
    vids = [v for f, wt, v in parse(data[0]) if f == 29 and wt == 2]

    seen = {}
    out = []
    for vb in vids:
        row = {}
        for f, wt, v in parse(vb):
            if wt == 2:
                t = utf8(v)
                if t is not None:
                    row[f] = t
            elif wt == 0:
                row[f] = v
        src = row.get(9, "")
        src_cn = row.get(10, "") or src
        path = row.get(4, "")
        ep = row.get(2, "")
        if not src or not path:
            continue
        if src_cn in seen:
            continue
        seen[src_cn] = True
        out.append((src_cn, src, path, ep, row.get(3, "")))
    return out


def resolve(source, path):
    r, _ = call("/api/proto/v5/videoUsableUrl",
                {"vodPlayFrom": source, "playUrl": urllib.parse.quote(path, safe="")},
                "plain")
    top = pb_fields(r.content)
    code = [v for f, t, v in top if f == 1 and t == "v"]
    data = [v for f, t, v in top if f == 3 and t == "b"]
    if not data:
        msg = [v for f, t, v in top if f == 2 and t == "s"]
        return code[0] if code else -1, "", msg[0] if msg else ""
    inner = pb_fields(data[0])
    url = ""
    for f, t, v in inner:
        if f == 1 and t == "s":
            url = v
            break
    return code[0] if code else -1, url, ""


def probe(url, tag="1st"):
    """HEAD/GET 400 字节，拿状态码 / 类型 / 长度 / 是否支持 Range"""
    hdr = {"User-Agent": UA, "Accept": "*/*"}
    try:
        req = urllib.request.Request(url, headers=hdr)
        with urllib.request.urlopen(req, timeout=20) as r:
            head = r.read(400)
            ctype = r.headers.get("Content-Type", "")
            clen = r.headers.get("Content-Length", "?")
            ar = r.headers.get("Accept-Ranges", "-")
            kind = "MP4" if b"ftyp" in head else ("M3U8" if head.lstrip().startswith(b"#EXTM3U") else "?")
            return dict(ok=True, status=r.status, ctype=ctype, len=clen,
                        ranges=ar, kind=kind, head=head[:40])
    except urllib.error.HTTPError as e:
        body = b""
        try:
            body = e.read()[:60]
        except Exception:
            pass
        return dict(ok=False, status=e.code, ctype="", len="", ranges="-",
                    kind="ERR", head=body)
    except Exception as e:
        return dict(ok=False, status=-1, ctype="", len="", ranges="-",
                    kind="ERR", head=f"{type(e).__name__}: {e}".encode()[:60])


def range_test(url):
    hdr = {"User-Agent": UA, "Accept": "*/*", "Range": "bytes=0-1023"}
    try:
        req = urllib.request.Request(url, headers=hdr)
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.headers.get("Content-Range", "-")
    except urllib.error.HTTPError as e:
        return e.code, "-"
    except Exception:
        return -1, "-"


def main():
    vod = sys.argv[1] if len(sys.argv) > 1 else "761499"
    srcs = get_sources(vod)
    print(f"共 {len(srcs)} 个源\n" + "=" * 96)

    rows = []
    for i, (cn, src, path, ep, ep_cn) in enumerate(srcs):
        print(f"\n[{i+1}/{len(srcs)}] {cn}  (source={src}, ep={ep_cn or ep})")
        code, url, msg = resolve(src, path)
        if not url:
            print(f"   解析失败 code={code} msg={msg!r}")
            rows.append((cn, src, "解析失败", "", "", "", ""))
            continue
        print(f"   URL: {url[:110]}{'...' if len(url) > 110 else ''}")

        p1 = probe(url, "1st")
        print(f"   1st: HTTP {p1['status']} kind={p1['kind']} "
              f"type={p1['ctype'][:40]} len={p1['len']} ranges={p1['ranges']}")

        if p1["kind"] == "M3U8":
            # 拿 playlist 内容看分片
            txt = ""
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=20) as r:
                    txt = r.read(3000).decode("utf-8", "ignore")
            except Exception as e:
                txt = f"ERR {e}"
            segs = [l.strip() for l in txt.splitlines()
                    if l.strip() and not l.strip().startswith("#")]
            print(f"   分片数(前3000字符内)={len(segs)}  首个={segs[0][:80] if segs else '-'}")
            rows.append((cn, src, "HLS", str(len(segs)), p1["len"], "-", "见分段"))
            continue

        # MP4 类：测 Range 与稳定性
        time.sleep(1)
        p2 = probe(url, "2nd")
        same = p2["ok"] and p2["len"] == p1["len"]
        rs, cr = range_test(url) if p1["ok"] else (0, "-")
        print(f"   2nd: HTTP {p2['status']} len={p2['len']} 稳定={same}")
        print(f"   Range 测试: HTTP {rs} Content-Range={cr}")
        rows.append((cn, src,
                     "MP4" if p1["kind"] == "MP4" else p1["kind"],
                     p1["len"], "稳定" if same else "变化",
                     "支持" if rs == 206 else f"不支持({rs})", ""))

    print("\n" + "=" * 96)
    print(f"{'源名称':<14}{'source':<10}{'类型':<6}{'大小/分片':<12}{'token':<8}{'Range':<12}")
    print("-" * 96)
    for cn, src, kind, size, tok, rng, note in rows:
        print(f"{cn:<14}{src:<10}{kind:<6}{size:<12}{tok:<8}{rng:<12}{note}")


if __name__ == "__main__":
    main()