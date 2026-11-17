#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""18 源全接口联网探针。

复刻 App 内 prepareRequest 的拼装逻辑，对 config/plugins/index.json 里
每个源打 home/list/search/detail 四类接口，记录：
  - HTTP 状态、耗时、响应字节数
  - 解析出的条目数（JSON 走 list/data，XML 走 <video>）
  - 详情里抽出的线路数 / 首集 m3u8
并对首集 m3u8 发一次 Range 请求，判断「源站响应超时」到底是采集接口
挂了还是视频 CDN 挂了。

只读探针，不修改任何源配置。断网/超时的源标记后继续，不中断整轮。
"""
import json, sys, time, urllib.parse, urllib.request, urllib.error, re, ssl, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INDEX = os.path.join(ROOT, 'config', 'plugins', 'index.json')
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

TIMEOUT = 25
KW = '庆余年'  # 通用热词，几乎所有站都有


def fill(t, params):
    s = str(t)
    for k, v in params.items():
        s = s.replace('{' + k + '}', str(v))
    return s


def build_url(pl, req, params):
    base = pl['baseUrl'].strip()
    path = fill(req.get('path', ''), params)
    if path.startswith('http://') or path.startswith('https://'):
        full = path
    else:
        full = urllib.parse.urljoin(base.rstrip('/') + '/', path.lstrip('/'))
    u = urllib.parse.urlsplit(full)
    qp = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True))
    for k, v in (req.get('query') or {}).items():
        qp[k] = fill(v, params)
    query = urllib.parse.urlencode(qp)
    return urllib.parse.urlunsplit((u.scheme, u.netloc, u.path, query, ''))


def fetch(url, method='GET', headers=None, body=None, timeout=TIMEOUT):
    hdr = {'User-Agent': UA}
    for k, v in (headers or {}).items():
        if k.lower() in ('host', 'cookie', 'authorization'):
            continue
        hdr[k] = v
    data = None
    if body is not None:
        if isinstance(body, str):
            data = body.encode('utf-8')
            hdr.setdefault('Content-Type', 'application/json')
        else:
            data = body
    r = urllib.request.Request(url, data=data, headers=hdr, method=method)
    t0 = time.time()
    try:
        with urllib.request.urlopen(r, timeout=timeout, context=CTX) as resp:
            raw = resp.read()
            return {
                'status': resp.status,
                'ms': int((time.time() - t0) * 1000),
                'size': len(raw),
                'text': raw.decode('utf-8', 'replace'),
                'raw': raw,
            }
    except urllib.error.HTTPError as e:
        raw = e.read()
        return {'status': e.code, 'ms': int((time.time() - t0) * 1000),
                'size': len(raw), 'text': raw.decode('utf-8', 'replace'), 'raw': raw}
    except Exception as e:
        return {'status': -1, 'ms': int((time.time() - t0) * 1000),
                'size': 0, 'text': '', 'error': type(e).__name__ + ': ' + str(e)[:120], 'raw': b''}


def count_items(script, text):
    if script.endswith('maccms-xml.js'):
        return len(re.findall(r'<video\b', text))
    # JSON
    try:
        d = json.loads(text)
    except Exception:
        return None
    for key in ('list', 'data', 'cards', 'videos'):
        v = d.get(key) if isinstance(d, dict) else None
        if isinstance(v, list):
            return len(v)
        if isinstance(v, dict):
            for k2 in ('list', 'video'):
                if isinstance(v.get(k2), list):
                    return len(v.get(k2))
    if isinstance(d, list):
        return len(d)
    return 0


def extract_play_urls(text, script):
    """从详情响应里尽量抽出 m3u8/mp4，返回 (线路数, 样例地址列表)。"""
    urls = []
    if script.endswith('maccms-json.js') or script.endswith('maccms-xml.js'):
        for m in re.finditer(r'(?:https?:)?//[^\s"\'<>#$]+\.m3u8[^\s"\'<>#$]*', text):
            u = m.group(0)
            if u.startswith('//'):
                u = 'https:' + u
            urls.append(u)
    else:
        for m in re.finditer(r'https?://[^\s"\'<>]+\.(?:m3u8|mp4)[^\s"\'<>]*', text):
            urls.append(m.group(0))
    # 去重保序
    seen, out = set(), []
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return len(out), out[:3]


def probe_one(pl):
    pid = pl['id']
    script = pl.get('script', '').split('/')[-1]
    res = {'id': pid, 'name': pl['name'], 'group': pl.get('group', ''),
           'baseUrl': pl['baseUrl'], 'script': script, 'api': {}}
    hdr = pl.get('defaultHeaders') or {}
    first_cat = ''
    for c in pl.get('categories', []):
        if c.get('id'):
            first_cat = c['id']
            break

    # ---- home ----
    if pl.get('home'):
        url = build_url(pl, pl['home'], {'page': 1, 'category': first_cat})
        r = fetch(url, pl['home'].get('method', 'GET'), hdr,
                  fill(pl['home'].get('body', ''), {'page': 1, 'category': first_cat})
                  if pl['home'].get('body') else None)
        res['api']['home'] = {'url': url, 'status': r['status'], 'ms': r['ms'],
                              'size': r['size'], 'error': r.get('error')}

    # ---- list ----
    first_id = ''
    if pl.get('list'):
        url = build_url(pl, pl['list'], {'page': 1, 'category': first_cat})
        r = fetch(url, pl['list'].get('method', 'GET'), hdr,
                  fill(pl['list'].get('body', ''), {'page': 1, 'category': first_cat})
                  if pl['list'].get('body') else None)
        n = count_items(script, r['text'])
        res['api']['list'] = {'url': url, 'status': r['status'], 'ms': r['ms'],
                              'size': r['size'], 'items': n, 'error': r.get('error')}
        # 抽一个 id 供 detail 用
        ids = re.findall(r'"vod_id"\s*:\s*"?(\d+)"?', r['text'])
        if not ids:
            ids = re.findall(r'<id>(\d+)</id>', r['text'])
        if not ids:
            ids = re.findall(r'"id"\s*:\s*"?([A-Za-z0-9_-]{4,})"?', r['text'])
        if ids:
            first_id = ids[0]

    # ---- search ----
    if pl.get('search'):
        url = build_url(pl, pl['search'], {'page': 1, 'keyword': urllib.parse.quote(KW),
                                           'category': first_cat})
        r = fetch(url, pl['search'].get('method', 'GET'), hdr,
                  fill(pl['search'].get('body', ''),
                       {'page': 1, 'keyword': KW, 'category': first_cat})
                  if pl['search'].get('body') else None)
        n = count_items(script, r['text'])
        res['api']['search'] = {'url': url, 'status': r['status'], 'ms': r['ms'],
                                'size': r['size'], 'items': n, 'error': r.get('error')}

    # ---- detail + 播放连通 ----
    if pl.get('detail') and first_id:
        url = build_url(pl, pl['detail'], {'id': first_id, 'category': first_cat})
        r = fetch(url, pl['detail'].get('method', 'GET'), hdr,
                  fill(pl['detail'].get('body', ''), {'id': first_id})
                  if pl['detail'].get('body') else None)
        nlines, samples = extract_play_urls(r['text'], script)
        entry = {'url': url, 'id': first_id, 'status': r['status'], 'ms': r['ms'],
                 'size': r['size'], 'playUrls': nlines, 'samples': samples,
                 'error': r.get('error')}
        # Range 探测第一个样例地址（跳过需要签名的非常规线路）
        if samples:
            vu = samples[0].replace('\\/', '/')
            vr = fetch(vu, 'GET', {**hdr, 'Range': 'bytes=0-1023'}, None, timeout=15)
            entry['videoProbe'] = {'status': vr['status'], 'ms': vr['ms'],
                                   'size': vr['size'], 'error': vr.get('error')}
        res['api']['detail'] = entry
    elif pl.get('detail'):
        res['api']['detail'] = {'error': 'no_first_id_from_list'}

    return res


def main():
    data = json.load(open(INDEX, encoding='utf-8'))
    plugins = data['plugins']
    out = []
    for i, pl in enumerate(plugins, 1):
        print(f'[{i:02d}/{len(plugins)}] {pl["id"]:10s} {pl["name"]}', flush=True)
        try:
            out.append(probe_one(pl))
        except Exception as e:
            out.append({'id': pl['id'], 'fatal': type(e).__name__ + ': ' + str(e)[:200]})
    outpath = os.path.join(ROOT, 'dist', 'probe_report.json')
    os.makedirs(os.path.dirname(outpath), exist_ok=True)
    with open(outpath, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print('\n报告:', outpath)

    # 摘要
    print('\n' + '=' * 100)
    print(f'{"ID":10s} {"名称":14s} | {"list":>18s} | {"search":>18s} | {"detail":>18s} | 视频')
    print('-' * 100)
    for r in out:
        if 'fatal' in r:
            print(f'{r["id"]:10s} FATAL {r["fatal"]}')
            continue
        a = r['api']
        def cell(k):
            v = a.get(k)
            if not v:
                return '-'
            st = v.get('status', '?')
            ms = v.get('ms', '?')
            extra = ''
            if 'items' in v:
                extra = f' n={v["items"]}'
            if 'playUrls' in v:
                extra = f' u={v["playUrls"]}'
            return f'{st}/{ms}ms{extra}'
        vp = a.get('detail', {}).get('videoProbe')
        vs = f'{vp["status"]}/{vp["ms"]}ms' if vp else '-'
        print(f'{r["id"]:10s} {r["name"][:12]:14s} | {cell("list"):>18s} | {cell("search"):>18s} | {cell("detail"):>18s} | {vs}')


if __name__ == '__main__':
    main()
