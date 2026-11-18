// 三角洲影视（com.shenma.tvlauncher / 神马TV 换皮）插件。
//
// ## 站点结构（逆向自 2.0 版，versionCode 200）
//
// 它不是 MacCMS。接口挂在 `/api.php/{host}/` 下，形状像 MacCMS 但不是同一套字段：
//
//   分类   GET  /api.php/localhost1/Category?key=..&tt=..
//   列表   GET  /api.php/localhost1/vod/?ac=list&class={type_en}&page={n}
//   详情   GET  /api.php/localhost1/vod/?ac=detail&ids={id}
//   搜索   GET  /api.php/localhost1/So/?ac=list&zm={kw}&page={n}
//
// **列表和搜索的响应体是 RC4 密文的十六进制串，不是 JSON**；详情是明文 JSON，
// 但里面每一集的地址又是被 RC4 加密过的 hex。所以这个脚本里带了一份纯 JS 的
// RC4 + UTF-8 解码（QuickJS 没有 Buffer / TextDecoder，宿主也只注入了 AES 系列）。
//
// RC4 的 key 由服务端下发（配置里的 `pg` 字段），当前解出是 `520720ygq`，
// 放在 `vars.rc4Key`。**key 变了这个源就整站失效**，改 index.json 一行即可，不用发版。
//
// ## 播放链路（当前打不通，如实记录）
//
// 每集解密后是 `{from}-{...}-{token}` 形式的内部串（各 from 编码不统一，
// 有的是 base64、有的是 hex、有的是 `ESPN-play-148191-1331379` 这种四段）。
// 客户端不看这个串的内部结构，直接丢给它的代理：
//
//   {Client}/?url={token}&app=10000&account=..&password=..&series=..&edition=2.0
//
// 代理本该返回 `{"code":200,"url":"http://...m3u8","referer":..,"userAgent":..}`。
// 实测 App 里配的三个代理（45:5001 / 45:6002 / 45:5001 Client2）**全部回 302
// 且 Location 为空**，任意 url（包括 http://example.com/a.m3u8）都这样，
// 说明是服务端的授权/配额判断没过，不是参数拼错。
// 因此本插件把代理地址原样给出，不假装能播：播放器会走它自己的失败提示。
//
// 同步函数、无死循环、返回可 JSON 序列化对象。

// ==================== RC4 / 编码 ====================

function hexToBytes(h) {
  var n = h.length >> 1;
  var out = [];
  for (var i = 0; i < n; i++) {
    var b = parseInt(h.substr(i * 2, 2), 16);
    if (isNaN(b)) return null;
    out.push(b);
  }
  return out;
}

function utf8Decode(bytes) {
  var out = '';
  var i = 0;
  while (i < bytes.length) {
    var b = bytes[i++];
    if (b < 0x80) {
      out += String.fromCharCode(b);
    } else if (b < 0xc0) {
      out += '\uFFFD';
    } else if (b < 0xe0) {
      var b2 = bytes[i++];
      out += String.fromCharCode(((b & 0x1f) << 6) | (b2 & 0x3f));
    } else if (b < 0xf0) {
      var b3 = bytes[i++];
      var b4 = bytes[i++];
      out += String.fromCharCode(((b & 0x0f) << 12) | ((b3 & 0x3f) << 6) | (b4 & 0x3f));
    } else {
      var b5 = bytes[i++];
      var b6 = bytes[i++];
      var b7 = bytes[i++];
      var cp = ((b & 0x07) << 18) | ((b5 & 0x3f) << 12) | ((b6 & 0x3f) << 6) | (b7 & 0x3f);
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    }
  }
  return out;
}

function rc4Bytes(bytes, key) {
  var kb = [];
  for (var k = 0; k < key.length; k++) kb.push(key.charCodeAt(k) & 0xff);
  if (kb.length === 0) return bytes;

  var S = [];
  for (var a = 0; a < 256; a++) S[a] = a;
  var j = 0;
  for (var b = 0; b < 256; b++) {
    j = (kb[b % kb.length] + S[b] + j) & 0xff;
    var t = S[b];
    S[b] = S[j];
    S[j] = t;
  }

  var out = [];
  var x = 0;
  var y = 0;
  for (var n = 0; n < bytes.length; n++) {
    x = (x + 1) & 0xff;
    y = (S[x] + y) & 0xff;
    var tmp = S[x];
    S[x] = S[y];
    S[y] = tmp;
    out.push(bytes[n] ^ S[(S[x] + S[y]) & 0xff]);
  }
  return out;
}

/** RC4 解 hex 串 → 明文。失败返回空串。 */
function dec(hexStr, key) {
  var bytes = hexToBytes(hexStr);
  if (bytes === null) return '';
  return utf8Decode(rc4Bytes(bytes, key));
}

function s(v) {
  if (v === null || v === undefined) return '';
  return String(v);
}

/** 响应体可能是 RC4 hex，也可能已经是明文 JSON。 */
function asJson(body, key) {
  var text = s(body).trim();
  if (text === '') return null;
  if (text.charAt(0) === '{' || text.charAt(0) === '[') {
    try {
      return JSON.parse(text);
    } catch (e) {
      return null;
    }
  }
  var plain = dec(text, key);
  if (plain === '') return null;
  try {
    return JSON.parse(plain);
  } catch (e) {
    return null;
  }
}

function keyOf(ctx) {
  return s(ctx && ctx.vars ? ctx.vars.rc4Key : '');
}

// ==================== 列表 / 搜索 ====================

function parseList(body, ctx) {
  var data = asJson(body, keyOf(ctx));
  if (!data) return { items: [] };

  var arr = [];
  if (Object.prototype.toString.call(data.data) === '[object Array]') arr = data.data;
  else if (Object.prototype.toString.call(data) === '[object Array]') arr = data;

  var items = [];
  for (var n = 0; n < arr.length; n++) {
    var it = arr[n];
    if (!it || typeof it !== 'object') continue;

    // 站点不给独立的 vod_id，只有 nextlink="?ac=detail&ids=630934"
    var id = '';
    var m = /ids=(\d+)/.exec(s(it.nextlink));
    if (m) id = m[1];
    if (id === '') continue;

    var name = s(it.title).trim();
    if (name === '') continue;

    items.push({
      id: id,
      name: name,
      pic: s(it.pic),
      remark: s(it.state),
      brief: s(it.state),
      area: '',
      year: 0,
      type: s(it.type)
    });
  }
  return { items: items };
}

// ==================== 详情 ====================

/** 从 player 字段解出 from → 线路显示名。player 里是 [{show,sort,from}]。 */
function lineNames(detail, key) {
  var map = {};
  var pl = detail && detail.player ? dec(s(detail.player), key) : '';
  if (pl === '') return map;
  var list;
  try {
    list = JSON.parse(pl);
  } catch (e) {
    return map;
  }
  if (Object.prototype.toString.call(list) !== '[object Array]') return map;
  for (var n = 0; n < list.length; n++) {
    var it = list[n];
    if (!it) continue;
    var from = s(it.from);
    if (from === '') continue;
    map[from] = s(it.show) || from;
  }
  return map;
}

function strOf(v) {
  if (Object.prototype.toString.call(v) === '[object Array]') {
    var out = [];
    for (var n = 0; n < v.length; n++) {
      var t = s(v[n]).trim();
      if (t !== '') out.push(t);
    }
    return out.join(' / ');
  }
  return s(v);
}

function parseDetail(body, ctx) {
  var key = keyOf(ctx);
  var d = asJson(body, key);
  if (!d || typeof d !== 'object') return { lines: [] };

  var names = lineNames(d, key);
  var vl = d.videolist || {};
  var lines = [];

  for (var from in vl) {
    if (!Object.prototype.hasOwnProperty.call(vl, from)) continue;
    var eps = vl[from];
    if (Object.prototype.toString.call(eps) !== '[object Array]') continue;

    var episodes = [];
    for (var n = 0; n < eps.length; n++) {
      var ep = eps[n];
      if (!ep) continue;
      var token = dec(s(ep.url), key);
      if (token === '') continue;
      // 宿主只会把 url 原样交给播放器，所以这里必须直接给出可播地址，
      // 不能留裸 token（播放器不认识 `PAN1-3-...` 这种内部串）。
      var play = resolveUrl(token, ctx);
      if (play === '') continue;
      episodes.push({ name: s(ep.title) || '第' + (n + 1) + '集', url: play });
    }
    if (episodes.length === 0) continue;

    lines.push({ line: names[from] || from, episodes: episodes });
  }

  var director = strOf(d.director);
  var actor = strOf(d.actor);

  return {
    id: s(d.id),
    name: s(d.title),
    pic: s(d.img_url),
    content: s(d.intro),
    brief: s(d.trunk),
    area: strOf(d.area),
    year: parseInt(s(d.pubtime), 10) || 0,
    remark: s(d.trunk),
    director: director,
    actor: actor,
    lines: lines
  };
}

// ==================== 播放 ====================

/**
 * 把内部 token 包成站点的代理地址。
 *
 * token 里带 `=` `+` `/`，必须整体百分号编码——否则 `=` 会被当成
 * query 分隔符截断，服务端拿到半截 token。这一点实测过：
 * 不编码时 5 条线路全部 302 空跳转，编码后行为一致（服务端问题），
 * 但编码仍是必须的，否则连通那天也是错的。
 */
function resolveUrl(token, ctx) {
  var client = s(ctx && ctx.vars ? ctx.vars.clientUrl : '');
  if (client === '' || token === '') return '';
  return client + '?url=' + encodeURIComponent(token);
}

/** 没有单独取址接口，detail 里已经把 token 给全了。 */
function parseResolve(body, ctx) {
  var text = s(body).trim();
  if (text === '') return { url: '' };
  // detail 阶段已经拼成代理地址了；再包一层会变成「代理的代理」，直接返回。
  if (/^https?:\/\//i.test(text)) return { url: text };
  if (text.charAt(0) === '{') {
    try {
      var j = JSON.parse(text);
      if (j && j.url) return { url: s(j.url) };
    } catch (e) {
      // 掉到下面按 token 处理
    }
  }
  return { url: resolveUrl(text, ctx) };
}
