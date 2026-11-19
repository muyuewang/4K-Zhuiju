// 诊断：把真实响应里一条 drama 的 protobuf 字段全部 dump 出来，
// 用来校准 dramaFrom / parseDetail 的字段号。
// node code/tools/diag_zhuiju_fields.js
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

// 独立 protobuf 解析（Node 侧，不受脚本实现影响）
function parse(buf) {
  const out = [];
  let i = 0;
  const readVar = () => {
    let v = 0, sh = 0, b;
    do { b = buf[i++]; v += (b & 0x7f) * Math.pow(2, sh); sh += 7; } while (b & 0x80);
    return v;
  };
  while (i < buf.length) {
    const tag = readVar();
    const no = Math.floor(tag / 8), wt = tag % 8;
    if (no === 0) break;
    if (wt === 0) {
      out.push({ no, wt, v: readVar() });
    } else if (wt === 2) {
      const len = readVar();
      out.push({ no, wt, b: buf.slice(i, i + len) });
      i += len;
    } else if (wt === 5) { out.push({ no, wt, skip: 4 }); i += 4; }
    else if (wt === 1) { out.push({ no, wt, skip: 8 }); i += 8; }
    else break;
  }
  return out;
}

const show = (b) => {
  // 可打印就显示文本，否则显示 hex 前 40
  const t = b.toString('utf8');
  const printable = /^[\x20-\x7e\u4e00-\u9fa5\s，。、：；！？（）《》·—…]*$/.test(t);
  return printable && t.length ? JSON.stringify(t.slice(0, 70)) : 'hex:' + b.toString('hex').slice(0, 40);
};

(async () => {
  const buf = await call('/api/proto/v5/drama/category',
    { typeId1: '21', page: '1', pagesize: '3' });
  console.log('响应字节:', buf.length);

  const top = parse(buf);
  console.log('\n=== ApiResult 顶层 ===');
  for (const f of top) {
    console.log(`  field ${f.no} wt=${f.wt}`, f.wt === 2 ? 'len=' + f.b.length : 'v=' + f.v);
  }

  const dataField = top.find((f) => f.no === 3 && f.wt === 2);
  if (!dataField) { console.log('没有 field 3 (data)'); return; }

  const dataFields = parse(dataField.b);
  console.log('\n=== data 层 ===');
  for (const f of dataFields) {
    console.log(`  field ${f.no} wt=${f.wt}`, f.wt === 2 ? 'len=' + f.b.length : 'v=' + f.v);
  }

  const firstItem = dataFields.find((f) => f.no === 1 && f.wt === 2);
  if (!firstItem) { console.log('没有 field 1 (drama 列表)'); return; }

  console.log('\n=== 第一条 drama 的全部字段 ===');
  for (const f of parse(firstItem.b)) {
    if (f.wt === 0) console.log(`  [${f.no}] varint = ${f.v}`);
    else if (f.wt === 2) {
      // 嵌套？
      const nested = parse(f.b);
      const looksNested = nested.length > 0 && nested.every((n) => n.no > 0 && n.no < 100)
        && nested.some((n) => n.wt === 2 || n.wt === 0)
        && f.b.length > 8;
      if (looksNested && nested.length >= 2) {
        console.log(`  [${f.no}] 嵌套 len=${f.b.length}:`,
          nested.map((n) => `${n.no}:${n.wt === 2 ? show(n.b).slice(0, 50) : n.v}`).join(' | '));
      } else {
        console.log(`  [${f.no}] ${show(f.b)}`);
      }
    }
  }
})().catch((e) => { console.error('失败:', e.message); process.exitCode = 1; });