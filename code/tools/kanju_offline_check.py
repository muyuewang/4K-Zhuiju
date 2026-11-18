"""深挖：带上 playback_source_id 后，官方线是否真的变成可播 url。

上一轮 B/C 都返回 HTTP 200，但只看顶层键不能下结论——必须检查
line_options 里那条官方线的 resolved / url_kind / url 有没有变。
这是「官方线能不能救回来」的唯一判据。
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


def req(path, extra=None):
    ts = str(int(time.time() * 1000))
    nonce = secrets.token_hex(16)
    msg = f'GET\n{path}\n{ts}\n{nonce}'
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
    if extra:
        h.update(extra)
    cmd = ['curl', '-s', '-m', '25', '--proxy', PROXY,
           '-w', '\n__C__%{http_code}']
    for k, v in h.items():
        cmd += ['-H', f'{k}: {v}']
    cmd.append(BASE + path)
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=40, env=clean_env())
    b, _, code = p.stdout.rpartition('__C__')
    return code.strip(), b


def dump_lines(tag, body):
    print(f'===== {tag} =====')
    try:
        d = json.loads(body)
    except Exception:
        print('  非 JSON:', body[:200]); return None
    opts = d.get('line_options') or []
    print(f'  line_options: {len(opts)}')
    req_n = sum(1 for o in opts if o.get('resolve_required') is True)
    ok_n = sum(1 for o in opts
               if str(o.get('url', '')).startswith('http'))
    print(f'  仍需解析: {req_n}   已有 http url: {ok_n}')
    for o in opts:
        lab = o.get('display_label', '')
        if o.get('resolve_required') is True or '官方' in lab or '优酷' in lab:
            print(f"    {lab:<14} resolved={o.get('resolved')} "
                  f"kind={o.get('url_kind')} url={str(o.get('url',''))[:60]}")
    return d


def main():
    raw = json.load(open('kanju_resolve_raw.json', encoding='utf-8'))
    ep = raw['token']
    opts = raw['line_options']
    off = [o for o in opts if o.get('resolve_required') is True][0]
    sid = off['playback_source_id']
    pid = off['provider_id']
    print('目标官方线:', off['display_label'], '| provider:', pid)
    print()

    base_body = None
    c, b = req(f'/v1/playback/resolve/{ep}')
    base_body = dump_lines('基线（不带任何参数）', b)

    c, b = req(f'/v1/playback/resolve/{ep}?playback_source_id={sid}')
    dump_lines(f'带 playback_source_id（HTTP {c}）', b)

    c, b = req(f'/v1/playback/resolve/{ep}?provider_id={pid}')
    dump_lines(f'带 provider_id（HTTP {c}）', b)

    both = f'/v1/playback/resolve/{ep}?provider_id={pid}&playback_source_id={sid}'
    c, b = req(both)
    dump_lines(f'两个都带（HTTP {c}）', b)

    print()
    print('=== 结论判据 ===')
    print('若上面任何一组的官方线 resolved=True 且 url 以 http 开头，')
    print('说明官方线不需要新能力，只是插件把参数丢掉了。')


if __name__ == '__main__':
    main()
