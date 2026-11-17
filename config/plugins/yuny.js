// 云影（yuny.app）解析脚本。
//
// ============================================================
// 这是什么站
// ============================================================
//
// Nuxt 3 SSR 前端 + 一套**纯 JSON 的 App 接口**。和采集站那种
// 「vod_play_url 里 `#` 分集、`$$$` 分线路」完全不是一类活，
// 所以单独一个脚本，不复用 maccms-json.js。
//
// 2026-11-17 逐条实测（每条都跑过，不是推测）：
//
//   首页  POST /app/video-home/today-updates
//         body {pageNo, pageSize, type}   → data.list[] + total + hasMore
//   分类  POST /app/video-search/label-v2
//         body {current, size, type}      → data.records[]
//   搜索  POST /app/video-search/type-v2
//         body {current, key, size, searchCode, order} → data.records[]
//   详情  GET  /app/video-interact/get-video-detail?videoInfoId=<id>
//         → data.videoChannelList[] 每项 {collectChannelName, videoSelectResList[]}
//
// **注意首页和分类的分页字段名不一样**（pageNo vs current），
// 这就是清单里要单独配一个 `home` 请求的原因。
//
// ============================================================
// 两个必须知道的坑
// ============================================================
//
// ① `type` 是**中文分类名**，不是数字 id。
//    传数字（videoClassify/1..5）接口不认，返回空。所以清单的
//    categories[].id 直接写「电影」「剧集」这些中文。
//
// ② `resourceType` 决定这条选集能不能播，**必须按它过滤**：
//      = 1 → 实测 1701/1701 全是 m3u8 直链，能播
//      = 2 → 实测 1159/1159 全部不可播，分三类：
//            covip_xxx 编码（不是地址，是个指纹）、
//            爱奇艺网页、腾讯/优酷网页
//    站方自己救不回来：这类条目的取址接口固定回 422，
//    网页版播放器同样 422。留着只会让用户点了报错，所以解析阶段直接丢。
//
//    2026-11-17 抽查《风犬少年的天空》(15307) 印证了这点：
//    线路1「精品线路1」16 集全是 resourceType=2；
//    线路2/3/4 各 16 集全是 resourceType=1 直链。
//
// ============================================================
// 为什么这个脚本不配 resolve
// ============================================================
//
// resourceType=1 的 resource **本身就是 m3u8 直链**
// （实测 48/48 全是 http 开头）。配了 resolve 会让宿主给每一集
// 多打一次取址请求，纯属自伤。所以清单里没有 resolve 项。
//
// ============================================================
// 硬性约束
// ============================================================
//
// 同步函数、不能有 Promise/await/fetch、不能写 `while(true)`。
// 返回对象由宿主 stringify，所以别放 undefined / 循环引用。

/**
 * 任意值 → 字符串。null/undefined → 空串。
 */
function s(v) {
  if (v === null || v === undefined) return '';
  return String(v);
}

/**
 * 去 HTML 标签与常见实体。
 *
 * 站方的 description 里混着 `<p>` 和 `&nbsp;`（实测），
 * 不处理的话详情页会显示成一堆标签源码。
 */
function strip(v) {
  var t = s(v);
  if (t === '') return '';
  t = t.replace(/<[^>]*>/g, '');
  t = t.replace(/&nbsp;/g, ' ');
  t = t.replace(/&amp;/g, '&');
  t = t.replace(/&lt;/g, '<');
  t = t.replace(/&gt;/g, '>');
  t = t.replace(/&quot;/g, '"');
  t = t.replace(/&#39;/g, "'");
  t = t.replace(/&#x27;/g, "'");
  // 折叠连续空白：HTML 折行在纯文本里会变成一长串空格
  return t.replace(/\s+/g, ' ').trim();
}

/**
 * 补全地址。站方给的多是完整 https，但保留兜底：
 * 协议相对（`//x.com/a.webp`）实测出现过。
 */
function abs(v) {
  var u = s(v).trim();
  if (u === '') return '';
  if (u.indexOf('http://') === 0 || u.indexOf('https://') === 0) return u;
  if (u.indexOf('//') === 0) return 'https:' + u;
  return u;
}

/**
 * 拆统一响应壳 `{success, code, msg, data}`。
 *
 * **业务失败也返回 HTTP 200**，只把 success 置 false。所以不能只看
 * 状态码——宿主已经把非 200 拦掉了，这里只需要认 success。
 */
function unwrap(body) {
  var d;
  try {
    d = JSON.parse(body);
  } catch (e) {
    return null;
  }
  if (!d || typeof d !== 'object') return null;
  if (d.success !== true) return null;
  return d.data && typeof d.data === 'object' ? d.data : {};
}

/**
 * 一条列表记录 → 宿主需要的 item 结构。
 *
 * 字段固定是 `id / name / cover / tags / description / remark / hot / score`，
 * 三个列表接口共用同一套，所以抽出来。
 */
function toItem(r) {
  if (!r || typeof r !== 'object') return null;
  var id = s(r.id).trim();
  var name = strip(r.name);
  // 没有 id 的点进去必崩，没有名字的是一块空白占位，都不如不显示
  if (id === '' || name === '') return null;
  return {
    id: id,
    name: name,
    pic: abs(r.cover),
    // 列表接口没有「简介」字段，description 就是它；remark 是更新进度
    brief: strip(r.description),
    remark: strip(r.remark),
    // tags 可能是 null（实测常见），兜底成空串
    type: strip(r.tags),
    year: 0,
    area: '',
  };
}

/**
 * 列表 / 搜索 / 首页的解析入口。
 *
 * 三个接口的容器键不同：
 *   home  → data.list
 *   label / type-v2 → data.records
 * 两个都认，顺序无所谓（同一个响应里只会有一个）。
 */
function parseList(body, ctx) {
  var data = unwrap(body);
  if (data === null) return { items: [] };

  var arr = null;
  if (Array.isArray(data.records)) arr = data.records;
  else if (Array.isArray(data.list)) arr = data.list;
  else if (Array.isArray(data)) arr = data;

  if (!arr) return { items: [] };

  var items = [];
  for (var n = 0; n < arr.length; n++) {
    var it = toItem(arr[n]);
    if (it) items.push(it);
  }
  return { items: items };
}

/**
 * 这条选集能不能播。**以 resourceType 为准**，URL 形态只作兜底。
 *
 * 判据为什么是 `resourceType == 1` 而不是匹配 `.m3u8`：
 * resourceType=2 里那批 `covip_xxx` 根本不是地址（是个选集指纹），
 * 字符串匹配对它无能为力，会全部误判成「未知形态」而放行。
 */
function playable(url, rt) {
  var n = typeof rt === 'number' ? rt : parseInt(rt, 10);
  if (n === 1) return true;
  if (n === 2) return false;

  // 没有 resourceType 的响应（站方改版）才走 URL 兜底
  if (url.indexOf('http') !== 0) return false;
  var low = url.toLowerCase();
  if (low.indexOf('.m3u8') >= 0 || low.indexOf('.mp4') >= 0) return true;

  // 知名视频站的**网页**地址一定播不了：播放器拿到的是 HTML 不是流
  var web = [
    'v.qq.com',
    'www.iqiyi.com',
    'v.youku.com',
    'www.bilibili.com',
    'www.mgtv.com',
  ];
  for (var k = 0; k < web.length; k++) {
    if (low.indexOf(web[k]) >= 0) return false;
  }
  // 其它 http 地址交给播放器自己试
  return true;
}

/**
 * 详情的解析入口。
 *
 * ## 关键：**每条线路单独铺自己的集数**
 *
 * 实测同一部剧各线路集数可以不同（《换座位后…》259266 是 5/7/8/8/8）。
 * 按最长线路铺满所有线路，会造出一堆点开就 404 的死条目。
 * 所以这里没有任何「按最大值补齐」的逻辑——有多少铺多少。
 */
function parseDetail(body, ctx) {
  var data = unwrap(body);
  if (data === null) return { lines: [] };

  // 两个键都要认：接口原始返回用 videoChannelList；
  // 站点前端 bundle 里有个转换器会把它改写成 lines（lines[].selects）。
  // 缓存或换版本时可能拿到后者。
  var channels = data.videoChannelList || data.lines || [];
  if (!Array.isArray(channels)) channels = [];

  var lines = [];
  for (var li = 0; li < channels.length; li++) {
    var ch = channels[li];
    if (!ch || typeof ch !== 'object') continue;

    // 线路名两个版本：详情接口用 collectChannelName，
    // 前端 bundle 用 lineSourceName
    var lineName = strip(ch.collectChannelName || ch.lineSourceName);
    if (lineName === '') lineName = '线路' + (li + 1);

    var sel = ch.videoSelectResList || ch.selects || [];
    if (!Array.isArray(sel)) sel = [];

    var episodes = [];
    for (var ei = 0; ei < sel.length; ei++) {
      var one = sel[ei];
      if (!one || typeof one !== 'object') continue;

      var url = abs(one.resource);
      // 不可播的直接丢。留着的话用户在选集中会看到一堆点了报错的条目，
      // 而这批条目**站方自己也修不好**（固定 422），等不来修复。
      if (!playable(url, one.resourceType)) continue;
      if (url === '') continue;

      var epName = strip(one.series);
      if (epName === '') epName = '第' + (ei + 1) + '集';
      episodes.push({ name: epName, url: url });
    }

    // 整条线路一条都不可播就整条不显示——
    // 空线路在选线路面板里是个点了没反应的死 tab
    if (episodes.length === 0) continue;
    lines.push({ line: lineName, episodes: episodes });
  }

  // ---- 人物 ----
  //
  // **tagList 不是标签列表，是人物列表**。2026-11-17 实测：
  //   tagList = [{tagName:"张一白", tagType:1}, {tagName:"彭昱畅", tagType:2}]
  // 其中 tagType=1 是导演、tagType=2 是演员。
  //
  // 早期按「tagList 全是标签」拼出来，结果是标签区显示一串人名
  // （"张一白 / 韩琰 / 彭昱畅"），而演员字段反而是空的——
  // 因为 actorList 实测是 []、performer 是 null，演员其实只在 tagList 里。

  var directors = [];
  var actors = [];
  var tl = data.tagList;
  if (Array.isArray(tl)) {
    for (var ti = 0; ti < tl.length; ti++) {
      var one = tl[ti];
      if (!one || typeof one !== 'object') continue;
      var nm = strip(one.tagName);
      if (nm === '') continue;
      // tagType 也可能是字符串 "1"
      var tp = typeof one.tagType === 'number'
        ? one.tagType
        : parseInt(one.tagType, 10);
      if (tp === 1) directors.push(nm);
      else if (tp === 2) actors.push(nm);
    }
  }

  // 演员：优先 performer 汇总字段，再 actorList，最后才用 tagList 里的
  var actor = strip(data.performer);
  if (actor === '') {
    var al = data.actorList;
    if (Array.isArray(al)) {
      var names = [];
      for (var ai = 0; ai < al.length; ai++) {
        var an = strip(al[ai] && (al[ai].name || al[ai].actorName));
        if (an !== '') names.push(an);
      }
      actor = names.join(' / ');
    }
  }
  if (actor === '') actor = actors.join(' / ');

  var director = strip(data.director);
  if (director === '') director = directors.join(' / ');

  // 真正的标签：站方没给 tags 时，用「类型 + 语言」顶上。
  // 云影实测 tags 恒为 null，详情页标签区若留空会显得信息缺失。
  var tag = strip(data.tags);
  if (tag === '') {
    var bits = [];
    var ty = strip(data.type);
    if (ty !== '') bits.push(ty);
    var lang = strip(data.language);
    if (lang !== '') bits.push(lang);
    tag = bits.join(' / ');
  }

  var desc = strip(data.description);

  return {
    id: s(data.id),
    name: strip(data.name),
    pic: abs(data.cover || data.resourceCover),
    content: desc,
    brief: desc,
    area: strip(data.area),
    year: parseInt(data.years, 10) || 0,
    remark: strip(data.remark),
    director: director,
    actor: actor,
    tag: tag,
    lines: lines,
  };
}