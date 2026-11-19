/// 诊断日志页（我的 → 诊断日志）。
///
/// ## 为什么要有这个页面
///
/// 2026-11-19 排查「橘汁所有分类全空」花了很久，卡点不是修，是**取证**：
/// 用户能给的只有一张截图，而截图里写着「这个分类暂时没有内容」——
/// 真正的错误（服务端 `code=100001 请求时间戳过期`）在日志里，
/// 而 release 包的日志谁都看不到。
///
/// 这个页面把三件事变成用户自己做得到的操作：
///   1. **看得见**：按等级着色，错误行一眼能挑出来
///   2. **拿得走**：一键复制全文，粘到聊天窗口就能发过来
///   3. **对得上号**：顶部固定显示版本/平台/日志文件位置，
///      这三样恰好最容易被截图裁掉
///
/// ## 为什么不做成「开发者选项」藏起来
///
/// 藏起来的诊断入口，用户永远找不到；而「找不到日志」正是这次事故里
/// 最贵的那部分成本。放在设置里一行、点开看一眼，比事后教用户
/// 用 adb logcat 现实得多。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_log.dart';
import '../core/layout.dart';
import '../core/platform.dart';
import '../core/tokens.dart';
import '../core/version.dart';
import '../theme.dart';

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  /// 只看错误。默认跟随设置页的开关状态，进页面后用户可自行切换。
  bool _onlyError = false;

  /// 列表滚到底部用的控制器：日志是「越新越靠下」，
  /// 进来应该直接看到最新的一屏，而不是从十分钟前的启动日志开始读。
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 首帧后再滚，否则 maxScrollExtent 还是 0，滚了个空
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  Future<void> _copy() async {
    final text = await AppLog.instance.export();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已复制 ${text.length} 字符，粘贴到聊天窗口发给开发者即可',
          style: const TextStyle(fontSize: Ts.bodySm),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _clear() {
    // 只清内存显示，不删磁盘文件：用户要的是「眼前干净」，
    // 而不是「销毁证据」——真出问题时那份文件才是唯一线索。
    setState(AppLog.instance.clearMemory);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已清空当前显示（历史文件保留）',
            style: TextStyle(fontSize: Ts.bodySm)),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final all = AppLog.instance.entries;
    final list = _onlyError ? all.where((e) => e.isError).toList() : all;
    final errCount = all.where((e) => e.isError).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断日志'),
        actions: [
          // 只显示错误：日志一多，「从 2000 行里找那 3 行红字」很折磨
          IconButton(
            tooltip: _onlyError ? '显示全部' : '只看错误',
            icon: Icon(_onlyError
                ? Icons.filter_alt_rounded
                : Icons.filter_alt_outlined),
            onPressed: () => setState(() => _onlyError = !_onlyError),
          ),
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_rounded),
            onPressed: _copy,
          ),
          IconButton(
            tooltip: '清空显示',
            icon: const Icon(Icons.clear_all_rounded),
            onPressed: all.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: ContentClamp(
        child: Column(
          children: [
            _header(errCount: errCount, total: all.length),
            Divider(height: 1, color: p.divider),
            Expanded(
              child: list.isEmpty
                  ? Center(
                      child: Text(
                        _onlyError ? '没有错误日志' : '还没有日志',
                        style:
                            TextStyle(fontSize: Ts.body, color: p.textDim),
                      ),
                    )
                  : Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                            horizontal: Sp.md, vertical: Sp.sm),
                        itemCount: list.length,
                        itemBuilder: (c, i) => _LogRow(entry: list[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header({required int errCount, required int total}) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      color: p.card,
      padding: const EdgeInsets.symmetric(horizontal: Sp.lg, vertical: Sp.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('v$kAppVersionFull',
                  style: TextStyle(fontSize: Ts.bodySm, color: p.textDim)),
              const SizedBox(width: Sp.md),
              Text(
                isDesktop ? '桌面端' : '移动端',
                style: TextStyle(fontSize: Ts.bodySm, color: p.textDim),
              ),
              const Spacer(),
              Text('$total 条',
                  style: TextStyle(fontSize: Ts.bodySm, color: p.textDim)),
              if (errCount > 0) ...[
                const SizedBox(width: Sp.sm),
                Text(
                  '$errCount 错误',
                  style: const TextStyle(
                      fontSize: Ts.bodySm,
                      color: Color(0xFFFF6B6B),
                      fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
          const SizedBox(height: Sp.xs),
          // 日志文件位置要给出来：桌面端用户可以直接去这个目录翻，
          // 比在 App 里一页页翻快得多。拿不到时说明只有内存日志，
          // 这一点必须明说，否则用户会去翻一个不存在的文件。
          Text(
            AppLog.instance.fileEnabled
                ? '文件：${AppLog.instance.filePath}'
                : '未写入文件（仅保留本次运行的内存日志）',
            style: TextStyle(fontSize: Ts.caption, color: p.textDim),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 一行日志。等宽字体 + 等级着色。
class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // 只给错误/警告上色。全部着色等于没着色 —— 一眼扫不到异常。
    final color = switch (entry.level) {
      'E' => const Color(0xFFFF6B6B),
      'W' => const Color(0xFFFFB020),
      'I' => const Color(0xFF64B5F6),
      _ => p.textDim,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: SelectableText(
        entry.line,
        style: TextStyle(
          fontSize: Ts.caption,
          height: 1.35,
          // 等宽：日志要能对齐着看（时间戳、标签、正文三列）。
          // 比例字体会让每一行错开，扫读成本高很多。
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier New'],
          color: entry.isError ? color : p.textDim,
        ),
      ),
    );
  }
}