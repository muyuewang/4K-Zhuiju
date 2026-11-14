/// 橘汁（原 APK 接口）数据源实现。
///
/// 这一层是**纯包装**，不改变任何行为：所有请求仍走 [ZhuijuApi]，
/// 只是把它的 int id 与一次取址的语义，翻译成 [DataSource] 的统一契约。
///
/// 刻意保持薄：原来的 api.dart 已经调通并写了大量注释记录踩坑，
/// 在这里重写一遍签名逻辑只会制造第二份真相。
library;

import '../api.dart';
import '../models.dart';
import 'data_source.dart';

/// 橘汁频道（对齐官方首页 tab 顺序：推荐 → 电视剧 → …）
///
/// 数字项是 `/api/proto/v5/drama/category` 的 typeId1，2026-11-11 把
/// 1..200 全枚举过：只有 20-26 有内容，27 以上一律空。
///   - 25 直播、26 漫剧早期版本整个漏掉 / 误标成「其他」，已补正。
///
/// v1.9.1 删掉「Netflix」频道：它是**搜索接口按 `clazz` 标签凑出来的**
/// 伪分类（服务端没有对应 typeId1），内容本质就是搜索结果，
/// 且和「电视剧 / 电影」大量重复，单独占一个 tab 反而误导。
const List<SourceCategory> kZhuijuCategories = [
  SourceCategory('', '推荐'),
  SourceCategory('21', '电视剧'),
  SourceCategory('20', '电影'),
  SourceCategory('22', '综艺'),
  SourceCategory('23', '动漫'),
  SourceCategory('24', '短剧'),
  SourceCategory('25', '直播'),
  SourceCategory('26', '漫剧'),
];

class ZhuijuSource implements DataSource {
  ZhuijuSource._();
  static final ZhuijuSource instance = ZhuijuSource._();

  @override
  String get id => 'zhuiju';

  @override
  String get displayName => '橘汁（默认）';

  @override
  String get description => '分类齐全、支持弹幕，单一线路';

  @override
  List<SourceCategory> get categories => kZhuijuCategories;

  @override
  bool get supportsDanmaku => true;

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    // 推荐页 = 空关键词搜索（实测返回全量热门），沿用原逻辑
    final list = await ZhuijuApi.instance.search(keyword, page: page);
    return list.map(_tag).toList();
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    if (categoryId.isEmpty) {
      // 「推荐」不是真的分类，是空关键词搜索
      final list = await ZhuijuApi.instance.search('', page: page);
      return list.map(_tag).toList();
    }
    final list = await ZhuijuApi.instance.category(categoryId, page: page);
    return list.map(_tag).toList();
  }

  @override
  Future<DramaDetail> detail(String dramaId) async {
    final d = await ZhuijuApi.instance.detail(dramaId);
    return _tagDetail(d);
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    // 直链（bfzym3u8 / qq 两类源）本身就能播，但接口会下发同一份清单的
    // CDN 镜像，响应更快且原站随时可能加防盗链。所以仍然优先走接口，
    // 只有接口失败时才回落到直链——这个策略沿用 player_page 原来的写法。
    final direct = ZhuijuApi.isDirectUrl(video.path) &&
        (video.path.endsWith('.m3u8') || video.path.endsWith('.mp4'));

    try {
      final info = await ZhuijuApi.instance.playUrl(video.source, video.path);
      final u = info.playUrl;
      if (u.isNotEmpty && ZhuijuApi.isDirectUrl(u)) return u;
      if (direct) return video.path;
      return u;
    } catch (e) {
      if (direct) return video.path;
      rethrow;
    }
  }

  /// 给列表项打上来源标记，避免跨源时用错 id 去查详情
  Drama _tag(Drama d) => Drama(
        id: d.id,
        name: d.name,
        area: d.area,
        brief: d.brief,
        stars: d.stars,
        director: d.director,
        actor: d.actor,
        remark: d.remark,
        year: d.year,
        type: d.type,
        clazz: d.clazz,
        updateTime: d.updateTime,
        vodPubdate: d.vodPubdate,
        cover: d.cover,
        sourceId: id,
      );

  DramaDetail _tagDetail(DramaDetail d) => DramaDetail(
        id: d.id,
        name: d.name,
        area: d.area,
        brief: d.brief,
        intro: d.intro,
        director: d.director,
        actor: d.actor,
        remark: d.remark,
        tag: d.tag,
        year: d.year,
        type: d.type,
        hits: d.hits,
        isEnd: d.isEnd,
        stars: d.stars,
        cover: d.cover,
        videos: d.videos.map(_tagVideo).toList(),
        sourceId: id,
      );

  /// 给 video 打「是不是直播流」的标记。
  ///
  /// 判据 `source == 'cctv' && path` 以 `zb-` 开头，来自对四个分类的
  /// 全量对照实测（见 `test/zhuiju_live_marker_probe_test.dart`）：
  ///
  ///   | 分类 | video 数 | 命中 |
  ///   | --- | --- | --- |
  ///   | 直播 25 | 114 | **114（100%）** |
  ///   | 电视剧 21 | 1947 | 0 |
  ///   | 电影 20 | 61 | 0 |
  ///   | 短剧 24 | 378 | 0 |
  ///
  /// 两个方向都验过才敢用：漏判会让直播内容继续套着「选集」外壳，
  /// 误判则会让正常剧集丢掉选集、不能记进度、播完不自动下一集 ——
  /// 后者对用户的伤害大得多，所以判据取「source + 前缀」双条件，
  /// 比只看 `zb-` 前缀更难被将来的新源撞上。
  ///
  /// 为什么标记打在这一层而不是详情页：只有数据源知道自家接口的语义。
  /// 让 UI 去猜「source=cctv 是不是直播」，每接一个带直播的分类就要
  /// 改一次页面，而且散落各处的判断迟早会不一致。
  DramaVideo _tagVideo(DramaVideo v) {
    final live = v.source == 'cctv' && v.path.trimLeft().startsWith('zb-');
    // 已经是目标值就直接返回原对象，避免 detail 每次刷新都重建上百个对象
    if (live == v.isLive) return v;
    return v.copyWith(isLive: live);
  }
}