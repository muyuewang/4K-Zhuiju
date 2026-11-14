import json, ssl, time, urllib.request, urllib.error, re
from concurrent.futures import ThreadPoolExecutor, as_completed

CTX=ssl.create_default_context(); CTX.check_hostname=False; CTX.verify_mode=ssl.CERT_NONE
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36"

def get(u, t=8, rd=600000):
    h={"User-Agent":UA,"Accept":"*/*","Accept-Language":"zh-CN,zh;q=0.9"}
    try:
        o=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=CTX))
        s=time.time()
        with o.open(urllib.request.Request(u,headers=h),timeout=t) as r:
            return r.status, round((time.time()-s)*1000), r.read(rd).decode('utf-8','ignore')
    except urllib.error.HTTPError as e: return e.code,0,""
    except Exception as e: return 0,0,type(e).__name__

# 候选：dex 里出现的影视站（排除网盘/CDN/统计）
CANDS = """www.meijutt.tv www.meijumi.xyz www.xb6v.com www.80sgod.com www.yjys.me
v.ikanbot.com seedhub.info www.kuba222.com luosz.top xunlei8.top so.252035.xyz
su.haotv.site dflm.top aaso.cc www.22a5.com www.slf4j.org img.51shazhu.com
freevideo.zqqds.cn danmu.huaqi.pro danmu.zxz.ee dm.ruyijx.com dmku.hls.one
b.funletu.com my.ksust.com api.uuuka.com""".split()

def probe(h):
    host = h
    base = 'https://' + host
    rec = {'host': host, 'scheme':'https', 'list_code':0, 'list_ms':0, 'total':None,
           'items':0, 'json':False, 'root_code':0, 'maccms':0, 'verdict':''}
    # 1) API 探测
    st, ms, txt = get(base + '/api.php/provide/vod/?ac=list')
    rec['list_code']=st; rec['list_ms']=ms
    if st==200 and txt:
        try:
            d=json.loads(txt)
            rec['json']=True
            rec['total']=d.get('total')
            rec['items']=len(d.get('list') or [])
            if rec['items']:
                lst=d['list']
                rec['sample']=lst[0].get('vod_name','')
                rec['verdict']='API_OK'
                return rec
        except Exception:
            pass
    # http 回退
    if st==0:
        st2, ms2, txt2 = get('http://' + host + '/api.php/provide/vod/?ac=list')
        rec['http_list_code']=st2
        if st2==200 and txt2:
            try:
                d=json.loads(txt2); rec['scheme']='http'; rec['json']=True
                rec['total']=d.get('total'); rec['items']=len(d.get('list') or [])
                if rec['items']:
                    rec['sample']=d['list'][0].get('vod_name','')
                    rec['verdict']='API_OK'
                    return rec
            except Exception:
                pass
    # 2) 根路径 HTML 判定
    st3, ms3, html = get(base + '/', rd=150000)
    rec['root_code']=st3
    if st3==200 and html:
        marks=['/voddetail/','/vodplay/','vodsearch','maccms','/vodtype/','template/']
        low=html.lower()
        rec['maccms']=sum(1 for m in marks if m in low)
        title=re.search(r'<title[^>]*>(.*?)</title>', html, re.S|re.I)
        rec['title']=(title.group(1).strip()[:30] if title else '')
        if rec['maccms']>=2: rec['verdict']='HTML_MACCMS'
        else: rec['verdict']='no_maccms'
    else:
        rec['verdict']='dead'
    return rec

out=[]
with ThreadPoolExecutor(max_workers=16) as ex:
    futs={ex.submit(probe,h):h for h in CANDS}
    for f in as_completed(futs):
        try: r=f.result()
        except Exception as e: r={'host':futs[f],'verdict':'exc:%s'%type(e).__name__}
        out.append(r)

order={'API_OK':0,'HTML_MACCMS':1,'no_maccms':2,'dead':3}
out.sort(key=lambda r:(order.get(r.get('verdict'),9), r.get('list_ms',9999)))
json.dump(out, open('dist/probe/dex_hosts_probe.json','w',encoding='utf-8'), ensure_ascii=False, indent=1)
for r in out:
    print('%-24s %-12s list=%-4s %5sms json=%s total=%s items=%s root=%s mac=%s %s' % (
        r.get('host','')[:24], r.get('verdict',''), r.get('list_code'), r.get('list_ms'),
        r.get('json'), r.get('total'), r.get('items'), r.get('root_code'),
        r.get('maccms'), r.get('title') or r.get('sample','')))
