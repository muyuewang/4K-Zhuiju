// 橘汁源的端到端联网验证：用脚本自己的 sign() 签发请求，打到真实接口。
//
// 为什么必须做这一步：橘汁的所有接口都要求 `publicParams` 签名头，
// 缺它服务端只回 `code=500 公共参数请求头不能为空`。域名对不对、
// 签名算得对不对，光看解析函数是看不出来的 —— 只有真发一次才知道。
//
// node code/tools/verify_zhuiju.js
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const crypto = require('crypto');

const root = path.resolve(__dirname, '../..');
const BASE = 'http://juziappcc.hzhcbkj.cn';

// ---------- 复刻宿主注入的加密原语（与 plugin_host_api.dart 对齐） ----------

function hexToBytes(h) { return Buffer.from(h, 'hex'); }

const host = {
  // AES-ECB + PKCS7，与 Dart 侧 ECBBlockCipher + _pkcs7Pad 一致
  aesEcbEncrypt({ key, keyFmt = 'utf8', plain, plainFmt = 'utf8', outFmt = 'base64' }) {
    const k = Buffer.from(key, keyFmt === 'hex' ? 'hex' : 'utf8');
    const p = Buffer.from(plain, plainFmt === 'hex' ? 'hex' : 'utf8');
    const c = crypto.createCipheriv('aes-256-ecb', k, null);
    c.setAutoPadding(true); // 默认 PKCS7
    const out = Buffer.concat([c.update(p), c.final()]);
    return outFmt === 'hex' ? out.toString('hex') : out.toString('base64');
  },
  // RSA PKCS#1 v1.5，模数 1024 位
  rsaEncrypt({ nHex, e = '65537', data, dataFmt = 'utf8', outFmt = 'base64' }) {
    const nBuf = hexToBytes(nHex);
    const eBuf = Buffer.from([0x01, 0x00, 0x01]); // 65537
    const key = crypto.createPublicKey({
      key: {
        kty: 'RSA',
        n: nBuf.toString('base64url'),
        e: eBuf.toString('base64url'),
      },
      format: 'jwk',
    });
    const d = Buffer.from(data, dataFmt === 'hex' ? 'hex' : 'utf8');
    const out = crypto.publicEncrypt(
      { key, padding: crypto.constants.RSA_PKCS1_PADDING }, d);
    return outFmt === 'hex' ? out.toString('hex') : out.toString('base64');
  },
  randomAlnum(n) {
    const chars = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    const b = crypto.randomBytes(n);
    let s = '';
    for (let i = 0; i < n; i++) s += chars[b[i] % chars.length];
    return s;
  },
  hex(text, fmt) {
    return Buffer.from(text, fmt === 'hex' ? 'hex' : 'utf8').toString('hex');
  },
  b64e(s, fmt) {
    return Buffer.from(s, fmt === 'hex' ? 'hex' : 'utf8').toString('base64');
  },
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

// ---------- 一次真实的签名请求 ----------

async function call(pathname, query) {
  const qs = new URLSearchParams(query).toString();
  const url = `${BASE}${pathname}?${qs}`;

  const signed = sandbox.sign({
    url, method: 'POST', query,
    headers: {}, body: '', vars: {}, ctx,
  });

  const bodyBuf = hexToBytes(signed.body || '');
  const res = await fetch(url, {
    method: 'POST',
    headers: signed.headers,
    body: bodyBuf,
  });
  const buf = Buffer.from(await res.arrayBuffer());
  return { status: res.status, bytes: buf };
}

function pbHead(buf) {
  // ApiResult{code=1 varint, msg=2 string}
  let i = 0, out = { code: null, msg: '' };
  try {
    // field 1
    if (buf[i] === 0x08) {
      i++; let v = 0, sh = 0, b;
      do { b = buf[i++]; v |= (b & 0x7f) << sh; sh += 7; } while (b & 0x80);
      out.code = v;
    }
    // field 2
    if (buf[i] === 0x12) {
      i++; const ln = buf[i++];
      out.msg = buf.slice(i, i + ln).toString('utf8');
    }
  } catch (e) { /* 非 ApiResult，忽略 */ }
  return out;
}

const err = (m) => console.log('  ✗ ' + m);

(async () => {
  console.log('=== 1. 分类列表 typeId1=21 (电视剧) ===');
  const cat = await call('/api/proto/v5/drama/category',
    { typeId1: '21', page: '1', pagesize: '20' });
  console.log('  HTTP', cat.status, '| 字节', cat.bytes.length);
  const h1 = pbHead(cat.bytes);
  console.log('  code =', h1.code, '| msg =', h1.msg || '(空)');

  if (cat.bytes.length < 100) {
    err('响应过小，签名很可能没被接受');
    console.log('  原文 hex:', cat.bytes.toString('hex').slice(0, 120));
    return;
  }

  const list = sandbox.parseList(cat.bytes.toString('base64'), ctx);
  console.log('  parseList -> items =', list.items.length);
  list.items.slice(0, 3).forEach((it) =>
    console.log('    ', it.id, it.name, '|', it.remark || '', '|',
      it.pic ? '有封面' : '无封面'));

  if (!list.items.length) { err('解析出 0 条，字段映射可能不匹配'); return; }

  const missingPic = list.items.filter((x) => !x.pic).length;
  console.log('  缺封面:', missingPic, '/', list.items.length);

  console.log('\n=== 2. 搜索 searchKeys=庆余年 ===');
  const sres = await call('/api/proto/v5/drama/search',
    { page: '1', pagesize: '20', searchKeys: '庆余年' });
  console.log('  HTTP', sres.status, '| 字节', sres.bytes.length);
  const h2 = pbHead(sres.bytes);
  console.log('  code =', h2.code, '| msg =', h2.msg || '(空)');
  if (sres.bytes.length >= 100) {
    const sl = sandbox.parseList(sres.bytes.toString('base64'), ctx);
    console.log('  parseList -> items =', sl.items.length);
    sl.items.slice(0, 3).forEach((it) =>
      console.log('    ', it.id, it.name, '|', it.remark || ''));
  }

  console.log('\n=== 3. 详情 getDetail id=' + list.items[0].id + ' ===');
  const dres = await call('/api/proto/v5/drama/getDetail',
    { id: String(list.items[0].id) });
  console.log('  HTTP', dres.status, '| 字节', dres.bytes.length);
  if (dres.bytes.length >= 100) {
    const det = sandbox.parseDetail(
      dres.bytes.toString('base64'),
      { ...ctx, dramaId: String(list.items[0].id) });
    console.log('  name   =', det.name);
    console.log('  area   =', det.area, '| year =', det.year);
    console.log('  remark =', det.remark, '| stars =', det.stars);
    console.log('  lines  =', det.lines.length);
    det.lines.slice(0, 3).forEach((l) => {
      const f = l.episodes[0] || {};
      console.log('    ', l.line, '|', l.episodes.length, '集 | 首集',
        f.name, '->', String(f.url).slice(0, 60));
    });

    // 取第一集的地址
    const l0 = det.lines.find((l) => l.episodes.length);
    if (l0) {
      const ep = l0.episodes[0];
      console.log('\n=== 4. 取址 videoUsableUrl ===');
      const ures = await call('/api/proto/v5/videoUsableUrl',
        { vodPlayFrom: l0.line, playUrl: ep.url || ep.token });
      console.log('  HTTP', ures.status, '| 字节', ures.bytes.length);
      const h3 = pbHead(ures.bytes);
      console.log('  code =', h3.code, '| msg =', h3.msg || '(空)');
      if (ures.bytes.length >= 20) {
        const rv = sandbox.parseResolve(ures.bytes.toString('base64'),
          { ...ctx, line: l0.line });
        console.log('  parseResolve ->', JSON.stringify(rv).slice(0, 220));
      }
    }
  }
})().catch((e) => {
  console.error('失败:', e && e.message ? e.message : e);
  process.exitCode = 1;
});