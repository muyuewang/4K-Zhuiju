"""抓一条真实播放地址，并检查 m3u8 结构，定位播放/下载失败原因。"""
import sys, io, urllib.parse, urllib.request, json

sys.path.insert(0, ".")
from proto_client2 import call, pb_fields

HDR = {"User-Agent": "okhttp/3.12.1"}


def get_detail(vod_id):
    r, kv = call("/api/proto/v5/drama/getDetail", {"id": str(vod_id)}, "plain")
    return r.content


def main():
    body = get_detail(761499)
    print("getDetail bytes:", len(body))
    fs = pb_fields(body)
    # 找 video 列表：field 2 为 data 里的 repeated video
    videos = [v for f, t, v in fs if t == "s" and "$$$" in str(v)]
    print("含 $$$ 的字段数:", len(videos))
    for v in videos[:3]:
        print("  ", str(v)[:160])

    fs2 = [(f, t, v) for f, t, v in fs]
    # 直接在 data 段里找 playFrom/playUrl
    import re
    txt = " ".join(str(v) for f, t, v in fs2 if t == "s")
    m = re.findall(r"(bfzym3u8|banyun|qq|m3u8|hdm3u8|wjm3u8)", txt)
    print("命中源关键字:", set(m))

    # 打印所有看起来像 key 或 url 的短串
    cands = [str(v) for f, t, v in fs2 if t == "s" and 2 < len(str(v)) < 90]
    print("\n--- 候选字段（前40） ---")
    for c in cands[:40]:
        print("  ", repr(c))


if __name__ == "__main__":
    main()