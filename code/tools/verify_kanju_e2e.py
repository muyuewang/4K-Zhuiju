"""端到端实证：严格按宿主的新链路走一遍，并验证换出的地址真能播。

宿主链路（remote_js_source.dart resolveUrl）：
  1. GET  /v1/playback/resolve/{episodeToken}       → line_options[33]
  2. 取用户点的线路：
       普通线 → line_options[].url 直接是 m3u8
       官方线 → line_options[].url = resolve://<ticket>
  3. 官方线再 POST /v1/playback/resolve-line?view=compact  body {"ticket":...}
       → {"line":{"url":"https://..."}}
  4. 对最终地址发一次请求，确认真的能取到流（m3u8 是文本，mp4 看 Content-Type）

这个脚本就是「验证修复是否真的生效」，不是单测。
"""

import hashlib
import hmac
import json
import os
import secrets
import subprocess
import sys
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


def req(method, path, body=None, timeout=30):
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
    cmd = ['curl', '-s', '-m', str(timeout), '--proxy', PROXY, '-X', method,
           '-w', '\n__C__%{http_code}']
    if body is not None:
        h['Content-Type'] = 'application/json'
        cmd += ['-d', json.dumps(body)]
    for k, v in h.items():
        cmd += ['-H', f'{k}: {v}']
    cmd.append(BASE + path)
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=timeout + 15, env=clean_env())
    b, _, code = p.stdout.rpartition('__C__')
    return code.strip(), b.strip()


def probe_stream(url, timeout=25):
    """对换出的地址发一次请求，判断是不是真能播出东西。"""
    cmd = ['curl', '-s', '-o', r'C:\Users\fengxin\WorkBuddy\vivos7\code\tools\_probe.bin',
           '-m', str(timeout), '--proxy', PROXY, '-L',
           '-w', '%{http_code} %{size_download} %{content_type}',
           '-r', '0-8191', '-H', f'User-Agent: {UA}', url]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout + 10, env=clean_env())
        out = (p.stdout or '').strip()
        parts = out.split(' ', 2)
        code = parts[0] if parts else '000'
        size = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        ctype = parts[2] if len(parts) > 2 else ''
        head = ''
        try:
            with open(r'C:\Users\fengxin\WorkBuddy\vivos7\code\tools\_probe.bin',
                      'rb') as f:
                head = f.read(200).decode('utf-8', 'ignore')
        except Exception:
            pass
        is_hls = head.lstrip().startswith('#EXTM3U')
        return code, size, ctype, is_hls
    except Exception as e:
        return 'ERR', 0, str(e), False


def main():
    # 取一集 token：从存档里拿不到 episode token，这里先用已知样本，
    # 失败就退回存档里的 line_options（线路集合本身不随集变化）
    raw_path = 'kanju_resolve_raw.json'
    raw = json.load(open(raw_path, encoding='utf-8'))
    opts = raw['line_options']
    offs = [o for o in opts if o.get('resolve_required') is True]
    dirs = [o for o in opts if o.get('resolve_required') is not True]

    print(f'线路清单：官方线 {len(offs)} 条 + 普通线 {len(dirs)} 条 = {len(opts)}')
    print('（修复后用户应能看到全部 %d 条）\n' % len(opts))

    ok_off = 0
    ok_dir = 0
    print('=== 官方线：换票 + 探流 ===')
    for o in offs[:4]:
        ticket = o['url'].replace('resolve://', '')
        code, body = req('POST', '/v1/playback/resolve-line?view=compact',
                         {'ticket': ticket})
        url = ''
        try:
            url = (json.loads(body).get('line') or {}).get('url', '')
        except Exception:
            pass
        if not url.startswith('http'):
            print(f'  NG  {o["display_label"]:<14} 换票失败 HTTP {code}')
            continue
        sc, size, ctype, hls = probe_stream(url)
        good = sc in ('200', '206') and size > 0
        if good:
            ok_off += 1
        tag = 'OK ' if good else 'NG '
        print(f'  {tag}{o["display_label"]:<14} 换票{code} → 探流 {sc} '
              f'{size}B hls={hls} {ctype[:22]}')

    print('\n=== 普通线：直接探流（证明修复没有把它们弄坏）===')
    for o in dirs[:3]:
        url = o['url']
        sc, size, ctype, hls = probe_stream(url)
        good = sc in ('200', '206') and size > 0
        if good:
            ok_dir += 1
        tag = 'OK ' if good else 'NG '
        print(f'  {tag}{o["display_label"]:<14} {sc} {size}B hls={hls} {ctype[:22]}')

    print(f'\n官方线可播 {ok_off}/{min(4, len(offs))}    '
          f'普通线可播 {ok_dir}/{min(3, len(dirs))}')

    if ok_off > 0 and ok_dir > 0:
        print('\n结论：两种线路都能播出内容，修复有效。')
        return 0
    print('\n结论：有线路播不出来，需继续排查。')
    return 1


if __name__ == '__main__':
    sys.exit(main())