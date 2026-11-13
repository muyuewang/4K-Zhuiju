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
