// 4K影视（www.4kvm.net）专用插件：Go 服务端渲染站，不是 MacCMS。
//
// 路径：/、/filter?classify=N&page=M、/search?q=、/play/<slug>
// 取址：/video/play?p=<dataid>&v=<slug>&s=<hmac>&t=<ts>&k=<token>
//
// ==================== 取址为什么要写签名钩子 ====================
//
// 站点把取址逻辑编译成 WASM，但还原后只有两个参数：
//   s = HMAC-SHA256(key=slug, msg="<dataid>:<ts>:<slug>") 的 hex 前 32 位
//   k = base64(userlink 逐字节 XOR "nbmovie2024secretkey")
// 时间戳每次现算，所以签名必须发生在**请求发出前**——parseResolve 是
// 拿到响应之后才调的，那时候再签毫无意义。这里用清单的 `signEntry`
// 钩子（`sign`），宿主会在发出每一条请求前先调一次；函数内部按 URL
// 判断只签 /video/play，列表/详情原样放行。
//
// userlink 由详情页每次渲染下发（`userlink:'...'`），所以 parseDetail
// 把它拼进单集 token：`dataid|userlink`。宿主把 token 拆成
// `{token0}` / `{token1}` 填进取址 query，签名函数再据此算出 k。
//
// 同步函数、无死循环、返回可 JSON 序列化对象。

function s(v) {
  if (v === null || v === undefined) return '';
  return String(v);
}

function unescapeHtml(t) {
  var out = s(t);
  for (var n = 0; n < 3; n++) {
    var before = out;
    out = out
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&#39;/g, "'")
      .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');
    if (out === before) break;
  }
  return out;
}

function strip(t) {
  var out = unescapeHtml(t)
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|h[1-6])\s*>/gi, '\n')
    .replace(/<[^>]*>/g, '');
  var lines = out.split('\n');
  var kept = [];
  for (var n = 0; n < lines.length; n++) {
    var one = lines[n].replace(/[ \t\u00a0]+/g, ' ').trim();
    if (one !== '') kept.push(one);
  }
  return kept.join('\n').trim();
}

function absUrl(p) {
  var t = s(p).trim();
  if (t === '') return '';
  if (t.indexOf('//') === 0) return 'https:' + t;
  return t;
}

// ==================== 列表 ====================

function parseList(body, ctx) {
  var html = s(body);
  if (html === '') return { items: [] };

  // `data-vod` 是 slug 的严格超集（搜索页也有），但详情页选集锚点
  // 只有 data-line/dataid、没有 data-vod —— 靠它把选集排除掉。
  var anchorRe = /href="\/play\/([A-Za-z0-9]+)"\s+data-vod="/g;
  var marks = [];
  var m;
  while ((m = anchorRe.exec(html)) !== null) marks.push(m);

  var items = [];
  var seen = {};
  for (var n = 0; n < marks.length; n++) {
    var id = marks[n][1];
    if (seen[id]) continue;
    seen[id] = 1;

    // 卡片间有 hover 面板，锚点到 <h3> 实测最远 3844 字节。
    // 用「下一张卡片起点」当右界，并封顶 6000，不能写死 220 字节。
    var next = n + 1 < marks.length ? marks[n + 1].index : html.length;
    var end = Math.min(Math.max(next, marks[n].index), marks[n].index + 6000);
    var seg = html.substring(marks[n].index, end);

    var name = '';
    var h3 = seg.match(/<h3[^>]*>([^<]+)<\/h3>/);
    if (h3) name = strip(h3[1]);
    if (name === '') {
      var alt = seg.match(/alt="([^"]*)"/);
      if (alt) name = strip(alt[1]);
    }
    if (name === '') continue;

    // 列表封面走懒加载 data-src；轮播/榜单卡片只有 src。
    // 两种都要认，但要排掉站内占位 SVG。
    var pic = '';
    var lazy = seg.match(/data-src="([^"]+)"/);
    if (lazy) pic = absUrl(unescapeHtml(lazy[1]));
    if (pic === '') {
      var plain = seg.match(/\ssrc="([^"]+)"/);
      if (plain) {
        pic = absUrl(unescapeHtml(plain[1]));
        if (pic.indexOf('placeholder') >= 0) pic = '';
      }
    }

    items.push({
      id: id, name: name, pic: pic,
      remark: '', brief: '', area: '', year: 0, type: ''
    });
    if (items.length >= 200) break;
  }
  return { items: items };
}

// ==================== 详情 ====================

function detailName(html, fallback) {
  var og = html.match(/property="og:title"\s+content="([^"]*)"/);
  var name = og ? unescapeHtml(og[1]).split(' - 第')[0].trim() : '';
  if (name === '') {
    var t = html.match(/<title>([^<]*)<\/title>/);
    name = t ? unescapeHtml(t[1]).split(' - ')[0].trim() : '';
  }
  return name !== '' ? name : fallback;
}

function detailCover(html) {
  var og = html.match(/property="og:image"\s+content="([^"]*)"/);
  if (og) return absUrl(unescapeHtml(og[1]));
  var lazy = html.match(/data-src="([^"]+)"/);
  return lazy ? absUrl(unescapeHtml(lazy[1])) : '';
}

function parseDetail(body, ctx) {
  var html = s(body);
  if (html === '') return { lines: [] };

  // 线路名来自 episodeManager(...) 里的 lineName: 'alists'。
  var lineNames = [];
  var re = /lineName:\s*'([^']*)'/g;
  var m;
  while ((m = re.exec(html)) !== null) lineNames.push(m[1]);

  // userlink 只出现在带引号的赋值里；页面还有 `window.myuserlink = userlink;`
  // 和 `||'0'`，泛匹配会抓到字符串 "userlink" 本身。
  var ul = html.match(/userlink:'([^']*)'/);
  var userlink = ul ? ul[1] : '0';

  var epRe = /<a href="\/play\/([A-Za-z0-9]+)"[^>]*?data-line="(\d+)"[^>]*?data-episode="(\d+)"[^>]*?dataid="(\d+)"[^>]*>([\s\S]*?)<\/a>/g;
  var grouped = {};
  var order = [];
  while ((m = epRe.exec(html)) !== null) {
    var line = parseInt(m[2], 10);
    if (!isFinite(line) || line < 1) line = 1;
    var ep = parseInt(m[3], 10);
    if (!isFinite(ep) || ep < 1) continue;

    var spans = m[5].match(/<span[^>]*>([^<]*)<\/span>/g);
    var label = '';
    if (spans && spans.length > 0) {
      var last = spans[spans.length - 1].match(/<span[^>]*>([^<]*)<\/span>/);
      label = last ? strip(last[1]) : '';
    }
    if (label === '') label = '第' + ep + '集';

    if (!grouped[line]) {
      grouped[line] = [];
      order.push(line);
    }
    grouped[line].push({
      name: label,
      url: '/play/' + m[1],
      // dataid 是取址的 p；userlink 算 k。宿主拆成 token0/token1。
      token: m[4] + '|' + userlink
    });
  }

  var lines = [];
  for (var n = 0; n < order.length; n++) {
    var ln = order[n];
    lines.push({
      line: lineNames[ln - 1] || ('线路' + ln),
      episodes: grouped[ln]
    });
  }

  var meta = html.match(/<meta\s+name="description"\s+content="([^"]*)"/);
  var intro = meta ? strip(meta[1]) : '';
  if (intro === '') {
    var kw = html.match(/<meta\s+name="keywords"\s+content="([^"]*)"/);
    intro = kw ? strip(kw[1]) : '';
  }

  return {
    name: detailName(html, s(ctx && ctx.dramaId)),
    pic: detailCover(html),
    content: intro,
    brief: intro,
    lines: lines
  };
}

// ==================== 签名（signEntry） ====================

var KVM_SECRET = 'nbmovie2024secretkey';

/** base64(userlink 逐字节 XOR 密钥)；空/未登录形态原样给 '0'。 */
function keyParam(userlink) {
  var u = s(userlink).trim();
  if (u === '' || u === '0') return '0';
  var hex = '';
  for (var i = 0; i < u.length; i++) {
    var b = u.charCodeAt(i) ^ KVM_SECRET.charCodeAt(i % KVM_SECRET.length);
    var h = b.toString(16);
    if (h.length < 2) h = '0' + h;
    hex += h;
  }
  // 注意：host.b64e 是**位置参数** b64e(s, fmt)，不是对象参数。
  // 写成 b64e({...}) 会把 "[object Object]" 编码进去，且不报错。
  return s(host.b64e(hex, 'hex'));
}

/**
 * 宿主在**每条**请求发出前调用。只处理 /video/play，其它请求原样放行。
 *
 * 返回 {query} 会覆盖同名参数；`userlink` 只是中间的承载字段，
 * 这里置空，不把凭据发给服务端。
 */
function sign(req) {
  var url = s(req && req.url);
  if (url.indexOf('/video/play') < 0) return {};

  var q = req.query || {};
  var dataid = s(q.p);
  var vodId = s(q.v);
  var userlink = s(q.userlink);
  if (dataid === '' || vodId === '') return {};

  return { query: buildPlayQuery(dataid, String(Date.now()), vodId, userlink) };
}

/**
 * 签名纯函数。单独提出来是为了能对拍：传入固定 ts，和 Dart 内置
 * 实现（`kvmPlayQuery`）逐字段比较。藏在 sign 里就只能靠读代码确认，
 * 而签名这种东西「看起来对」和「真的一样」差着一次线上 401。
 */
function buildPlayQuery(dataid, ts, vodId, userlink) {
  var msg = dataid + ':' + ts + ':' + vodId;
  // hmac 同样是位置参数 hmac(algo, key, msg)（见 signed-demo.js）。
  var full = s(host.hmac('sha256', vodId, msg));
  return {
    p: dataid,
    v: vodId,
    q: '1',
    t: ts,
    s: full.substring(0, 32),
    k: keyParam(userlink),
    // 承载字段，签完置空，不把 userlink 发给服务端
    userlink: ''
  };
}

// ==================== 取址 ====================

function parseResolve(body, ctx) {
  var text = s(body).trim();
  if (text === '') return { url: '', error: '取址接口没有返回内容' };
  if (text.charAt(0) !== '{') {
    return { url: '', error: '取址接口返回的不是 JSON' };
  }

  var d;
  try { d = JSON.parse(text); } catch (e) {
    return { url: '', error: '取址接口返回的内容坏了' };
  }
  if (!d || d.code !== 200) {
    var msg = d ? s(d.message || d.msg) : '';
    if (msg.indexOf('令牌') >= 0 || msg.indexOf('登录') >= 0) {
      return { url: '', error: '取址令牌已过期，请重试' };
    }
    return { url: '', error: msg !== '' ? msg : '取址失败' };
  }

  var urls = d.data && d.data.quality_urls;
  if (!urls || Object.prototype.toString.call(urls) !== '[object Array]') {
    return { url: '', error: '该集没有下发播放地址' };
  }

  // 4K 档标了 isvip 且 url 是字符串 "1"（占位符不是地址）。
  // 宁可降到 1080P，也不能把 "1" 丢给播放器。
  var fallback = '';
  for (var i = 0; i < urls.length; i++) {
    var one = urls[i];
    var url = s(one && one.url).trim();
    if (url.indexOf('http') !== 0) continue;
    if (!one.isvip && !one.locked) return { url: url };
    if (fallback === '') fallback = url;
  }
  if (fallback !== '') return { url: fallback };
  return { url: '', error: '该集没有可直接播放的地址，可能只在站点 VIP 线路上' };
}
