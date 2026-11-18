// 用真实接口应答离线验证 kanju.js 的三个入口函数。
//
// 不跑宿主、不联网：把 tools/kanju_resolve_raw.json（第一次 resolve 的
// 真实应答）和 tools/kanju_resolveline_raw.json（换票的真实应答）
// 直接喂给脚本，断言「官方线进清单 / 官方线能出票据 / 票据能换地址」。
//
// 用法：node verify_kanju_js.js

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const HERE = __dirname;
const ROOT = path.resolve(HERE, '../..');
const SCRIPT = path.join(ROOT, 'config/plugins/kanju.js');

const resolveRaw = fs.readFileSync(path.join(HERE, 'kanju_resolve_raw.json'), 'utf8');
const lineRaw = fs.readFileSync(path.join(HERE, 'kanju_resolveline_raw.json'), 'utf8');
const src = fs.readFileSync(SCRIPT, 'utf8');

let pass = 0;
let fail = 0;

function ok(name, cond, extra) {
  if (cond) {
    pass++;
    console.log(`  OK   ${name}`);
  } else {
    fail++;
    console.log(`  FAIL ${name}${extra ? '  → ' + extra : ''}`);
  }
}

// 插件里用到 host.hmac / host.randomHex，给一个够用的假实现
const sandbox = {
  host: {
    hmac: () => 'deadbeef',
    randomHex: (n) => 'a'.repeat((n || 16) * 2),
    b64e: (s) => Buffer.from(s).toString('base64'),
    b64d: (s) => Buffer.from(s, 'base64').toString('utf8'),
  },
  Date,
  JSON,
  console,
};
vm.createContext(sandbox);
vm.runInContext(src, sandbox);

console.log('=== 1. parseLines：官方线是否进清单 ===');
const lines = sandbox.parseLines(resolveRaw, {});
const labels = lines.lines.map((l) => l.line);
console.log(`  线路总数 ${labels.length}`);
ok('线路总数为 33（官方 10 + 普通 23）', labels.length === 33, `实际 ${labels.length}`);
ok('首条是「高清-官方B」（站点原顺序）', labels[0] === '高清-官方B', labels[0]);
ok('第 10 条是「优酷」', labels[9] === '优酷', labels[9]);
ok('第 11 条是「新浪资源」（普通线起点）', labels[10] === '新浪资源', labels[10]);
const official = lines.lines.filter((l) => l.resolveRequired === true);
ok('官方线 10 条都被标记 resolveRequired', official.length === 10, `实际 ${official.length}`);
const directCount = lines.lines.filter((l) => l.direct === true).length;
ok('普通线 23 条标记 direct', directCount === 23, `实际 ${directCount}`);
ok('官方线标记 direct=false', lines.lines[0].direct === false, String(lines.lines[0].direct));
ok('无重名', new Set(labels).size === labels.length, `${new Set(labels).size} vs ${labels.length}`);

console.log('\n=== 2. parseResolve：点官方线是否给出票据 ===');
const r1 = sandbox.parseResolve(resolveRaw, { line: '高清-官方B' });
ok('返回 ticket 而不是 url', typeof r1.ticket === 'string' && r1.ticket.length > 100,
   JSON.stringify(r1).slice(0, 80));
ok('票据不含 resolve:// 前缀', !String(r1.ticket).startsWith('resolve://'), String(r1.ticket).slice(0, 30));
ok('URL 字段为空（不能当直链用）', !r1.url, String(r1.url));

console.log('\n=== 3. parseResolve：点普通线是否直出 ===');
const r2 = sandbox.parseResolve(resolveRaw, { line: '新浪资源' });
ok('返回 http 地址', typeof r2.url === 'string' && r2.url.startsWith('http'), String(r2.url).slice(0, 60));
ok('没有 ticket 字段', !r2.ticket, JSON.stringify(r2).slice(0, 60));

console.log('\n=== 4. parseResolve：不指定线路的兜底 ===');
const r3 = sandbox.parseResolve(resolveRaw, {});
ok('兜底给普通线（不多发一次换票请求）',
   typeof r3.url === 'string' && r3.url.startsWith('http'), JSON.stringify(r3).slice(0, 60));

console.log('\n=== 5. parseLineResolve：换票应答解析 ===');
const r4 = sandbox.parseLineResolve(lineRaw, { line: '高清-官方B' });
ok('取到 https 地址', typeof r4.url === 'string' && r4.url.startsWith('https'), String(r4.url).slice(0, 60));
ok('没有 error', !r4.error, String(r4.error));

console.log('\n=== 6. 边界：坏数据不能抛异常 ===');
for (const [name, fn, body] of [
  ['parseLines(垃圾)', () => sandbox.parseLines('not json', {}), 'not json'],
  ['parseLines(null)', () => sandbox.parseLines(null, {}), 'null'],
  ['parseResolve(垃圾)', () => sandbox.parseResolve('<html>', { line: 'x' }), '<html>'],
  ['parseLineResolve(垃圾)', () => sandbox.parseLineResolve('{', {}), '{'],
  ['parseLineResolve(空对象)', () => sandbox.parseLineResolve('{}', {}), '{}'],
]) {
  let threw = null;
  let out = null;
  try {
    out = fn();
  } catch (e) {
    threw = e;
  }
  ok(`${name} 不抛异常且有返回`, threw === null && out !== null, threw ? String(threw) : '');
}
const r5 = sandbox.parseLineResolve('{}', {});
ok('空应答返回 error 给用户看', typeof r5.error === 'string' && r5.error.length > 0, JSON.stringify(r5));

console.log('\n=== 7. 签名函数仍可用 ===');
const sg = sandbox.sign({ url: 'https://kanju.ai/v1/playback/resolve-line?view=compact', method: 'POST' });
ok('sign 返回 4 个必需头',
   ['x-ai-movie-timestamp', 'x-ai-movie-nonce', 'x-ai-movie-signature',
    'x-ai-movie-protocol-version'].every((h) => sg.headers[h]), JSON.stringify(sg.headers));

console.log(`\n===== 结果：通过 ${pass} / 失败 ${fail} =====`);
process.exit(fail === 0 ? 0 : 1);