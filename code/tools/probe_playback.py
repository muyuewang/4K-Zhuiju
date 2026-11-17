#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从每个源的真实详情里抽 m3u8，探测视频 CDN 是否可达。

回答用户的核心问题：'源站响应超时'到底是采集接口挂了，还是视频地址挂了。
"""
import json, re, ssl, sys, time, urllib.error, urllib.parse, urllib.request, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INDEX = os.path.join(ROOT, 'config', 'plugins', 'index.json')
REPORT = os.path.join(ROOT, 'dist', 'probe_report.json')
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE


def fetch(url, headers=None, timeout=15, range_bytes=True):
    hdr = {'User-Agent': UA}
    if headers:
        for k, v in headers.items():
            if k.lower() not in ('host', 'cookie', 'authorization'):
                hdr[k] = v
    if range_bytes:
        hdr['Range'] = 'bytes=0-2047'
    req = urllib.request.Request(url, headers=hdr)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            raw = r.read(4096)
            return r.status, int((time.time() - t0) * 1000), len(raw), raw[:200].decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        raw = e.read(200)
        return e.code, int((time.time() - t0) * 1000), 0, raw.decode('utf-8', 'replace')
    except Exception as e:
        return -1, int((time.time() - t0) * 1000), 0, type(e).__name__ + ': ' + str(e)[:80]


def fill(t, p):
    s = str(t)
    for k, v in p.items():
        s = s.replace('{' + k + '}', str(v))
    return s


def build(pl, req, p):
    path = fill(req.get('path', ''), p)
    full = path if path.startswith('http') else urllib.parse.urljoin(pl['baseUrl'].rstrip('/') + '/', path.lstrip('/'))
    u = urllib.parse.urlsplit(full)
    qp = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True))
    for k, v in (req.get('query') or {}).items():
        qp[k] = fill(v, p)
    return urllib.parse.urlunsplit((u.scheme, u.netloc, u.path, urllib.parse.urlencode(qp), ''))


def get_json(url, headers=None):
    hdr = {'User-Agent': UA}
    if headers:
        hdr.update(headers)
    try:
        raw = urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=20, context=CTX).read()
        return json.loads(raw)
    except Exception:
        return None


def extract_urls(text, script):
    """按脚本类型提取候选播放地址，保留线路结构。"""
    out = []
    if script == 'maccms-json.js':
        try:
            d = json.loads(text)
            lst = d.get('list', [])
            if isinstance(lst, list) and lst:
                froms = str(lst[0].get('vod_play_from', '')).split('$$$')
                urls = str(lst[0].get('vod_play_url', '')).split('$$$')
                for i, chunk in enumerate(urls):
                    line = froms[i] if i < len(froms) else 'L%d' % (i + 1)
                    # 每条线路取第一集
                    first = chunk.split('#')[0]
                    u = first.split('$')[-1] if '$' in first else first
                    if u.startswith('http'):
                        out.append((line, u))
        except Exception:
            pass
    elif script == 'maccms-xml.js':
        for m in re.finditer(r'<dd[^>]*flag="([^"]*)"[^>]*>([^<]*)</dd>', text):
            first = m.group(2).split('#')[0]
            u = first.split('$')[-1] if '$' in first else first
            if u.startswith('http'):
                out.append((m.group(1), u))
    else:
        for m in re.finditer(r'https?://[^\s"\'<>\\)]+\.(?:m3u8|mp4)[^\s"\'<>\\)]*', text):
            out.append(('直出', m.group(0)))
    seen, uniq = set(), []
    for line, u in out:
        if u not in seen:
            seen.add(u); uniq.append((line, u))
    return uniq


def main():
    idx = json.load(open(INDEX, encoding='utf-8'))
    report = json.load(open(REPORT, encoding='utf-8'))
    byid = {r['id']: r for r in report}
    results = []
    for pl in idx['plugins']:
        pid = pl['id']
        if not pl.get('detail'):
            continue
        script = pl.get('script', '').split('/')[-1]
        # 复用首轮探针拿到的 first id
        det = byid.get(pid, {}).get('api', {}).get('detail', {})
        fid = det.get('id', '')
        if not fid:
            # 从新请求拿
            continue
        url = build(pl, pl['detail'], {'id': fid})
        hdr = pl.get('defaultHeaders') or {}
        try:
            raw = urllib.request.urlopen(urllib.request.Request(url, headers={**{'User-Agent': UA}, **hdr}),
                                         timeout=20, context=CTX).read().decode('utf-8', 'replace')
        except Exception as e:
            results.append({'id': pid, 'error': str(e)[:80]})
            continue
        urls = extract_urls(raw, script)
        probed = []
        for line, u in urls[:4]:
            st, ms, size, head = fetch(u, hdr)
            probed.append({'line': line, 'url': u[:160], 'status': st, 'ms': ms,
                           'size': size, 'head': head[:100]})
        results.append({'id': pid, 'name': pl['name'], 'detailUrl': url,
                        'candidates': len(urls), 'probes': probed})
        print('[%s] %s 候选=%d' % (pid, pl['name'], len(urls)), flush=True)
        for p in probed:
            print('   %-16s %s/%sms size=%s %s' % (p['line'], p['status'], p['ms'], p['size'], p['url'][:70]), flush=True)
    with open(os.path.join(ROOT, 'dist', 'play_probe_report.json'), 'w', encoding='utf-8') as f:
        json.dump(results, f, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
