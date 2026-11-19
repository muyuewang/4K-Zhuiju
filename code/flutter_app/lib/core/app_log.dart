/// 应用日志中心：内存环形缓冲 + 落盘 + 客户端可读。
///
/// ## 为什么需要它
///
/// 2026-11-19 排查「橘汁所有分类全空」时，最耗时的不是修，是**定位**：
/// 界面上只有一句「这个分类暂时没有内容」，而真正的错误
/// （服务端 `code=100001 请求时间戳过期`）被 `parseList` 吞成了空数组。
/// 全项目 163 处 `debugPrint` 在 release 包里**一个字都看不到**——
/// 用户能提供的信息只有截图，而截图里没有任何技术线索。
///
/// ## 三个设计决定
///
/// ### 1. 拦截 `debugPrint` 本身，而不是逐个改造调用点
///
/// 163 处调用散在 30 多个文件里。挨个换成 `AppLog.i(...)` 有两大问题：
/// 漏改（且漏了不会报错，只在下次排查时才发现没有日志）和
/// 改了之后新旧风格混杂。劫持 `debugPrint` 让它**一次到位**：
/// 老代码一行不动就获得落盘能力，新代码照常写 `debugPrint`。
///
/// ### 2. 环形缓冲 + 节流落盘，绝不阻塞 UI
///
/// 日志是诊断设施，不能反过来成为卡顿源。内存里只留最近 [capacity] 条
/// （给「我的 → 诊断日志」即时展示），落盘走 2 秒定时器批量 append，
/// 单次 IO 摊薄到几十条一条。
///
/// 首次落盘时会**立即**拆出一份「会话头」（版本/平台/设备），
/// 因为用户报问题时最关键的三个信息是「哪个版本、什么设备、什么时候」——
/// 而这三样恰恰是最容易在截图里被裁掉的。
///
/// ### 3. 落盘失败永不抛异常
///
/// 路径拿不到（桌面沙箱、权限被拒）、磁盘满、文件被占用，全都要
/// 静默降级成「只有内存日志」。诊断设施自己崩掉比没有更糟。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'platform.dart';
import 'version.dart';

/// 一条日志。
@immutable
class LogEntry {
  const LogEntry({
    required this.at,
    required this.level,
    required this.tag,
    required this.text,
  });

  final DateTime at;

  /// 单字母等级：V/D/I/W/E。`debugPrint` 拦截进来的统一记 D。
  final String level;

  /// 来源标签，如 `PLUGIN` / `API` / `BOOT`。取不到时是 `APP`。
  final String tag;

  final String text;

  bool get isError => level == 'E' || level == 'W';

  /// 一行文本。时间精确到毫秒——排查「两次 `Date.now()` 差 50ms」
  /// 那种问题时，秒级精度不够用。
  String get line {
    final t = at;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$hh:$mm:$ss.$ms $level [$tag] $text';
  }

  /// 带日期的完整行，用于导出。
  String get fullLine {
    final t = at;
    final d = '${t.year}-${_p(t.month)}-${_p(t.day)}';
    return '$d $line';
  }

  static String _p(int v) => v.toString().padLeft(2, '0');
}

/// 日志中心。全局单例，[init] 之后所有 `debugPrint` 都会进来。
class AppLog {
  AppLog._();

  /// 内存里保留的条数。
  ///
  /// 2000 条对本项目是合适的：橘汁一次详情页解析会打十几行，
  /// 翻十个分类再加一次详情约 200 行；2000 条够看清「从启动到出事」
  /// 的完整过程，而内存占用只有几百 KB（每条平均 150 字符左右）。
  static const int capacity = 2000;

  /// 单个日志文件的上限。超了就切到 `.1`，只保留一份历史。
  ///
  /// 为什么只留一份而不是按天轮转：用户几乎总是「刚出问题就来报」，
  /// 需要的是**这一次会话**；留一份上一会话已经够对比「昨天还好」。
  /// 无限累积只会让导出文件大到没法发给别人看。
  static const int maxFileBytes = 2 * 1024 * 1024;

  /// 落盘节流间隔。
  static const Duration flushInterval = Duration(seconds: 2);

  static final AppLog instance = AppLog._();

  final Queue<LogEntry> _buffer = Queue<LogEntry>();
  final List<LogEntry> _pending = <LogEntry>[];

  /// 内存里的日志（只读快照）。
  ///
  /// 返回副本而不是内部队列：UI 遍历的同时后台还在 append，
  /// 直接暴露可迭代对象会抛 `ConcurrentModificationError`。
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_buffer);

  bool _installed = false;
  bool _fileReady = false;
  File? _file;
  DebugPrintCallback? _originalPrint;

  /// 本次会话是否成功落盘。false 表示只有内存日志（UI 要据此提示用户）。
  bool get fileEnabled => _fileReady;

  /// 日志文件路径（未启用时为 null）。
  String? get filePath => _file?.path;

  /// 装好拦截并启动定时落盘。
  ///
  /// 必须在 `main()` 里尽量早调用，且**只调用一次**。重复调用会被忽略——
  /// 重复安装会把 `debugPrint` 指向自己，直接无限递归。
  static Future<void> init() async {
    final self = instance;
    if (self._installed) return;
    self._installed = true;

    // 先写一行会话头：用户报问题时最容易被截图裁掉的三件事
    // （版本、平台、时间）在这里先落下来，后面所有日志都能对上号。
    self.capture(
      'I',
      'BOOT',
      'app=$kAppVersionFull platform=${_platformLabel()} '
          'dart=${Platform.version.split(' ').first}',
    );

    // 再接管 debugPrint。放在记会话头之后，避免这一行被自己拦两次。
    self._originalPrint = debugPrint;
    debugPrint = AppLog._handlePrint;

    // 定时器句柄有意不保存：它随进程存活，没有「停下来」的场景。
    // 存成字段只会招来一条 unused_field 告警，还得为它编一个用不上的
    // dispose 路径 —— 日志系统要的是活得久，不是可回收。
    Timer.periodic(flushInterval, (_) => self.flush());

    // 文件通道是异步的：拿目录要走平台通道，不能卡住首帧。
    // 拿不到就静默降级（见类注释第 3 条）。
    unawaited(self._openFile());
  }

  /// 拦截 `debugPrint` 的入口。
  ///
  /// **必须把内容交回原实现**，否则控制台输出会消失——
  /// 开发时 `flutter run` 看不到日志，等于把现有的开发体验弄坏。
  static void _handlePrint(String? message, {int? wrapWidth}) {
    instance._originalPrint?.call(message, wrapWidth: wrapWidth);
    if (message == null || message.isEmpty) return;
    instance.capture('D', _tagOf(message), message);
  }

  /// 从 `[PLUGIN] xxx` / `[CFG] xxx` 这类前缀里取标签。
  ///
  /// 全项目的 `debugPrint` 基本都带方括号前缀（这也是本项目一直的惯例），
  /// 所以提取标签不需要改任何调用点。
  static String _tagOf(String message) {
    final m = RegExp(r'^\[([A-Za-z0-9_]{1,12})\]').firstMatch(message);
    if (m != null) return m.group(1)!.toUpperCase();
    return 'APP';
  }

  /// 记一条日志。超长内容会被截断（见 [sanitize]）。
  void capture(String level, String tag, String text) {
    final one = LogEntry(
      at: DateTime.now(),
      level: level,
      tag: tag,
      text: sanitize(text),
    );

    _buffer.addLast(one);
    while (_buffer.length > capacity) {
      _buffer.removeFirst();
    }
    _pending.add(one);

    // 错误立刻刷，不攒——用户很可能在崩溃/闪退前一刻出问题，
    // 攒了却没写出去就等于没记。
    if (level == 'E') {
      unawaited(flush());
    }
  }

  /// 显式记错误。业务代码里有意义的失败都应该走这里，
  /// 这样「诊断日志」页能把错误行高亮出来。
  static void error(String tag, Object error, [StackTrace? stack]) {
    instance.capture('E', tag, '$error');
    if (stack != null) instance.capture('E', tag, '$stack');
  }

  /// 把多行文本按行拆开记录。
  ///
  /// 堆栈直接 `capture` 的话在 UI 上是一条超长行，横向滚动很难读。
  static void errorMulti(String tag, String text) {
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      instance.capture('E', tag, line);
    }
  }

  /// 清理不该进日志的内容。
  ///
  /// ## 为什么必须有这一步
  ///
  /// 插件请求头里有 `publicParams`（含 RSA 签名、设备指纹），
  /// 响应体里有 base64 的 protobuf。这些一旦整段落盘：
  ///   1. 日志文件会膨胀到几十 MB，用户没法发出来；
  ///   2. 签名/指纹属于「不该随手发出去」的内容。
  ///
  /// 处理方式：超长无空格串（base64/hex 的典型形态）留头尾各 24 字符，
  /// 中间省略。**不做正则替换整段**——那会误伤正常的中文长句。
  static String sanitize(String text) {
    const int lineMax = 800;
    var out = text;

    // 单条过长直接截断（正常日志不会有 800 字符的行）
    if (out.length > lineMax) {
      out = '${out.substring(0, lineMax)}…（共 ${out.length} 字符）';
    }

    // 压缩超长的「无空格连续串」——典型是 base64 / hex / JSON 头
    out = out.replaceAllMapped(
      RegExp(r'[A-Za-z0-9+/=_-]{120,}'),
      (m) {
        final s = m.group(0)!;
        return '${s.substring(0, 24)}…(${s.length})…${s.substring(s.length - 8)}';
      },
    );
    return out;
  }

  // ---------------- 文件通道 ----------------

  Future<void> _openFile() async {
    try {
      final dir = await _logDir();
      if (dir == null) {
        debugPrint('[LOG] 拿不到日志目录，仅保留内存日志');
        return;
      }
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final f = File('${dir.path}/app.log');

      // 超过上限就滚动：当前文件改名 `.1`，`.1` 已存在则被覆盖。
      // 只留一份历史（见 maxFileBytes 的说明）。
      if (await f.exists() && await f.length() > maxFileBytes) {
        final old = File('${dir.path}/app.1.log');
        if (await old.exists()) await old.delete();
        await f.rename(old.path);
      }

      _file = f;
      _fileReady = true;
      debugPrint('[LOG] 日志文件：${f.path}');
    } catch (e) {
      // 路径不可用不影响主流程，只丢一句话到内存
      debugPrint('[LOG] 打开日志文件失败：$e');
    }
  }

  Future<Directory?> _logDir() async {
    try {
      // 桌面与移动端都用 ApplicationSupport：它专放「用户不该手动翻」
      // 的数据，且不会被系统当缓存清掉（临时目录会被清，日志就没了）。
      final base = await getApplicationSupportDirectory();
      return Directory('${base.path}/logs');
    } catch (e) {
      debugPrint('[LOG] getApplicationSupportDirectory 失败：$e');
      return null;
    }
  }

  /// 把待写内容刷到磁盘。可安全重复调用。
  Future<void> flush() async {
    if (_pending.isEmpty) return;
    final f = _file;
    if (f == null) {
      // 文件还没就绪（或永远不就绪）：丢掉待写队列，避免无界增长。
      // 内存缓冲仍在，UI 可以看。
      _pending.clear();
      return;
    }

    // 先摘出再写：写的过程中可能又进来新的，不能边遍历边清空
    final batch = List<LogEntry>.from(_pending);
    _pending.clear();

    try {
      final buf = StringBuffer();
      for (final e in batch) {
        buf.writeln(e.fullLine);
      }
      await f.writeAsString(buf.toString(), mode: FileMode.append, flush: true);
    } catch (e) {
      // 写失败（磁盘满/被占用）不重试不抛：重试会形成死循环，
      // 抛出去会把调用方（可能是 UI 线程）带崩。
      _file = null;
      _fileReady = false;
      _originalPrint?.call('[LOG] 写日志失败，已降级为内存模式：$e');
    }
  }

  /// 导出全部日志为一个字符串（给「复制」「保存」用）。
  ///
  /// 包含会话头、内存日志、以及当前文件里的历史内容。
  Future<String> export() async {
    await flush();
    final buf = StringBuffer();
    buf.writeln('===== $kAppTitle $kAppVersionFull 诊断日志 =====');
    buf.writeln('导出时间：${DateTime.now()}');
    buf.writeln('平台：${_platformLabel()}');
    buf.writeln('日志文件：${_file?.path ?? '不可用（仅内存）'}');
    buf.writeln('内存条数：${_buffer.length}');
    buf.writeln('===== 本次会话 =====');
    for (final e in _buffer) {
      buf.writeln(e.fullLine);
    }

    // 附上文件里的历史（上一会话），方便对比「昨天还是好的」
    try {
      final f = _file;
      if (f != null && await f.exists()) {
        final text = await f.readAsString();
        if (text.isNotEmpty) {
          buf.writeln('===== 文件历史 =====');
          buf.writeln(text);
        }
      }
    } catch (_) {
      // 读不到历史不影响主体导出
    }
    return buf.toString();
  }

  /// 清空内存缓冲（不动磁盘历史，用户要的是「看不见了」而不是「销毁证据」）。
  void clearMemory() {
    _buffer.clear();
    _pending.clear();
  }

  static String _platformLabel() {
    if (Platform.isAndroid) return 'Android ${Platform.operatingSystemVersion}';
    if (Platform.isIOS) return 'iOS ${Platform.operatingSystemVersion}';
    if (isDesktop) return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    return Platform.operatingSystem;
  }
}