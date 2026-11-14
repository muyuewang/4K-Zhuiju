/// 直播源（IPTV / 直播平台聚合）的离线数据层。
///
/// ## 为什么这个源和别的源长得不一样
///
/// 其余 15 个源都是「运行时去对方服务器要数据」：[DataSource] 的每个方法
/// 背后都是一次 HTTP 请求。直播源不能这么做，原因有三个：
///
///   1. **包内给的是 `.m3u` 文件，不是接口**。7 个文件、4180 个去重频道，
///      没有 host 可以问「给我第一页」。
///   2. **可用性极不稳定**。实测 4180 个里能连上的只有一半左右，
///      且分布极不均匀（`yylunbo` 97%、`Gather` 27%、`ipv4` 20%）。
///      如果运行时才逐个探测，用户点开「直播」要等十几秒才有画面。
///   3. **频道不是「剧集」**。没有详情、没有多线路、没有分集，
///      点开就是一条流。硬套剧集模型会让详情页出现「第1集」这种荒谬文案。
///
/// 所以这里的策略是**构建期探活、运行期零网络**：
/// 先用脚本把 4180 个频道全量探一遍，只把**当前可播**的那些连同
/// 名称 / 分组 / 台标一起打包进 `assets/live_channels.json`，
/// App 启动时读本地文件，打开直播页没有任何网络等待。
///
/// 代价是**频道会比源站旧**：源站删台、换地址之后，本地这份不会自动跟上。
/// 这是刻意接受的取舍 —— 直播源本来就是「今天能看、下周可能就没了」，
/// 与其每次打开都等一轮探测，不如保证「打开就能看，看不了的不会出现」。
/// 想更新时重新跑一次 `tools/probe_live.py` 即可。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 一条线路：同一个频道的另一个播放地址。
///
/// 为什么线路要带自己的 kind/ua 而不是复用频道级的：同一个台的
/// 不同线路来自不同源站，一个是 m3u8、另一个可能是 flv，UA 也可能
/// 只有其中一条需要指定。用频道级的字段套到所有线路上，
/// 会把能播的那条也带成播不了。
class LiveLine {
  const LiveLine({
    required this.url,
    this.kind = '',
    this.ua = '',
  });

  final String url;
  final String kind;
  final String ua;

  Map<String, dynamic> toJson() => {'url': url, 'kind': kind, 'ua': ua};

  factory LiveLine.fromJson(Map<String, dynamic> j) => LiveLine(
        url: (j['url'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? '',
        ua: (j['ua'] as String?) ?? '',
      );
}

/// 一个直播频道。
///
/// 刻意不复用 [Drama]：频道没有 area/year/director/stars 这些字段，
/// 硬塞进去要造一堆空值，而 [DramaVideo] 又要求 `dramaId` 指向一部不存在的剧。
/// 独立一个轻量模型（5 个字段）比复用两个重模型干净得多。
class LiveChannel {
  const LiveChannel({
    required this.id,
    required this.name,
    required this.url,
    this.group = '',
    this.section = '',
    this.logo = '',
    this.kind = '',
    this.ua = '',
    this.lines = const [],
  });

  /// 稳定 id：由 url 派生。同一频道换分组、改名字，id 不变，
  /// 收藏和历史才不会失效。
  final String id;

  final String name;

  /// 播放地址（m3u8 / flv / mp4 / rtmp）
  final String url;

  /// 原始分组名，来自 `group-title`。空串表示源里没给分组。
  ///
  /// 保留原值是为了排查问题（「这个台到底来自哪个分组」），
  /// 界面上不直接展示 —— 源里的分组名有 `zonghe`、`原创IP` 这种，
  /// 直接给用户看等于没分类。展示用 [section]。
  final String group;

  /// 归并后的一级栏目（央卫视 / 港澳台 / 影视 / 地方台 / 一起看 / 主播原创 / 其他）。
  ///
  /// 源文件里是 44 个细分组，其中很多是同一个东西的不同写法
  /// （`央视IPV4` / `央视频道` / `•咪咕「移动」` 都是央卫视频道）。
  /// 归并在打包阶段做完并写进 JSON，App 启动时不用再算一遍。
  final String section;

  /// 台标地址，来自 `tvg-logo`。空串表示无台标。
  final String logo;

  /// 探活时判定出的流类型：`M3U8` / `FLV` / `MP4` / `RTMP`。
  ///
  /// 保留它不是给播放器看的（播放器自己能认），而是给**排序**用：
  /// m3u8 的播放器兼容性最好、起播最快；rtmp 在移动端基本不能播。
  /// 同分组内按这个字段排序，能把「点了就出来」的频道顶到前面。
  final String kind;

  /// 播放时必须使用的 User-Agent，来自 m3u 的 `http-user-agent` 属性。
  ///
  /// **空串是常态，不是异常**。但一旦非空就必须照用，实测代价极大：
  /// 同一个地址 `101.35.240.114:88/live.php?id=CCTV1`
  ///
  ///   | 请求 UA | 结果 |
  ///   | --- | --- |
  ///   | 默认（AptvPlayer/1.4.1） | **HTTP 404** |
  ///   | `http-user-agent` 里写的 | HTTP 200 + `#EXTM3U` |
  ///
  /// 第一版探活没读这个属性，导致 160 个 CCTV/卫视类频道被误判为失效、
  /// 整个「央卫视」栏目只剩 9 个台。播放链路同理：这里存下来，
  /// 传给播放器的 httpHeaders，否则「能探活的台点开却 404」。
  final String ua;

  /// 同一频道的**其他线路**（不含 [url] 本身）。
  ///
  /// 空列表表示这个台只有一条线路，播放器没有可切换的余地。
  /// 由打包脚本 `tools/merge_live_lines.py` 在构建期聚合好写进 JSON：
  /// 运行期按名字/域名去猜"这两条是不是同一个台"既慢又容易错，
  /// 而这件事在构建期有完整信息、还能人工核对。
  ///
  /// 为什么聚合键是「栏目 + 规范化台名」而不是 m3u 的 tvg-id：
  /// 实测 tvg-id 只有 7.1% 填充率，且语义不统一 —— `tvg-id="咪咕体育"`
  /// 底下是咪咕 1/19/30/4K-1 等 38 个**不同频道**，按它聚合会把 38 个
  /// 台并成 1 个。详见该脚本文件头的说明。
  final List<LiveLine> lines;

  /// 本频道的全部线路：主地址在前，其余在后。
  ///
  /// 播放器按这个顺序依次尝试，第一条能出画面就用它。
  /// 主地址排第一是因为打包脚本已按流类型排过序（m3u8 优先），
  /// 它通常就是兼容性最好的那条。
  List<LiveLine> get allLines => [
        LiveLine(url: url, kind: kind, ua: ua),
        ...lines,
      ];

  /// 线路数（含主地址）。1 表示没有可切换的备选。
  int get lineCount => lines.length + 1;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'group': group,
        'section': section,
        'logo': logo,
        'kind': kind,
        'ua': ua,
        if (lines.isNotEmpty) 'lines': [for (final l in lines) l.toJson()],
      };

  factory LiveChannel.fromJson(Map<String, dynamic> j) => LiveChannel(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        group: (j['group'] as String?) ?? '',
        section: (j['section'] as String?) ?? '',
        logo: (j['logo'] as String?) ?? '',
        ua: (j['ua'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? '',
        lines: [
          for (final x in (j['lines'] as List? ?? const []))
            if (x is Map<String, dynamic>) LiveLine.fromJson(x),
        ],
      );
}

/// 一条 `#EXTINF` 的原始解析结果（尚未分配 id、尚未探活）。
class M3uEntry {
  const M3uEntry({
    required this.name,
    required this.url,
    this.group = '',
    this.logo = '',
    this.tvgId = '',
    this.ua = '',
  });

  final String name;
  final String url;
  final String group;
  final String logo;
  final String tvgId;

  /// m3u 里的 `http-user-agent`，空串表示不指定。见 [LiveChannel.ua]。
  final String ua;
}

/// 解析 `.m3u` 播放列表，返回条目列表。
///
/// 这个解析器**只处理真正用得到的三种行**：
///
///   | 行 | 处理 |
///   | --- | --- |
///   | `#EXTINF:...` | 取 `group-title` / `tvg-logo` / `tvg-id` 与逗号后的频道名 |
///   | 非 `#` 开头的 http(s)/rtmp 行 | 当作地址，配对前一条 `#EXTINF` |
///   | 其余（`#EXTM3U`、`#EXT-X-*`、空行） | 忽略 |
///
/// **不引第三方 m3u 库**：这些文件的写法非常随意（属性间单空格、
/// 频道名里带逗号、URL 里有中文），通用库反而会因为严格校验把条目丢掉。
List<M3uEntry> parseM3u(String text) {
  final out = <M3uEntry>[];
  String? name;
  String group = '';
  String logo = '';
  String tvgId = '';
  String ua = '';

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXTINF')) {
      group = _attr(line, 'group-title');
      logo = _attr(line, 'tvg-logo');
      tvgId = _attr(line, 'tvg-id');
      ua = _attr(line, 'http-user-agent');
      name = _titleOf(line);
      continue;
    }

    // 其他 # 开头的是指令，不是地址
    if (line.startsWith('#')) continue;

    final lower = line.toLowerCase();
    final isUrl = lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('rtmp://') ||
        lower.startsWith('rtsp://');
    if (!isUrl) continue;

    // 没有 #EXTINF 的裸地址：用地址本身当名字，否则界面上是一片空白卡片
    final n = (name == null || name.isEmpty) ? line : name;
    out.add(M3uEntry(
      name: n,
      url: line,
      group: group,
      logo: logo,
      tvgId: tvgId,
      ua: ua,
    ));

    name = null;
    group = '';
    logo = '';
    tvgId = '';
    ua = '';
  }

  return out;
}

/// 取 `#EXTINF` 行里「属性区之后的频道名」。
///
/// 格式是 `#EXTINF:<时长>,<频道名>`，属性（`key="value"`）夹在时长和
/// 频道名之间。分隔用的逗号是**第一个不在双引号内的逗号**。
///
/// 为什么不能用 `lastIndexOf(',')`：真实源里有
/// `#EXTINF:-1 group-title="电影",碟中谍系列电影, 完整版` 这种频道名
/// 本身就带逗号的条目，取最后一个会得到「 完整版」，名字被切掉一半。
/// 反过来用 `indexOf(',')` 也不行 —— 属性值里一旦出现逗号
/// （如 `group-title="电影,剧集"`）就会从属性中间切断。
///
/// 只有「跳过引号内容、再找第一个逗号」两边都正确。
String _titleOf(String line) {
  var inQuote = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      inQuote = !inQuote;
    } else if (c == ',' && !inQuote) {
      return line.substring(i + 1).trim();
    }
  }
  return '';
}

/// 从 `#EXTINF` 行里取双引号属性值，取不到返回空串。
String _attr(String line, String key) {
  final i = line.indexOf('$key="');
  if (i < 0) return '';
  final start = i + key.length + 2;
  final end = line.indexOf('"', start);
  if (end < 0) return '';
  return line.substring(start, end).trim();
}

/// 把条目转成频道，并按 url 生成稳定 id。
///
/// id 用 url 派生的原因见 [LiveChannel.id]。这里用 [stableIdOf] 而不是
/// 自增序号：序号会随着源文件增减整体错位，已有的收藏全部指向错误的台。
List<LiveChannel> toChannels(List<M3uEntry> entries, {Map<String, String> kinds = const {}}) {
  final seen = <String>{};
  final out = <LiveChannel>[];
  for (final e in entries) {
    final url = e.url.trim();
    if (url.isEmpty || !seen.add(url)) continue;
    out.add(LiveChannel(
      id: stableIdOf(url),
      name: e.name.trim(),
      url: url,
      group: e.group.trim(),
      logo: e.logo.trim(),
      kind: kinds[url] ?? '',
      ua: e.ua.trim(),
    ));
  }
  return out;
}

/// 由 url 生成稳定 id：`live_` + CRC32 十六进制。
///
/// **为什么不用 `url.hashCode`**：Dart 的 `String.hashCode` 只保证
/// 「同一次运行内一致」，跨版本/跨平台没有稳定性承诺，而这里生成的 id
/// 要被写进收藏和历史。一旦某次 SDK 升级让 hashCode 变了，用户攒的收藏
/// 会全部失效（指向不存在的频道）。
///
/// **为什么不用自增序号**：源文件增删一个频道，后面所有序号整体错位，
/// 后果和上面一样。
///
/// **为什么是 CRC32**：打包 `assets/live_channels.json` 的脚本（Python）
/// 也用 `zlib.crc32`，两边算法一致，所以「运行时解析 m3u 得到的 id」
/// 与「打包文件里写的 id」完全相同，不会出现同一个台两个身份。
String stableIdOf(String url) {
  var crc = 0xFFFFFFFF;
  for (final byte in utf8.encode(url)) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  final hex = ((crc ^ 0xFFFFFFFF) & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return 'live_$hex';
}

/// 从打包的 JSON 文本还原频道列表。解析失败返回空列表而不是抛异常 ——
/// 直播是附属功能，资源文件坏了不该让整个 App 启动失败。
List<LiveChannel> decodeChannels(String jsonText) {
  try {
    final raw = jsonDecode(jsonText);
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map<String, dynamic>) LiveChannel.fromJson(item),
    ];
  } catch (_) {
    return const [];
  }
}

/// 打包资源的路径。改文件名时这里和 `pubspec.yaml` 的 assets 要一起改。
const String kLiveChannelsAsset = 'assets/live_channels.json';

/// 栏目展示顺序。
///
/// 按「用户最可能想看的排前面」而不是按数量：央卫视是刚需（74 个），
/// 排第一；「主播原创」有 1356 个但那是 B站/斗鱼主播的房间，排在后面
/// 不挡路。这个顺序在打包脚本里已经用于排序，这里保留一份是为了
/// 界面分组标题能按同样顺序渲染。
const List<String> kLiveSections = [
  '央卫视',
  '港澳台',
  '影视',
  '地方台',
  '一起看',
  '主播原创',
  '其他',
];
/// 从打包资源加载频道清单（进程内只读一次）。
///
/// 为什么把缓存放在这里而不是每个页面各存一份：直播页可能有多个入口
/// （分类页、搜索页、首页卡片），每次进来都重新读一遍 631 KB 的 JSON
/// 并解析 2553 个对象，是白白的卡顿。
///
/// 为什么不缓存到磁盘：资源本身就在包里，读它比读磁盘文件还快，
/// 缓存反而要处理「包更新了但缓存是旧的」这个额外问题。
class LiveTvLibrary {
  LiveTvLibrary._();

  static List<LiveChannel>? _cache;

  /// 全部频道。首次调用读资源，之后走缓存。
  ///
  /// 读失败/解析失败返回空列表：直播是附属功能，资源异常不该让
  /// 「打开直播页」变成崩溃。
  static Future<List<LiveChannel>> all() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      final text = await rootBundle.loadString(kLiveChannelsAsset);
      return _cache = decodeChannels(text);
    } catch (_) {
      return _cache = const [];
    }
  }

  /// 按栏目分组，顺序固定为 [kLiveSections]，空栏目不出现。
  static Future<Map<String, List<LiveChannel>>> bySection() async {
    final list = await all();
    final out = <String, List<LiveChannel>>{};
    for (final s in kLiveSections) {
      final items = list.where((c) => c.section == s).toList();
      if (items.isNotEmpty) out[s] = items;
    }
    // 兜底：打包脚本以后加了新栏目而这里没同步，也不能让这些频道消失
    final known = kLiveSections.toSet();
    final rest = list.where((c) => !known.contains(c.section)).toList();
    if (rest.isNotEmpty) out['其他'] = [...(out['其他'] ?? const []), ...rest];
    return out;
  }

  /// 按频道名/分组名搜索。
  ///
  /// 本地过滤而不是走后端：频道清单已经在内存里，2500 条 `contains`
  /// 是微秒级的事。做成异步只是为了和其他源的 search 签名一致，
  /// 调用方不用区分「这个源要不要联网」。
  static Future<List<LiveChannel>> search(String keyword) async {
    final k = keyword.trim().toLowerCase();
    if (k.isEmpty) return const [];
    final list = await all();
    return list
        .where((c) =>
            c.name.toLowerCase().contains(k) ||
            c.group.toLowerCase().contains(k))
        .toList();
  }
}
