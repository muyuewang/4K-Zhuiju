// 橘汁：逐条线路试取址，统计可播率。
// 目的：告诉用户「哪几条线能播」，避免点一条失败一条。
// node code/tools/probe_zhuiju_lines.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const crypto = require('crypto');

const root = path.resolve(__dirname, '../..');
const BASE = 'http://juziappcc.hzhcbkj.cn';

const host = {
  aesEcbEncrypt({ key, keyFmt = 'utf8', plain, plainFmt = 'utf8', outFmt = 'base64' }) {
    const k = Buffer.from(key, keyFmt === 'hex' ? 'hex' : 'utf8');
    const p = Buffer.from(plain, plainFmt === 'hex' ? 'hex' : 'utf8');
    const c = crypto.createCipheriv('aes-256-ecb', k, null);
    const out = Buffer.concat([c.update(p), c.final()]);
    return outFmt === 'hex' ? out.toString('hex') : out.toString('base64');
  },
  rsaEncrypt({ nHex, e = '65537', data, dataFmt = 'utf8', outFmt = 'base64' }) {
    const key = crypto.createPublicKey({
      key: {
        kty: 'RSA',
        n: Buffer.from(nHex, 'hex').toString('base64url'),
        e: Buffer.from([0x01, 0x00, 0x01]).toString('base64url'),
      },
      format: 'jwk',
    });
    const out = crypto.publicEncrypt(
      { key, padding: crypto.constants.RSA_PKCS1_PADDING },
      Buffer.from(data, dataFmt === 'hex' ? 'hex' : 'utf8'));
    return outFmt === 'hex' ? out.toString('hex') : out.toString('base64');
  },
  randomAlnum(n) {
    const chars = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    const b = crypto.randomBytes(n);
    let s = '';
    for (let i = 0; i < n; i++) s += chars[b[i] % chars.length];
    return s;
  },
  hex(text, fmt) { return Buffer.from(text, fmt === 'hex' ? 'hex' : 'utf8').toString('hex'); },
  b64e(s, fmt) { return Buffer.from(s, fmt === 'hex' ? 'hex' : 'utf8').toString('base64'); },
  b64d(s, fmt = 'utf8') {
    const b = Buffer.from(s, 'base64');
    return fmt === 'hex' ? b.toString('hex') : b.toString('utf8');
  },
};

const code = fs.readFileSync(path.join(root, 'config/plugins/zhuiju.js'), 'utf8');
const sandbox = { host, console };
vm.createContext(sandbox);
vm.runInContext(code, sandbox);
const ctx = { baseUrl: BASE, vars: {}, sourceId: 'zhuiju' };

async function call(pathname, query) {
  const url = `${BASE}${pathname}?${new URLSearchParams(query).toString()}`;
  const signed = sandbox.sign({ url, method: 'POST', query, headers: {}, body: '', vars: {}, ctx });
  const res = await fetch(url, {
    method: 'POST', headers: signed.headers,
    body: Buffer.from(signed.body || '', 'hex'),
  });
  return Buffer.from(await res.arrayBuffer());
}

(async () => {
  // 用一部电影，线路少、验证快
  const listBuf = await call('/api/proto/v5/drama/category',
    { typeId1: '20', page: '1', pagesize: '3' });
  const l = sandbox.parseList(listBuf.toString('base64'), ctx);
  const drama = l.items[0];
  console.log('测试剧目:', drama.name, '(', drama.id, ')\n');

  const detBuf = await call('/api/proto/v5/drama/getDetail', { id: drama.id });
  const det = sandbox.parseDetail(detBuf.toString('base64'),
    { ...ctx, dramaId: drama.id });
  console.log('线路数:', det.lines.length, '\n');

  let ok = 0, fail = 0;
  for (const line of det.lines) {
    const ep = line.episodes[0];
    if (!ep) continue;
    try {
      const r = await call('/api/proto/v5/videoUsableUrl',
        { vodPlayFrom: line.line, playUrl: ep.url || ep.token });
      const rv = sandbox.parseResolve(r.toString('base64'), { ...ctx, line: line.line });
      const good = rv.url && rv.url.indexOf('http') === 0;
      if (good) {
        ok++;
        const kind = /\.m3u8/.test(rv.url) ? 'm3u8' : (/\.mp4/.test(rv.url) ? 'mp4' : '其它');
        console.log(`  ✓ ${line.line.padEnd(12)} ${line.episodes.length}集  ${kind}  ${rv.url.slice(0, 52)}…`);
      } else {
        fail++;
        console.log(`  ✗ ${line.line.padEnd(12)} ${line.episodes.length}集  ${rv.error || '(空地址)'}`);
      }
    } catch (e) {
      fail++;
      console.log(`  ✗ ${line.line.padEnd(12)} 请求异常: ${e.message}`);
    }
  }
  console.log(`\n可播 ${ok} / ${ok + fail}`);
})().catch((e) => { console.error('失败:', e.message); process.exitCode = 1; });