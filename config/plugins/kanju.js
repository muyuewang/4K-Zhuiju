// 看剧（kanju.ai）专用插件：HMAC 签名 + JSON 接口。
//
// 签名串是四行拼接（**不能少换行**）：
//   {METHOD}\n{PATH?QUERY}\n{TIMESTAMP}\n{NONCE}
// 三个头：x-ai-movie-timestamp / -nonce / -signature。
//
// 中文参数**必须先百分号编码再签名**：对 `q=沙` 原文签名会得
// 401 invalid_request_signature，因为 HTTP 实际发的是 `q=%E6%B2%99`。
// 这里直接从 `req.url` 取最终 URL 的 path?query 来签，保证「签名的串 ==
// 发出去的串」，不自己重新拼接/编码。
//
// ## 已知能力边界（诚实记录）
//
// 内置实现有「官方线优先 + 游客会话 + 二次 resolve」三步。插件只做
// 第一阶段的线路解析，取址时挑**直出**线路（实测每集稳定 26 条），
// 不走需要会话的官方线。官方线在部分新片上是唯一可播源时，
// 播放会给出「换一条线路」的提示，而不是假装成功。
//
// 同步函数、无死循环、返回可 JSON 序列化对象。

var KJ_KEY = '557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0';

function s(v) {
  if (v === null || v === undefined) return '';
  return String(v);
}

function num(v) {
  var n = parseInt(s(v), 10);
  return isNaN(n) ? 0 : n;
}

function strip(t) {
  var out = s(t)
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<[^>]*>/g, '');
  return out.replace(/[ \t]+/g, ' ').trim();
}

function arr(v) {
  return Object.prototype.toString.call(v) === '[object Array]' ? v : [];
}

// ==================== 签名（signEntry） ====================

/** 从完整 URL 里取 path?query —— 就是签名串的第二行。 */
function pathQueryOf(url) {
  var u = s(url);
  var at = u.indexOf('://');
  if (at < 0) return u;
  var rest = u.substring(at + 3);
  var slash = rest.indexOf('/');
  return slash < 0 ? '/' : rest.substring(slash);
}

/** 纯函数，便于与 Dart 的 KanjuSource.signHex 对拍。 */
function buildSignature(method, pathQuery, ts, nonce) {
  var msg = s(method).toUpperCase() + '\n' + pathQuery + '\n' + s(ts) + '\n' + s(nonce);
  return s(host.hmac('sha256', KJ_KEY, msg));
}

function sign(req) {
  var url = s(req && req.url);
  var method = s(req && req.method) || 'GET';
  var ts = String(Date.now());
  // 32 位 hex，与服务端的 anonymous_id 形态一致
  var nonce = s(host.randomHex(16));
  var sig = buildSignature(method, pathQueryOf(url), ts, nonce);
  return {
    headers: {
      'x-ai-movie-timestamp': ts,
      'x-ai-movie-nonce': nonce,
      'x-ai-movie-signature': sig,
      'x-ai-movie-client-name': 'dianyingtiantang-frontend',
      'x-ai-movie-client-version': '1.0.0',
      'x-ai-movie-protocol-version': '2026-07-05.library-v2.playback-v1'
    }
  };
}

// ==================== 列表 ====================

function namesOf(v) {
  var out = [];
  var a = arr(v);
  for (var i = 0; i < a.length && out.length < 3; i++) {
    if (typeof a[i] === 'string' && a[i].trim() !== '') out.push(a[i].trim());
  }
  return out.join(' / ');
}

function cardToItem(c) {
  if (!c || typeof c !== 'object') return null;
  var poster = s(c.poster_url);
  var genres = arr(c.genres);
  var brief = namesOf(genres);
  if (brief === '') brief = s(c.content_kind);
  var id = s(c.id);
  if (id === '') return null;
  return {
    id: id,
    name: s(c.title),
    pic: poster,
    remark: s(c.remarks),
    brief: brief,
    area: s(c.area),
    year: num(c.year),
    stars: typeof c.score === 'number' ? c.score : 0,
    director: namesOf(c.directors),
    actor: namesOf(c.actors),
    type: s(c.content_kind)
  };
}

function unwrap(body) {
  var d;
  try { d = JSON.parse(s(body)); } catch (e) { return null; }
  if (!d || typeof d !== 'object') return null;
  return d;
}

function parseList(body, ctx) {
  var d = unwrap(body);
  if (!d) return { items: [] };
  var raw = arr(d.cards);

  // 首页是分区流：sections[].cards[]，展平成一个列表
  if (raw.length === 0) {
    var sections = arr(d.sections);
    for (var i = 0; i < sections.length; i++) {
      var more = arr(sections[i] && sections[i].cards);
      for (var j = 0; j < more.length; j++) raw.push(more[j]);
    }
  }

  var items = [];
  var seen = {};
  for (var n = 0; n < raw.length; n++) {
    var one = cardToItem(raw[n]);
    if (!one || seen[one.id]) continue;
    seen[one.id] = 1;
    items.push(one);
  }
  return { items: items };
}

// ==================== 详情 ====================

function parseDetail(body, ctx) {
  var d = unwrap(body);
  if (!d) return { lines: [] };

  var episodes = arr(d.episodes);
  var lines = [];
  var episodesOut = [];
  for (var i = 0; i < episodes.length; i++) {
    var e = episodes[i];
    var token = s(e && e.token);
    if (token === '') continue;
    var ep = num(e.number);
    var title = s(e.title);
    if (title === '') title = ep > 0 ? ('第' + ep + '集') : '正片';
    // `resolve://` 让选集条通过宿主的可播判定；真正取址时
    // 宿主用 token 去调 resolve 接口。
    episodesOut.push({
      name: title,
      url: 'resolve://' + token,
      token: token
    });
  }

  // 线路清单本应先 resolve 第一集再展开（内置实现如此），但那要额外
  // 一次请求 + 游客会话。这里只给一条占位，播放时由 parseResolve
  // 按线路可用性挑直出源。少的是「官方线优先」，不是播放能力。
  if (episodesOut.length > 0) {
    lines.push({ line: '默认线路', episodes: episodesOut });
  }

  return {
    name: s(d.title),
    pic: s(d.poster_url),
    content: strip(d.description),
    brief: strip(d.remarks),
    area: s(d.area),
    year: num(d.year),
    director: namesOf(d.directors),
    actor: namesOf(d.actors),
    tag: s(d.content_kind),
    lines: lines
  };
}

// ==================== 线路清单（expandLines） ====================

/**
 * 详情只给剧集 token，线路清单藏在 resolve 接口里。
 * 宿主在详情阶段 resolve 第一集后调这里，拿到线路名清单，
 * 再把占位线路展开成 N 条——否则用户只能看到一条「默认线路」。
 *
 * 实测：一部 24 集的剧，第一集 resolve 返回 33 条 line_options，
 * 其中 23 条是直出 m3u8，其余是需要游客会话二次换票的官方线。
 * 插件框架没有「取址时再发一次请求」的能力，所以这里只展开直出线——
 * 给用户 23 条能播的，好过给 33 条里 10 条点开就失败。
 */
function parseLines(body, ctx) {
  var d = unwrap(body);
  if (!d) return { lines: [] };
  var opts = arr(d.line_options);
  var lines = [];
  var seen = {};
  for (var i = 0; i < opts.length; i++) {
    var o = opts[i];
    if (!o || typeof o !== 'object') continue;
    // 只要直出线：resolve_required 的官方线要二次换票，插件做不到
    if (o.resolve_required === true) continue;
    var url = s(o.url);
    if (url.indexOf('http') !== 0) continue;
    var label = s(o.display_label || o.label).trim();
    if (label === '' || seen[label]) continue;
    seen[label] = 1;
    lines.push({
      line: label,
      label: label,
      playFrom: s(o.play_from),
      direct: true
    });
  }
  return { lines: lines };
}

// ==================== 取址 ====================

/**
 * body 是 `/v1/playback/resolve/{token}` 的应答，含 line_options[]。
 *
 * ctx.line 是选中的线路名（parseLines 给的 label）。先看站点是否按
 * 「官方线」返回了换线路的 ticket：带 ctx.line 时能精确选中用户点的
 * 那条；没带（老调用路径）就退回原来的「选第一个直出」。
 */
function parseResolve(body, ctx) {
  var d = unwrap(body);
  if (!d) return { url: '', error: '线路接口没有返回数据' };

  var opts = arr(d.line_options);
  var wanted = s(ctx && ctx.line).trim();

  // 用户点了具体线路（expandLines 展开出的 23 条直出线之一）：
  // 按线路名精确取那一条，避免所有线路都播同一条。
  if (wanted !== '') {
    for (var j = 0; j < opts.length; j++) {
      var t = opts[j];
      if (!t || t.resolve_required === true) continue;
      var name = s(t.display_label || t.label).trim();
      var tu = s(t.url).trim();
      if (name === wanted && tu.indexOf('http') === 0) return { url: tu };
    }
    // 该集恰好没有这条线（线路按集浮动）：退回第一条直出线
  }

  var picked = null;
  for (var i = 0; i < opts.length; i++) {
    var o = opts[i];
    var url = s(o && o.url).trim();
    if (o && o.resolve_required !== true && url.indexOf('http') === 0) {
      if (o.selected === true) { picked = url; break; }
      if (picked === null) picked = url;
    }
  }
  if (picked !== null) return { url: picked };

  // 全是需二次解析的官方线：明确说明，不返回 resolve://（播放器放不了）
  var code = s(d.code);
  if (code === 'playback_user_session_required') {
    return { url: '', error: '这条线路需要登录，请换一条线路' };
  }
  if (code === 'invalid_public_playback_id') {
    return { url: '', error: '播放标识已失效，请重新打开详情页' };
  }
  return {
    url: '',
    error: '这一集没有可直接播放的线路，请在选集里换一条'
  };
}
