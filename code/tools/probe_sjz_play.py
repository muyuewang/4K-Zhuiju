"""实测三角洲影视：列表/搜索/详情是否还活着，播放代理是否仍不可用。

不改任何生产文件，只发真实请求并把结论打到 stdout。

用法:
    python code/tools/probe_sjz_play.py
"""
import json
import sys
import urllib.parse
import urllib.request

BASE = 'http://43.248.117.149:5656'
RC4_KEY = b'520720ygq'

PROXIES = [
    'http://43.248.117.45:5001/Client/',
    'http://43.248.117.45:6002/Client/',
    'http://43.248.117.45:5001/Client2/',
]

UA = 'okhttp/3.12.0'


def rc4(data: bytes, key: bytes) -> bytes:
    S = list(range(256))
    j = 0
    for i in range(256):
        j = (key[i % len(key)] + S[i] + j) & 0xFF
        S[i], S[j] = S[j], S[i]
    out = bytearray()
    x = y = 0
    for b in data:
        x = (x + 1) & 0xFF
        y = (S[x] + y) & 0xFF
        S[x], S[y] = S[y], S[x]
        out.append(b ^ S[(S[x] + S[y]) & 0xFF])
    return bytes(out)


def dec(hexstr: str) -> str:
    hexstr = (hexstr or '').strip()
    if not hexstr:
        return ''
    try:
        raw = bytes.fromhex(hexstr)
    except ValueError:
        return hexstr  # 已经是明文
    try:
        return rc4(raw, RC4_KEY).decode('utf-8', 'replace')
    except Exception:
        return ''


def get(url: str, timeout=15):
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:  # noqa: BLE001
        return 0, repr(e).encode()


def fetch_json(path_q: str, label: str):
    url = BASE + path_q
    st, body = get(url)
    print(f'\n--- {label} ---')
    print(f'GET {url}')
    print(f'HTTP {st}  {len(body)} bytes')
    if st != 200 or not body:
        print('  ❌ 接口不可用')
        return None
    txt = body.decode('utf-8', 'replace').strip()
    plain = txt if txt[:1] in ('{', '[') else dec(txt)
    try:
        return json.loads(plain)
    except Exception:
        print(f'  ❌ 解密/解析失败，前 80 字符: {plain[:80]!r}')
        return None


def main() -> int:
    ok_list = False
    ok_detail = False
    play_probe = []

    lst = fetch_json('/api.php/localhost1/vod/?ac=list&class=tvplay&page=1', '列表 tvplay')
    items = []
    if isinstance(lst, dict):
        items = lst.get('data') or []
    print(f'  条目数 = {len(items)}')
    ok_list = len(items) > 0
    if items:
        print('  首条 =', json.dumps(items[0], ensure_ascii=False)[:160])

    # 搜索也一并验
    sr = fetch_json('/api.php/localhost1/So/?ac=list&zm=%E7%81%AB%E5%BD%B1&page=1', '搜索 火影')
    if isinstance(sr, dict):
        print('  命中 =', len(sr.get('data') or []))

    if not items:
        print('\n结论：列表已取不到内容，源实际已废。')
        return 1

    # 取详情：nextlink 里抽 ids
    import re
    vid = ''
    for it in items:
        m = re.search(r'ids=(\d+)', str(it.get('nextlink', '')))
        if m:
            vid = m.group(1)
            break
    if not vid:
        print('\n❌ 列表里抽不到 ids，无法验详情')
        return 1

    det = fetch_json(f'/api.php/localhost1/vod/?ac=detail&ids={vid}', f'详情 ids={vid}')
    if not isinstance(det, dict):
        print('\n结论：详情不可用。')
        return 1

    title = det.get('title')
    vl = det.get('videolist') or {}
    print(f'  剧名 = {title}')
    print(f'  线路数 = {len(vl)}')
    ok_detail = len(vl) > 0

    # 取第一条线路的首集 token
    token = ''
    line_name = ''
    for from_key, eps in vl.items():
        if not isinstance(eps, list) or not eps:
            continue
        t = dec(str(eps[0].get('url', '')))
        if t:
            token = t
            line_name = from_key
            break
    print(f'  首线路 {line_name} 首集 token = {token[:70]}')
    if not token:
        print('\n❌ 解不出 token')
        return 1

    # 逐个代理试播
    print('\n--- 播放代理实测 ---')
    for p in PROXIES:
        q = p + '?url=' + urllib.parse.quote(token, safe='')
        st, body = get(q, timeout=20)
        loc = ''
        if st in (301, 302, 303, 307, 308):
            loc = '(Location 未回读)'
        snippet = body[:200].decode('utf-8', 'replace') if body else ''
        print(f'{p}\n  HTTP {st}  {len(body)} bytes  {loc}')
        print(f'  响应前 200: {snippet!r}')
        play_probe.append((p, st, len(body), snippet))

    # 判定：有任意代理返回 200 且含 m3u8/mp4 即算可播
    playable = False
    for _p, st, ln, snip in play_probe:
        if st == 200 and ('.m3u8' in snip or '.mp4' in snip or '"url"' in snip):
            playable = True
            break

    print('\n=== 结论 ===')
    print(f'列表可用   : {"是" if ok_list else "否"}')
    print(f'详情可用   : {"是" if ok_detail else "否"}')
    print(f'播放可播   : {"是" if playable else "否"}')
    if playable:
        print('→ 保留该源')
    else:
        print('→ 播放仍不可用，建议剔除')
    return 0


if __name__ == '__main__':
    sys.exit(main())