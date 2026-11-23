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
// ## 线路的两种形态（2026-11-18 实测，务必读）
//
// `line_options[]` 里混着两种线路，实测一部剧固定 33 条 = 官方线 10 + 普通线 23：
//
//   | 形态   | url_kind        | resolve_required | url 字段是什么      |
//   | ------ | --------------- | ---------------- | ------------------- |
//   | 官方线 | resolve_ticket  | true             | resolve://<票据>    |
//   | 普通线 | m3u8            | false            | 直接可播的 m3u8     |
//
// 官方线是站方自己的付费/合作源（优酷、字节、专享4K 等），画质明显好于
// 抓来的普通线，而且**本来就排在原始顺序最前面**（preference_weight
// 1000→989 全在这 10 条上，普通线最高才 920）。
//
// 早先这版脚本把它们整批 `continue` 掉了，理由是「要二次换票，插件做不到」。
// 那个判断是错的：宿主加了 `resolveLine` 端点之后，换票就是一次普通 POST。
// 实测 2026-11-18 时 10/10 全部成功、**不需要游客会话**。
//
// ⚠ 2026-11-23 站点改了策略：匿名换官方线票据时 11 条里 9 条返回
//   HTTP 401 {"code":"playback_user_session_required","message":"该内容需要登录后播放"}
// 即官方线现在要登录态（网页端是登录 VIP 账号，所以能播）。唯一返回 201
// 的那条是 `token_scenario: series_intro_zero` 的片头预览（实际是张 jpg），
// 不是正片。匿名状态下**只有普通线可播**（实测 红牛/无水印/ikun 等可用）。
// 用户点官方线报 401 不是 bug，是站点的登录门槛；宿主已把服务端 message
// 透传到错误页，用户会看到「该内容需要登录后播放」而不是干巴巴的 HTTP 401。
//
// 现在的分工：
//   parseLines        → 33 条全给，按站点原顺序（官方线自然在前）
//   parseResolve      → 用户点哪条给哪条；官方线返回 {ticket}
//   宿主             → 见到 ticket 就 POST resolveLine 换票
//   parseLineResolve → 从换票应答 {"line":{"url":...}} 里取真地址
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
 * 实测一部剧 33 条 line_options = 官方线 10 + 普通线 23，
 * **两种都要给**。官方线是站方合作源（优酷/字节/专享4K），
 * 画质最好且本来就在最前面；把它们过滤掉，用户看到的线路面板
 * 会从「新浪资源」这种抓来的普通线开始，和网页版对不上。
 *
 * 这里只负责「有哪些线路」，不负责「怎么取址」——官方线的票据
 * 由 parseResolve 在播放时现取现换（换票请求由宿主发）。
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
    var url = s(o.url).trim();
    // 官方线的 url 是 resolve://<票据>，普通线是 http(s)。
    // 两种都是有效线路，只挡空值和既不是 http 也不是票据的怪数据。
    var isTicket = url.indexOf('resolve://') === 0;
    if (!isTicket && url.indexOf('http') !== 0) continue;
    var label = s(o.display_label || o.label).trim();
    if (label === '') label = s(o.provider_name).trim();
    if (label === '' || seen[label]) continue;
    seen[label] = 1;
    lines.push({
      line: label,
      label: label,
      playFrom: s(o.play_from),
      // direct 只表示「地址已可直接播」，界面上据此判断要不要提示
      // 用户「这条线可能要等一下」。官方线换票只是多一次 POST，
      // 不改变它可播这一事实，所以不在这里过滤。
      direct: !isTicket,
      // 需要二次换票的线，宿主不用看这个字段（它按 parseResolve
      // 返回的 ticket 自行判断），这里留着只为排查时一眼可辨。
      resolveRequired: o.resolve_required === true
    });
  }
  return { lines: lines };
}

// ==================== 取址 ====================

/**
 * body 是 `/v1/playback/resolve/{token}` 的应答，含 line_options[]。
 *
 * ctx.line 是选中的线路名（parseLines 给的 label）。
 *
 * 返回值有两种含义：
 *   - `{url: "https://..."}` —— 普通线，直接可播
 *   - `{ticket: "..."}`      —— 官方线，宿主见到 ticket 会自动
 *                                POST resolveLine 换票（见 parseLineResolve）
 */
function parseResolve(body, ctx) {
  var d = unwrap(body);
  if (!d) return { url: '', error: '线路接口没有返回数据' };

  var opts = arr(d.line_options);
  var wanted = s(ctx && ctx.line).trim();

  // 用户点了具体线路：按名字精确取那一条。
  //
  // 官方线也要认——它给的是票据，交给宿主去换票。之前这里跳过
  // resolve_required，导致「点了官方线就播不了」，而线路面板里
  // 那些线本来就不该出现（已在 parseLines 里放出来）。
  if (wanted !== '') {
    for (var j = 0; j < opts.length; j++) {
      var t = opts[j];
      if (!t || typeof t !== 'object') continue;
      var name = s(t.display_label || t.label).trim();
      if (name === '') name = s(t.provider_name).trim();
      if (name !== wanted) continue;
      var tu = s(t.url).trim();
      if (tu.indexOf('resolve://') === 0) {
        // 票据原样交出去，剥前缀由宿主做（见 _ticketOf）。
        // 这里只保证「不是空票据」。
        var ticket = tu.substring('resolve://'.length);
        if (ticket !== '') return { ticket: ticket, label: name };
        continue;
      }
      if (tu.indexOf('http') === 0) return { url: tu };
    }
    // 该集恰好没有这条线（线路按集浮动）：走到下面的兜底
  }

  // 兜底：优先站点标记为 selected 的普通线，否则第一条普通线。
  //
  // 为什么不兜到官方线：换票要多一次 POST（约 300~800ms），而用户
  // 没点具体线路时（老调用路径）本来就不知道该播哪条，选条立刻能起的
  // 更合适。只有明确点了官方线才走换票。
  var picked = null;
  for (var i = 0; i < opts.length; i++) {
    var o = opts[i];
    var url = s(o && o.url).trim();
    if (o && url.indexOf('http') === 0 && o.resolve_required !== true) {
      if (o.selected === true) { picked = url; break; }
      if (picked === null) picked = url;
    }
  }
  if (picked !== null) return { url: picked };

  // 站点明确说了「这一集要登录/标识失效」时先报错，不要再去换票。
  //
  // 这两条码是**整体状态**而不是单条线路的属性：换票也会被同一原因
  // 拒掉，白跑一次请求还让用户多等 500ms，报错信息也更模糊。
  var code = s(d.code);
  if (code === 'playback_user_session_required') {
    return { url: '', error: '这条线路需要登录，请换一条线路' };
  }
  if (code === 'invalid_public_playback_id') {
    return { url: '', error: '播放标识已失效，请重新打开详情页' };
  }

  // 一条普通线都没有（新片常见：只有官方合作源）：交给第一条官方线。
  // 这比直接报错强——换票成功率实测 10/10。
  for (var k = 0; k < opts.length; k++) {
    var oo = opts[k];
    if (!oo || typeof oo !== 'object') continue;
    var ou = s(oo.url).trim();
    if (ou.indexOf('resolve://') === 0) {
      var tk = ou.substring('resolve://'.length);
      if (tk !== '') {
        return { ticket: tk, label: s(oo.display_label || oo.label) };
      }
    }
  }

  return {
    url: '',
    error: '这一集没有可播放的线路，请在选集里换一条'
  };
}

/**
 * 官方线换票应答的解析。宿主发的是
 *   POST /v1/playback/resolve-line?view=compact   body {"ticket": "..."}
 * 应答形如：
 *   {"object":"playback.line.resolve", ..., "line": {"url": "https://..."}}
 *
 * 实测（2026-11-18）10/10 条官方线都能换出地址，不需要任何会话。
 * 失败时站点会把原因放在 code 里，尽量翻成人话给用户。
 */
function parseLineResolve(body, ctx) {
  var d = unwrap(body);
  if (!d) return { url: '', error: '官方线路换票没有返回数据' };

  var ln = d.line;
  if (ln && typeof ln === 'object') {
    var u = s(ln.url).trim();
    if (u.indexOf('http') === 0) return { url: u };
    // 换完票还是 resolve:// 说明站点又给了一张票据（连环换票）。
    // 宿主不支持多层，直接报清楚，不要让它进播放器。
    if (u.indexOf('resolve://') === 0) {
      return { url: '', error: '这条线路需要多次换票，暂不支持，请换一条线路' };
    }
  }

  // 兜底：有些站把地址平铺在顶层
  var flat = s(d.url).trim();
  if (flat.indexOf('http') === 0) return { url: flat };

  var code = s(d.code);
  if (code === 'playback_line_ticket_expired' ||
      code === 'invalid_line_ticket') {
    return { url: '', error: '线路票据已过期，请返回重新选集' };
  }
  if (code === 'playback_user_session_required') {
    return { url: '', error: '这条官方线路需要登录，请换一条线路' };
  }
  return {
    url: '',
    error: s(d.message) || '官方线路换票失败，请换一条线路'
  };
}
