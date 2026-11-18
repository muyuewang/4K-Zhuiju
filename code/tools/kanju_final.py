"""确认官方线换票返回的真实 url（正文单独取，不带响应头干扰）。"""

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


def post(path, body, cookie=None):
    ts = str(int(time.time() * 1000))
    nonce = secrets.token_hex(16)
    msg = f'POST\n{path}\n{ts}\n{nonce}'
    sig = hmac.new(KEY.encode(), msg.encode(), hashlib.sha256).hexdigest()
    h = {
        'x-ai-movie-timestamp': ts,
        'x-ai-movie-nonce': nonce,
        'x-ai-movie-signature': sig,
        'x-ai-movie-client-name': 'dianyingtiantang-frontend',
        'x-ai-movie-client-version': '1.0.0',
        'x-ai-movie-protocol-version': '2026-07-05.library-v2.playback-v1',
        'Accept': 'application/json', 'Origin': BASE, 'Referer': BASE + '/',
        'User-Agent': UA, 'Content-Type': 'application/json',
    }
    if cookie:
        h['Cookie'] = cookie
    cmd = ['curl', '-s', '-m', '25', '--proxy', PROXY, '-X', 'POST',
           '-w', '\n__C__%{http_code}']
    for k, v in h.items():
        cmd += ['-H', f'{k}: {v}']
    cmd += ['-d', json.dumps(body), BASE + path]
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=40, env=clean_env())
    b, _, code = p.stdout.rpartition('__C__')
    return code.strip(), b.strip()


def main():
    raw = json.load(open('kanju_resolve_raw.json', encoding='utf-8'))
    opts = raw['line_options']
    offs = [o for o in opts if o.get('resolve_required') is True]
    print(f'共 {len(offs)} 条官方线，逐条试换票（不带会话）\n')

    ok = 0
    for o in offs:
        ticket = o['url'].replace('resolve://', '')
        code, body = post('/v1/playback/resolve-line?view=compact',
                          {'ticket': ticket})
        url = ''
        try:
            d = json.loads(body)
            ln = d.get('line') or {}
            url = ln.get('url', '')
        except Exception:
            pass
        mark = 'OK ' if url.startswith('http') else 'NG '
        if url.startswith('http'):
            ok += 1
        print(f'{mark}{o["display_label"]:<14} HTTP {code:<4} {url[:78]}')

    print(f'\n官方线可换票: {ok}/{len(offs)}（未使用任何会话）')

    if ok:
        print('\n结论：官方线不需要游客会话，缺的只是「第二次请求」这一步。')


if __name__ == '__main__':
    main()
