// 通用 MacCMS「网页模板」插件（HTML 版）。
//
// ============================================================
// 和 maccms-json.js / maccms-xml.js 什么关系
// ============================================================
//
// 那两个吃的是采集**接口**（`api.php/provide/vod/`），返回 JSON / XML。
// 这个吃的是**站点网页**，返回 HTML。三类的差别：
//
//   采集接口站：一个接口给全站数据，字段规整，最省事 —— 优先选这类
//   网页模板站：只能抓页面，靠正则抠锚点，模板一改就可能失效 —— 本脚本
//
// 为什么需要这一版：片库（pianku）这类站把采集接口关了
// （`api.php/provide/vod/` 实测 404），但网页本身结构稳定 ——
// 用的是同一套 MacCMS 模板，路径约定完全一致：
//
//   /vodtype/{id}.html               分类
//   /vodsearch/-------------.html?wd=  搜索
//   /voddetail/{id}.html             详情
//   /vodplay/{id}-{line}-{ep}.html   播放页（内含 player_aaaa 配置）
//
// 所以「接同类新站 = 填一份 JSON 配置」，路径与正则都能在 vars 里覆盖。
//
// ============================================================
// 为什么用正则而不是 DOM 解析
// ============================================================
//
// QuickJS 里没有 DOM（也没有 DOMParser）。宿主可以注入一个解析器，
// 但那会把「模板差异」变成「解析器能力问题」——采集站模板千奇百怪，
// 依赖 DOM 结构反而更脆。这里只抓几个稳定锚点：
// `href="…/voddetail/N.html"`、`title="…"`、`data-target="playlist-N"`。
//
// ============================================================
// 三个必须知道的结构事实（片库实测）
// ============================================================
//
// 1. **封面大量无扩展名**。片库有近一半封面是 CDN 直链，没有 `.jpg`，
//    例如 `http://m.ykimg.com/050E00006A85293BC7AFFF141AD91378`。
//    早期版本要求带图片后缀，结果这些卡片全部没封面，界面上
//    「隔一个空一个」。所以 coverOf 只认 `<img>` 标签，不看扩展名。
//
// 2. **线路能不能播，全看播放页里的 `from` 字段**：
//      from=wsym3u8 / jlm3u8 / mjzy → 直出 m3u8（可播）
//      from=qq / qiyi / bilibili    → 给的是网页地址（播放器打不开）
//    详情页 HTML 里**没有** `from`，只有线路名。所以这里不猜：
//    把「腾讯/奇异/B站」这类已知网页源沉底，其余保持站点原顺序。
//
// 3. **`player_aaaa` 是个 JSON 串但字段顺序不固定**，还可能带 `\/` 转义。
//    逐字段正则取，不用 JSON.parse（部分站的串里混了单引号，解析会炸）。
//
// ============================================================
// 接口约定（与 json / xml 版完全一致，可互换）
// ============================================================
//
//   parseList(body, ctx)    → { items: [{id, name, pic, remark, brief, area, year, type}] }
//   parseDetail(body, ctx)  → { name, pic, content, lines: [{line, episodes: [{name, url}]}] }
//   parseResolve(body, ctx) → { url } 或 { url: '', error: '人话原因' }
//
// ============================================================
// 硬性约束（违反会失败）
// ============================================================
//
// 1. **必须是同步函数**。返回 Promise 会被宿主直接拒绝。
// 2. **不能写死循环**（`while(true)` / `for(;;)`），宿主装载前会拒绝。
// 3. 返回值必须能被 JSON.stringify。

// ==================== 基础工具 ====================

/** 任意值 → 字符串。null/undefined → 空串。 */
function s(v) {
  if (v === null || v === undefined) return '';
  return String(v);
}

/** 取整数，失败给 0。 */
function i(v) {
  var n = parseInt(s(v), 10);
  return isNaN(n) ? 0 : n;
}

/**
 * HTML 实体还原。与宿主 `models.dart` 的 stripHtml 保持同一套语义。
 *
 * 循环 3 次是必要的：接口的简介字段实测有**二次转义**的
 * （`&amp;lt;p&amp;gt;`），只解一层会留下一堆 `&lt;p&gt;` 字样。
 */
function unescapeHtml(t) {
  var out = s(t);
  for (var n = 0; n < 3; n++) {
    var before = out;
    out = out
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&apos;/g, "'")
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&');
    if (out === before) break;
  }
  return out;
}

/**
 * 剥掉 HTML 标签，得到纯文本。
 *
 * `<br>` 与块级闭合标签替换成换行而不是删掉 —— 直接删会让整段简介
 * 粘成一行，用户看到的是一坨没有段落的长文。
 */
function strip(t) {
  var out = unescapeHtml(t);
  out = out.replace(/<br\s*\/?>/gi, '\n');
  out = out.replace(/<\/(p|div|li|h[1-6])\s*>/gi, '\n');
  out = out.replace(/<[^>]*>/g, '');
  // 行内连续空白压成单空格，但保留换行
  var lines = out.split('\n');
  var kept = [];
  for (var n = 0; n < lines.length; n++) {
    var one = lines[n].replace(/[ \t\u00a0]+/g, ' ').trim();
    if (one !== '') kept.push(one);
  }
  return kept.join('\n').trim();
}

/** 相对地址补成绝对地址。站点里 `//cdn.x/a.jpg` 这种协议相对写法很常见。 */
function absUrl(p, base) {
  var t = s(p).trim();
  if (t === '') return '';
  if (t.indexOf('//') === 0) return 'https:' + t;
  if (t.indexOf('http://') === 0 || t.indexOf('https://') === 0) return t;
  if (t.charAt(0) === '/') return s(base).replace(/\/+$/, '') + t;
  return t;
}

/**
 * 从一段 HTML 里挑出第一张像样的封面。
 *
 * **不能要求图片带 `.jpg/.png` 后缀**（见文件头注释第 1 条）。
 * 先圈出 `<img>` 标签再取属性，这样也天然排除了
 * `<script src="…jquery.min.js">` 这种同样带 src 的标签。
 */
function coverOf(seg, base) {
  var imgs = s(seg).match(/<img\b[^>]*>/gi);
  if (!imgs) return '';
  // 占位图 / 站标 / loading 图不能当封面，否则列表里全是同一个灰块
  var bad = /logo_placeholder|noneCoverImg|favicon|\/static\/|noimg|nopic|load\.gif/i;
  var attrRe = /(?:data-original|data-src|src)\s*=\s*"([^"]+)"/i;
  for (var n = 0; n < imgs.length; n++) {
    var m = imgs[n].match(attrRe);
    if (!m) continue;
    var p = s(m[1]).trim();
    if (p === '' || bad.test(p)) continue;
    // 脚本 / 样式 / loading 占位不是封面
    if (/\.(js|css|gif)(\?|$)/i.test(p)) continue;
    return absUrl(p, base);
  }
  return '';
}

/** 取 `<title>` 内容。 */
function docTitle(html) {
  var m = s(html).match(/<title>([^<]+)<\/title>/i);
  return m ? strip(m[1]) : '';
}

/** 取某个 `<meta name=… content=…>` 的 content。属性顺序两种都认。 */
function metaContent(html, name) {
  var h = s(html);
  var re1 = new RegExp('<meta\\s+name="' + name + '"\\s+content="([^"]*)"', 'i');
  var m = h.match(re1);
  if (m) return unescapeHtml(m[1]);
  var re2 = new RegExp('<meta\\s+content="([^"]*)"\\s+name="' + name + '"', 'i');
  m = h.match(re2);
  return m ? unescapeHtml(m[1]) : '';
}

/** 把 vars 里的逗号串拆成数组（去空白、去空项）。 */
function csv(v) {
  if (!v) return [];
  var parts = s(v).split(',');
  var out = [];
  for (var n = 0; n < parts.length; n++) {
    var one = parts[n].trim();
    if (one !== '') out.push(one);
  }
  return out;
}

/** 从 vars 读一个可选配置，空则用默认值。 */
function cfg(ctx, key, dflt) {
  var v = ctx && ctx.vars ? ctx.vars[key] : '';
  return (v === null || v === undefined || s(v).trim() === '') ? dflt : s(v);
}

// ==================== 列表 ====================

/**
 * 列表 / 搜索 / 首页 → 条目数组。
 *
 * 三条路径的 HTML 是同一套模板（首页、分类页、搜索页都是卡片流），
 * 所以共用这个函数。详情页里也有 24 张推荐卡片，但那边走 parseDetail，
 * 不会调到这里。
 */
function parseList(body, ctx) {
  var html = s(body);
  if (html === '') return { items: [] };

  var base = (ctx && ctx.baseUrl) || '';
  // 详情链接的形状可以在 vars 里覆盖（少数站用 /detail/N.html）
  var linkRe = new RegExp(cfg(ctx, 'detailLinkPattern',
    'href="/voddetail/(\\d+)\\.html"'), 'g');

  var items = [];
  var seen = {};
  var m;
  while ((m = linkRe.exec(html)) !== null) {
    var id = m[1];
    if (!id || seen[id]) continue;
    seen[id] = 1;

    // 卡片窗口取 900 字符：实测片库卡片从锚点到标题/封面都在 600 以内，
    // 900 留了余量。窗口太大反而会吃到下一张卡的标题。
    var seg = html.substring(m.index, Math.min(m.index + 900, html.length));

    var name = '';
    var tm = seg.match(/title="([^"]+)"/);
    if (tm) name = strip(tm[1]);
    if (name === '') {
      // 没有 title 属性时退到 alt（部分模板的懒加载卡片只有 alt）
      var am = seg.match(/alt="([^"]+)"/);
      if (am) name = strip(am[1]);
    }
    if (name === '') continue;

    var pic = coverOf(seg, base);
    // 备注（"全40集" / "HD"）在标题后面，取不到就留空
    var rm = seg.match(/class="[^"]*(?:remarks|note|pic-text)[^"]*"[^>]*>([^<]*)</i);
    var remark = rm ? strip(rm[1]) : '';

    items.push({
      id: id,
      name: name,
      pic: pic,
      remark: remark,
      brief: remark,
      area: '',
      year: 0,
      type: ''
    });

    // 防御：单页最多 200 条。正常的卡片流一页 20-60 条，
    // 200 已经宽到不会误伤；设上限是为了万一正则吃错（比如把
    // 导航栏里的某个固定链接也匹配上）不至于产出几千条。
    if (items.length >= 200) break;
  }

  return { items: items };
}

// ==================== 详情 ====================

/**
 * 详情页 → 元信息 + 分线路的选集。
 *
 * 结构（片库实测）：
 *
 *   <span class="source-tab-item" data-target="playlist-0">备用线路</span>
 *   ...
 *   <div id="playlist-0">
 *     <a href="/vodplay/15211-2-1.html" title="HD中字">
 *
 * 线路名在 tab 上，集数在各 pane 里，两边靠 `playlist-N` 这个 id 对齐。
 * 所以必须**先收 tab 名表，再按 pane 分段**——只按 pane 收会拿到
 * `playlist-0` 这种原始 id 当线路名，用户看不懂。
 */
function parseDetail(body, ctx) {
  var html = s(body);
  if (html === '') return { lines: [] };

  var base = (ctx && ctx.baseUrl) || '';

  // ---- 剧名 ----
  var raw = docTitle(html);
  var name = '';
  if (raw !== '') {
    // 形如「依然的喜事详情介绍-依然的喜事在线观看-…」，取第一段
    name = raw.split(/详情介绍|在线观看| - /)[0].trim();
  }
  if (name === '') name = metaContent(html, 'og:title');
  if (name === '') name = s(ctx && ctx.dramaId);

  // ---- 线路名表 ----
  var tabNames = {};
  var tabRe = new RegExp(cfg(ctx, 'tabPattern',
    'data-target="(playlist-\\d+)"[^>]*>([^<]+)</span>'), 'g');
  var tm;
  while ((tm = tabRe.exec(html)) !== null) {
    tabNames[tm[1]] = strip(tm[2]);
  }

  // ---- 按 pane 分段 ----
  var paneRe = new RegExp(cfg(ctx, 'panePattern', 'id="(playlist-\\d+)"'), 'g');
  var panes = [];
  var pm;
  while ((pm = paneRe.exec(html)) !== null) {
    panes.push({ at: pm.index, end: pm.index + pm[0].length, id: pm[1] });
  }

  var playRe = new RegExp(cfg(ctx, 'playLinkPattern',
    'href="(/vodplay/(\\d+)-(\\d+)-(\\d+)\\.html)"'), 'g');

  var webLines = csv(cfg(ctx, 'webLineNames',
    '腾讯,奇异,爱奇艺,优酷,B站,芒果,搜狐'));

  var lines = [];
  for (var n = 0; n < panes.length; n++) {
    var start = panes[n].end;
    var stop = (n + 1 < panes.length) ? panes[n + 1].at : html.length;
    if (stop <= start) continue;
    var seg = html.substring(start, stop);

    var paneId = panes[n].id;
    var lineName = tabNames[paneId] || paneId;

    var episodes = [];
    var seenEp = {};
    var em;
    playRe.lastIndex = 0;
    while ((em = playRe.exec(seg)) !== null) {
      var link = em[1];
      var lineNo = em[3];
      var ep = i(em[4]);
      // 同一集可能在同一 pane 里出现两次（PC / 移动两套模板都渲染了）
      var key = lineNo + '-' + ep;
      if (seenEp[key]) continue;
      seenEp[key] = 1;

      // 集名在锚点的 title 上（"HD中字" / "第01集"），取不到就用集数
      var tail = seg.substring(em.index, Math.min(em.index + 260, seg.length));
      var ttm = tail.match(/title="([^"]+)"/);
      var epName = ttm ? strip(ttm[1]) : '';
      if (epName === '') epName = ep > 0 ? ('第' + ep + '集') : '正片';

      episodes.push({ name: epName, url: link });
    }

    if (episodes.length === 0) continue;
    lines.push({ line: lineName, episodes: episodes });
  }

  // ---- 网页源沉底 ----
  // 不改其余线路的顺序：站点自己的排序通常已把自营/直出排在前面，
  // 我们只把「确定放不了」的那几条挪到最后。
  var direct = [];
  var web = [];
  for (var q = 0; q < lines.length; q++) {
    var isWeb = false;
    for (var w = 0; w < webLines.length; w++) {
      if (lines[q].line.indexOf(webLines[w]) >= 0) {
        isWeb = true;
        break;
      }
    }
    if (isWeb) web.push(lines[q]);
    else direct.push(lines[q]);
  }
  var ordered = direct.concat(web);

  // 简介：片库没有独立的简介区块，正文只在 meta 里
  var intro = metaContent(html, 'description');
  if (intro === '') {
    var dm = html.match(
      /<div[^>]*class="[^"]*(?:detail-content|vod-content|detail-desc)[^"]*"[^>]*>([\s\S]*?)<\/div>/i);
    if (dm) intro = strip(dm[1]);
  }

  return {
    name: name,
    pic: coverOf(html, base),
    content: strip(intro),
    brief: strip(intro),
    area: '',
    year: 0,
    remark: '',
    director: '',
    actor: '',
    lines: ordered
  };
}

// ==================== 取址 ====================

/**
 * 播放页 → 真实地址。
 *
 * `player_aaaa={"from":"wsym3u8","url":"https://…/index.m3u8",...}`
 *
 * 不用 JSON.parse 的理由：这个串里常见 `\/` 转义，个别站还混单引号，
 * `JSON.parse` 会直接抛异常；而抛异常在宿主侧只表现为「解析失败」，
 * 看不出是这行的问题。逐字段正则更钝，但更稳。
 */
function parseResolve(body, ctx) {
  var html = s(body);
  if (html === '') return { url: '', error: '播放页是空的，请换一条线路' };

  // 只在 player_aaaa 附近找，避免误抓页面上其它 JSON 配置里的 url 字段
  var at = html.indexOf('player_aaaa');
  var scope = at >= 0
    ? html.substring(at, Math.min(at + 1600, html.length))
    : html;

  function pick(key) {
    var m = scope.match(new RegExp('"' + key + '"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"'));
    if (!m) return '';
    // `\/` 是合法 JSON 转义，还原成 `/`，否则拼出的地址打不开
    return m[1].replace(/\\\//g, '/').replace(/\\\\/g, '\\');
  }

  var url = pick('url');
  var from = pick('from');

  if (url.indexOf('http') !== 0 && url.indexOf('/') !== 0) {
    return { url: '', error: '这条线路没有返回播放地址，请切换其它线路' };
  }

  // qq / qiyi / bilibili 这类线路给的是网页地址，播放器放不开。
  // 这里给出能指导操作的话，而不是让它走到播放器再报格式不支持。
  if (url.indexOf('.m3u8') < 0 && url.indexOf('.mp4') < 0) {
    var cn = s(ctx && ctx.line) || from;
    return {
      url: '',
      error: '「' + cn + '」是网页源，播放器放不了，请在选集上方切到自营/备用线路'
    };
  }

  return { url: url };
}