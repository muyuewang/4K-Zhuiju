// 低调影视（ddys.io）专用插件。
//
// ## 为什么是 .io 不是 .app
//
// ddys.app 挂了 ddys-protect 三层闸门：访客密码、ALTCHA 工作量证明、
// 3 点图形点选验证码。前两层能程序化通过，第三层必须看图点选，
// 客户端做不到无感通过。但 ddys.io 是同系列无需闸门的入口，
// 内置源接的就是它 —— 这里保持一致。
//
// ## Cloudflare 的一个反直觉细节
//
// 站点拦的是「浏览器 UA + 非浏览器 TLS 指纹」这个**不一致组合**：
// Chrome UA + Dart TLS 必被挑战，如实报 `Dart/3.5 (dart:io)` 反而 200。
// 所以清单的 defaultHeaders 必须覆盖宿主默认 UA。
//
// ## 播放零请求
//
// 详情页把每集 m3u8 直接写在 `switchSource(...)` 里，path 就是地址，
// 不需要 resolve 接口。
//
// 同步函数、无死循环、返回可 JSON 序列化对象。

function s(v) {
  if (v === null || v === undefined) return '';
  return String(v);
}

function i(v) {
  var n = parseInt(s(v), 10);
  return isNaN(n) ? 0 : n;
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

  var starts = [];
  var re = /<div class="movie-card/g;
  var m;
  while ((m = re.exec(html)) !== null) starts.push(m.index);

  var items = [];
  var seen = {};
  for (var n = 0; n < starts.length; n++) {
    var stop = n + 1 < starts.length ? starts[n + 1] : html.length;
    var seg = html.substring(starts[n], stop);

    var sm = seg.match(/href="\/movie\/([A-Za-z0-9_\-]+)"/);
    if (!sm || seen[sm[1]]) continue;
    seen[sm[1]] = 1;

    var name = '';
    var h3 = seg.match(/<h3[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)<\/a>/);
    if (h3) name = strip(h3[1]);
    if (name === '') {
      var alt = seg.match(/alt="([^"]*)"/);
      if (alt) name = strip(alt[1]);
    }
    if (name === '') continue;

    var cover = '';
    var im = seg.match(/<img[^>]*src="([^"]+)"/);
    if (im) cover = absUrl(im[1]);

    var year = 0;
    var clazz = '';
    var meta = seg.match(/(\d{4})\s*·\s*([^<\n]{1,20})/);
    if (meta) {
      year = i(meta[1]);
      clazz = meta[2].trim();
    }
    var online = seg.match(/在线：\s*(\d+)/);
    var pan = seg.match(/网盘：\s*(\d+)/);
    var note = [];
    if (online) note.push('在线 ' + online[1]);
    if (pan) note.push('网盘 ' + pan[1]);

    items.push({
      id: sm[1], name: name, pic: cover,
      remark: note.join(' · '), brief: note.join(' · '),
      year: year, clazz: clazz, type: clazz,
      area: '', director: '', actor: ''
    });
  }
  return { items: items };
}

// ==================== 详情 ====================

function labeled(html, label) {
  var re = new RegExp(label + '：</span>\\s*<span[^>]*>([^<]*)</span>');
  var m = html.match(re);
  return m ? strip(m[1]) : '';
}

function detailMeta(html, fallback) {
  var name = '';
  var h1 = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/);
  if (h1) {
    // h1 里还嵌了别名 <span>，取第一段文本
    name = strip(h1[1].split('<span')[0]);
  }
  if (name === '') name = fallback;

  var year = 0, area = '', tags = '';
  var line = html.match(/(\d{4})\s*·\s*([^·<]{1,20})·\s*([^<\n]{1,60})/);
  if (line) {
    year = i(line[1]);
    area = line[2].trim();
    tags = line[3].trim();
  } else {
    var y = html.match(/(\d{4})\s*·\s*([^<\n]{1,40})/);
    if (y) year = i(y[1]);
  }

  var stars = 0;
  var r = html.match(/豆瓣（\s*([\d.]+)\s*）/);
  if (r) stars = parseFloat(r[1]) || 0;

  var desc = html.match(/<meta\s+name="description"\s+content="([^"]*)"/);
  var intro = desc ? strip(desc[1]) : '';

  // 页面没有 og:image；锚定 alt == 剧名的那张海报
  var cover = '';
  var imgRe = /<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)"/g;
  var im;
  while ((im = imgRe.exec(html)) !== null) {
    if (name && strip(im[2]) === name) {
      cover = absUrl(im[1]);
      break;
    }
  }
  if (cover === '') {
    var first = html.match(/<img[^>]*src="(https:\/\/img\.ddys\.io\/[^"]+)"/);
    if (first) cover = absUrl(first[1]);
  }

  return {
    name: name, year: year, area: area, tags: tags, stars: stars,
    intro: intro, cover: cover,
    director: labeled(html, '导演'), actor: labeled(html, '主演')
  };
}

function epNo(title, fallback) {
  var m = title.match(/第\s*(\d+)\s*[集话期]/);
  var v = m ? i(m[1]) : 0;
  return v >= 1 ? v : fallback;
}

function parseDetail(body, ctx) {
  var html = s(body);
  if (html === '') return { lines: [] };

  // onclick="switchSource(16729, '第01集$url#第02集$url', 'm3u8')"
  var re = /onclick="switchSource\(\s*(\d+)\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*\)"([\s\S]*?)<\/button>/g;
  var lines = [];
  var m;
  while ((m = re.exec(html)) !== null) {
    var payload = s(m[2]).trim();
    var type = s(m[3]).trim();
    if (type !== '' && type !== 'm3u8') continue;

    var tail = s(m[4]);
    var after = tail.indexOf('>') >= 0 ? tail.split('>').pop() : tail;
    var name = strip(after);
    if (name === '') name = '播放源 ' + (lines.length + 1);

    var eps = [];
    // 形态一：纯 URL（电影常见），既可能是 http 也可能是 //cdn
    var bare = payload.indexOf('$') < 0 &&
        (payload.indexOf('http') === 0 || payload.indexOf('//') === 0);
    if (bare) {
      var u = absUrl(payload);
      if (u !== '') eps.push({ name: '正片', url: u });
    } else {
      // 形态二：`第01集$url#第02集$url`
      var parts = payload.split('#');
      for (var n = 0; n < parts.length; n++) {
        var one = parts[n].trim();
        var cut = one.indexOf('$');
        if (cut <= 0) continue;
        var epName = one.substring(0, cut).trim() || ('第' + (eps.length + 1) + '集');
        var epUrl = absUrl(one.substring(cut + 1).trim());
        if (epUrl.indexOf('http') !== 0) continue;
        eps.push({
          name: epName,
          url: epUrl,
          episode: epNo(epName, eps.length + 1)
        });
      }
    }
    if (eps.length > 0) lines.push({ line: name, episodes: eps });
  }

  var meta = detailMeta(html, s(ctx && ctx.dramaId));
  return {
    name: meta.name,
    pic: meta.cover,
    content: meta.intro,
    brief: meta.intro,
    area: meta.area,
    year: meta.year,
    stars: meta.stars,
    tag: meta.tags,
    director: meta.director,
    actor: meta.actor,
    lines: lines
  };
}
