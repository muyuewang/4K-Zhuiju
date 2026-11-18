"""实察看剧（kanju.ai）的 resolve 接口，确认官方线到底要求什么。

插件 kanju.js 的 parseLines 直接 continue 掉 resolve_required===true 的线路，
注释说"插件框架没有取址时再发一次请求的能力"。但官方线可能不需要新能力——
只要宿主在 resolve 时带上会话/bearer，服务端就会返回可播 url。
本脚本先看原始应答，不下结论。
"""

import hashlib
import hmac
import json
import os
import secrets
import subprocess
import sys
import time
from urllib.parse import urlparse

KEY = '557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0'
BASE = 'https://kanju.ai'
PROXY = os.environ.get('KJ_PROXY', 'http://127.0.0.1:7897')
UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')


def clean_env():
    env = dict(os.environ)
    for k in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
              'http_proxy', 'https_proxy', 'all_proxy'):
        env.pop(k, None)
    return env


def sign(method, path_query, ts, nonce):
    msg = f'{method.upper()}\n{path_query}\n{ts}\n{nonce}'
    return hmac.new(KEY.encode(), msg.encode(), hashlib.sha256).hexdigest()


def req(path, extra_headers=None, method='GET', body=None):
    ts = str(int(time.time() * 1000))
    nonce = secrets.token_hex(16)
    sig = sign(method, path, ts, nonce)
    h = {
        'x-ai-movie-timestamp': ts,
        'x-ai-movie-nonce': nonce,
        'x-ai-movie-signature': sig,
        'x-ai-movie-client-name': 'dianyingtiantang-frontend',
        'x-ai-movie-client-version': '1.0.0',
        'x-ai-movie-protocol-version': '2026-07-05.library-v2.playback-v1',
        'Accept': 'application/json',
        'Origin': BASE,
        'Referer': BASE + '/',
        'User-Agent': UA,
    }
    if extra_headers:
        h.update(extra_headers)
    cmd = ['curl', '-s', '-m', '25', '-X', method,
           '--proxy', PROXY,
           '-w', '\n__CODE__%{http_code}']
    for k, v in h.items():
        cmd += ['-H', f'{k}: {v}']
    if body:
        cmd += ['-H', 'Content-Type: application/json', '-d', body]
    cmd.append(BASE + path)
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=40, env=clean_env())
    return p.stdout, p.stderr


def main():
    print('=== 1) 首页 feed，拿一个 id ===')
    out, err = req('/v1/feed/home?scope=public&mode=page&sections=3&cards=12')
    body, _, code = out.rpartition('__CODE__')
    print('HTTP', code.strip())
    try:
        d = json.loads(body)
    except Exception:
        print(body[:400]); return
    cards = d.get('cards') or []
    if not cards:
        for s in d.get('sections') or []:
            cards += s.get('cards') or []
    if not cards:
        print('无 cards'); return
    cid = cards[0].get('id')
    print('取到剧:', cards[0].get('title'), '| id =', cid)

    print('\n=== 2) 详情，拿 token ===')
    out, err = req(f'/v1/catalog/{cid}')
    body, _, code = out.rpartition('__CODE__')
    print('HTTP', code.strip())
    d = json.loads(body)
    eps = d.get('episodes') or []
    print('集数:', len(eps))
    if not eps:
        print(json.dumps(d, ensure_ascii=False)[:600]); return
    tok = eps[0].get('token')
    print('第一集 token:', tok)

    print('\n=== 3) resolve 第一集（看 line_options 全貌）===')
    out, err = req(f'/v1/playback/resolve/{tok}')
    body, _, code = out.rpartition('__CODE__')
    print('HTTP', code.strip())
    d = json.loads(body)
    print('顶层键:', list(d.keys()))
    print('code:', d.get('code'), '| code_str:', d.get('code_str'))

    opts = d.get('line_options') or []
    print('line_options 总数:', len(opts))
    need, direct = [], []
    for o in opts:
        (need if o.get('resolve_required') is True else direct).append(o)
    print(f'  需二次解析(官方线): {len(need)}')
    print(f'  直出(普通线): {len(direct)}')

    print('\n--- 官方线样本（前 4 条完整字段）---')
    for o in need[:4]:
        print(json.dumps(o, ensure_ascii=False, indent=2)[:700])
    print('\n--- 直出线样本（前 2 条）---')
    for o in direct[:2]:
        print(json.dumps(o, ensure_ascii=False)[:400])

    with open('kanju_resolve_raw.json', 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    print('\n原始应答已存 kanju_resolve_raw.json')


if __name__ == '__main__':
    sys.exit(main())
