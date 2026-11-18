"""验证官方线票据（resolve://av_...）怎样才能换成真实播放地址。

resolve 应答里官方线的形态：
    url          = "resolve://av_DrPOg..."
    url_kind     = "resolve_ticket"
    resolve_mode = "parse"
    resolve_required = True
普通线则是 url_kind="m3u8" / resolve_mode="direct"，url 直接可用。

所以「官方线」缺的正是「把票据再提交一次」这一步。本脚本穷举几种可能的
换票方式，看哪一种真的返回 m3u8。
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


def sign(method, pq, ts, nonce):
    msg = f'{method.upper()}\n{pq}\n{ts}\n{nonce}'
    return hmac.new(KEY.encode(), msg.encode(), hashlib.sha256).hexdigest()


def req(path, method='GET', body=None, extra=None):
    ts = str(int(time.time() * 1000))
    nonce = secrets.token_hex(16)
    h = {
        'x-ai-movie-timestamp': ts,
        'x-ai-movie-nonce': nonce,
        'x-ai-movie-signature': sign(method, path, ts, nonce),
        'x-ai-movie-client-name': 'dianyingtiantang-frontend',
        'x-ai-movie-client-version': '1.0.0',
        'x-ai-movie-protocol-version': '2026-07-05.library-v2.playback-v1',
        'Accept': 'application/json', 'Origin': BASE, 'Referer': BASE + '/',
        'User-Agent': UA,
    }
    if extra:
        h.update(extra)
    cmd = ['curl', '-s', '-m', '25', '--proxy', PROXY, '-X', method,
           '-w', '\n__C__%{http_code}']
    for k, v in h.items():
        cmd += ['-H', f'{k}: {v}']
    if body:
        cmd += ['-H', 'Content-Type: application/json', '-d', body]
    cmd.append(BASE + path)
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=40, env=clean_env())
    out = p.stdout
    b, _, code = out.rpartition('__C__')
    return code.strip(), b


def brief(b, n=300):
    try:
        d = json.loads(b)
    except Exception:
        return b[:n]
    if isinstance(d, dict):
        keep = {k: d[k] for k in list(d)[:8]}
        return json.dumps(keep, ensure_ascii=False)[:n]
    return str(d)[:n]


def main():
    d = json.load(open('kanju_resolve_raw.json', encoding='utf-8'))
    opts = d['line_options']
    off = [o for o in opts if o.get('resolve_required') is True][0]
    raw_url = off['url']
    ticket = raw_url.replace('resolve://', '')
    print('官方线:', off['display_label'])
    print('票据前缀:', ticket[:40], '...')
    print()

    ep_token = d.get('token')
    print('当前集 token 前缀:', str(ep_token)[:30], '...')
    print()

    tries = [
        ('A. 票据当 token 投回 resolve', f'/v1/playback/resolve/{ticket}'),
        ('B. 原集 token + 票据做 query',
         f'/v1/playback/resolve/{ep_token}?playback_source_id={off["playback_source_id"]}'),
        ('C. 原集 token + provider',
         f'/v1/playback/resolve/{ep_token}?provider_id={off["provider_id"]}'),
        ('D. 原集 token + label',
         f'/v1/playback/resolve/{ep_token}?label={off["display_label"]}'),
        ('E. parse 专用路径',
         f'/v1/playback/parse/{ticket}'),
        ('F. ticket 路径',
         f'/v1/playback/ticket/{ticket}'),
    ]

    for name, path in tries:
        code, body = req(path)
        print(f'--- {name}')
        print(f'    HTTP {code}')
        print(f'    {brief(body, 260)}')
        print()

    print('=== 对照：普通线（direct）直接可播 ===')
    direct = [o for o in opts if o.get('resolve_required') is not True][:1]
    if direct:
        print('   ', direct[0]['display_label'], '->', direct[0]['url'][:90])


if __name__ == '__main__':
    main()
