// 橘汁（4K追剧 App 接口）专用插件。
//
// 这是协议最重的一个源，三件事都和别的源不一样：
//   1. 请求体：protobuf 帧，里面裹 AES-256-ECB 加密的 `k=v&...` 串；
//   2. 请求头：publicParams 里带 RSA 签名 + AES 分段签名；
//   3. 响应体：protobuf 二进制，宿主按 `responseType:"bin"` 转成 base64 交给脚本。
//
// 清单的 body 是 **hex 模板**，签名钩子（sign）每次现算随机数和密文，
// 返回新的 hex body；宿主按 `bodyFormat:"hex"` 解码成原始字节发出。
//
// 宿主能力：host.aesEcbEncrypt / host.rsaEncrypt / host.hex / host.b64e / host.b64d。
// 注意 host 的摘要与编码函数是**位置参数**，加密类是对象参数。
//
// 同步函数、无死循环、返回可 JSON 序列化对象。

var ZJ_SAFE_CODE = 'ZU1DSFFWNENKMDYXVUQRN0ZJDUC4PQ==';
var ZJ_SAFE_SECRET = 'OC1A06E197EF10CF3F6058CA7A803B5E';
var ZJ_RSA_N =
  'a9f44938c0895002dc059ee05196c162a30dadafee1439c88678d29b63b9cbef' +
  '87ad52a51be9fbe939238784511f69695fc14a4e075ef1dc910bdcda35f677e3' +
  '09e558ad83e3949720a2a5161ffb5f21f140416bedc4120194a6b3921c3c7770' +
  'a1cac5a679646290aaa406c551638a2a34fba3e2c8e6e99ba5b74538238a6b45';
var ZJ_VAPP = '3070';

function s(v) {
  if (v === null || v === undefined) return '';
  return String(v);
}

function n(v) {
  var x = parseInt(s(v), 10);
  return isNaN(x) ? 0 : x;
}

/** 原版 randomToken(len)：len-1 位随机 + '='。服务端不校验去重。 */
function token(len) {
  return s(host.randomAlnum(len - 1)) + '=';
}

function aesB64(key, plain) {
  return s(host.aesEcbEncrypt({
    key: key, keyFmt: 'utf8',
    plain: plain, plainFmt: 'utf8',
    outFmt: 'base64'
  }));
}

// ==================== protobuf 写入（请求体） ====================

/** 无符号 varint → hex 字节串 */
function varint(v) {
  var x = Math.floor(n(v));
  if (x < 0) x = 0;
  var out = '';
  while (x >= 128) {
    var b = (x % 128) + 128;
    out += ('0' + b.toString(16)).slice(-2);
    x = Math.floor(x / 128);
  }
  out += ('0' + x.toString(16)).slice(-2);
  return out;
}

/** string 字段（wire type 2） */
function fStr(no, text) {
  var h = s(host.hex(text, 'utf8'));
  return varint(no * 8 + 2) + varint(h.length / 2) + h;
}

/** varint 字段（wire type 0）。时间戳走这里。 */
function fInt(no, v) {
  return varint(no * 8) + varint(v);
}

/**
 * SecureRequest{aes1, aes2, fake, timestamp, random}
 * 返回 hex 串；宿主会解码成原始字节发出。
 */
function buildBody(params) {
  var keys = [];
  for (var k in params) {
    if (Object.prototype.hasOwnProperty.call(params, k)) keys.push(k);
  }
  var kv = '';
  for (var i = 0; i < keys.length; i++) {
    if (kv !== '') kv += '&';
    kv += keys[i] + '=' + s(params[keys[i]]);
  }

  var ts = Date.now();
  var r8 = token(8);
  var fake = token(20);
  var encrypted = aesB64(ZJ_SAFE_CODE, kv + ts);
  var merged = r8 + encrypted;

  return fStr(1, merged.substring(0, 20)) +
         fStr(2, merged.substring(20)) +
         fStr(3, fake) +
         fInt(4, ts) +
         fStr(5, r8);
}

// ==================== 签名钩子 ====================

function buildPublicParams(ts, r16) {
  var map = {
    country: 'CN', vName: '3.0.7.0',
    cpuId: 'Qualcomm%20Technologies%2C%20Inc%20MSM8998',
    young: 0, facturer: 'samsung', pkg: 'com.asjdhjhd.mgd.p3',
    uuid: '3342CF6E5B34747029419DBA6B159A35',
    resolution: '720x1280', mac: '00%3Adb%3A1e%3A1b%3Aa8%3Ae8',
    abid: '4365', model: 'SM-N9700', plat: 'android',
    udid: '3342CF6E5B34747029419DBA6B159A35', dpi: '320',
    net: '1', lang: 'zh', brand: 'samsung', density: '2.0',
    appName: '%E6%A9%98%E6%B1%81', cpu: 'x86_64', chid: '10000',
    carrier: '%E7%A7%BB%E5%8A%A8', v: '1', tenantId: '',
    _vOsCode: '28', vOs: '9', vApp: ZJ_VAPP, device: '0',
    androidID: 'f00b0e69983f85a9',
    timestamp: ts,
    random_str: r16
  };

  map.sig = s(host.rsaEncrypt({
    nHex: ZJ_RSA_N,
    e: '65537',
    data: ts + r16 + ZJ_VAPP
  }));
  var sigA = aesB64(ZJ_SAFE_SECRET, ts + r16);
  map.sig2 = sigA.substring(0, 8);
  map.sig3 = sigA.substring(8);
  return JSON.stringify(map);
}

/**
 * 宿主在发出每条请求前调用。
 * 橘汁的所有接口都是 POST + protobuf body，所以这里统一生成
 * publicParams 和新的 body；query 只是参数的**载体**，由清单模板
 * 填好，脚本读出来塞进加密的请求体。
 */
function sign(req) {
  var ts = Date.now();
  var r16 = token(16);
  var raw = req.query || {};
  var q = {};
  for (var k in raw) {
    if (Object.prototype.hasOwnProperty.call(raw, k)) q[k] = raw[k];
  }
  // 取址接口的 playUrl 参数在明文里要先百分号编码（内置实现的做法），
  // 而搜索关键词必须保持中文原文（实测编码后服务端不认）。
  if (s(req && req.url).indexOf('/videoUsableUrl') >= 0 && q.playUrl) {
    q.playUrl = encodeURIComponent(q.playUrl);
  }
  return {
    headers: {
      'publicParams': buildPublicParams(ts, r16),
      'Content-Type': 'application/x-protobuf',
      'Accept': 'application/x-protobuf',
      'User-Agent': 'okhttp/3.12.1'
    },
    body: buildBody(q)
  };
}

// ==================== protobuf 读取（响应） ====================

/**
 * 极简 protobuf 阅读器。只处理 string / varint / bytes / fixed32/64
 * 四种 wire type —— 够解析 ApiResult 与本源的全部数据结构。
 */
function pbFields(hex) {
  var out = {};
  var pos = 0;
  var total = hex.length / 2;
  function readVar() {
    var result = 0;
    var shift = 0;
    while (pos < total && shift < 70) {
      var b = parseInt(hex.substr(pos * 2, 2), 16);
      pos++;
      result += (b & 127) * Math.pow(2, shift);
      if ((b & 128) === 0) return result;
      shift += 7;
    }
    return result;
  }
  function push(no, v) {
    if (!out[no]) out[no] = [];
    out[no].push(v);
  }
  while (pos < total) {
    var tag = readVar();
    var no = Math.floor(tag / 8);
    var wt = tag % 8;
    if (no === 0) break;
    if (wt === 0) {
      push(no, readVar());
    } else if (wt === 2) {
      var len = readVar();
      if (len < 0 || pos + len > total) break;
      push(no, hex.substr(pos * 2, len * 2));
      pos += len;
    } else if (wt === 5) {
      pos += 4;
    } else if (wt === 1) {
      pos += 8;
    } else {
      break;
    }
  }
  return out;
}

function first(fields, no) {
  var a = fields[no];
  return a && a.length > 0 ? a[0] : null;
}

function all(fields, no) {
  return fields[no] || [];
}

/** hex 字节串 → UTF-8 文本（经宿主解码，QuickJS 没有 TextDecoder） */
function text(hexBytes) {
  if (!hexBytes) return '';
  var b64 = s(host.b64e(hexBytes, 'hex'));
  var out = s(host.b64d(b64, 'utf8'));
  // 错误对象形如 {"__err": "..."}，不能当正文返回
  if (out.charAt(0) === '{' && out.indexOf('"__err"') >= 0) return '';
  return out;
}

function str(fields, no) {
  return text(first(fields, no));
}

function int(fields, no, dflt) {
  var v = first(fields, no);
  return v === null ? (dflt || 0) : Math.floor(v);
}

function stripHtml(t) {
  var out = s(t).replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]*>/g, '');
  return out.replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&').trim();
}

/** 从外层 ApiResult 里取 data 字段的 hex */
function unwrap(bodyB64) {
  var hex;
  try {
    hex = s(host.b64d(s(bodyB64), 'hex'));
  } catch (e) {
    return { error: '接口返回的不是 protobuf 数据' };
  }
  if (hex.charAt(0) === '{' && hex.indexOf('"__err"') >= 0) return null;
  var fs = pbFields(hex);
  var code = int(fs, 1, -1);
  if (code !== 200) return { error: str(fs, 2) || ('请求失败(' + code + ')') };
  var data = first(fs, 3);
  return data === null ? { data: '' } : { data: data };
}

/** CoverImage：字段 1 = url（实测封面只有一个地址字段） */
function coverOf(seg) {
  return str(pbFields(seg), 1);
}

// ==================== 列表 ====================

function dramaFrom(seg) {
  var f = pbFields(seg);
  var id = int(f, 3);
  if (!id) return null;
  return {
    id: String(id),
    name: str(f, 5),
    pic: coverOf(first(f, 2) || ''),
    area: str(f, 1),
    brief: stripHtml(str(f, 4)),
    director: str(f, 7),
    actor: str(f, 12),
    remark: str(f, 13),
    year: int(f, 14),
    type: String(int(f, 8)),
    clazz: str(f, 15),
    updateTime: int(f, 10),
    vodPubdate: str(f, 11)
  };
}

function parseList(body, ctx) {
  var u = unwrap(body);
  if (!u || u.error) return { items: [] };
  if (!u.data) return { items: [] };
  var fs = pbFields(u.data);
  var items = [];
  var segs = all(fs, 1);
  for (var i = 0; i < segs.length; i++) {
    var one = dramaFrom(segs[i]);
    if (one) items.push(one);
  }
  return { items: items };
}

// ==================== 详情 ====================

function videoFrom(seg) {
  var f = pbFields(seg);
  var ep = int(f, 13);
  var source = str(f, 9);
  var path = str(f, 4);
  return {
    name: str(f, 2) || (ep > 0 ? ('第' + ep + '集') : '正片'),
    // 直播标记靠 source + path 前缀双条件（实测 114/114 命中，
    // 其它分类 0 误判），宿主把 isLive 交给播放器决定 UI。
    isLive: source === 'cctv' && path.indexOf('zb-') === 0,
    token: String(int(f, 1)),
    source: source,
    // path 直接给宿主；取址接口会再换一次 CDN 地址
    url: path
  };
}

function parseDetail(body, ctx) {
  var u = unwrap(body);
  if (!u || u.error) return { lines: [], error: u ? u.error : '详情解析失败' };
  if (!u.data) return { lines: [] };
  var f = pbFields(u.data);

  var groups = {};
  var order = [];
  var vids = all(f, 29);
  for (var i = 0; i < vids.length; i++) {
    var v = videoFrom(vids[i]);
    var key = v.source || 'default';
    if (!groups[key]) {
      groups[key] = [];
      order.push(key);
    }
    groups[key].push(v);
  }

  var lines = [];
  for (var n = 0; n < order.length; n++) {
    var k = order[n];
    lines.push({ line: k, episodes: groups[k] });
  }

  return {
    name: str(f, 9),
    pic: coverOf(first(f, 2) || ''),
    content: stripHtml(str(f, 6)),
    brief: stripHtml(str(f, 7)),
    area: str(f, 1),
    director: str(f, 12),
    tag: str(f, 13),
    lines: lines
  };
}

// ==================== 取址 ====================

function parseResolve(body, ctx) {
  var u = unwrap(body);
  if (!u || u.error) return { url: '', error: u ? u.error : '取址失败' };
  if (!u.data) return { url: '', error: '播放地址为空' };
  var f = pbFields(u.data);
  var url = str(f, 1);
  if (url.indexOf('http') !== 0) {
    return { url: '', error: str(f, 9) || '该集没有可播放的地址' };
  }
  return { url: url };
}
