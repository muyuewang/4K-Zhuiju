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