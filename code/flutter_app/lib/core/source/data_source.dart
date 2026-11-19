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

/// 可选能力：自己声明在切换面板里归到哪一组。
///
/// ## 为什么是可选能力而不是必选成员
///
/// 绝大多数源就是普通采集站，恒返回「采集站（直连）」没有任何信息量。
/// 把它写进 [DataSource] 会要求每个实现类都补一行 getter，纯噪音。
/// 与 [SectionedFeed] 同一套做法：需要特殊分组的源才实现。
///
/// ## 为什么不在注册表里按 id 硬编码
///
/// 源全部来自远程配置后，注册表不可能预知会下发哪些 id。硬编码的
/// id 表一旦对不上，新源就会被静默归到「采集站」——而它实际可能
/// 需要系统代理，用户点进去只会看到「无法连接」，且看不出原因。
/// 让源自己声明，加新源时分组天然正确。
abstract class SourceGrouped {
  /// 分组名。空串表示不声明，注册表按默认分组处理。
  ///
  /// 约定取值见 [SourceRegistry.groupOrder]，但**不强制**：
  /// 未知分组名会作为新分组排在已知分组之后，而不是被丢弃。
  String get group;
}

/// 可选能力：**站方本身不提供站内搜索**。
///
/// 有的采集站把 `/api.php?ac=list&wd=关键词` 直接拦死，恒返回一句
/// 「暂不支持搜索」（实测索尼资源：18 字节纯文本，换任何 UA/Referer/
/// Accept 都一样）。这种源不是请求失败，也不是「没搜到」——用户看到
/// 空列表只会以为 App 坏了。
///
/// 与 [SourceGrouped] 同一套做法：只有这类源才实现，页面据此给出明确
/// 提示，且不再发那次注定无效的请求。
///
/// [searchUnsupportedHint] 返回**空串**表示本实例其实支持搜索——插件源
/// 是同一套代码实例化的，没法按清单开关决定 `implements` 哪个接口，
/// 所以用「空串 = 不拦」表达。
abstract class SearchUnsupported {
  /// 给用户看的解释。返回空串表示用页面默认文案。
  String get searchUnsupportedHint;
}

/// 可选能力：**搜索结果不支持翻页**。
///
/// ## 为什么做成可选接口而不是 [DataSource] 的必选 getter
///
/// 项目里所有源都是 `implements DataSource`（不是 extends），Dart 的
/// `implements` 会绕过继承来的默认实现 —— 在 [DataSource] 里写
/// `bool get supportsSearchPaging => true` 一点用都没有，编译器照样要求
/// 每个实现类补一行。加一个恒为 true 的 getter 到 9 个源里，纯噪音。
///
/// 只有「真的不能翻」的源才实现本接口，页面统一按
/// `s is SearchSinglePage` 判断，加源时不用动页面。
///
/// ## 实测依据（2026-11-19 逐源核对源码）
///
/// 下面三个源的 `search` 里都有 `if (page > 1) return const [];`，
/// 且各自注释写明了原因（站点搜索接口不分页 / page=2 返回与第 1 页
/// 逐字节相同）。在这种情况下把「下一页」画出来，用户点了只会得到
/// 一个空列表，看起来像 App 坏了。
abstract class SearchSinglePage {}

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