// 用真实响应体对拍 juzong.js 的解析结果。
// node code/tools/verify_juzong.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '../..');
const code = fs.readFileSync(path.join(root, 'config/plugins/juzong.js'), 'utf8');
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(code, sandbox);

const ctx = {
  vars: {
    plainLineHints: 'XG,BF,DY,WJ,WS,蓝光,专线',
    ticketLineHints: '独家,维护',
    webLineNames: '鹅播,爱播,酷播,芒果,腾讯,爱奇艺,优酷,B站,搜狐',
    detailLinkPattern: 'href="/voddetail/(\\d+)/"',
  },
  baseUrl: 'https://www.juzong01.me',
};

const fx = (n) => fs.readFileSync(path.join(root, 'code/flutter_app/test/fixtures', n), 'utf8');
const label = (t) => console.log('\n=== ' + t + ' ===');

// ---- 列表（JSON 接口） ----
label('parseList  JSON  tid=6');
const list = sandbox.parseList(fx('juzong_list.json'), ctx);
console.log('items =', list.items.length);
console.log('缺封面:', list.items.filter((x) => !x.pic).length,
  ' 缺 id:', list.items.filter((x) => !/^\d+$/.test(x.id)).length,
  ' 缺名:', list.items.filter((x) => !x.name).length);
list.items.slice(0, 3).forEach((it) => console.log('  ', JSON.stringify(it)));
const dirty = list.items.filter((x) => /&nbsp;|&#\d+;|\r|\n/.test(JSON.stringify(x)));
console.log('含未清洗实体/换行的条目:', dirty.length);

// ---- 搜索（HTML 页，需 Cookie 挑战，已抓成夹具） ----
label('parseList  HTML 搜索 色戒');
const search = sandbox.parseList(fx('juzong_search.html'), ctx);
console.log('items =', search.items.length);
console.log('缺封面:', search.items.filter((x) => !x.pic).length,
  ' 站标误判:', search.items.filter((x) => /icon_\d+\.png|statics?\//.test(x.pic)).length);
search.items.forEach((it) => console.log('  ', it.id, it.name, '|', it.pic ? it.pic.slice(-32) : '(无封面)',
  '|', it.year, '|', it.remark));

// ---- 详情 ----
label('parseDetail  106');
const det = sandbox.parseDetail(fx('juzong_detail.html'), ctx);
console.log('id     =', det.id, ' name =', det.name);
console.log('area   =', det.area, ' year =', det.year, ' remark =', det.remark);
console.log('pic    =', det.pic);
console.log('director =', det.director, '| actor =', String(det.actor).slice(0, 50));
console.log('content 长度 =', String(det.content).length);
console.log('线路数 =', det.lines.length);
det.lines.forEach((l) => {
  const f = l.episodes[0] || {};
  console.log('  线路', l.line, '|', l.episodes.length, '集 | 首集', f.name, '->', String(f.url).slice(0, 58));
});
const total = det.lines.reduce((a, l) => a + l.episodes.length, 0);
console.log('总集数 =', total);

// ---- 取址：明文线 ----
label('parseResolve  明文线 line7');
const plain = sandbox.parseResolve(fx('juzong_play_plain.html'), ctx);
console.log(JSON.stringify(plain));

// ---- 取址：票据线 ----
label('parseResolve  票据线 line1');
const ticket = sandbox.parseResolve(fx('juzong_play_ticket.html'), ctx);
console.log(JSON.stringify(ticket));