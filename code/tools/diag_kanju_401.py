"""定位《凡人修仙传》第201集「1080P-官方K」在软件里 HTTP 401 的那一层。

用户报障 2026-11-23：
  网页 https://kanju.s2/player/av/P-2v5Wealr1otabU1ZU/zeahWWsZKwoLzsJ1oapDkxcYBl8v1by2cPvMp54fDhg4kl
  选「1080P-官方K」第201集能播；软件同集报 HTTP 401。

宿主链路四步，每一步都打 HTTP 状态：
  1. GET  /v1/catalog/{id}                  详情，拿剧集 token
  2. GET  /v1/playback/resolve/{token}      拿 line_options
  3. POST /v1/playback/resolve-line         官方线换票
  4. GET  换出的真实地址                    播放器实际请求

用法: python code/tools/diag_kanju_401.py
"""

import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import time

KEY = '557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0'
BASE = 'https://kanju.ai'
PROXY = 'http://127.0.0.1:7897'
UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
MOVIE_ID = 'av_P-2fvsUWEahkU1ofbAB1UZI7ehaRWVSzZKiwoEzs1_oIaPbKzyKBl17pziV2cPhM9pFDJhgikk983lI'


def clean_env():
    env = dict(os.environ)
    for k in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
              'http_proxy', 'https_proxy', 'all_proxy'):
        env.pop(k, None)
    return env


def req(method, path, body=None, extra_headers=None, use_proxy=True,
        host=BASE, timeout=30):
    ts = str(int(time.time() * 1000))
    nonce = secrets.token_hex(16)
    msg = f'{method}\n{path}\n{ts}\n{nonce}'
    sig = hmac.new(KEY.encode(), msg.encode(), hashlib.sha256).hexdigest()
    h = {
        'x-ai-movie-timestamp': ts,
        'x-ai-movie-nonce': nonce,
        'x-ai-movie-signature': sig,
        'x-ai-movie-client-name': 'dianyingtiantang-frontend',
        'x-ai-movie-client-version': '1.0.0',
        'x-ai-movie-protocol-version': '2026-07-05.library-v2.playback-v1',
        'Accept': 'application/json',
        'Origin': host,
        'Referer': host + '/',
        'User-Agent': UA,
    }
    cmd = ['curl', '-s', '-m', str(timeout),
           '-D', '-', '-w', '\n__C__%{http_code}']
    if use_proxy:
        cmd += ['--proxy', PROXY]
    cmd += ['-X', method]
    if body is not None:
        h['Content-Type'] = 'application/json'
        cmd += ['-d', json.dumps(body)]
    if extra_headers:
        h.update(extra_headers)
    for k, v in h.items():
        cmd += ['-H', f'{k}: {v}']
    cmd.append(host + path)
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=timeout + 15, env=clean_env())
    out = p.stdout or ''
    # 代理会先回一行 "HTTP/1.1 200 Connection established"，再回真正的响应头。
    # 用最后一个 "__C__" 切出状态码，body 就是它前面、最后一组空行之后的内容。
    bodytxt, _, code = out.rpartition('__C__')
    bodytxt = bodytxt.strip()
    # body 是 JSON，从第一个 { 或 [ 开始截，规避前面混进的响应头
    for marker in ('\r\n\r\n', '\n\n'):
        if marker in bodytxt:
            candidate = bodytxt.split(marker)[-1]
            if candidate.lstrip()[:1] in ('{', '['):
                bodytxt = candidate
                break
    if bodytxt[:1] not in ('{', '['):
        k = min([i for i in (bodytxt.find('{'), bodytxt.find('[')) if i >= 0] or [0])
        bodytxt = bodytxt[k:]
    return code.strip(), out, bodytxt.strip()


def show(label, code, headers, body, limit=400):
    print(f'\n=== {label} ===')
    print(f'HTTP {code}')
    if code != '200':
        for line in headers.splitlines():
            if line.lower().startswith(('http/', 'www-authenticate', 'location')):
                print('  ', line.strip())
    print('  响应前', limit, '字符:', body[:limit].replace('\n', ' '))


def main():
    # ---------- 第 1 步：详情 ----------
    code, hd, body = req('GET', f'/v1/catalog/{MOVIE_ID}')
    show('第1步 详情 /v1/catalog/' + MOVIE_ID, code, hd, body)
    if code != '200':
        print('\n结论：详情这一步就挂了，根本到不了播放。')
        return
    try:
        d = json.loads(body)
    except Exception:
        print('详情不是 JSON，退出')
        return

    # 找到 data 容器
    obj = d.get('data', d) if isinstance(d, dict) else d

    # 递归找第201集 token：剧集通常挂在 episodes / items / videos 等
    found = []

    def walk(x, depth=0):
        if depth > 8:
            return
        if isinstance(x, dict):
            # 典型形态：{title/name/label: "第201集", token/id: "..."}
            txt = json.dumps({k: v for k, v in x.items()
                              if isinstance(v, (str, int))}, ensure_ascii=False)
            if '201' in txt and any(k in x for k in ('token', 'episode_token',
                                                      'playback_id', 'id', 'vid')):
                found.append(x)
            for v in x.values():
                walk(v, depth + 1)
        elif isinstance(x, list):
            for v in x:
                walk(v, depth + 1)

    walk(obj)
    print(f'\n含「201」且带 id/token 的节点: {len(found)} 个')
    for f in found[:6]:
        print('   ', json.dumps(f, ensure_ascii=False)[:300])

    if not found:
        # 打印结构，供人工找 token 字段
        print('\n详情顶层 keys:', list(obj.keys()) if isinstance(obj, dict) else type(obj))
        s = json.dumps(obj, ensure_ascii=False)
        idx = s.find('201')
        print('「201」附近原文:', s[max(0, idx - 300):idx + 300])
        return

    # 取第一个像 token 的字段
    tok = ''
    # 优先取 number==201 那一集的 token 字段（不是影片 id！）
    for f in found:
        if f.get('number') == 201 or f.get('key') == 'e-0201':
            for k in ('token', 'episode_token', 'playback_id'):
                v = f.get(k)
                if isinstance(v, str) and v and len(v) > 12:
                    tok = v
                    break
            if tok:
                break
    if not tok:
        for f in found:
            v = f.get('token')
            if isinstance(v, str) and v:
                tok = v
                break
    print(f'\n用 token = {tok}')

    # ---------- 第 2 步：resolve ----------
    code, hd, body = req('GET', f'/v1/playback/resolve/{tok}')
    show('第2步 resolve /v1/playback/resolve/{token}', code, hd, body)
    if code != '200':
        print('\n结论：401 发生在 resolve 接口（签名或会话），不是播放器。')
        return
    try:
        rj = json.loads(body)
    except Exception:
        print('resolve 应答不是 JSON')
        return
    robj = rj.get('data', rj) if isinstance(rj, dict) else rj
    opts = robj.get('line_options', []) if isinstance(robj, dict) else []
    print(f'\nline_options 共 {len(opts)} 条')
    target = None
    for o in opts:
        label = str(o.get('display_label') or o.get('label') or o.get('provider_name') or '')
        if label == '1080P-官方K':
            target = (label, o)
            break
    if not target:
        # 退化：列出所有官方线，方便人工核对名字
        print('没找到精确的「1080P-官方K」，当前所有官方线:')
        for o in opts:
            lb = str(o.get('display_label') or o.get('label') or o.get('provider_name') or '')
            if '官方' in lb:
                print('  -', lb, '|', str(o.get('url', ''))[:20])
    if not target:
        print('没找到「1080P-官方K」，前 12 条线路名:')
        for o in opts[:12]:
            print('  -', o.get('display_label') or o.get('label') or o.get('provider_name'))
        return
    label, o = target
    print(f'\n找到目标线路: {label}')
    print('  字段:', json.dumps(o, ensure_ascii=False)[:500])

    url = str(o.get('url', ''))
    if not url.startswith('resolve://'):
        print('  这不是票据线，直接地址:', url[:200])
        stream = url
    else:
        ticket = url[len('resolve://'):]
        # ---------- 第 3 步：换票 ----------
        code, hd, body = req('POST', '/v1/playback/resolve-line?view=compact',
                             body={'ticket': ticket})
        show('第3步 换票 POST /v1/playback/resolve-line', code, hd, body)
        if code != '200':
            print('\n结论：401 发生在换票接口。')
            return
        try:
            lj = json.loads(body)
        except Exception:
            print('换票应答不是 JSON')
            return
        lo = lj.get('data', lj)
        line = lo.get('line', {}) if isinstance(lo, dict) else {}
        stream = str(line.get('url') or lo.get('url') or '')
        print('\n换出的真实地址:', stream[:300])
        if not stream.startswith('http'):
            print('换票没拿到 http 地址，退出')
            return

    # ---------- 第 4 步：请求真实流 ----------
    cmd = ['curl', '-s', '-o', os.devnull, '-m', '25', '--proxy', PROXY,
           '-w', '%{http_code} %{content_type} %{size_download}',
           '-H', f'User-Agent: {UA}', stream]
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=40, env=clean_env())
    print(f'\n=== 第4步 请求真实流 ===\n  {p.stdout.strip()}')
    if '401' in p.stdout:
        print('\n结论：401 发生在播放器请求真实流时 —— 需要带 Referer / UA / Cookie。')


if __name__ == '__main__':
    main()