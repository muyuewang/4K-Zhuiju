/// 数据源抽象层。
///
/// 为什么要有这一层：
///
/// 最初整个 App 只有一个数据源（橘汁的 protobuf 接口），页面直接调
/// [ZhuijuApi.instance]，写起来最省事。但当第二个数据源（kanju）进来时，
/// 那两个源在**每一层**都不一样：
///
///   | 维度     | 橘汁                    | kanju                        |
///   | -------- | ----------------------- | ---------------------------- |
///   | 传输     | protobuf + AES/RSA 签名 | JSON + HMAC-SHA256 签名      |
///   | id       | int                     | `av_` 前缀长串               |
///   | 分类     | typeId1 = 20/21/22...   | content_kind = movie/series  |
///   | 播放取址 | 一次 videoUsableUrl     | 两阶段 resolve + resolve-line |
///   | 线路粒度 | 详情页一次给全           | 按集 resolve，不能预加载     |
///
/// 如果把这些差异写成 `if (源 == kanju) ... else ...` 散落到页面里，
/// 那么每加一个源就要改一遍所有页面，且改坏了自己也不知道。
/// 抽成接口后，页面只依赖这里的契约，加源 = 新增一个实现类。
///
/// 设计原则：**接口只暴露页面真正需要的能力**，不追求把两个源的
/// 所有特性都抽象出来。橘汁独有的弹幕、kanju 独有的榜单分区，
/// 各自留在自己的实现里，页面按需 instanceof 或走可选能力判断。
library;

import '../models.dart';

/// 线路（播放源）面板的排序策略。
///
/// 为什么必须让数据源自己声明，而不是在 source_picker 里按内容嗅探：
/// 两个源对「什么叫好线路」的定义完全相反。
///
///   - 橘汁：接口下发顺序本身就是编辑推荐 —— 实测「走马上任」12 条线
///     依次是 自建蓝光 → 自建4K-4 → 自建4K-3 → … → B蓝光 → QQ 垫底。
///     自建线画质高且流畅，QQ/B蓝光是采集来的、清晰度差还常卡。
///     任何自定义排序都可能把最差的线顶到第一屏。
///   - kanju：接口顺序按线路生成时间排，官方线（1080P/4K）混在中间，
///     且官方线要靠游客会话解析。这里才需要「官方优先 / 普通优先」
///     的用户偏好，以及把不可播线路沉底。
///
/// 2026-11-11 的真实回归：早期统一按「是不是直出 MP4」排序，结果把
/// 橘汁的 QQ 和 B蓝光提到最前、10 条自建线全部沉底。用户反馈
/// 「这线路不行，没有自建的清晰流畅」。按源分流后不再互相打架。
///
/// 新接入的源只需返回其中一种，不必改 [source_picker] 的任何一行。
enum LineOrderPolicy {
  /// 保持接口下发的原始顺序，只把整条不可播的线路沉到底部。
  /// 适合「服务端已排好序」的源（橘汁、多数 MacCMS 采集站）。
  sourceOrder,

  /// 按用户设置的线路偏好重排（官方优先 / 普通优先），并让不可播线路沉底。
  /// 适合「线路多且顺序无语义」的源（kanju）。
  byPreference,
}

/// 一个数据源必须提供的最小能力集。
///
/// 所有方法都可能抛异常，调用方统一用 `friendlyError()` 转成人话。
abstract class DataSource {
  /// 数据源标识，用于持久化（收藏/历史要记住条目来自哪个源）
  String get id;

  /// 展示名，用于设置页的源选择
  String get displayName;

  /// 设置页里的一句话说明（**必填**）。
  ///
  /// 放在契约里而不是在 `profile_page` 用 `if (源 == xxx)` 拼：
  /// 早期版本那里只有「SectionedFeed / 其它」二选一，结果新接入的
  /// 片库 4K、可可影视都被误标成「分类齐全、支持弹幕」，而它们其实
  /// 都不支持弹幕。**加源时自己声明能力，页面一行都不用改。**
  ///
  /// 刻意不给默认实现：Dart 的 `implements` 会绕过继承来的默认值，
  /// 编译器照样要求每个实现类提供，所以留默认值是自欺欺人。
  /// 设为必填后，漏写会直接编译失败，不会等到界面上出现错文案。
  String get description;

  /// 该源的分类列表。推荐页（id 为空）放第一位。
  List<SourceCategory> get categories;

  /// 搜索。[keyword] 为空时，两个源的语义都是「给我推荐/热门」。
  Future<List<Drama>> search(String keyword, {int page = 1});

  /// 分类列表。[categoryId] 是该源自己的分类标识（见 [categories]）。
  Future<List<Drama>> category(String categoryId, {int page = 1});

  /// 详情。返回的 [DramaDetail.id] 必须能再次传给本方法。
  Future<DramaDetail> detail(String dramaId);

  /// 把一条 [DramaVideo] 解析成可直接交给播放器的地址。
  ///
  /// 这是两个源差异最大的地方，也是唯一必须由实现方完全负责的逻辑：
  ///   - 橘汁：调 videoUsableUrl 换一次签名地址
  ///   - kanju：先 resolve 拿线路，官方线还要再 resolve-line 换真实地址
  ///
  /// 调用方（播放器）拿到字符串就直接播，不关心背后发生了几次请求。
  Future<String> resolveUrl(DramaVideo video);

  /// 线路面板与默认选源的排序策略。见 [LineOrderPolicy]。
  LineOrderPolicy get lineOrderPolicy;

  /// 该源是否支持弹幕。橘汁有弹幕池，kanju 没有。
  bool get supportsDanmaku;
}

/// 分类项。与页面原有的 Category 结构一致，但归属数据源。
class SourceCategory {
  final String id;
  final String name;
  const SourceCategory(this.id, this.name);
}

/// 榜单分区（首页信息流中的一块）。
///
/// 只有部分源提供这种「编排好的多分区流」，橘汁的接口是纯分页列表，
/// 没有分区概念。所以这里做成**可选能力**而不是 [DataSource] 的必选方法：
/// 加进必选接口，橘汁就得实现一个永远返回空列表的假方法。
class FeedSection {
  final String id;
  final String title;
  final String subtitle;
  final List<Drama> cards;

  const FeedSection({
    required this.id,
    required this.title,
    this.subtitle = '',
    required this.cards,
  });
}

/// 一页榜单（多分区）+ 下一页游标
class HomeFeed {
  final List<FeedSection> sections;

  /// 下一页游标，null 表示没有更多分区
  final String? nextCursor;

  const HomeFeed({required this.sections, this.nextCursor});
}

/// 可选能力：多分区榜单流。
///
/// 页面用 `source is SectionedFeed` 判断是否走榜单视图，
/// 不实现这个接口的源继续走原来的分页网格。
abstract class SectionedFeed {
  /// 拉一页榜单。[cursor] 为空表示第一页。
  Future<HomeFeed> homeFeed({String? cursor});
}