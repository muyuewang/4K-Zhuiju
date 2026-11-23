"""前后集对比：官方线换票是否在某一集之后升级为登录/门禁（2026-11-23）。

用户报障：凡人修仙传官方线，前几集能看，后面提示 401 要登录。
本脚本建一次匿名会话，对多个集数逐一 resolve + 换官方线票，
打印每集 HTTP 状态、错误码、是否拿到真实地址，定位门禁分界。

用法: python code/tools/diag_kanju_episode_gate.py
"""
import json
import re
import sys

sys.path.insert(0, 'code/tools')
import diag_kanju_401 as d

MOVIE_ID = 'av_P-2fvsUWEahkU1ofbAB1UZI7ehaRWVSzZKiwoEzs1_oIaPbKzyKBl17pziV2cPhM9pFDJhgikk983lI'
SAMPLE = (1, 2, 3, 5, 10, 20, 50, 80, 100, 150, 180, 200, 201)


def find_episodes(obj):
    """递归找最大的「剧集数组」：元素同时带 token 类字段与集数字段。"""
    best = []

    def walk(x, depth=0):
        nonlocal best
        if depth > 10:
            return
        if isinstance(x, list):
            cand = [e for e in x if isinstance(e, dict)
                    and any(k in e for k in ('token', 'episode_token', 'playback_id'))
                    and any(k in e for k in ('number', 'key', 'title', 'name', 'episode'))]
            if len(cand) > len(best):
                best = cand
            for v in x:
                walk(v, depth + 1)
        elif isinstance(x, dict):
            for v in x.values():
                walk(v, depth + 1)

    walk(obj)
    return best


def ep_num(e):
    n = e.get('number')
    if n is None:
        m = re.search(r'(\d+)', str(e.get('title') or e.get('name') or e.get('key') or ''))
        n = int(m.group(1)) if m else 0
    try:
        return int(n)
    except Exception:
        return 0


def anonymous_cookie():
    code, hd, body = d.req('POST', '/v1/users/anonymous', body={})
    for line in hd.splitlines():
        if 'set-cookie:' in line.lower() and 'ai_movie_session=' in line:
            m = re.search(r'ai_movie_session=([^;]+)', line)
            if m and len(m.group(1)) > 10:
                print(f'匿名会话 HTTP {code}')
                return 'ai_movie_session=' + m.group(1)
    print(f'匿名会话 HTTP {code}，未拿到 cookie')
    return ''


def main():
    code, hd, body = d.req('GET', '/v1/catalog/' + MOVIE_ID)
    print(f'详情 HTTP {code}')
    if code != '200':
        print(body[:200])
        return
    j = json.loads(body)
    obj = j.get('data', j)
    eps = find_episodes(obj)
    print(f'找到剧集节点 {len(eps)} 个')
    if not eps:
        print('详情顶层 keys:', list(obj.keys()) if isinstance(obj, dict) else type(obj))
        return
    eps = sorted(eps, key=ep_num)
    print('集数范围:', ep_num(eps[0]), '~', ep_num(eps[-1]))
    by_num = {}
    for e in eps:
        by_num.setdefault(ep_num(e), e)

    cookie = '' if '--no-cookie' in sys.argv else anonymous_cookie()
    print('本次' + ('不携带' if not cookie else '携带') + '匿名会话 cookie')

    print('\n集数 | 线路 | 换票HTTP | 错误码 | 真实地址')
    print('-' * 90)
    for n in SAMPLE:
        e = by_num.get(n)
        if not e:
            print(f'{n:4d} | (无此集节点)')
            continue
        tok = e.get('token') or e.get('episode_token') or e.get('playback_id')
        if not tok:
            print(f'{n:4d} | (无 token)')
            continue
        c, h, b = d.req('GET', '/v1/playback/resolve/' + str(tok),
                        extra_headers={'Cookie': cookie} if cookie else None)
        if c != '200':
            print(f'{n:4d} | resolve HTTP {c} | {b[:60]}')
            continue
        rj = json.loads(b)
        robj = rj.get('data', rj)
        opts = robj.get('line_options', [])
        official = [o for o in opts if str(o.get('url', '')).startswith('resolve://')]
        if not official:
            plain = [o for o in opts if str(o.get('url', '')).startswith('http')]
            print(f'{n:4d} | 无官方线(总{len(opts)}条, 普通{len(plain)}条)')
            continue
        o = official[0]
        label = str(o.get('display_label') or o.get('label') or o.get('provider_name') or '')
        ticket = str(o['url'])[len('resolve://'):]
        c2, h2, b2 = d.req('POST', '/v1/playback/resolve-line?view=compact',
                           body={'ticket': ticket},
                           extra_headers={'Cookie': cookie} if cookie else None)
        try:
            jj = json.loads(b2)
            err = str(jj.get('code') or jj.get('message') or '')[:40]
            url = str((jj.get('line') or {}).get('url', ''))
        except Exception:
            err, url = b2[:40], ''
        flag = 'OK ' + url[8:48] if url.startswith('http') else '--'
        print(f'{n:4d} | {label[:12]:12s} | {c2:3s} | {err:40s} | {flag}')


if __name__ == '__main__':
    main()
