// 剧踪影院（juzong）插件。
//
// ============================================================
// 这个源和 maccms-html.js 什么关系，为什么不直接复用
// ============================================================
//
// 它是 MacCMS + stui 模板站，路径形态和 maccms-html.js 一样
// （`/voddetail/{id}/`、`/vodplay/{id}-{line}-{ep}/`），但有三处**结构差异**
// 让复用变成一堆 if-else，不如单独一份：
//
//   1. **变量名是 `player_data`，不是 `player_aaaa`**
//      标准 MacCMS 用 `player_aaaa={"flag":...}`，这里实测是
//      `var player_data={"flag":"play",...}`。maccms-html.js 里写死了
//      `indexOf('player_aaaa')`，拿不到就会退化成全文搜索，容易抓到
//      页面上别的 JSON 配置里的 url 字段。
//
//   2. **路径不带 `.html` 后缀**
//      `/voddetail/106/`、`/vodplay/106-1-1/`。maccms-html.js 的默认正则
//      带 `\\.html`，改配置能覆盖，但下面的第 3 条覆盖不了。
//
//   3. **采集接口被关了，但有个 JSON 接口能列表**
//      `api.php/provide/vod/` 实测 301 打回首页（采集接口已归档），
//      可是 `/index.php/ajax/data?mid=1&ac=detail` 能返回标准 JSON
//      （`code/total/page/list`，全量 6.2 万条）。列表走 JSON 比抓 HTML
//      稳得多 —— HTML 里封面是懒加载、备注在 `<span class="pic-text">`，
//      而 JSON 直接把 `vod_pic` / `vod_remarks` / `vod_blurb` 给全了。
//
// ============================================================
// 三条必须知道的结构事实（2026-11-19 实测）
// ============================================================
//
// 1. **搜索页有「挑战式」软验证，必须靠宿主的 cookieJar**
//    无 cookie 请求 `/vodsearch/` 一律回 403（连测四次、冷却 50 秒后
//    仍然 403），但那次 403 的响应头里带 `Set-Cookie`；带着它重发一次
//    就是 200 + 22 条结果（连测 3 次全成功）。随便编一个 cookie 值无效，
//    服务端认值。
//    所以清单里必须开 `cookieJar: true`，由宿主吸收 Set-Cookie 并在
//    403 后自动重试一次。**这不是图形验证码，也不需要跑 JS。**
//
// 2. **线路分成三种，只有一种能在本体系里播**
//
//    | 线路名 | from | `url` 长什么样 | 能不能播 |
//    | --- | --- | --- | --- |
//    | 剧踪XG[海外] | xiguam3u8 | `https://…/index.m3u8` | 能 |
//    | 剧踪BF[海外] | bfzym3u8 | `https://…/index.m3u8` | 能 |
//    | 剧踪DY[海外] | dyttm3u8 | `https://…/index.m3u8` | 能 |
//    | 剧踪独家[*] | dujiarbx 等 | `juzong1-<票据>` | 不能 |
//    | 剧踪鹅播/爱播/酷播 | qq/qiyi/youku | 网页地址 | 不能 |
//
//    票据线要经第三方解析站（`jzpic.ok1333.cn` / `jzpic.wanmeikan.xyz`），
//    返回的 `config.url` 是 AES 密文，解密逻辑在 jsjiami v6 混淆过的
//    `setting.js` 里，实测按 vkey 直接派生密钥解不出来。
//    所以票据线与网页线**一律沉到底部**，parseResolve 给一句人话说明，
//    让用户知道该切哪条，而不是点开看到一个播放器错误码。
//
// 3. **详情页每条线路是一个独立 panel，靠 h3 标题分段**
//
//      <div class="stui-pannel-box b playlist mb">
//        <h3 class="title"><img src="…"/>剧踪独家[热播X]</h3>
//        <ul class="stui-content__playlist">
//          <li><a href="/vodplay/106-1-1/">第01集</a></li>
//
//    实测一部 167 集的剧，10 个 panel 每个都是完整 167 集，所以
//    **绝不能**全页扫 `/vodplay/` 链接 —— 那样会把 1670 条集数
//    混成一条线路。必须先按 panel 切块，再在块内收链接。
//
// ============================================================
// 接口约定（与 maccms-html.js 完全一致，可互换）
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
 * HTML 实体还原。
 *
 * 循环 3 次：接口的简介字段实测有**二次转义**的（`&amp;lt;p&amp;gt;`），
 * 只解一层会留下一堆 `&lt;p&gt;` 字样。
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

/** 剥掉 HTML 标签。`<br>` 与块级闭合标签换成换行，避免整段粘成一行。 */
function strip(t) {
  var out = unescapeHtml(t);
  out = out.replace(/<br\s*\/?>/gi, '\n');
  out = out.replace(/<\/(p|div|li|h[1-6])\s*>/gi, '\n');
  out = out.replace(/<[^>]*>/g, '');
  var lines = out.split('\n');
  var kept = [];
  for (var n = 0; n < lines.length; n++) {
    var one = lines[n].replace(/[ \t\u00a0]+/g, ' ').trim();
    if (one !== '') kept.push(one);
  }
  return kept.join('\n').trim();
}

/** 相对地址补成绝对地址。 */
function absUrl(p, base) {
  var t = s(p).trim();
  if (t === '') return '';
  if (t.indexOf('//') === 0) return 'https:' + t;
  if (t.indexOf('http://') === 0 || t.indexOf('https://') === 0) return t;
  if (t.charAt(0) === '/') return s(base).replace(/\/+$/, '') + t;
  return t;
}

/** 取 `<title>` 内容。 */
function docTitle(html) {
  var m = s(html).match(/<title>([^<]+)<\/title>/i);
  return m ? strip(m[1]) : '';
}

/** 取 `<meta name=… content=…>` 的 content，属性顺序两种都认。 */
function metaContent(html, name) {
  var h = s(html);
  var m = h.match(new RegExp('<meta\\s+name="' + name + '"\\s+content="([^"]*)"', 'i'));
  if (m) return unescapeHtml(m[1]);
  m = h.match(new RegExp('<meta\\s+content="([^"]*)"\\s+name="' + name + '"', 'i'));
  return m ? unescapeHtml(m[1]) : '';
}

/** 把 vars 里的逗号串拆成数组。 */
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

/** 从一段 HTML 里挑第一张像样的封面。 */
function coverOf(seg, base) {
  var imgs = s(seg).match(/<img\b[^>]*>/gi);
  if (!imgs) return '';
  var bad = /logo_placeholder|noneCoverImg|favicon|\/statics?\/|noimg|nopic|load\.gif|icon_\d+\.png/i;
  var attrRe = /(?:data-original|data-src|src)\s*=\s*"([^"]+)"/i;
  for (var n = 0; n < imgs.length; n++) {
    var one = imgs[n];
    // 详情页第一张图是站方塞在 `#topbanner`（`display:none`）里的提示图：
    //   <img src="https://m.ykimg.com/…" class="tip-img" loading="lazy">
    // 它不是封面，但因为在最前面，按「第一张像样的图」取就会命中它 ——
    // 结果是详情页封面永远显示一张和剧无关的优酷占位图。
    if (/class="[^"]*tip-img/i.test(one)) continue;
    var m = one.match(attrRe);
    if (!m) continue;
    var p = s(m[1]).trim();
    if (p === '' || bad.test(p)) continue;
    if (/\.(js|css|gif)(\?|$)/i.test(p)) continue;
    return absUrl(p, base);
  }
  return '';
}

/**
 * 线路名 → 排序档位。值越小越靠前。
 *
 * 0 = 明文 m3u8（能播）
 * 1 = 认不出来（保持站点原顺序，排在明文后面）
 * 2 = 网页源（qq / 优酷这类，给的是网页地址）
 * 3 = 票据线（要第三方解析，实测解不出）
 *
 * **为什么按名字判断而不是按 from**：`from` 只在播放页里有，
 * 详情页拿不到。等拿到 from 时用户已经在播了，那时排序已经没意义。
 * 名字虽然比 from 脏一点，但它是详情页唯一可见的信号。
 */
function lineRank(name, ctx) {
  var n = s(name);
  var ticket = csv(cfg(ctx, 'ticketLineHints', '独家,维护'));
  for (var a = 0; a < ticket.length; a++) {
    if (n.indexOf(ticket[a]) >= 0) return 3;
  }
  var web = csv(cfg(ctx, 'webLineNames', '鹅播,爱播,酷播,芒果,腾讯,爱奇艺,优酷,B站,搜狐'));
  for (var b = 0; b < web.length; b++) {
    if (n.indexOf(web[b]) >= 0) return 2;
  }
  var plain = csv(cfg(ctx, 'plainLineHints', 'XG,BF,DY,WJ,WS,蓝光,专线'));
  for (var c = 0; c < plain.length; c++) {
    if (n.indexOf(plain[c]) >= 0) return 0;
  }
  return 1;
}

// ==================== 列表 ====================

/**
 * 列表 / 搜索 / 首页 → 条目数组。
 *
 * ## 一个函数吃两种格式（这是本插件最容易踩的坑）
 *
 * - **列表/分类** 走 `/index.php/ajax/data?mid=1&ac=detail` → **JSON**
 * - **搜索** 走 `/vodsearch/…?wd=` → **HTML**（站方没有搜索 JSON 接口：
 *   `ajax/data` 会**静默忽略** `wd` 参数，返回全量 6.2 万条。这意味着
 *   「用一个接口顺便把搜索也做了」是行不通的 —— 实测过 8 种参数名
 *   （wd/keyword/key/name/search/k/q/title），全部返回全量列表。）
 *
 * 所以这里先看首字符：`{` 按 JSON，否则按 HTML 抠卡片。
 * 两条路都返回同一套 items 结构，上层无感。
 */
function parseList(body, ctx) {
  var t = s(body).trim();
  if (t === '') return { items: [] };

  // JSON 分支：首字符是 `{` 就当 JSON 试，失败再退回 HTML
  if (t.charAt(0) === '{') {
    var byJson = parseListJson(t, ctx);
    if (byJson.items.length > 0) return byJson;
  }
  return parseListHtml(t, ctx);
}

/** JSON 形态（`/index.php/ajax/data`，标准 MacCMS 字段）。 */
function parseListJson(t, ctx) {
  var data;
  try {
    data = JSON.parse(t);
  } catch (e) {
    return { items: [] };
  }

  // 接口异常时回 `{"code":1001,"msg":"参数错误"}`，没有 list
  var arr = data ? data.list : null;
  if (!arr || !arr.length) return { items: [] };

  var base = (ctx && ctx.baseUrl) || '';
  var items = [];
  for (var n = 0; n < arr.length; n++) {
    var x = arr[n] || {};
    var id = s(x.vod_id);
    var name = s(x.vod_name);
    // 没有 id 或名字的条目直接丢：前者点进去必崩，后者是一块空白占位
    if (id === '' || name === '') continue;

    var pic = absUrl(s(x.vod_pic), base);
    // 站点没图时填的是 `/`，那不是地址，当成没有
    if (pic === '/') pic = '';

    items.push({
      id: id,
      name: name,
      pic: pic,
      remark: s(x.vod_remarks),
      // 简介必须过 `strip`：接口原样返回 `&nbsp;大唐敦煌…` 且带 `\r\n`，
      // 直接塞进 UI 会显示成「&nbsp;大唐敦煌」——列表页每一条都这样，
      // 一眼就能看出没处理。
      brief: strip(s(x.vod_blurb)) || s(x.vod_remarks),
      area: s(x.vod_area),
      year: i(x.vod_year),
      type: s(x.vod_class)
    });
  }
  return { items: items };
}

/**
 * 从一张卡片里取封面。
 *
 * **不能只认 `<img>` 标签** —— 这是实测踩到的：搜索页的卡片根本没有
 * `<img>`，封面直接写在锚点的 `data-original` 属性上（懒加载靠 JS 补 img）：
 *
 *   <a class="v-thumb stui-vodlist__thumb lazyload"
 *      href="/voddetail/14108/" title="五十度黑"
 *      data-original="https://p5.music.126.net/…jpg">
 *
 * 只认 img 的结果是搜索页**全部无封面**（列表页走 JSON 有 vod_pic，
 * 所以只有搜索看起来坏掉，很容易以为是搜索本身的问题）。
 */
function thumbOf(seg, base) {
  // 站标/占位图不能当封面。注意 `statics` 是复数 —— 站点图标在
  // `/statics/icon/icon_1.png`，只写 `/static/` 拦不住，会有一半卡片
  // 顶着同一个站标。
  var bad = /logo_placeholder|noneCoverImg|favicon|\/statics?\/|noimg|nopic|load\.gif|icon_\d+\.png/i;

  // 懒加载属性优先，其次 src
  var pats = [
    /data-original\s*=\s*"([^"]+)"/i,
    /data-src\s*=\s*"([^"]+)"/i,
    /<img\b[^>]*\bsrc\s*=\s*"([^"]+)"/i
  ];
  for (var n = 0; n < pats.length; n++) {
    var m = s(seg).match(pats[n]);
    if (!m) continue;
    var p = s(m[1]).trim();
    if (p === '' || p === '/' || bad.test(p)) continue;
    if (/\.(js|css|gif)(\?|$)/i.test(p)) continue;
    return absUrl(p, base);
  }
  return coverOf(seg, base);
}

/**
 * HTML 形态（搜索结果页）。
 *
 * 卡片结构（实测）：
 *
 *   <li class="active clearfix">
 *     <div class="thumb">
 *       <a class="v-thumb stui-vodlist__thumb lazyload"
 *          href="/voddetail/14108/" title="五十度黑" data-original="https://…jpg">
 *         <span class="pic-text text-right">HD中字</span>
 *       </a>
 *     </div>
 *     <div class="detail">
 *       <h3 class="title"><a href="/voddetail/14108/">五十度黑</a></h3>
 *       <p><span class="text-muted">类型：</span>喜剧<span class="split-line"></span>
 *          <span class="text-muted">地区：</span>美国…<span class="text-muted">年份：</span>2016
 *
 * 只认 `href="/voddetail/{数字}/"` 这个锚点（**带尾部斜杠，没有 .html**），
 * 再去窗口里取 title / data-original / pic-text。
 */
function parseListHtml(html, ctx) {
  var base = (ctx && ctx.baseUrl) || '';

  // **先剔掉侧边栏的榜单**，这是实测踩到的第二个坑（而且分两轮才剔干净）。
  //
  // 搜索页除了结果卡片，还带四块榜单，全部命中 `href="/voddetail/(\d+)/"`：
  //
  //   电影热播榜  <ul class="stui-vodlist__media active col-pd clearfix">
  //   剧集热播榜  <ul class="stui-vodlist__media active col-pd clearfix">
  //   热播榜      <ul class="stui-vodlist__text active col-pd clearfix">
  //   新上线      <ul class="stui-vodlist__text active col-pd clearfix">
  //
  // 而**真正的搜索结果块没有 `active`**：
  //
  //   查询结果    <ul class="stui-vodlist__media col-pd clearfix">
  //
  // 第一版只删了 `stui-vodlist__text`，漏掉两块 media 版榜单，结果搜「色戒」
  // 拿回的 4 条里有 2 条是「欢迎来龙餐馆」「嫁金钗」——与关键词毫不相关，
  // 而且有封面有主演，界面上看不出是噪声，比没结果更误导。
  //
  // 判据就用 `active` + 这两个 class 的组合：既覆盖两类榜单，
  // 又不会误删真实结果（真实结果不带 active）。两块榜单都是平铺的 li，
  // 没有嵌套，非贪婪匹配即可安全删除。
  var cleaned = s(html)
    .replace(/<ul[^>]*class="[^"]*stui-vodlist__(?:text)[^"]*"[^>]*>[\s\S]*?<\/ul>/gi, '')
    .replace(/<ul[^>]*class="[^"]*stui-vodlist__media[^"]*\bactive\b[^"]*"[^>]*>[\s\S]*?<\/ul>/gi, '');

  var linkRe = new RegExp(cfg(ctx, 'detailLinkPattern',
    'href="/voddetail/(\\d+)/"'), 'g');

  // 从一段卡片 HTML 里取「标签：值」。定义在循环**外面**：
  // QuickJS 对块内函数声明的处理不保证（sloppy mode 下各引擎不一致），
  // 放进 while 里可能在第二圈就取不到。
  function labelled(seg, label) {
    var r = seg.match(new RegExp(
      '<span class="text-muted">' + label + '：?</span>\\s*([^<]{1,40})', 'i'));
    return r ? strip(r[1]) : '';
  }

  var items = [];
  var seen = {};
  var m;
  while ((m = linkRe.exec(cleaned)) !== null) {
    var id = m[1];
    if (!id || seen[id]) continue;
    seen[id] = 1;

    // 窗口 1200 字符：媒体列表版卡片带导演/主演/类型/地区/年份五段，
    // 比网格版长不少。窗口太小会吃不到「年份」。
    //
    // 截窗必须基于 `cleaned` 而不是原始 `html` —— 上面删掉两块榜单后
    // 长度已经变了，`m.index` 是 `cleaned` 里的下标，拿去切原始串会整体
    // 前移，把上一张卡片的封面/年份错配给当前条目。
    var seg = cleaned.substring(m.index, Math.min(m.index + 1200, cleaned.length));

    var name = '';
    var tm = seg.match(/title="([^"]+)"/);
    if (tm) name = strip(tm[1]);
    if (name === '') {
      // 没有 title 时退到卡片标题的锚点文本
      var hm = seg.match(/<h3[^>]*class="[^"]*title[^"]*"[^>]*>[\s\S]{0,80}?>([^<>]{1,80})</i);
      if (hm) name = strip(hm[1]);
    }
    if (name === '') continue;

    var pic = thumbOf(seg, base);

    // 备注：「HD中字」「更新至12集」
    var rm = seg.match(/class="[^"]*pic-text[^"]*"[^>]*>([^<]*)</i);
    var remark = rm ? strip(rm[1]) : '';

    // 「地区：美国」「年份：2016」「类型：喜剧」—— 三项共用同一个
    // `<span class="text-muted">标签：</span>值` 的写法
    var area = labelled(seg, '地区');
    var type = labelled(seg, '类型');
    var year = i(labelled(seg, '年份'));

    var brief = labelled(seg, '主演');
    if (brief !== '') brief = '主演：' + brief;

    items.push({
      id: id,
      name: name,
      pic: pic,
      remark: remark,
      brief: brief || remark,
      area: area,
      year: year,
      type: type
    });

    // 防御：单页最多 200 条。搜索结果实测一页 20 条，
    // 200 宽到不会误伤，但能挡住正则吃错时产出几千条。
    if (items.length >= 200) break;
  }
  return { items: items };
}

// ==================== 详情 ====================

/**
 * 详情页 → 元信息 + 分线路的选集。
 *
 * 见文件头第 3 条：必须按 panel 切块，不能全页扫播放链接。
 */
/**
 * 从详情页的 `p.data` 里取「标签：值」。
 *
 * 不能用「`<span class="text-muted">标签：</span>` 紧接纯文本」这种写法 ——
 * 本站三类字段的形态各不相同：
 *
 *   类型：<a href='/vodtype/4/'>动漫</a><span class="split-line"></span>
 *   地区：</span>大陆<span class="split-line"></span>        ← 裸文本
 *   主演：</span><a>史泽鲲</a>&nbsp;<a>周健</a>…</p>        ← 一串锚点
 *
 * 而且标签本身的 class 带附加项（`text-muted hidden-xs`、
 * `left text-muted`），只认 `class="text-muted"` 会一个都匹配不到。
 *
 * 所以停点取「下一个 text-muted 或 split-line 的 span」或 `</p>`，
 * 谁先到算谁 —— 三种形态都能正确截断。
 *
 * ## 窗口必须够宽（实测踩过）
 *
 * 主演给的是**一串锚点**，每个约 100 字符（`<a href="/vodsearch/-%E5%8F%B2…`
 * 的 URL 编码人名很长）。12 个人就是 1200+ 字符。早先窗口给 900，
 * 结果匹配不到 `</p>`、整个 match 在这处失败，而 `String.match` 不带 `g`
 * 标志时会**继续往后找**，最后命中推荐位里另一部剧的
 * `主演：钱文青,杨天翔,杨默` —— 表现为「详情页主演是别人的」，
 * 而且因为不报错，极难发现。
 *
 * 所以：窗口放宽到 3000，并且调用方必须先框定详情头部（见 parseDetail
 * 里的 `head`），两道保险都上，只靠窗口迟早再被更长的演员表击穿。
 */
function pdValue(scope, label) {
  var re = new RegExp(
    '<span[^>]*class="[^"]*text-muted[^"]*"[^>]*>\\s*' + label + '\\s*[：:]?\\s*</span>' +
    '([\\s\\S]{0,3000}?)' +
    '(?=<span[^>]*class="[^"]*(?:split-line|text-muted)[^"]*"|</p>)', 'i');
  var m = s(scope).match(re);
  if (!m) return '';
  // 多个 `<a>` 之间是 `&nbsp;`，strip 后压成空格，可读性够；
  // 但要把残留的分隔符统一，避免出现「史泽鲲  周健」这种双空格
  return strip(m[1]).replace(/\s+/g, ' ').trim();
}

function parseDetail(body, ctx) {
  var html = s(body);
  if (html === '') return { lines: [] };

  var base = (ctx && ctx.baseUrl) || '';

  // ---- 剧名 ----
  // 站点标题形如「色，戒详情介绍-色，戒在线观看-剧踪电影网」，取第一段
  var name = '';
  var h1 = html.match(/<h1[^>]*>([\s\S]{0,240}?)<\/h1>/i);
  if (h1) name = strip(h1[1]);
  if (name === '') {
    name = docTitle(html).split(/详情介绍|在线观看| - /)[0].trim();
  }
  if (name === '') name = metaContent(html, 'og:title');
  if (name === '') name = s(ctx && ctx.dramaId);

  // ---- 按 panel 切块 ----
  // 标记必须同时含 stui-pannel-box 和 playlist：详情页还有「为你推荐」
  // 「动漫热播排行榜」等同款 box，它们不是线路面板。
  var marks = [];
  var markRe = /class="[^"]*stui-pannel-box[^"]*playlist[^"]*"/g;
  var mm;
  while ((mm = markRe.exec(html)) !== null) {
    marks.push(mm.index);
  }

  var idHint = s(ctx && ctx.dramaId);
  // 播放链接形如 `/vodplay/106-1-1/`（不带 .html）
  var playRe = /href="(\/vodplay\/(\d+)-(\d+)-(\d+)\/)"/g;

  // ---- 详情头部 ----
  // 从 `stui-content__detail`（海报 + 剧名 + 字段区）到第一个线路面板之间。
  //
  // **不框定就会取到别的剧的字段**：页面下半截全是推荐位卡片，它们同样带
  // `主演：`/`地区：` 这些标签（实测推荐位里有一处
  // `主演：钱文青,杨天翔,杨默`，那是《凡人修仙传》的）。pdValue 一旦在
  // 头部匹配失败就会跑到后半页命中推荐位，界面上表现为「主演是别人的」。
  var head = html;
  var headStart = html.indexOf('stui-content__detail');
  if (headStart >= 0) {
    var headEnd = marks.length > 0 ? marks[0] : html.length;
    if (headEnd > headStart) head = html.substring(headStart, headEnd);
  }

  var lines = [];
  for (var n = 0; n < marks.length; n++) {
    var start = marks[n];
    var stop = (n + 1 < marks.length) ? marks[n + 1] : html.length;
    if (stop <= start) continue;
    var seg = html.substring(start, stop);

    // 线路名：本 panel 的 h3.title。里面可能裹一个 <img> 图标，要剥掉
    var lineName = '';
    var tm = seg.match(/<h3 class="title">([\s\S]{0,240}?)<\/h3>/i);
    if (tm) lineName = strip(tm[1]);
    if (lineName === '') continue;

    var episodes = [];
    var seenEp = {};
    var em;
    playRe.lastIndex = 0;
    while ((em = playRe.exec(seg)) !== null) {
      var link = em[1];
      var vid = em[2];
      var lineNo = em[3];
      var ep = i(em[4]);
      if (ep < 1) continue;

      // 防御：只收当前剧的集数。详情页里偶尔会串进推荐位别的剧。
      if (idHint !== '' && vid !== idHint) continue;

      var key = lineNo + '-' + ep;
      if (seenEp[key]) continue;
      seenEp[key] = 1;

      // 集名在锚点文本里（`第01集`），也可能在 title 属性上
      var tail = seg.substring(em.index, Math.min(em.index + 200, seg.length));
      var epName = '';
      var ttm = tail.match(/title="([^"]+)"/);
      if (ttm) epName = strip(ttm[1]);
      if (epName === '') {
        var atm = tail.match(/>([^<>]{1,24})<\/a>/);
        if (atm) epName = strip(atm[1]);
      }
      if (epName === '') epName = '第' + ep + '集';

      episodes.push({ name: epName, url: link });
    }

    if (episodes.length === 0) continue;
    lines.push({ line: lineName, episodes: episodes, rank: lineRank(lineName, ctx) });
  }

  // ---- 按「能不能播」重排 ----
  // 用插入排序而不是 sort：JS 的 sort 在部分引擎上不稳定，
  // 同档位内的原始顺序（站点自己的编排）要保住。
  var ordered = [];
  for (var q = 0; q < lines.length; q++) {
    var cur = lines[q];
    var at = ordered.length;
    for (var r = 0; r < ordered.length; r++) {
      if (ordered[r].rank > cur.rank) { at = r; break; }
    }
    ordered.splice(at, 0, cur);
  }

  var out = [];
  for (var w = 0; w < ordered.length; w++) {
    out.push({ line: ordered[w].line, episodes: ordered[w].episodes });
  }

  // ---- 简介 ----
  //
  // 三种来源，按优先级取，但每种都要先洗一道：
  //
  // 1. `<span class="detail-content">` —— 完整正文，但**前面粘着站方模板话术**：
  //    「欢迎在线观看由X, Y, Z主演动漫的《仙逆》，剧踪影院第一时间为你提供…
  //     祝你观片愉快！剧情简介:　　改编自耳根同名小说…」
  //    要砍到「剧情简介」之后，否则详情页一打开先看到一段广告。
  // 2. `<span class="detail-sketch">` —— 同一段正文的**截断版**（实测 54 字），
  //    适合当列表摘要，但不能当正文。
  // 3. `meta description` —— 完整正文，但带「仙逆免费在线观看,」前缀。
  //
  // brief 用完整的（宿主在列表/卡片里会自己截断），content 也用完整的。
  // 用 sketch 会让详情页只有一行字，比不显示更糟。
  var intro = '';
  var dc = html.match(
    /<span[^>]*class="[^"]*detail-content[^"]*"[^>]*>([\s\S]*?)<\/span>/i);
  if (dc) intro = strip(dc[1]);
  if (intro === '') {
    var dm = html.match(
      /<div[^>]*class="[^"]*(?:detail-content|vod-content|detail-desc)[^"]*"[^>]*>([\s\S]*?)<\/div>/i);
    if (dm) intro = strip(dm[1]);
  }
  if (intro === '') {
    intro = strip(metaContent(html, 'description'));
    // meta 版的前缀是「<剧名>免费在线观看,」，按剧名精确剥，不要盲删前 N 字
    if (name !== '' && intro.indexOf(name) === 0) {
      intro = intro.substring(name.length);
      intro = intro.replace(/^\s*免费(在线)?观看\s*[,，:：]?\s*/, '');
    }
  }
  // 模板话术：从「剧情简介」起截断。找不到就原样，不硬删。
  var ji = intro.indexOf('剧情简介');
  if (ji >= 0) {
    intro = intro.substring(ji + 4).replace(/^\s*[:：]\s*/, '');
  }
  intro = intro.replace(/^\s+/, '').trim();

  return {
    name: name,
    pic: coverOf(html, base),
    content: intro,
    brief: intro,
    // 详情页字段都在 `p.data` 里，形态见 pdValue 的注释。
    // 站点**没有**备注/评分/语言/片长字段（实测全文搜不到），
    // 所以 remark/stars 留空，界面按「无」显示 —— 不编一个假的填进去。
    area: pdValue(head, '地区'),
    year: i(pdValue(head, '年份')),
    remark: '',
    director: pdValue(head, '导演'),
    actor: pdValue(head, '主演'),
    lines: out
  };
}

// ==================== 取址 ====================

/**
 * 播放页 → 真实地址。
 *
 * 页面里是 `var player_data={"flag":"play","encrypt":0,…,"url":"…","from":"…"}`。
 *
 * **变量名是 `player_data` 不是 `player_aaaa`** —— 见文件头第 1 条。
 * 用 `indexOf` 定位而不是全文正则，是为了避免抓到页面上其它 JSON
 * 配置里的 `url` 字段。
 */
function parseResolve(body, ctx) {
  var html = s(body);
  if (html === '') return { url: '', error: '播放页是空的，请换一条线路' };

  var at = html.indexOf('player_data');
  var scope = at >= 0
    ? html.substring(at, Math.min(at + 1800, html.length))
    : html;

  function pick(key) {
    var m = scope.match(new RegExp('"' + key + '"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"'));
    if (!m) return '';
    // `\/` 是合法 JSON 转义，还原成 `/`，否则拼出的地址打不开
    return m[1].replace(/\\\//g, '/').replace(/\\\\/g, '\\');
  }

  var url = pick('url');
  var from = pick('from');
  var encrypt = pick('encrypt');

  if (url === '') {
    return { url: '', error: '这条线路没给播放地址，请切到「剧踪XG / BF / DY」线路' };
  }

  // encrypt: 0 明文 / 1 unescape / 2 base64（标准 MacCMS 约定）
  if (encrypt === '1') {
    try { url = decodeURIComponent(url); } catch (e) {}
  } else if (encrypt === '2') {
    try { url = host.b64d(url, 'utf8'); } catch (e) {}
  }

  url = url.trim();

  // ---- 票据线：先给出明确原因，不要让它走到播放器再报格式错误 ----
  // 形如 `juzong1-f459ebF-J9URH2…`，要走 jzpic 的第三方解析才能换出真实地址。
  if (url.indexOf('http') !== 0) {
    var cn = s(ctx && ctx.line) || from;
    return {
      url: '',
      error: '「' + cn + '」是站方的加密专线，需要第三方解析才能取到地址，' +
        '本播放器解不开。请切到「剧踪XG / BF / DY[海外]」线路'
    };
  }

  // ---- 网页源：qq / 优酷这类给的是网页地址 ----
  if (url.indexOf('.m3u8') < 0 && url.indexOf('.mp4') < 0) {
    var cn2 = s(ctx && ctx.line) || from;
    return {
      url: '',
      error: '「' + cn2 + '」是网页源（腾讯/优酷这类），播放器放不了，' +
        '请切到「剧踪XG / BF / DY[海外]」线路'
    };
  }

  return { url: url };
}