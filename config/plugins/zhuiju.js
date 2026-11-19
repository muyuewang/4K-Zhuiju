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
 *
 * ## `ts` 必须由调用方传进来，**不能在这里再调一次 Date.now()**
 *
 * 2026-11-19 实测（`test/zhuiju_sign_diag_test.dart`）：本函数内部自己调
 * `Date.now()` 时，body 里的时间戳与 `publicParams.timestamp` 相差 **50ms**，
 * 服务端直接回 `code=100001 请求时间戳过期`，界面上表现为**所有分类全空
 * 且不报错**（`parseList` 把错误吞成了空数组）。
 *
 * 差 50ms 的原因是两者之间夹着一次 RSA 公钥加密：pointycastle 的
 * 1024 位 PKCS#1 在 QuickJS 里要跑几十毫秒，Node 侧原生实现只要 1ms
 * 左右，所以离线对拍脚本一直是绿的 —— 这个坑只有在真实宿主里才现形。
 *
 * 服务端的判据是「header.timestamp 必须等于 body 里的 ts」，差 1ms 都算
 * 重放。所以**时间戳只能取一次**，由 sign() 算好后同时给两处用。
 */
function buildBody(params, ts) {
  var keys = [];
  for (var k in params) {
    if (Object.prototype.hasOwnProperty.call(params, k)) keys.push(k);
  }
  var kv = '';
  for (var i = 0; i < keys.length; i++) {
    if (kv !== '') kv += '&';
    kv += keys[i] + '=' + s(params[keys[i]]);
  }

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
  // 时间戳**只取一次**，header 与 body 共用同一个值。
  // 分别取会让两者差几十毫秒（中间夹着 RSA 加密），服务端判重放。
  // 详见 buildBody 上方的说明。
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
    body: buildBody(q, ts)
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

/**
 * hex 字节串 → UTF-8 文本，**纯 JS 实现，不调宿主**。
 *
 * ## 为什么不能用 host.b64e + host.b64d
 *
 * 那样一次解码要跨 FFI 两次。列表页（20 条 × 3 字段）才 120 次，
 * 看不出问题；但详情页是**线路 × 集数**的乘积 —— 实测《兰香如故》
 * 47 集 × 14 条线路 = 658 条 video，每条取 name/source/path 三个字段，
 * 就是 658 × 3 × 2 ≈ **3900 次**，再加上其它开销直接撞穿宿主
 * 5000 次/次的预算，整个 parseDetail 抛
 * 「host 调用次数超出上限（5000 次）」。
 *
 * 表现是**详情页解析失败**，而列表页完全正常 —— 很容易误判成
 * 「详情接口挂了」或「剧集太多不支持」，其实只是解码方式太贵。
 *
 * 自己解 UTF-8 没有额外成本（纯字符串运算），QuickJS 没有 TextDecoder
 * 也不影响 —— 手写一个不到 30 行。改完之后详情页只剩 1 次宿主调用
 * （解响应体的 base64），与集数无关。
 */
function hexToText(hex) {
  var len = hex.length / 2;
  var out = '';
  var i = 0;
  while (i < len) {
    var b0 = parseInt(hex.substr(i * 2, 2), 16);
    i++;
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      continue;
    }

    // 判定首字节属于几字节序列，并取出已含的高位
    var cp;
    var extra;
    if ((b0 & 0xE0) === 0xC0) {
      cp = b0 & 0x1F;
      extra = 1;
    } else if ((b0 & 0xF0) === 0xE0) {
      cp = b0 & 0x0F;
      extra = 2;
    } else if ((b0 & 0xF8) === 0xF0) {
      cp = b0 & 0x07;
      extra = 3;
    } else {
      // 非法首字节（含孤立的 continuation）：按替换符处理，不中断整串
      out += '\uFFFD';
      continue;
    }

    if (i + extra > len) {
      out += '\uFFFD';
      break;
    }

    var bad = false;
    for (var k = 0; k < extra; k++) {
      var b = parseInt(hex.substr(i * 2, 2), 16);
      i++;
      if ((b & 0xC0) !== 0x80) {
        bad = true;
        break;
      }
      cp = (cp << 6) | (b & 0x3F);
    }
    if (bad) {
      out += '\uFFFD';
      continue;
    }

    if (cp > 0xFFFF) {
      // 补充平面要拆成代理对，否则 String.fromCharCode 会被截断
      cp -= 0x10000;
      out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
    } else {
      out += String.fromCharCode(cp);
    }
  }
  return out;
}

/** hex 字节串 → UTF-8 文本 */
function text(hexBytes) {
  if (!hexBytes) return '';
  return hexToText(hexBytes);
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

/**
 * CoverImage：地址在字段 **2**。
 *
 * 2026-11-19 实测（`diag_zhuiju_detail.js` 逐字段 dump）：封面容器内部只有
 * `[2] = "https://vcover-vt-pic.puui.qpic.cn/vcover_vt_pic/0/mzc002008…"`，
 * 字段 1 是空的。旧实现取字段 1，结果**列表 20 条全部无封面**，
 * 而搜索/详情有各自的封面路径，看起来像「只有列表页坏掉」——
 * 很容易误判成列表接口没返回图片。
 *
 * 两个字段都试：优先 2，退化到 1，兼容以后换版本又把顺序改回来的情况。
 */
function coverOf(seg) {
  var f = pbFields(seg);
  var u = str(f, 2);
  return u !== '' ? u : str(f, 1);
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
    // 类型 id 在字段 **9**（实测 = 21 对应电视剧）。旧实现取字段 8，
    // 而 8 在实测响应里根本不存在，于是每个条目的 type 都是 0。
    type: String(int(f, 9)),
    clazz: str(f, 15),
    updateTime: int(f, 10),
    vodPubdate: str(f, 11)
  };
}

function parseList(body, ctx) {
  var u = unwrap(body);
  // 错误必须往上传，不能吞成空数组。
  //
  // 2026-11-19 的事故就是吞出来的：服务端回 `code=100001 请求时间戳过期`，
  // 这里返回 `{items: []}`，宿主只检查 items 是不是数组，界面上于是
  // 显示「这个分类暂时没有内容」——看起来像站方片库空了，实际是签名炸了。
  // 宿主侧已改成「空 items + 有 error ⇒ 报错」，这里负责把 error 填上。
  if (!u) return { items: [], error: '接口返回的不是 protobuf 数据' };
  if (u.error) return { items: [], error: u.error };
  if (!u.data) return { items: [], error: '接口没返回内容' };
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

  // ## 详情的字段号与列表**完全不同**（实测 dump 校准，2026-11-19）
  //
  // 同一部剧在列表接口里是 `name=5, actor=12, remark=13, year=14, type=9`，
  // 到了 getDetail 变成 `name=9, actor=25, remark=26, year=18, type=15`。
  // 两套编号必须分别记，不能把列表那套拿来用 —— 用错的表现是
  // 详情页名字对、但地区/年份/主演全空，而**接口本身返回得好好的**，
  // 排查时会一直怀疑是接口少了字段。
  return {
    name: str(f, 9),
    pic: coverOf(first(f, 2) || ''),
    content: stripHtml(str(f, 6)),
    brief: stripHtml(str(f, 7)),
    area: str(f, 1),
    year: int(f, 18),
    remark: str(f, 26),
    director: str(f, 12),
    actor: str(f, 25),
    // 站点不给评分，也不给中文类型串（只有 typeId 数字），
    // 不编造：留空让界面按「无」显示。
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
