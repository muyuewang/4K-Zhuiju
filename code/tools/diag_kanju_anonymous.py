"""决定性实验：匿名会话能否解锁看剧官方线换票（2026-11-23）。

用户提示「看剧能匿名登录」。实测 /v1/users/anonymous 返回 201 +
set-cookie ai_movie_session=ums_xxx。本脚本验证：带着这个 cookie
去 POST resolve-line，原本 401 的官方线是否变成 200。

用法: python code/tools/diag_kanju_anonymous.py
"""
import json
import re
import subprocess
import sys

sys.path.insert(0, 'code/tools')
import diag_kanju_401 as d

TOKEN = 'av_Vm_OFGxGcdlu1TObNQUDuCxxBUaOc1bTCHe89HVhcL2CQ0K3Rmtgxyv6wLvGixhXi6J1VV7NpHYgStU4RfXlU6E'


def anonymous_session():
    """POST /v1/users/anonymous，从 set-cookie 里抠出 ai_movie_session。"""
    code, hd, body = d.req('POST', '/v1/users/anonymous', body={})
    print(f'匿名登录 HTTP {code}')
    cookie = ''
    for line in hd.splitlines():
        if 'set-cookie:' in line.lower() and 'ai_movie_session=' in line:
            m = re.search(r'ai_movie_session=([^;]+)', line)
            if m and m.group(1) and len(m.group(1)) > 10:  # 跳过清空的 Max-Age=0
                cookie = 'ai_movie_session=' + m.group(1)
    print('拿到 cookie:', cookie[:60] + '...' if cookie else '(无)')
    return cookie


def main():
    cookie = anonymous_session()
    if not cookie:
        print('匿名登录没拿到有效 cookie，退出')
        return

    code, hd, body = d.req('GET', '/v1/playback/resolve/' + TOKEN,
                           extra_headers={'Cookie': cookie})
    print(f'\n带 cookie 取线路 HTTP {code}')
    if code != '200':
        print('body:', body[:200])
        return
    j = json.loads(body)
    obj = j.get('data', j)
    opts = obj.get('line_options', [])
    print(f'线路数 {len(opts)}（匿名不带 cookie 时是 34 条）')

    labels = [str(o.get('display_label') or o.get('label') or '')
              for o in opts]
    print('前 15 条线路:', ', '.join(labels[:15]))

    print('\n=== 带 cookie 逐条换官方线 ===')
    codes = {}
    for o in opts:
        url = str(o.get('url', ''))
        label = str(o.get('display_label') or o.get('label') or o.get('provider_name') or '')
        if not url.startswith('resolve://'):
            continue
        ticket = url[len('resolve://'):]
        c, h, b = d.req('POST', '/v1/playback/resolve-line?view=compact',
                        body={'ticket': ticket},
                        extra_headers={'Cookie': cookie})
        try:
            jj = json.loads(b)
            err = jj.get('code') or jj.get('message') or ''
            ln = (jj.get('line') or {}).get('url', '')
        except Exception:
            err, ln = b[:50], ''
        codes[c] = codes.get(c, 0) + 1
        flag = 'OK' if ln.startswith('http') else '--'
        print(f'  {flag} {label:14s} HTTP {c:3s} | {str(err)[:36]:38s} | {ln[:36]}')
    print('\n换票状态码统计:', codes)


if __name__ == '__main__':
    main()