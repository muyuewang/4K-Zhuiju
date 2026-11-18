"""决定性实验：官方线换票（resolve-line）需不需要游客会话？

如果不需要 → 只要给清单加一个「第二次请求」配置就能修好，不必动会话。
如果需要   → 必须把匿名会话（/v1/users/anonymous）一起补回来。

两种都测，对照出结论。
"""

import hashlib
import hmac
import json
import os
import secrets
import subprocess
import time

KEY = '557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0'
BASE = 'https://kanju.ai'
PROXY = 'http://127.0.0.1:7897'
UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')


def clean_env():
    env = dict(os.environ)
    for k in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
              'http_proxy', 'https_proxy', 'all_proxy'):
        env.pop(k, None)
    return env


def call(method, path, body=None, cookie=None, extra=None):
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
        'Accept': 'application/json', 'Origin': BASE, 'Referer': BASE + '/',
        'User-Agent': UA,
    }
    if cookie:
        h['Cookie'] = cookie
    if extra:
        h.update(extra)
    cmd = ['curl', '-s', '-m', '25', '--proxy', PROXY, '-X', method,
           '-D', '-', '-w', '\n__C__%{http_code}', '-o', '-']
    for k, v in h.items():
        cmd += ['-H', f'{k}: {v}']
    if body is not None:
        cmd += ['-H', 'Content-Type: application/json',
                '-d', json.dumps(body)]
    cmd.append(BASE + path)
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=40, env=clean_env())
    return p.stdout


def split(raw):
    b, _, code = raw.rpartition('__C__')
    return code.strip(), b


def main():
    raw = json.load(open('kanju_resolve_raw.json', encoding='utf-8'))
    opts = raw['line_options']
    off = [o for o in opts if o.get('resolve_required') is True][0]
    ticket = off['url'].replace('resolve://', '')
    print('测试线路:', off['display_label'])
    print()

    print('===== 实验 1：不带任何会话，直接换票 =====')
    r = call('POST', '/v1/playback/resolve-line?view=compact',
             {'ticket': ticket})
    code, body = split(r)
    print('HTTP', code)
    print(body[:600])
    print()

    print('===== 实验 2：先注册游客会话，再换票 =====')
    anon = secrets.token_hex(16)
    r = call('POST', '/v1/users/anonymous', {'anonymous_id': anon})
    heads = r.split('\r\n\r\n')[0]
    code, body = split(r)
    print('anonymous HTTP', code)
    cookie = ''
    for line in heads.split('\n'):
        if line.lower().startswith('set-cookie') and 'ai_movie_session=' in line:
            seg = line.split(':', 1)[1].strip()
            cookie = seg.split(';')[0]
            print('  拿到 Cookie:', cookie[:60], '...')
    print('  应答:', body[:200])
    print()

    if cookie:
        r = call('POST', '/v1/playback/resolve-line?view=compact',
                 {'ticket': ticket}, cookie=cookie)
        code, body = split(r)
        print('带会话换票 HTTP', code)
        print(body[:700])
        print()
        try:
            d = json.loads(body)
            ln = d.get('line') or {}
            u = ln.get('url', '')
            print('解析出 url:', u[:160] if u else '(空)')
            print('=>', '官方线可播' if u.startswith('http') else '仍不可播')
        except Exception as e:
            print('解析失败', e)


if __name__ == '__main__':
    main()
