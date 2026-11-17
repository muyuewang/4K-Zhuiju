// 通用 MacCMS 采集接口插件（JSON 版）。
//
// ============================================================
// 这个文件放在哪、谁在用
// ============================================================
//
// 它是「远程插件源」的解析脚本，由 App 从 GitHub 拉下来、在 QuickJS 里执行。
// 改完这里的内容推到 main 分支，用户下次启动 App 就自动生效，**不用发版**。
//
// 索引在 config/plugins/index.json，那里声明「哪个源用这个脚本、
// 域名是什么、接口长什么样」。日常站点换域名只需要改 index.json 一行，
// 这个脚本不用动。
//
// ============================================================
// 硬性约束（违反会失败，且报错不好懂，所以先看这段）
// ============================================================
//
// 1. **必须是同步函数**。返回 Promise 会被宿主直接拒绝。
//    所有网络请求由宿主发起，脚本只负责「解析响应体」。
//    没有 await、没有 fetch、没有 XMLHttpRequest。
//
// 2. **不能写死循环**。宿主会在装载前静态检查 `while(true)` / `for(;;)`，
//    发现就拒绝执行。这不是限制你，是因为 JS 引擎的死循环
//    **宿主杀不掉**（实测 isolate.kill 对它无效），一旦卡住
//    后台线程会一直烧 CPU。所以循环条件一定要能自己结束。
//
// 3. **返回值必须能被 JSON.stringify**。返回对象即可，宿主会替你
//    stringify；返回字符串也行（宿主原样用）。
//
// 4. 可用能力：标准 JS 全集（JSON / RegExp / String / Array / Math /
//    Date / encodeURIComponent 都有）。**没有** require / process /
//    fetch / setTimeout —— QuickJS 本身不提供这些。
//
// ============================================================
// 接口约定
// ============================================================
//
//   parseList(body, ctx)    → { items: [{id, name, pic, remark, area, year}] }
//   parseDetail(body, ctx)  → { name, content, pic, year, area,
//                              lines: [{line, episodes: [{name, url}]}] }
//   parseResolve(body, ctx) → { url: "http://..." }   // 清单配了 resolve 才需要
//
// ctx 是一个对象：{ vars, baseUrl, finalUrl, sourceId }
//   vars      —— index.json 里该源的 vars 字段，用来放站方自定义参数
//   baseUrl   —— 该源的站点根地址（补全相对链接时用）
//   finalUrl  —— 本次请求重定向之后的真实地址
//
// ============================================================
// 为什么解析要写这么啰嗦
// ============================================================
//
// MacCMS 的字段是「约定俗成」而不是「规范」，同一个字段名在
// 不同站上可能是字符串、数字、null，或者干脆不存在。
// 下面每个字段都做了兜底，是因为实测碰到过：
//   - vod_id 是数字（JSON 里不带引号）→ 直接拼进 URL 会变 `id=123` 没问题，
//     但 `==` 比较、当 map key 会踩坑，所以统一 String()
//   - vod_pic 缺失（`ac=list` 常砍掉封面）→ 不兜底会得到 "undefined"
//   - vod_play_url 用 `#` 分线路、`$` 分集名与地址，缺一个都会解析错位

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
 * 补全相对地址。
 *
 * 采集站给的 vod_pic 有三种形态：
 *   1. `https://x.com/a.jpg`      完整地址 → 原样用
 *   2. `//x.com/a.jpg`            协议相对 → 补 https:
 *   3. `/upload/a.jpg`            站内相对 → 拼 baseUrl
 *
 * 不处理第 2、3 种的话，封面全是破图。这是最常见的「插件写好了但
 * 列表一片灰」的原因。
 */
function abs(url, base) {
  var u = s(url).trim();
  if (u === '') return '';
  if (u.indexOf('http://') === 0 || u.indexOf('https://') === 0) return u;
  if (u.indexOf('//') === 0) return 'https:' + u;
  if (u.charAt(0) === '/') {
    // base 可能带路径（https://x.com/api/），取协议+主机即可
    var m = s(base).match(/^(https?:\/\/[^\/]+)/);
    return m ? m[1] + u : u;
  }
  return u;
}

/**
 * 从 MacCMS 的 vod_play_url 里拆线路和分集。
 *
 * 格式：`第1集$http://a.m3u8#第2集$http://b.m3u8`
 * 多条线路用 `$$$` 分隔，但那是在 vod_play_from 里对应多个源名的情况下，
 * 单条 play_url 内部只用 `#`。
 *
 * 每集内部 `$` 左边是集名、右边是地址。有些站只有地址没有集名
 * （`http://a.m3u8`），这时用序号当集名。
 */
function parsePlayUrl(playUrl) {
  var out = [];
  var raw = s(playUrl);
  if (raw === '') return out;

  var parts = raw.split('#');
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
    // 少数站会在地址里塞 `#` 的字面转义，这里已经是 split 之后的
    // 半截地址，丢掉即可（拼回去反而可能拼出错误链接）
    if (url.indexOf('http') !== 0) continue;
    out.push({ name: s(name).trim() || ('第' + (k + 1) + '集'), url: url });
  }
  return out;
}

/**
 * 列表 / 搜索结果的解析入口。
 *
 * MacCMS 的 JSON 应答统一是 `{code:1, list:[...]}`，但 `list` 有时是
 * 对象包装（`{list: {list: [...]}}`）——取决于站用的接口版本。
 * 两种都得认，否则会有「这个源永远没数据」的诡异现象。
 */
function parseList(body, ctx) {
  var data;
  try {
    data = JSON.parse(body);
  } catch (e) {
    // 返回非 JSON 通常是「被 WAF 拦了，返回一个 HTML 错误页」。
    // 直接返回空列表，宿主会显示空态，比抛异常好排查
    // （异常在 App 里只显示一句「解析失败」）。
    return { items: [] };
  }

  var arr = [];
  if (data && data.list && Array.isArray(data.list)) {
    arr = data.list;
  } else if (data && data.data && Array.isArray(data.data)) {
    // 少数站把结果放在 data 里
    arr = data.data;
  } else if (Array.isArray(data)) {
    arr = data;
  }

  var items = [];
  for (var n = 0; n < arr.length; n++) {
    var it = arr[n];
    if (!it || typeof it !== 'object') continue;

    var id = s(it.vod_id);
    // 没有 id 的条目点进去必然崩，直接丢
    if (id === '') continue;

    var name = s(it.vod_name).trim();
    if (name === '') continue;

    items.push({
      id: id,
      name: name,
      pic: abs(it.vod_pic, ctx.baseUrl),
      remark: s(it.vod_remarks),
      // 简介在列表页通常被砍掉了，退回用备注，避免列表里全是空副标题
      brief: s(it.vod_blurb || it.vod_remarks),
      area: s(it.vod_area),
      year: i(it.vod_year),
      type: s(it.type_name),
    });
  }
  return { items: items };
}

/**
 * 详情的解析入口。
 *
 * 关键在 vod_play_from / vod_play_url 的**对齐关系**：
 * 两个字段都用 `$$$` 分隔，第 n 个 from 对应第 n 个 play_url。
 * 只取 play_url 不管 from 的话，线路名会全部错位或变成 "线路1"，
 * 用户在选线路面板里就分不清哪条是 4K、哪条是备用。
 */
function parseDetail(body, ctx) {
  var data;
  try {
    data = JSON.parse(body);
  } catch (e) {
    return { lines: [] };
  }

  var arr = [];
  if (data && data.list && Array.isArray(data.list)) {
    arr = data.list;
  } else if (Array.isArray(data)) {
    arr = data;
  }
  if (arr.length === 0) return { lines: [] };

  var it = arr[0];
  var froms = s(it.vod_play_from).split('$$$');
  var urls = s(it.vod_play_url).split('$$$');

  var lines = [];
  for (var n = 0; n < urls.length; n++) {
    var epUrl = urls[n];
    if (!epUrl) continue;

    // 线路名：优先用 vod_play_from 里对应的那个
    var lineName = n < froms.length ? s(froms[n]).trim() : '';
    if (lineName === '') lineName = '线路' + (n + 1);

    var episodes = parsePlayUrl(epUrl);
    if (episodes.length === 0) continue;
    lines.push({ line: lineName, episodes: episodes });
  }

  return {
    id: s(it.vod_id),
    name: s(it.vod_name),
    pic: abs(it.vod_pic, ctx.baseUrl),
    content: s(it.vod_content),
    brief: s(it.vod_blurb),
    area: s(it.vod_area),
    year: i(it.vod_year),
    remark: s(it.vod_remarks),
    director: s(it.vod_director),
    actor: s(it.vod_actor),
    lines: lines,
  };
}

/**
 * 取播放地址。
 *
 * 大多数 MacCMS JSON 站不需要这个——detail 里的地址可以直接播。
 * 只有「detail 给的是网页地址、要再抠一层」的站才配 resolve。
 * 这个脚本里给一个通用实现：从 HTML/JSON 里抠第一个 m3u8。
 */
function parseResolve(body, ctx) {
  var text = s(body);

  // ① 先试 JSON（有些站取址接口返回 {"url":"..."}）
  try {
    var j = JSON.parse(text);
    if (j && typeof j === 'object') {
      var direct = s(j.url || j.play_url || j.data);
      if (direct.indexOf('http') === 0) return { url: direct };
    }
  } catch (e) {
    // 不是 JSON，往下走 HTML 抠取
  }

  // ② HTML 里常见的几种写法
  var patterns = [
    /"url"\s*:\s*"([^"]+\.m3u8[^"]*)"/,
    /var\s+main\s*=\s*"([^"]+)"/,
    /url\s*:\s*'([^']+\.m3u8[^']*)'/,
    /(https?:\/\/[^\s"'<>]+\.m3u8[^\s"'<>]*)/
  ];
  for (var n = 0; n < patterns.length; n++) {
    var m = text.match(patterns[n]);
    if (m && m[1]) {
      // 抠出来的地址里可能带转义斜杠
      var u = m[1].replace(/\\\//g, '/');
      if (u.indexOf('http') === 0) return { url: u };
    }
  }

  return { url: '' };
}