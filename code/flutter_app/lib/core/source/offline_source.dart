/// 还没加载到任何源时的占位。
///
/// ## 为什么需要它
///
/// 源全部来自远程配置后，「列表为空」从异常状态变成了**合法状态**：
/// 首次安装、断网启动、配置正在拉取时，都必然经历它。
///
/// 没有占位的话，界面每条路径都要自己处理空列表——`all.first` 会
/// 直接抛 `Bad state: No element`，而这类崩溃最容易发生在冷启动，
/// 用户看到的就是「一打开就闪退」。
///
/// 有了占位，所有页面都按「拿到一个 DataSource，正常渲染」的路径走，
/// 只是每个方法都明确失败，界面显示「源配置还没准备好」
/// 而不是白屏或崩溃。
///
/// ## 它不能做什么
///
/// 它**不是**一个真源：没有片库、不能搜索、不允许被选为当前源
/// （[SourceRegistry.select] 会直接忽略它）。它唯一的职责是把
/// 「还没有源」这件事表达成一个正常的、可渲染的对象。
library;

import '../models.dart';
import 'data_source.dart';

class OfflineSource implements DataSource {
  const OfflineSource._();

  static const OfflineSource instance = OfflineSource._();

  /// 固定 id，且刻意用 `__` 前缀：它不会和任何真实源撞车
  /// （manifest 校验只允许小写字母/数字/下划线/连字符，但真实源
  /// 不会用双下划线开头这种名字）。
  @override
  String get id => '__offline';

  @override
  String get displayName => '源配置未就绪';

  @override
  String get description => '正在获取远程源配置，请检查网络后到「我的」页点「刷新插件配置」';

  @override
  List<SourceCategory> get categories => const <SourceCategory>[];

  @override
  LineOrderPolicy get lineOrderPolicy => LineOrderPolicy.sourceOrder;

  @override
  bool get supportsDanmaku => false;

  @override
  Future<List<Drama>> search(String keyword, {int page = 1}) async {
    throw const OfflineSourceException();
  }

  @override
  Future<List<Drama>> category(String categoryId, {int page = 1}) async {
    throw const OfflineSourceException();
  }

  @override
  Future<DramaDetail> detail(String dramaId) async {
    throw const OfflineSourceException();
  }

  @override
  Future<String> resolveUrl(DramaVideo video) async {
    throw const OfflineSourceException();
  }
}

/// 占位源的统一错误。
///
/// 单独一个类型而不是 `ApiException`：界面要据此区分「这个源暂时没配置」
/// 和「源站挂了」——前者该引导用户刷新配置，后者该建议换源或重试。
class OfflineSourceException implements Exception {
  const OfflineSourceException([this.message = '源配置尚未加载完成']);

  final String message;

  @override
  String toString() => message;
}