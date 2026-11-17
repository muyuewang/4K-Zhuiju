// 极速追剧（jisuzhuiju.com）专用插件。
//
// 不是 MacCMS：采集接口 404，只能抓 HTML；搜索参数叫 keyword（不是 wd）；
// 取址走独立的 `/api/play-url`，要 `playFrom=<线路前缀>` + `index=<集数>`。
//
// ==================== 三个实测坑（写出来防止再踩） ====================
//
// 1. 站点对非浏览器 UA 直接 403 —— UA 由清单的 defaultHeaders 提供，
//    脚本不要指望宿主默认 UA。
//
// 2. 选集锚点的 `data-index` 是 **0-based**，而取址 API 的 `index` 是
//    1-based。这里一律从 URL 尾段取集数，绝不用 data-index。
//    index=0 会回 500「未找到该集播放地址」，且看不出是参数错。
//
// 3. 各线路集数不同（qq 15 集、其余 12 集）。必须逐面板收自己的集数，
//    按最长线路补齐就是造死链。
//
// 列表/搜索是两套卡片模板（.vod-card / .search-item），都在 parseList 里处理。
//
// 同步函数、无死循环、返回 JSON.stringify 能序列化的对象。

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
      .replace(/&#x27;/g, "'").replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&');
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

function absUrl(p, base) {
  var t = s(p).trim();
  if (t === '') return '';
  if (t.indexOf('//') === 0) return 'https:' + t;
  if (t.indexOf('http://') === 0 || t.indexOf('https://') === 0) return t;
  if (t.charAt(0) === '/') return s(base).replace(/\/+$/, '') + t;
  return t;
}

/** 站点 alt 写成「XX封面图片」，去掉后缀才像剧名。 */
function cleanTitle(t) {
  var v = strip(t);
  var suffixes = ['封面图片', '海报', '封面'];
  for (var n = 0; n < suffixes.length; n++) {
    if (v.length > suffixes[n].length &&
        v.substring(v.length - suffixes[n].length) === suffixes[n]) {
      return v.substring(0, v.length - suffixes[n].length).trim();
    }
  }
  return v;
}

// ==================== 列表 / 搜索 ====================

function parseList(body, ctx) {
  var html = s(body);
  if (html === '') return { items: [] };
  var base = (ctx && ctx.baseUrl) || '';
  var items = [];
  var seen = {};

  function add(id, name, pic) {
    if (!id || seen[id]) return;
    name = cleanTitle(name);
    if (name === '') return;
    seen[id] = 1;
    items.push({
      id: id,
      name: name,
      pic: absUrl(pic, base),
      remark: '',
      brief: '',
      area: '',
      year: 0,
      type: ''
    });
  }

  // 分类页 / 首页：`<a href="/detail/N.html"><div class="vod-card">…`
  var cardRe = /<a href="\/detail\/(\d+)\.html"[^>]*>\s*<div class="vod-card">([\s\S]*?)<\/div>\s*<\/div>\s*<\/a>/g;
  var m;
  while ((m = cardRe.exec(html)) !== null) {
    var block = m[2];
    var tm = block.match(/<p class="vod-title[^"]*"[^>]*>([^<]*)<\/p>/);
    var name = tm ? tm[1] : '';
    if (name === '') {
      var am = block.match(/alt="([^"]*)"/);
      name = am ? am[1] : '';
    }
    var pm = block.match(/<img[^>]*src="([^"]+)"/);
    add(m[1], name, pm ? pm[1] : '');
  }

  // 搜索页：`.search-item-poster` 里直接带 img + alt
  var searchRe = /<a href="\/detail\/(\d+)\.html"[^>]*class="search-item-poster"[^>]*>([\s\S]*?)<\/a>/g;
  while ((m = searchRe.exec(html)) !== null) {
    var seg = m[2];
    var im = seg.match(/<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"/);
    if (!im) {
      // 属性顺序偶尔反过来
      im = seg.match(/<img[^>]*alt="([^"]*)"[^>]*src="([^"]*)"/);
      add(m[1], im ? im[1] : '', im ? im[2] : '');
    } else {
      add(m[1], im[2], im[1]);
    }
  }

  return { items: items };
}

// ==================== 详情 ====================

function detailName(html, fallback) {
  var og = html.match(/property="og:title"\s+content="([^"]*)"/);
  var raw = og ? unescapeHtml(og[1]).trim() : '';
  var book = raw.match(/《([^》]+)》/);
  if (book && book[1].trim() !== '') return book[1].trim();
  if (raw !== '') {
    var n = raw.split('高清')[0].trim();
    if (n !== '') return n;
  }
  var t = html.match(/<title>([^<]*)<\/title>/);
  var cleaned = t ? unescapeHtml(t[1]).split(' - ')[0].trim() : '';
  return cleaned !== '' ? cleaned : fallback;
}

function detailCover(html, base) {
  var p = html.match(/class="detail-poster-wrapper"[^>]*>\s*<img[^>]*src="([^"]+)"/);
  if (p) return absUrl(p[1], base);
  var og = html.match(/property="og:image"\s+content="([^"]*)"/);
  return og ? absUrl(og[1], base) : '';
}

function parseDetail(body, ctx) {
  var html = s(body);
  if (html === '') return { lines: [] };
  var base = (ctx && ctx.baseUrl) || '';

  // 线路名：source-N → 中文名
  var names = {};
  var tabRe = /data-target="source-(\d+)"[^>]*>([^<]*)<\/button>/g;
  var tm;
  while ((tm = tabRe.exec(html)) !== null) {
    names[tm[1]] = strip(tm[2]);
  }

  // 面板：`<div class="source-panel"\s+id="source-N">` —— 中间是换行+缩进，
  // 写成单个空格会一个也匹配不到，详情页会整页空（52 集全丢）。
  var panels = [];
  var panelRe = /<div class="source-panel"\s+id="source-(\d+)"/g;
  var pm;
  while ((pm = panelRe.exec(html)) !== null) {
    panels.push({ at: pm.index, idx: pm[1] });
  }

  var lines = [];
  for (var n = 0; n < panels.length; n++) {
    var start = panels[n].at;
    var stop = n + 1 < panels.length ? panels[n + 1].at : html.length;
    var seg = html.substring(start, stop);

    var linkRe = /href="(\/vodplay\/(\d+)-([A-Za-z0-9]+)-(\d+)\.html)"[^>]*>([^<]*)</g;
    var episodes = [];
    var seenEp = {};
    var prefix = '';
    var em;
    while ((em = linkRe.exec(seg)) !== null) {
      var ep = parseInt(em[4], 10);
      if (!isFinite(ep) || ep < 1 || seenEp[ep]) continue;
      seenEp[ep] = 1;
      if (prefix === '') prefix = em[3];
      var label = strip(em[5]);
      episodes.push({
        name: label !== '' ? label : ('第' + ep + '集'),
        url: em[1],
        // 取址要 playFrom=<prefix> + index=<ep>（1-based）。
        // 宿主把 token 拆成 token0/token1 供清单模板取用。
        token: em[3] + '|' + ep
      });
    }
    if (episodes.length === 0) continue;
    lines.push({
      line: names[panels[n].idx] || prefix || ('线路' + panels[n].idx),
      episodes: episodes
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
    pic: detailCover(html, base),
    content: intro,
    brief: intro,
    lines: lines
  };
}

// ==================== 取址 ====================

/**
 * body 是 `/api/play-url` 的 JSON 应答。
 * `code:500` + `msg:未找到...` 表示该线路没有这一集 —— 翻成人话，
 * 原文对用户毫无意义。
 */
function parseResolve(body, ctx) {
  var text = s(body).trim();
  if (text === '') return { url: '', error: '取址接口没有返回内容' };
  if (text.charAt(0) !== '{') {
    return { url: '', error: '取址接口返回的不是 JSON，请稍后重试' };
  }

  var d;
  try { d = JSON.parse(text); } catch (e) {
    return { url: '', error: '取址接口返回的内容坏了' };
  }
  if (!d || typeof d !== 'object') {
    return { url: '', error: '取址接口返回的内容坏了' };
  }

  var code = typeof d.code === 'number' ? d.code : parseInt(d.code, 10);
  if (code !== 200) {
    var msg = s(d.message || d.msg || '').trim();
    if (msg.indexOf('未找到') >= 0) {
      return { url: '', error: '这条线路没有这一集，换个线路试试' };
    }
    return { url: '', error: msg !== '' ? msg : ('取址失败（code ' + code + '）') };
  }

  var url = s(d.url).trim();
  if (url.indexOf('http') !== 0) {
    return { url: '', error: '该集没有可播放的地址' };
  }
  return { url: url };
}
