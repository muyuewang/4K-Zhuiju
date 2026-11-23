"""批量验证《凡人修仙传》第201集所有线路：官方线换票是否全 401、普通线能否直连。

复用 diag_kanju_401.py 的签名与请求函数。
"""
import json
import sys

sys.path.insert(0, 'code/tools')
import diag_kanju_401 as d

TOKEN = 'av_Vm_OFGxGcdlu1TObNQUDuCxxBUaOc1bTCHe89HVhcL2CQ0K3Rmtgxyv6wLvGixhXi6J1VV7NpHYgStU4RfXlU6E'


def main():
    code, hd, body = d.req('GET', '/v1/playback/resolve/' + TOKEN)
    if code != '200':
        print('resolve 失败', code)
        return
    j = json.loads(body)
    obj = j.get('data', j)
    opts = obj.get('line_options', [])

    ticket_lines = []
    plain_lines = []
    for o in opts:
        label = str(o.get('display_label') or o.get('label') or o.get('provider_name') or '')
        url = str(o.get('url', ''))
        if url.startswith('resolve://'):
            ticket_lines.append((label, url[len('resolve://'):]))
        elif url.startswith('http'):
            plain_lines.append((label, url))

    print(f'总线路 {len(opts)} | 官方票据线 {len(ticket_lines)} | 普通直连线 {len(plain_lines)}')

    print('\n=== 官方线逐条换票 ===')
    codes = {}
    for label, ticket in ticket_lines:
        c, h, b = d.req('POST', '/v1/playback/resolve-line?view=compact',
                        body={'ticket': ticket})
        try:
            jj = json.loads(b)
            err = jj.get('code') or jj.get('message') or ''
            ln = (jj.get('line') or {}).get('url', '')
        except Exception:
            err, ln = b[:60], ''
        codes[c] = codes.get(c, 0) + 1
        print(f'  {label:14s} HTTP {c:3s} | {str(err)[:40]:42s} | 地址 {ln[:40]}')
    print('\n换票状态码统计:', codes)

    print('\n=== 普通线逐条探活（只发 HEAD /range） ===')
    import subprocess
    ok = 0
    for label, url in plain_lines[:12]:
        cmd = ['curl', '-s', '-o', '/dev/null', '-m', '12', '--proxy', d.PROXY,
               '-w', '%{http_code}', '-r', '0-1023',
               '-H', f'User-Agent: {d.UA}', url]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=20, env=d.clean_env())
            c = p.stdout.strip()
        except Exception:
            c = 'ERR'
        if c == '200':
            ok += 1
        print(f'  {label:14s} HTTP {c:5s} | {url[:60]}')
    print(f'\n普通线前 12 条可播 {ok} 条')


if __name__ == '__main__':
    main()