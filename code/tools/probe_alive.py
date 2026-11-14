"""检查现有已接入采集源的存活度。

「转化率」的另一面不是能接多少，而是接了之后有多少还活着。
采集站域名寿命普遍只有几周~几个月，这份体检比再扫 300 个死站有用。
"""
import json, re, ssl, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

CTX=ssl.create_default_context(); CTX.check_hostname=False; CTX.verify_mode=ssl.CERT_NONE
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36"

SOURCES = [
 ("dytt 电影天堂","http://caiji.dyttzyapi.com/api.php/provide/vod/from/dyttm3u8/at/json/"),
 ("guangsu 光速","https://api.guangsuapi.com/api.php/provide/vod/"),
 ("ffzy 非凡","http://cj.ffzyapi.com/api.php/provide/vod/"),
 ("maoyan 猫眼","https://api.maoyanapi.top/api.php/provide/vod"),
 ("lziapi 量子","https://cj.lziapi.com/api.php/provide/vod/"),
 ("suoni 索尼","https://suoniapi.com/api.php/provide/vod/"),
 ("qdys2 奇点","https://www.qdys2.cc/api.php/provide/vod/"),
 ("jinying 金鹰","https://jyzyapi.com/provide/vod/"),
 ("wujin 无尽","https://api.wujinapi.com/api.php/provide/vod/"),
 ("yzzy 优子","https://api.yzzyapi.com/api.php/provide/vod/"),
 ("jszy 金山","https://jszyapi.com/api.php/provide/vod/"),
 ("bofeng 暴风","https://bfzyapi.com/api.php/provide/vod/"),
]

def get(u, t=15, rd=900000):
    h={"User-Agent":UA,"Accept":"*/*"}
    try:
        o=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=CTX))
        s=time.time()
        with o.open(urllib.request.Request(u,headers=h),timeout=t) as r:
            return r.status, round((time.time()-s)*1000), r.read(rd).decode('utf-8','ignore')
    except urllib.error.HTTPError as e: return e.code,0,""
    except Exception as e: return 0,0,type(e).__name__

def check(item):
    nm, api = item
    st, ms, txt = get(api + '?ac=list&pg=1')
    r={'name':nm,'api':api,'http':st,'ms':ms,'alive':False,'total':None,
       'verdict':'','format':''}
    if not (st==200 and txt):
        r['verdict']='dead:%s'%(st or r.get('err',''))
        return r

    # 两种格式都要认。优子（yzzy）是 XML 站，返回 <rss>，只按 JSON 解析
    # 会把它误判成「接口挂了」—— 那是一个已接入的源被误报成故障，
    # 比漏测一个新站危险得多。
    if txt.lstrip().startswith('{'):
        r['format']='json'
        try:
            d=json.loads(txt)
            r['total']=d.get('total')
            items=len(d.get('list') or [])
            r['items']=items
            r['alive']=items>0
            r['verdict']='OK' if r['alive'] else 'empty'
        except Exception:
            r['verdict']='bad_json'
    elif txt.lstrip().startswith('<'):
        r['format']='xml'
        m_rec=re.search(r'recordcount="(\d+)"', txt)
        m_page=re.search(r'pagesize="(\d+)"', txt)
        vids=len(re.findall(r'<video>', txt))
        r['total']=int(m_rec.group(1)) if m_rec else None
        r['items']=vids
        r['page_size']=int(m_page.group(1)) if m_page else None
        r['alive']=vids>0
        r['verdict']='OK' if r['alive'] else 'empty'
    else:
        r['format']='other'
        r['verdict']='not_json_xml'
    return r

out=[]
with ThreadPoolExecutor(max_workers=8) as ex:
    for f in as_completed([ex.submit(check,s) for s in SOURCES]):
        out.append(f.result())
out.sort(key=lambda r:(0 if r['alive'] else 1, r['ms']))
for r in out:
    print('%-16s %-6s %6sms total=%-8s items=%-4s %s' % (
        r['name'], '存活' if r['alive'] else '异常', r['ms'], r['total'], r.get('items',0), r['verdict']))
n=sum(1 for r in out if r['alive'])
print('\n存活 %d / %d' % (n, len(out)))
json.dump(out, open('dist/probe/alive_check.json','w',encoding='utf-8'), ensure_ascii=False, indent=1)
