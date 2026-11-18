// 用真实响应体对拍 sanjiaozhou.js 的解析结果。
// node code/tools/verify_sanjiaozhou.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '../..');
const code = fs.readFileSync(path.join(root, 'config/plugins/sanjiaozhou.js'), 'utf8');
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(code, sandbox);

const ctx = {
  vars: {
    rc4Key: '520720ygq',
    clientUrl: 'http://43.248.117.45:5001/Client/',
  },
  baseUrl: 'http://43.248.117.149:5656',
};

const label = (t) => console.log('\n=== ' + t + ' ===');

// ---- 列表 ----
label('parseList  tvplay');
const listBody = fs.readFileSync(path.join(__dirname, '_sjz_out/list_tvplay.hex'), 'utf8');
const list = sandbox.parseList(listBody, ctx);
console.log('items =', list.items.length);
list.items.slice(0, 3).forEach((it) => console.log('  ', JSON.stringify(it)));
const missingPic = list.items.filter((x) => !x.pic).length;
const missingId = list.items.filter((x) => !/^\d+$/.test(x.id)).length;
console.log('缺封面:', missingPic, ' id 非数字:', missingId);

// ---- 搜索 ----
label('parseList  search 火影');
const search = sandbox.parseList(
  fs.readFileSync(path.join(__dirname, '_sjz_out/search.hex'), 'utf8'),
  ctx
);
console.log('items =', search.items.length);
search.items.slice(0, 3).forEach((it) => console.log('  ', it.name, '|', it.id, '|', it.remark));

// ---- 详情 ----
label('parseDetail');
const det = sandbox.parseDetail(
  fs.readFileSync(path.join(__dirname, '_sjz_out/det.hex'), 'utf8'),
  ctx
);
console.log('name   =', det.name);
console.log('id     =', det.id);
console.log('pic    =', det.pic);
console.log('area   =', det.area, ' year =', det.year);
console.log('remark =', det.remark);
console.log('content 长度 =', det.content.length);
console.log('director =', det.director, '| actor =', det.actor.slice(0, 40));
console.log('线路数 =', det.lines.length);
det.lines.forEach((l) => {
  const first = l.episodes[0] || {};
  console.log(
    '  线路', l.line, '|', l.episodes.length, '集 | 首集', first.name, '->',
    String(first.url).slice(0, 52) + '...'
  );
});

// ---- 播放地址 ----
label('播放地址');
const epUrl = det.lines.length ? det.lines[0].episodes[0].url : '';
console.log('episode url =', epUrl.slice(0, 80) + '...');
console.log('幂等检查    =', sandbox.parseResolve(epUrl, ctx).url === epUrl ? '二次包装已避免' : '❌ 被重复包装');

// ---- 断言 ----
label('断言');
const checks = [];
checks.push(['列表解出条目 >= 15', list.items.length >= 15]);
checks.push(['列表全部有 id', missingId === 0]);
checks.push(['列表全部有封面', missingPic === 0]);
checks.push(['搜索命中 > 0', search.items.length > 0]);
checks.push(['详情剧名非空', det.name.length > 0]);
checks.push(['详情线路 >= 3', det.lines.length >= 3]);
checks.push(['集地址已是代理 http 地址', epUrl.indexOf('http://43.248.117.45:5001/Client/?url=') === 0]);
checks.push(['token 做了百分号编码', /%3D|%2F|%2B/.test(epUrl)]);
checks.push(['parseResolve 不二次包装', sandbox.parseResolve(epUrl, ctx).url === epUrl]);

let bad = 0;
checks.forEach(([t, ok]) => {
  console.log((ok ? '  PASS  ' : '  FAIL  ') + t);
  if (!ok) bad++;
});
console.log('\n结论:', bad === 0 ? '全部通过' : bad + ' 项失败');
process.exit(bad === 0 ? 0 : 1);
