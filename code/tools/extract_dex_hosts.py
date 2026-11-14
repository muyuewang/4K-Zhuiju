import re, glob, os
from collections import Counter

host_re = re.compile(rb'https?://([a-zA-Z0-9][a-zA-Z0-9\-\.]{3,60}\.[a-zA-Z]{2,10})')
junk = ('schemas.android.com','w3.org','apache.org','googleapis.com','gstatic.com',
        'github.com','githubusercontent.com','google.com','android.com','json.org',
        'oracle.com','sun.com','kotlinlang.org','jetbrains.com','example.com',
        'bugly.qq.com','umeng.com','jpush.cn','getui.com',
        'iqiyi.com','qq.com','youku.com','mgtv.com','douban.com','doubanio.com',
        'bilibili.com','bilivideo.com')

all_h = Counter()
files = glob.glob('C:/Users/fengxin/WorkBuddy/vivos7/.tmp/jarx/**/classes.dex', recursive=True)
print('dex 文件数:', len(files))
for dex in files:
    data = open(dex, 'rb').read()
    hs = [h.decode('ascii','ignore').lower() for h in host_re.findall(data)]
    keep = sorted({h for h in hs if not any(j in h for j in junk)})
    name = dex.split('jarx')[1].split('classes')[0].strip('\\/')
    for h in keep: all_h[h] += 1
    print('\n--- %s (%d B) 唯一域名 %d ---' % (name, len(data), len(keep)))
    for h in keep[:40]:
        print('   ', h)

print('\n\n=== 跨包汇总：唯一域名 %d ===' % len(all_h))
for h, c in all_h.most_common(60):
    print('  %2d  %s' % (c, h))
open('C:/Users/fengxin/WorkBuddy/vivos7/.tmp/dex_hosts.txt','w',encoding='utf-8').write('\n'.join(h for h,_ in all_h.most_common()))
