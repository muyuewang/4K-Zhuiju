/// 站点型数据源的「注册表」。
///
/// 以后接入新的 MacCMS/苹果CMS 采集站，**只需要在下面加一条配置**，
/// 不需要写请求代码、不需要改解析逻辑、不需要动页面。
/// 如果模板差异大到配置盖不住，再复制一份 [MacCmsConfig] 调正则即可。
library;

import 'data_source.dart';
import 'mac_cms_source.dart';
import 'maccms_api_source.dart';

/// 片库 4K —— 标准 MacCMS 模板。
///
/// 线路实测（2026-11-11，id=100 有 4 条线）：
///   腾讯 / 奇异 / B站 → `from` 是 qq / qiyi / bilibili，给的是网页地址，
///                       播放器打不开；
///   自营 / 备用线路    → `from` 是 mjzy / wsym3u8 / jlm3u8，直出 m3u8，
///                       实测 #EXTM3U 合法。
/// 详情页只有线路名、没有 `from`，所以用 [MacCmsConfig.webLineNames]
/// 把已知网页源沉底，自营/备用自然浮到第一组。
final DataSource kPiankuSource = MacCmsSource(
  const MacCmsConfig(
    id: 'pianku',
    displayName: '片库 4K',
    baseUrl: 'https://4k01.pianku.online',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('20', '电影'),
      SourceCategory('37', '剧集'),
      SourceCategory('43', '动漫'),
      SourceCategory('45', '综艺'),
      SourceCategory('47', '短剧'),
    ],
    webLineNames: ['腾讯', '奇异', '爱奇艺', '优酷', 'B站', '芒果', '搜狐'],
  ),
);

// ---------------------------------------------------------------------------
// 以下两个源来自「大师兄影视」APK 的逆向结果（2026-11-11）。
//
// 结论：那个 App 自己**不托管任何视频**，它的底层片源就是两个公开的
// MacCMS 采集接口站。证据链：
//   1. APK 详情响应里 13 条线路的 `parse_api` 分别指向
//      `bt2.php` / `gf2.php` / `nby.php` / `za.php` 等一大堆中转脚本；
//   2. 但它自己 bfzym3u8 线路的地址 `v.fengbao14.com/video/…/index.m3u8`
//      与暴风接口对同一部剧下发的地址**逐字符相同**；
//   3. 「嫁金钗」两侧交叉验证通过（暴风 vod_id=168316）。
//
// 所以我们不需要复刻它的中转脚本栈，直接接原始采集接口即可：
// 线路更少但每条都是真的，也不用维护一堆随时会挂的 php 中转。
// ---------------------------------------------------------------------------

/// 大师兄 · 暴风源（bfzyapi.com）
///
/// 实测（2026-11-11）：
///   总量 171,460 条；主分类 48 个
///   搜索「嫁金钗」命中 1,216 条，首位即目标
///   `bfzym3u8` 线路直出 m3u8 → HTTP 200 / 24,005 B 合法 VOD 清单 ✅
///
/// **分类只能填子分类 id**：父分类（`20` 电影片 / `30` 连续剧）
/// 在接口里几乎没挂数据（实测分别只有 14 / 7 条），
/// 真正的内容全在 21~29、31~38 这些子分类下。填父分类会让用户
/// 点进去看到一片空白，误以为源坏了。
final DataSource kBofengSource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'bofeng',
    displayName: '大师兄 · 暴风',
    apiUrl: 'https://bfzyapi.com/api.php/provide/vod/',
    description: '直连采集接口，线路直出 m3u8，无弹幕；片库 17 万+',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('26', '电影'),
      SourceCategory('31', '国产剧'),
      SourceCategory('32', '欧美剧'),
      SourceCategory('41', '日韩动漫'),
      SourceCategory('58', '短剧'),
      SourceCategory('68', 'AI漫剧'),
      SourceCategory('51', '解说'),
    ],
    lineNameCn: {
      'bfzym3u8': '暴风线路',
      'lzm3u8': '量子线路',
      'liangzi': '量子分享',
      'bfzy': '暴风线路',
    },
  ),
);

/// 大师兄 · 量子源（cj.lziapi.com）
///
/// 实测（2026-11-11）：
///   总量 163,457 条；主分类 33 个
///   `lzm3u8` 线路 → HTTP 200 / 96 B 多码率 master，可播 ✅
///   `liangzi` 线路 → 301 到分享页 HTML，地址藏在 `var main = "…"`，
///                    由 [MacCmsApiSource.resolveUrl] 二次解析，也能播
///
/// 与暴风互补性很好：同一部剧常能在这里找到另一条线路，
/// 正好用来做「这条线挂了换那条」。
final DataSource kLiangziSource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'liangzi',
    displayName: '大师兄 · 量子',
    apiUrl: 'https://cj.lziapi.com/api.php/provide/vod/',
    description: '直连采集接口，短剧与解说资源极多；无弹幕，片库 16 万+',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('7', '电影'),
      SourceCategory('13', '国产剧'),
      SourceCategory('16', '欧美剧'),
      SourceCategory('30', '日韩动漫'),
      SourceCategory('46', '短剧'),
      SourceCategory('52', 'AI漫剧'),
      SourceCategory('35', '解说'),
    ],
    lineNameCn: {
      'lzm3u8': '量子线路',
      'liangzi': '量子分享',
      'bfzym3u8': '暴风线路',
    },
  ),
);

// ---------------------------------------------------------------------------
// 以下 5 个源来自 2026-11-13 的全网探测 + 用户实机验收。
//
// 探测链路（脚本在 code/tools/probe_maccms*.py，可复跑）：
//   34 个候选 → 接口初筛 15 → 深度验证 13 → 国内直连 13/13 → m3u8 真播 10/13
//   再经用户浏览器实测，剔掉域名过期 / CF 盾的，最终保留这 5 个。
//
// ## 两条必须知道的实测结论
//
// 1. **父分类是空的**。`t=1`（电影）/`t=2`（电视剧）在 `ac=list` 下恒返回
//    0 条，数据全挂在子分类（`6` 动作片、`13` 国产剧…）。而 `t=6,7` 这种
//    逗号写法**不会聚合**，只取第一个 id（实测 `t=6,7` 与 `t=6` 的 total
//    完全相同，都是 5705，且返回条目的 type_id 全是 6）。
//    所以栏目用「逗号串」表达，由 [MacCmsApiSource.category] 在客户端
//    并发拉取各子分类再交错合并。
//
// 2. **第一条线路是网页分享页**。这些站给同一部剧常下发两条线路，第一条
//    是 `…/share/<md5>` 的 HTML 页，第二条才是直出 m3u8。播放器默认取
//    第一条，而非凡 / 电影天堂的分享页里连 m3u8 都抠不出来（靠 JS 渲染），
//    用户就会看到「点进去播放没出来」。所以全部打开
//    [MacCmsApiConfig.preferDirectLine]，把直出线路顶到前面。
//
// 下面的分类 id 全部逐条实测过数据量，不是抄来的。
// ---------------------------------------------------------------------------

/// 电影天堂 —— 实测首页 213ms，全部 5 个源里最快。
///
/// 用户实机反馈：「综合最后视频没有水印、响应也快」，列为第一优先。
/// 片库 85,114 条；`dyttm3u8` 直出多码率 master，实测 #EXTM3U 合法。
final DataSource kDyttSource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'dytt',
    displayName: '电影天堂',
    apiUrl: 'http://caiji.dyttzyapi.com/api.php/provide/vod/',
    description: '直连采集接口、无弹幕；无水印，响应最快；片库 8.5 万+',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('11,7,6,10,8,20,9,12', '电影'),
      SourceCategory('13,16,14,22,15,24,21,23', '剧集'),
      SourceCategory('25,27,28,26', '综艺'),
      SourceCategory('30,37,29,31,32', '动漫'),
      SourceCategory('36', '短剧'),
    ],
    lineNameCn: {
      'dyttm3u8': '天堂线路',
      'dytt': '天堂网页',
    },
    // 该站 ac=list 只回 8 个字段、不含 vod_pic（实测 0/20），
    // 必须走 ac=detail 才有封面。代价：6.0 KB → 459.1 KB（约 77×）。
    listNeedsDetail: true,
  ),
);

/// 光速资源 —— 实测首页 224ms。
///
/// 用户实机反馈「还行就是搜索有验证码」。已查清：**验证码在网页站上，
/// 采集接口的搜索完全正常**（`走马上任` 命中 1 条、`凡人修仙传` 命中 5 条，
/// 均为 200 + 合法 JSON）。App 走采集接口，不受影响。
final DataSource kGuangsuSource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'guangsu',
    displayName: '光速资源',
    apiUrl: 'https://api.guangsuapi.com/api.php/provide/vod/',
    description: '直连采集接口、无弹幕；短剧极多，另有体育赛事；片库 11.8 万+',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('10,6,11,8,24,7,9,12', '电影'),
      SourceCategory('13,14,21,16,23,22', '剧集'),
      SourceCategory('37,38,39', '综艺'),
      SourceCategory('42,52,43', '动漫'),
      SourceCategory('45,47,44,49,50,46,48', '短剧'),
      SourceCategory('33,34,35,36', '体育'),
    ],
    lineNameCn: {
      'gsm3u8': '光速线路',
      'gsyun': '光速网页',
    },
    // ac=list 9 字段、无封面（实测 0/20）。代价：7.1 KB → 104.4 KB（约 15×）。
    listNeedsDetail: true,
  ),
);

/// 非凡资源 —— 实测首页 228ms。
///
/// 用户实机反馈「这个还行」。老牌站，条目多带简介与豆瓣 ID。
/// 片库 99,094 条；`ffm3u8` 直出多码率 master。
final DataSource kFeifanSource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'feifan',
    displayName: '非凡资源',
    apiUrl: 'http://cj.ffzyapi.com/api.php/provide/vod/',
    description: '直连采集接口、无弹幕；老牌站，条目多带简介；片库 9.9 万+',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('11,7,10,6,8,20,9,12', '电影'),
      SourceCategory('13,16,14,22,15,24,21,23', '剧集'),
      SourceCategory('25,26,27,28', '综艺'),
      SourceCategory('30,29,31,33,32', '动漫'),
      SourceCategory('36', '短剧'),
    ],
    lineNameCn: {
      'ffm3u8': '非凡线路',
      'feifan': '非凡网页',
    },
    // ac=list 8 字段、无封面（实测 0/20）。代价：6.0 KB → 261.9 KB（约 44×）。
    listNeedsDetail: true,
  ),
);

/// 猫眼资源 —— 实测首页 264ms。
///
/// 用户实机反馈「这个也不错」。片库较小（34,482）但分类最细：
/// 惊悚 / 悬疑 / 犯罪 / 灾难 / 历史 / 家庭 / 西部片各自独立。
/// **单线路 `mym3u8` 直出**，没有网页分享页，播放最省事。
///
/// 不挂「体育」栏目：`t=18`（NBA）实测只有 32 条，点进去几乎是空页。
final DataSource kMaoyanSource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'maoyan',
    displayName: '猫眼资源',
    apiUrl: 'https://api.maoyanapi.top/api.php/provide/vod/',
    description: '直连采集接口、无弹幕；分类最细，单线路直出最稳；片库 3.4 万+',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('11,7,6,8,20,24,25,9', '电影'),
      SourceCategory('13,16,31,15,33,30,14', '剧集'),
      SourceCategory('34,36', '综艺'),
      SourceCategory('38,40,29,39', '动漫'),
    ],
    lineNameCn: {
      'mym3u8': '猫眼线路',
    },
    // ac=list 8 字段、无封面（实测 0/30）。代价：9.3 KB → 292.5 KB（约 31×）。
    listNeedsDetail: true,
  ),
);

// ---------------------------------------------------------------------------
// 以下 2 个源来自 2026-11-14 对「本地包合集」的全量重测。
//
// 那一轮把 71 个 json 配置展开成 1771 条 site 条目、去重后 450 个唯一站点、
// 合并 jar/脚本里的域名得 432 个唯一域名，再逐个实打（312 个有效候选）。
// 最终只有这 2 个同时满足「接口稳定 + 有封面 + 播放地址真可播」。
//
// 被刷掉的 310 个不是没测，原因都记在 doc/ 的探测报告里：
//   返回 HTML 网页 135、DNS 解析失败 41、超时 35、list 空数组 22、
//   非 JSON/XML 21、404 14、403 11、连接被 RST 7、5xx 10、SSL 2。
//
// 特别说明**最电影**（api.zuidapi.com）：接口 5/5 全通、片库 12.6 万、
// 搜索 7 条，看起来是个好源。但它的片源 CDN `v15.zuidazym3u8.com`
// → 216.180.239.46 的 TCP 80/443 **全是 TimeoutError**（连根路径都超时），
// 也就是「接口能查、片子放不出来」。接进来只会让用户点一次骂一次，故不接。
// ---------------------------------------------------------------------------

/// 优子资源（YZY）—— XML 采集站，唯一需要「两次请求」的源。
///
/// ## 实测（2026-11-14，逐条 curl）
///
/// | 项 | 数据 |
/// | --- | --- |
/// | 格式 | **XML**（`<rss version="5.1">`），不是 JSON |
/// | 片库 | 109,192 条 |
/// | 播放线路 | `1080zyk`（直出 m3u8）、`zykyun`（`/share/` 分享页） |
/// | 可播性 | `1080zyk` 抽 6 集实测 **6/6 可播**（HTTP 200 + `#EXTM3U`） |
/// | 翻页 | 60/60 无重复 |
/// | 封面 | `ac=videolist` 路径 20/20 |
///
/// ## 为什么打开 [MacCmsApiConfig.listNeedsBatchDetail]
///
/// 这站的两个出口能力互补且互斥，没有任何参数能同时满足：
///   - `ac=list&pg=n` → **按更新时间倒序**（最新片），但只有 `<dt>`
///     线路名、没有 `<dl>` 分集、没有 `<pic>` 封面，5.7 KB；
///   - `ac=videolist&pg=n` → 有封面有分集，但**按 id 升序**，
///     第一页全是 2022 年的老片，打开就是「这源怎么这么旧」。
///
/// `order=time` / `order=last` / `at=json` 三种参数全部实测**被服务端忽略**
/// （返回字节数与不加参数完全一致）。所以只能先用 list 拿最新 id、
/// 再 `ac=videolist&ids=a,b,c` 批量回查。代价：1.2s + 2.1s ≈ 3.3s / 页。
final DataSource kYzzySource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'yzzyapi',
    displayName: '优子资源',
    apiUrl: 'https://api.yzzyapi.com/api.php/provide/vod/',
    description: '直连采集接口、无弹幕；片库 10.9 万+，线路直出 m3u8',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('5,6,7,8,9,10,11', '电影'),
      SourceCategory('12,14,15,18,16,17,13', '剧集'),
      SourceCategory('62,64,65,63', '综艺'),
      SourceCategory('41,66,67,68', '动漫'),
      SourceCategory('95,97,103,117', '短剧'),
      SourceCategory('20', '纪录片'),
    ],
    lineNameCn: {
      '1080zyk': '优子线路',
      'zykyun': '优子网页',
    },
    format: MacCmsFormat.xml,
    listNeedsBatchDetail: true,
  ),
);

/// 金山资源（JSZY）—— 现有采集站里**片库最大**的一个。
///
/// ## 实测（2026-11-14）
///
/// | 项 | 数据 |
/// | --- | --- |
/// | 片库 | **116,660 条**（大于暴风的 17 万之外所有站） |
/// | `ac=list` 中位 | 3.4s / 8 字段 / **无封面** |
/// | `ac=detail` 中位 | **4.4s** / 278 KB / 封面 20/20 |
/// | 线路 | `jsyun`（网页播放页）、`jsm3u8`（直出 m3u8） |
/// | 可播性 | `jsm3u8` 实测 HTTP 200 + `#EXTM3U` + 36 个分片 ✅ |
/// | 分类 | 48 个，但父分类 `1/2/17/27/29/38` 实测全 0 条 |
///
/// ## 两个必须知道的坑
///
/// 1. **首条线路是网页页**。`jsyun` 给的是 `vv.jisuzyv.com/play/epY8gOra`
///    （无 `.m3u8`），`jsm3u8` 才是 `…/play/epY8gOra/index.m3u8`。
///    靠 [MacCmsApiConfig.preferDirectLine] 把直出顶前，否则默认点第一条必挂。
/// 2. **响应偏慢**（3.4~4.4s），是当前所有采集站里最慢的一个。
///    片库够大值得保留，但排序放在采集站末尾，不让它挡在快源前面。
final DataSource kJszySource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'jszyapi',
    displayName: '金山资源',
    apiUrl: 'https://jszyapi.com/api.php/provide/vod/',
    description: '直连采集接口、无弹幕；片库 11.6 万+，线路直出 m3u8；响应稍慢',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('9,11,10,14,13,12,15,35,36', '电影'),
      SourceCategory('20,3,5,6,4,28,7', '剧集'),
      SourceCategory('30,31,33,32', '综艺'),
      SourceCategory('23,24,25,26', '动漫'),
      SourceCategory('46,48,50,45,47,52,49,54', '短剧'),
      SourceCategory('40,41,42,43', '体育'),
      SourceCategory('16', '纪录片'),
    ],
    lineNameCn: {
      'jsm3u8': '金山线路',
      'jsyun': '金山网页',
    },
    // ac=list 8 字段、无封面（实测 0/20）。代价：3.4s/17KB → 4.4s/278KB。
    listNeedsDetail: true,
    // jsyun 的 `/play/<token>` 是 1294 B 的 Vue 空壳，抓下来也抠不出地址；
    // 而 `…/play/<token>/index.m3u8` 实测 6/6 可播。见 [derivePlayIndexUrl]。
    derivePlayIndex: true,
  ),
);

/// 起点资源（QDYS2）—— 全部采集站里**片库最大**的一个，23.1 万条。
///
/// ## 怎么找到的（这条比源本身更重要）
///
/// 它不是从包里直接读出来的接口地址。包内 283 个域名的原始清单里，
/// 有 137 个「请求了 `/api.php/provide/vod/` 却返回 HTML」的候选，
/// 逐一复查后发现 **114 个其实是站点首页**（路径就没有 `/api.php`），
/// 带 `/api.php` 还返 HTML 的是 **0 个** —— 说明原来的测法没错，
/// 是这批站确实没有 JSON 接口。
///
/// 于是换了个方向：把那 260 个唯一根域名，每个再补测 7 条标准采集路径
/// （`/api.php/provide/vod/`、`/at/xml/`、`/index.php/ajax/data`、
/// `/at/json/`、`/inc/api.php`、`/api/json.php`、`/zyapi.php/provide/vod/`），
/// **只命中这一个**。换路径这条路基本枯竭，真正剩下的矿是 HTML 网页站。
///
/// ## 实测（2026-11-14）
///
/// | 项 | 数据 |
/// | --- | --- |
/// | 片库 | **230,978 条**（现有最大暴风 17 万的 1.36 倍） |
/// | `ac=list` 中位 | 1.2s / 5.7 KB / 9 字段 / **无封面** |
/// | `ac=detail` 中位 | 1.5s / 283 KB / 封面 **20/20** |
/// | 线路 | 4 条，**全部 m3u8 直出** |
/// | 搜索 | 「凡人」20 条 2.5s、「庆余年」14 条 4.3s |
///
/// ## 分类这次是真的有货
///
/// 金山和优子的父分类是空壳（`t=1` 返回 0 条，必须列子分类 id）。
/// 这站反过来：7 个父分类的 total **相加正好等于 230,978**，
/// 说明每个父分类都能直接用，不用去扒子分类：
///
/// | 分类 | t | total |
/// | --- | --- | --- |
/// | 电影 | 1 | 69,291 |
/// | 短剧 | 39 | 49,192 |
/// | 电视剧 | 2 | 38,957 |
/// | 动漫 | 4 | 31,931 |
/// | 体育 | 53 | 25,501 |
/// | 综艺 | 3 | 11,821 |
/// | 纪录片 | 7 | 4,285 |
/// | 少儿 | 6 | **0** ← 空壳，不列 |
/// | 片单推荐 | 55 | **0** ← 空壳，不列 |
///
/// ## 线路名是 4 个前缀复用
///
/// `dyttm3u8` / `bfzym3u8` / `okm3u8` / `1080zyk` 这四个名字是行业通用的
/// 线路标识（分别对应电影天堂、暴风、ok、优子系资源），不是本站独有。
/// 但**地址不是同一个 CDN**：实测同一部剧四条线路的域名完全不同
/// （`play.phimgood.com` / `v.fengbao14.com` / `v15.yaaabc.com` /
/// `cdn.yzzy32-play.com`），所以四条线路各自独立可用，互为备份。
final DataSource kQdys2Source = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'qdys2',
    displayName: '起点资源',
    apiUrl: 'https://www.qdys2.cc/api.php/provide/vod/',
    description: '直连采集接口、无弹幕；片库 23 万+（当前最大），4 条线路全直出 m3u8',
    categories: [
      SourceCategory('', '推荐'),
      SourceCategory('1', '电影'),
      SourceCategory('2', '电视剧'),
      SourceCategory('39', '短剧'),
      SourceCategory('4', '动漫'),
      SourceCategory('3', '综艺'),
      SourceCategory('7', '纪录片'),
      SourceCategory('53', '体育'),
    ],
    lineNameCn: {
      'dyttm3u8': '电影天堂',
      'bfzym3u8': '暴风线路',
      'okm3u8': 'OK 线路',
      '1080zyk': '优子线路',
    },
    // ac=list 9 字段、实测封面 0/20；ac=detail 283 KB 换 20/20。
    // qdys2 的 detail 比金山小（283 KB vs 278 KB 差不多），但 list 只要 5.7 KB，
    // 所以这站开 detail 的代价是 +277 KB，换一整屏封面，值。
    listNeedsDetail: true,
  ),
);

/// 索尼资源 —— 2026-11-14 复测接入，片库 **149,014 条**（现存第二）。
///
/// ## 为什么之前被漏掉
///
/// 2026-11-13 那轮初筛把它标了「★★★ 可播」，但当时按父分类
/// （`t=1` 电影 / `t=2` 电视剧 / `t=3` 综艺 / `t=4` 动漫）去验，
/// 四个父分类**全部返回 0 条**，于是被当成「没有分类结构」跳过。
///
/// 复测时把 `class` 数组里 60 多个 type_id 逐个打了一遍才发现：
/// 这站是**完全扁平**的分类结构 —— 父分类是空壳，货全挂在
/// `t=6 动作片`、`t=11 剧情片` 这些**看起来像子分类、实际是顶层**的 id 上。
/// 54 个分类有货，其中剧情片 26,118、现代都市 12,362、女频恋爱 10,215。
///
/// ## 实测数据
///
/// | 项 | 数据 |
/// | --- | --- |
/// | 片库 | 149,014 条 |
/// | `ac=list` | 1.2s / 5 KB / **封面 0/20** |
/// | `ac=detail` | 2.1s / 113 KB / 封面 20/20 |
/// | 线路 | `snm3u8` 单线路直出 |
/// | 可播性 | 实测 HTTP 200 + `#EXTM3U` ✅ |
///
/// 上表耗时是**单次实测**（复测时那一次的读数），不是 5 次中位数。
/// 这站实际波动不小（另一次 `ac=list` 测到 4.9s），所以排序时
/// 没有把它放到「比暴风快」的位置，而是按偏保守的估计排在采集站中段。
///
/// ## 刻意不收的分类
///
/// `伦理` / `港台三级` / `韩国伦理` / `西方伦理` / `日本伦理` /
/// `两性课堂` / `写真热舞`（共 4,000+ 条）**一律不配置**。
/// 这些不是「漏了」，是明确不要：本 App 是通用追剧客户端，
/// 把这几个栏目做成一级 Tab 会影响它在应用商店与家庭场景下的可用性。
/// 接口层面仍能搜到，只是不给独立入口。
final DataSource kSuoniSource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'suoni',
    displayName: '索尼资源',
    apiUrl: 'https://suoniapi.com/api.php/provide/vod/',
    description: '直连采集接口、无弹幕；片库 14.9 万+，单线路直出 m3u8',
    categories: [
      SourceCategory('', '推荐'),
      // 电影：动作/喜剧/爱情/科幻/恐怖/剧情/战争
      SourceCategory('6,7,8,9,10,11,12', '电影'),
      // 剧集：国产/欧美/韩/日/港/台/泰/海外
      SourceCategory('13,14,15,16,17,18,19,23', '剧集'),
      // 综艺：大陆/日韩/港台/欧美
      SourceCategory('25,26,27,28', '综艺'),
      // 动漫：国产/日韩/欧美/动画片/港台/海外
      SourceCategory('29,30,31,39,44,45', '动漫'),
      // 短剧：女频恋爱 10215 / 现代都市 12362 / 反转爽剧 4664 / 古装仙侠 4566
      SourceCategory('64,65,66,67,68,69,73', '短剧'),
      // 体育：篮球 3020 / 足球 4158
      SourceCategory('49,50', '体育'),
      SourceCategory('20', '纪录片'),
      // 影视解说 7407 —— 现在几乎所有采集站都有这个分类，
      // 单独给一个 Tab，不和电影混在一起
      SourceCategory('53', '解说'),
    ],
    lineNameCn: {
      'snm3u8': '索尼线路',
    },
    // ac=list 只有 5 KB 且无封面；ac=detail 113 KB 换 20/20。
    // 增量 108 KB，和金山（278 KB）、优子（批量两次）比算便宜。
    listNeedsDetail: true,
  ),
);

/// 无尽资源 —— 2026-11-14 复测接入，片库 **125,081 条**。
///
/// ## 坑（与索尼同源，但表现更迷惑）
///
/// 父分类 `t=1~5` 全部 0 条；更麻烦的是 `ac=detail&ids=1,2,3` 也返回空
/// —— 因为 id 1/2/3 在这种量级的片库里**根本不存在**（采集器自增，
/// 中间大量删除，首个真实 id 是 171207）。拿不存在的 id 去查返回空，
/// 这是正确行为，不能据此判断「接口不支持按 ids 查」。
///
/// 换成真实 id 后：详情正常、线路 `wjm3u8` 直出、9 个分集全部可播。
/// **这条经验对以后接新站通用：验详情必须用 ac=list 里拿到的真实 id。**
///
/// ## 实测数据
///
/// | 项 | 数据 |
/// | --- | --- |
/// | 片库 | 125,081 条 |
/// | `ac=list` | 1.1s / 5 KB / **封面 0/20** |
/// | `ac=detail` | **4.5s** / 269 KB / 封面 20/20 |
/// | 线路 | `wjm3u8` 单线路直出 |
/// | 可播性 | 实测 HTTP 200 + `#EXTM3U` ✅ |
/// | 分类 | 54 个有货（63 个里） |
///
/// 响应是这几个新站里最慢的（detail 4.5s / 269 KB），所以排在采集站靠后。
/// 耗时同样来自单次实测，不是中位数。
final DataSource kWujinSource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'wujin',
    displayName: '无尽资源',
    apiUrl: 'https://api.wujinapi.com/api.php/provide/vod/',
    description: '直连采集接口、无弹幕；片库 12.5 万+，单线路直出 m3u8；响应稍慢',
    categories: [
      SourceCategory('', '推荐'),
      // 电影：动作/喜剧/爱情/科幻/恐怖/剧情/战争/悬疑/犯罪/奇幻
      SourceCategory('6,7,8,9,10,11,12,32,34,35', '电影'),
      // 剧集：国产/香港/台湾/美国/韩国/日本/海外/泰
      SourceCategory('13,14,15,16,22,23,24,37', '剧集'),
      SourceCategory('25,26,27,28', '综艺'),
      // 动漫：国产/欧美/动画片/港台/海外（t=30 日韩动漫实测 0 条，不收）
      SourceCategory('29,31,33,42,43', '动漫'),
      // 短剧：女频恋爱 9280 / 现代都市 12023 / 古装仙侠 4455 / 年代穿越 4395
      SourceCategory('54,55,56,57,58,59,62', '短剧'),
      // 体育：篮球 2926 / 足球 3997
      SourceCategory('39,45', '体育'),
      SourceCategory('21', '纪录片'),
      // 影视解说 3602
      SourceCategory('40', '解说'),
    ],
    lineNameCn: {
      'wjm3u8': '无尽线路',
    },
    listNeedsDetail: true,
  ),
);

/// 金鹰资源 —— 2026-11-14 复测接入，片库 **118,333 条**。
///
/// 三个新站里**分类结构最正规**的一个：两级树，父分类确实是空壳
/// （`t=1` 电视剧 0 条），子分类货真价实，39/44 有货。
///
/// ## 实测数据
///
/// | 项 | 数据 |
/// | --- | --- |
/// | 片库 | 118,333 条 |
/// | `ac=list` | 1.0s / 6 KB / **封面 0/20** |
/// | `ac=detail` | 1.7s / 236 KB / 封面 20/20 |
/// | 线路 | `jinyingyun`（网页页）+ `jinyingm3u8`（直出），2 条 |
/// | 可播性 | `jinyingm3u8` 实测 HTTP 200 + `#EXTM3U` ✅ |
///
/// 耗时是单次实测，非中位数；三个新站里它是最快的，但仍慢于暴风/量子。
///
/// **两条线路的差异要注意**：`jinyingyun` 给的是无 `.m3u8` 后缀的
/// 分享页，靠 [MacCmsApiConfig.preferDirectLine]（默认开）把直出顶到前面，
/// 否则默认点第一条会打开一个 HTML 页，播放器直接报格式错误。
final DataSource kJinyingSource = MacCmsApiSource(
  const MacCmsApiConfig(
    id: 'jinying',
    displayName: '金鹰资源',
    apiUrl: 'https://jyzyapi.com/provide/vod/',
    description: '直连采集接口、无弹幕；片库 11.8 万+，短剧与国剧更新快',
    categories: [
      SourceCategory('', '推荐'),
      // 电影：动作/爱情/喜剧/科幻/恐怖/剧情/战争（t=2 只有 1 条，不收）
      SourceCategory('9,10,11,12,13,14,15', '电影'),
      // 剧集：欧美/香港/韩/日/马泰/内地/台湾
      SourceCategory('3,4,5,6,7,20,28', '剧集'),
      SourceCategory('36,37,38,39', '综艺'),
      // 动漫：中国/日本/欧美/动画片
      SourceCategory('24,25,26,23', '动漫'),
      // 短剧：现代都市 15823 / 言情总裁 6196 / 古装仙侠 5903 / 反转爽剧 4779
      SourceCategory('40,41,42,43,44,45,46,48', '短剧'),
      // 体育：足球 5663 / 篮球 3593 / 台球 273 / 其他 134
      SourceCategory('32,33,34,35', '体育'),
      SourceCategory('16', '纪录片'),
    ],
    lineNameCn: {
      'jinyingm3u8': '金鹰线路',
      'jinyingyun': '金鹰网页',
    },
    listNeedsDetail: true,
  ),
);
