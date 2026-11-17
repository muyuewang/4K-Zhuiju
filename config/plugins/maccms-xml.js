// 通用 MacCMS 采集接口插件（XML 版）。
//
// ============================================================
// 和 maccms-json.js 什么关系
// ============================================================
//
// 两个脚本的**输出结构完全一样**，区别只在「吃什么格式的响应体」。
// 所以 index.json 里换个 script 字段就能把一个源从 JSON 切到 XML，
// 其余配置（域名、接口路径、分类）都不用动。
//
// 为什么需要这个版本：MacCMS 有大量老站只开 XML 接口。
// 它们的 `api.php/provide/vod/?ac=list` 默认返回 XML，
// 传 `at=json` 才行——但有些站直接把这个参数过滤掉了，只留 XML。
// 这类站在之前的实现里完全没法接（脚本只认 JSON.parse）。
//
// ============================================================
// 硬性约束（同 JSON 版，违反会失败）
// ============================================================
//
// 1. **必须是同步函数**。返回 Promise 会被宿主直接拒绝。
// 2. **不能写死循环**（`while(true)` / `for(;;)`），宿主装载前会拒绝。
// 3. 返回值能被 JSON.stringify。
// 4. 可用能力见 README。XML 解析走 `host.xml2json()`——
//    QuickJS 自己没有 DOMParser，这一步必须由宿主代劳。
//
// ============================================================
// XML 站的两个坑（都在这份脚本里兜掉了）
// ============================================================
//
// 坑一：**同名元素只有一个时不是数组**。
//   `<dl><dd flag="a">…</dd></dl>`  →  dl.dd 是对象
//   `<dl><dd flag="a">…</dd><dd flag="b">…</dd></dl>` → dl.dd 是数组
//   这是 xml2js 的固有行为（我们刻意不「统一成数组」，否则按
//   xml2js 文档写的脚本会拿不到预期结果）。所以一律过 toArr()。
//
// 坑二：**元素文本的位置取决于有没有属性**。
//   `<name>剧名</name>`            →  name 直接是字符串 "剧名"
//   `<dd flag="x">第1集$…</dd>`    →  dd 是 {"@flag":"x", "#text":"第1集$…"}
//   只取 `node` 不取 `node['#text']` 的话，线路文本永远是空，
//   表现是「详情页线路列表一片空白」。
//
// ============================================================
// 接口约定（与 JSON 版一致）
// ============================================================
//
//   parseList(body, ctx)    → { items: [{id, name, pic, remark, brief,
//                                        area, year, type}] }
//   parseDetail(body, ctx)  → { id, name, pic, content, brief, area, year,
//                               remark, director, actor,
//                               lines: [{line, episodes: [{name, url}]}] }
//   parseResolve(body, ctx) → { url: "http://..." }

/**
 * 把任意值安全转成字符串。null/undefined → 空串。
 */
function s(v) {
  if (v === null || v === undefined) return '';
  return String(v);
}

/**
 * 把任意值转成整数，失败给 0。
 */
function i(v) {
  var n = parseInt(v, 10);
  return isNaN(n) ? 0 : n;
}

/**
 * 把「可能是单个对象、也可能是数组」的东西统一成数组。
 *
 * 这是整份脚本最常用的函数——XML 里几乎所有列表都可能是单元素。
 */
function toArr(v) {
  if (v === null || v === undefined) return [];
  return Array.isArray(v) ? v : [v];
}

/**
 * 取元素的文本内容，兼容「有没有属性」两种形态。
 */
function textOf(node) {
  if (node === null || node === undefined) return '';
  if (typeof node === 'string') return node;
  if (typeof node === 'number' || typeof node === 'boolean') return String(node);
  if (typeof node === 'object') {
    // 带属性的元素被转成了 {@flag:…, #text:…}
    if (node['#text'] !== undefined) return s(node['#text']);
    return '';
  }
  return '';
}

/**
 * 取元素属性。没有就返回空串。
 */
function attrOf(node, name) {
  if (!node || typeof node !== 'object') return '';
  return s(node['@' + name]);
}

/**
 * 补全相对地址（同 JSON 版）。
 *
 * XML 站的 `<pic>` 更容易给相对路径，因为老站的模板直接把数据库里
 * 存的 `/upload/xxx.jpg` 吐出来。
 */
function abs(url, base) {
  var u = s(url).trim();
  if (u === '') return '';
  if (u.indexOf('http://') === 0 || u.indexOf('https://') === 0) return u;
  if (u.indexOf('//') === 0) return 'https:' + u;
  if (u.charAt(0) === '/') {
    var m = s(base).match(/^(https?:\/\/[^\/]+)/);
    return m ? m[1] + u : u;
  }
  return u;
}

/**
 * 把 MacCMS **JSON** 应答归一化成 XML 等价的形状。
 *
 * 为什么要做这一步，而不是「JSON 就照 JSON 解析」：
 * 这条路径的存在意义只有一个——**站方偷偷把默认返回格式改了**。
 * 这种情况真实发生（升级 MacCMS 版本、换模板、运维加了中间层），
 * 表现是「源昨天好好的，今天列表全空」。
 *
 * 如果这里只把 JSON 包个外壳就当 XML 用，字段名对不上
 * （JSON 是 `vod_id`，XML 是 `id`），结果是**照样全空**——
 * 那就等于这个兼容分支白写了，还多一处会骗人的代码。
 *
 * 所以这里做完整的字段映射，映射完之后下游（itemOf / linesOf /
 * parseDetail）一行都不用改。代价是这一个函数要维护映射表，
 * 收益是「格式漂移」这条故障路径被真正堵住。
 */
function normalizeJsonRoot(obj) {
  if (!obj || typeof obj !== 'object') return null;

  var arr = [];
  if (Array.isArray(obj)) {
    arr = obj;
  } else if (Array.isArray(obj.list)) {
    arr = obj.list;
  } else if (Array.isArray(obj.data)) {
    arr = obj.data;
  }

  var videos = [];
  for (var n = 0; n < arr.length; n++) {
    var it = arr[n];
    if (!it || typeof it !== 'object') continue;

    var v = {
      id: s(it.vod_id),
      name: s(it.vod_name),
      pic: s(it.vod_pic),
      note: s(it.vod_remarks),
      area: s(it.vod_area),
      year: s(it.vod_year),
      type: s(it.type_name || it.vod_class),
      des: s(it.vod_blurb || it.vod_content),
      director: s(it.vod_director),
      actor: s(it.vod_actor)
    };

    // 线路：JSON 用两个 `$$$` 分隔的平行数组，要合回 <dl><dd flag>
    var froms = s(it.vod_play_from).split('$$$');
    var urls = s(it.vod_play_url).split('$$$');
    var dds = [];
    for (var k = 0; k < urls.length; k++) {
      if (!urls[k]) continue;
      dds.push({
        '@flag': k < froms.length ? s(froms[k]) : '',
        '#text': urls[k]
      });
    }
    if (dds.length > 0) v.dl = { dd: dds };

    videos.push(v);
  }

  return { rss: { list: { video: videos } } };
}

/**
 * 解析响应体，返回 XML 根对象。失败返回 null。
 *
 * 先用 `host.xml2json` 转换。这里额外做两件事：
 *   1. 去掉 BOM —— 老 PHP 站导出的 XML 常带 `\uFEFF`，`XmlDocument.parse`
 *      会直接报错，且错误信息只说「unexpected character」，很难联想
 *   2. 兼容「配了 XML 但站方实际返回 JSON」的情况 —— 有些站在
 *      升级后把默认格式改了。两端都认，源就不会无缘无故变成空列表
 */
function parseXml(body) {
  var text = s(body);
  // 去 BOM（部分站点的 XML 声明前有不可见字符）
  if (text.charCodeAt(0) === 0xFEFF) text = text.substring(1);
  text = text.trim();
  if (text === '') return null;

  // 站方实际返回 JSON（配置写的是 xml 但接口变了）
  if (text.charAt(0) === '{' || text.charAt(0) === '[') {
    try {
      return normalizeJsonRoot(JSON.parse(text));
    } catch (e) {
      return null;
    }
  }

  try {
    return host.xml2json(text);
  } catch (e) {
    // 被 WAF 拦了会返回 HTML。返回 null 让上层给空列表，
    // 比抛异常好——异常在 App 里只显示一句「解析失败」，
    // 看不出是源挂了还是脚本写错了。
    return null;
  }
}

/**
 * 从 XML 根对象里取 `<list>` 节点。
 *
 * 两种常见层级：
 *   <rss><list><video>…     （MacCMS 标准）
 *   <list><video>…          （少数站省略 rss 外壳）
 */
function listNodeOf(root) {
  if (!root) return null;
  if (root.rss) return root.rss.list || null;
  if (root.list) return root.list;
  return null;
}

/**
 * 从 `<dl>` 里取线路列表。
 *
 * XML 的线路结构和 JSON 不同：
 *   JSON: vod_play_from="bfzym3u8$$$lzm3u8"  vod_play_url="…$$$…"
 *   XML:  <dl><dd flag="bfzym3u8">第1集$url#第2集$url</dd>
 *            <dd flag="lzm3u8">…</dd></dl>
 *
 * 也就是说 XML 已经把线路拆开放在 `<dd>` 上了，不需要再按 `$$$` 分。
 * 但线路名在 `flag` **属性**里（不是文本里），这点最容易漏——
 * 漏了的结果是所有线路都叫「线路1」「线路2」，用户分不清哪条是 4K。
 */
function linesOf(video, base) {
  var out = [];
  var dls = toArr(video.dl);
  for (var a = 0; a < dls.length; a++) {
    var dds = toArr(dls[a].dd);
    for (var b = 0; b < dds.length; b++) {
      var dd = dds[b];
      var urlText = textOf(dd).trim();
      if (urlText === '') continue;

      var flag = attrOf(dd, 'flag').trim();
      var episodes = parsePlayUrl(urlText, base);
      if (episodes.length === 0) continue;

      out.push({
        line: flag !== '' ? flag : ('线路' + (out.length + 1)),
        episodes: episodes
      });
    }
  }
  return out;
}

/**
 * 拆单条线路里的分集。
 *
 * 格式：`第1集$http://a.m3u8#第2集$http://b.m3u8`
 * 和 JSON 版完全一样，所以逻辑直接搬过来。
 */
function parsePlayUrl(raw, base) {
  var out = [];
  var text = s(raw);
  if (text === '') return out;

  var parts = text.split('#');
  for (var k = 0; k < parts.length; k++) {
    var seg = parts[k];
    if (!seg) continue;
    var idx = seg.indexOf('$');
    var name, url;
    if (idx >= 0) {
      name = seg.substring(0, idx);
      url = seg.substring(idx + 1);
    } else {
      name = '第' + (k + 1) + '集';
      url = seg;
    }
    url = url.trim();
    if (url === '') continue;
    if (url.indexOf('http') !== 0) continue;
    out.push({
      name: s(name).trim() || ('第' + (k + 1) + '集'),
      url: url
    });
  }
  return out;
}

/**
 * 把一条 `<video>` 转成列表项。
 *
 * 返回 null 表示这条不可用（缺 id 或缺片名），上层直接丢掉——
 * 没有 id 的条目点进去必然崩，没有片名的条目在列表里是空白行。
 */
function itemOf(v, base) {
  if (!v || typeof v !== 'object') return null;

  var id = s(textOf(v.id)).trim();
  if (id === '') return null;

  var name = s(textOf(v.name)).trim();
  if (name === '') return null;

  // XML 里备注字段叫 note，类型叫 type（JSON 里是 vod_remarks / type_name）
  var note = s(textOf(v.note)).trim();

  return {
    id: id,
    name: name,
    pic: abs(textOf(v.pic), base),
    remark: note,
    // 列表页通常没有简介，退回用备注，避免整列空副标题
    brief: s(textOf(v.des)).trim() || note,
    area: s(textOf(v.area)).trim(),
    year: i(textOf(v.year)),
    type: s(textOf(v.type)).trim()
  };
}

/**
 * 列表 / 搜索的解析入口。
 */
function parseList(body, ctx) {
  var base = ctx && ctx.baseUrl ? ctx.baseUrl : '';
  var root = parseXml(body);
  var listNode = listNodeOf(root);
  if (!listNode) return { items: [] };

  var vids = toArr(listNode.video);
  var items = [];
  for (var n = 0; n < vids.length; n++) {
    var it = itemOf(vids[n], base);
    if (it) items.push(it);
  }
  return { items: items };
}

/**
 * 详情的解析入口。
 *
 * XML 的关键差异：detail 的 `<video>` 里带 `<dl>`，列表里的不带。
 * 所以「详情」本质上就是「列表项 + 线路」，不需要另一套字段映射。
 */
function parseDetail(body, ctx) {
  var base = ctx && ctx.baseUrl ? ctx.baseUrl : '';
  var root = parseXml(body);
  var listNode = listNodeOf(root);
  if (!listNode) return { lines: [] };

  var vids = toArr(listNode.video);
  if (vids.length === 0) return { lines: [] };

  var v = vids[0];
  if (!v || typeof v !== 'object') return { lines: [] };

  return {
    id: s(textOf(v.id)).trim(),
    name: s(textOf(v.name)).trim(),
    pic: abs(textOf(v.pic), base),
    content: s(textOf(v.des)).trim(),
    brief: s(textOf(v.des)).trim(),
    area: s(textOf(v.area)).trim(),
    year: i(textOf(v.year)),
    remark: s(textOf(v.note)).trim(),
    director: s(textOf(v.director)).trim(),
    actor: s(textOf(v.actor)).trim(),
    lines: linesOf(v, base)
  };
}

/**
 * 取播放地址。
 *
 * 大多数 XML 站不需要——detail 的 `<dd>` 里直接就是 m3u8。
 * 只有拿到的是网页地址、要再抠一层时才配 resolve。
 * 实现与 JSON 版一致：先试 JSON，再从 HTML 里抠 m3u8。
 */
function parseResolve(body, ctx) {
  var text = s(body).trim();
  if (text === '') return { url: '' };

  // ① 取址接口有时返回 {"url":"…"}
  if (text.charAt(0) === '{') {
    try {
      var j = JSON.parse(text);
      if (j && typeof j === 'object') {
        var direct = s(j.url || j.play_url || j.data);
        if (direct.indexOf('http') === 0) return { url: direct };
      }
    } catch (e) {
      // 不是 JSON，往下走
    }
  }

  // ② 从 HTML / JS 里抠
  var patterns = [
    /"url"\s*:\s*"([^"]+\.m3u8[^"]*)"/,
    /var\s+main\s*=\s*"([^"]+)"/,
    /url\s*:\s*'([^']+\.m3u8[^']*)'/,
    /(https?:\/\/[^\s"'<>]+\.m3u8[^\s"'<>]*)/
  ];
  for (var n = 0; n < patterns.length; n++) {
    var m = text.match(patterns[n]);
    if (m && m[1]) {
      var u = m[1].replace(/\\\//g, '/');
      if (u.indexOf('http') === 0) return { url: u };
    }
  }

  return { url: '' };
}