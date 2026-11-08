/// 「我的」页面
///
/// 原来底部第二个 Tab 是「下载」，直接进下载管理。问题是下载只是
/// 一个功能，用户还有「接着看上次的剧」「清理空间」这类需求，
/// 全塞进下载页会越堆越乱。改成「我的」做聚合入口：
///   顶部统计 → 快捷入口（下载管理 / 最近观看）→ 最近观看预览 → 设置
///
/// 不做账号体系：App 的数据全在本机，强行加登录只会增加使用门槛。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/download.dart';
import '../core/history.dart';
import '../core/layout.dart';
import '../core/version.dart';
import '../theme.dart';
import 'detail_page.dart';
import 'download_page.dart';
import 'history_page.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('我的')),
      body: wide ? _wideBody(context) : _narrowBody(context),
    );
  }

  /// 手机：单列纵向流
  Widget _narrowBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
      children: [
        _header(),
        const SizedBox(height: 16),
        _quickEntries(context),
        const SizedBox(height: 18),
        _recentSection(context),
        const SizedBox(height: 18),
        _settings(context),
      ],
    );
  }

  /// 宽屏：左右两栏
  ///
  /// 左边是账号卡 + 快捷入口 + 设置，右边是「继续观看」列表。
  /// 单列拉满 1400 宽的话，每一行都只有一小截内容、剩下全是空白，
  /// 看起来像没做完。
  ///
  /// 但「没有观看记录」时右栏是空的（_recentSection 返回 shrink），
  /// 双栏就会留下半屏死白——新装用户第一眼看到的就是这个。
  /// 所以这里按记录数动态决定：没记录就单列铺开，有记录才分两栏。
  Widget _wideBody(BuildContext context) {
    return ContentClamp(
      child: ValueListenableBuilder<List<WatchRecord>>(
        valueListenable: HistoryStore.instance.records,
        builder: (c, list, _) {
          final hasRecent = list.isNotEmpty;
          final left = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              const SizedBox(height: 16),
              _quickEntries(context),
              const SizedBox(height: 18),
              _settings(context),
            ],
          );

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
            child: hasRecent
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: left),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [_recentSection(context, previewCount: 8)],
                        ),
                      ),
                    ],
                  )
                // 单列时限制到 720：账号卡和设置项本来就是横向宽条，
                // 拉满 1500 宽会变成一条细长的、读起来很累的行。
                : Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: left,
                    ),
                  ),
          );
        },
      ),
    );
  }

  // ---------------- 顶部统计 ----------------

  Widget _header() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kAccent.withValues(alpha: 0.22), kCard],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.person_rounded, color: kAccent, size: 28),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '本地用户',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 4),
                Text(
                  '数据仅保存在本机',
                  style: TextStyle(fontSize: 11.5, color: kTextDim),
                ),
              ],
            ),
          ),
          // 下载数与观看数：用两个 ValueListenable 各自订阅，
          // 任何一边变化都只重建对应数字
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 下载器的数据源是 Stream（不是 ValueListenable），
              // 所以这里必须用 StreamBuilder；观看历史是 ValueNotifier。
              StreamBuilder<List<DownloadTask>>(
                stream: DownloadManager.instance.stream,
                initialData: DownloadManager.instance.tasks,
                builder: (c, snap) {
                  final list = snap.data ?? const <DownloadTask>[];
                  final done =
                      list.where((t) => t.state == DownloadState.done).length;
                  return _stat('$done', '已下载');
                },
              ),
              const SizedBox(height: 6),
              ValueListenableBuilder<List<WatchRecord>>(
                valueListenable: HistoryStore.instance.records,
                builder: (c, list, _) => _stat('${list.length}', '看过'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String v, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            v,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: kAccent),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11, color: kTextDim)),
        ],
      );

  // ---------------- 快捷入口 ----------------

  Widget _quickEntries(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: StreamBuilder<List<DownloadTask>>(
            stream: DownloadManager.instance.stream,
            initialData: DownloadManager.instance.tasks,
            builder: (c, snap) {
              final list = snap.data ?? const <DownloadTask>[];
              final running = list
                  .where((t) =>
                      t.state == DownloadState.running ||
                      t.state == DownloadState.paused ||
                      t.state == DownloadState.pending)
                  .length;
              return _entryCard(
                context,
                icon: Icons.download_rounded,
                title: '下载管理',
                subtitle: running > 0 ? '$running 个进行中' : '${list.length} 个任务',
                badge: running,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DownloadPage()),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ValueListenableBuilder<List<WatchRecord>>(
            valueListenable: HistoryStore.instance.records,
            builder: (c, list, _) => _entryCard(
              context,
              icon: Icons.history_rounded,
              title: '最近观看',
              subtitle: list.isEmpty ? '还没有记录' : '${list.length} 条记录',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryPage()),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _entryCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    int badge = 0,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: kAccent, size: 22),
                if (badge > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: kAccent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: kBg),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 11, color: kTextDim),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 最近观看预览 ----------------

  Widget _recentSection(BuildContext context, {int previewCount = 3}) {
    return ValueListenableBuilder<List<WatchRecord>>(
      valueListenable: HistoryStore.instance.records,
      builder: (c, list, _) {
        if (list.isEmpty) return const SizedBox.shrink();
        final show = list.take(previewCount).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '继续观看',
                  style:
                      TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (list.length > previewCount)
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const HistoryPage()),
                    ),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    child: const Text('全部', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (final r in show) _recentRow(context, r),
          ],
        );
      },
    );
  }

  Widget _recentRow(BuildContext context, WatchRecord r) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DetailPage(dramaId: r.dramaId, title: r.dramaName),
        ),
      ),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 62,
                height: 84,
                child: r.cover.isEmpty
                    ? Container(color: kCard)
                    : CachedNetworkImage(
                        imageUrl: r.cover,
                        fit: BoxFit.cover,
                        // 62px 宽的小图，按原图解码纯属浪费内存
                        memCacheWidth: 200,
                        errorWidget: (_, __, ___) =>
                            Container(color: kCard),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    r.dramaName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    r.epLabel.isEmpty
                        ? '看到 ${_dur(r.positionSec)}'
                        : '${r.epLabel} · 看到 ${_dur(r.positionSec)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 11, color: kTextDim),
                  ),
                  const SizedBox(height: 6),
                  // 进度条：一眼看出看到哪了
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: r.progress,
                      minHeight: 3,
                      backgroundColor: kBg,
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(kAccent),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '移除记录',
              icon: const Icon(Icons.close_rounded, size: 16),
              color: kTextDim,
              onPressed: () =>
                  HistoryStore.instance.remove(r.dramaId, r.dramaName),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 设置 ----------------

  Widget _settings(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          // 下载目录是懒创建的：第一次真正下载时才建。之前这里直接读
          // rootPath，是个普通字段、赋值时没有通知，所以哪怕目录早就建好了，
          // 这一行也永远显示「未创建」。改成订阅 dirNotifier，建好后自动刷新。
          ValueListenableBuilder<String>(
            valueListenable: DownloadManager.instance.dirNotifier,
            builder: (c, path, _) => _settingRow(
              context,
              icon: Icons.folder_open_rounded,
              title: '下载保存位置',
              trailing: path.isEmpty ? '未创建' : '已设置',
              onTap: () {
                // 点击时读实时值，而不是闭包捕获的 path：
                // 用户可能正是在目录刚建好的一瞬间点的。
                final p = DownloadManager.instance.rootPath;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(p.isEmpty ? '尚未创建下载目录' : '保存到：$p',
                      style: const TextStyle(fontSize: 12)),
                  duration: const Duration(seconds: 5),
                ));
              },
            ),
          ),
          const Divider(height: 1, color: kBg),
          _settingRow(
            context,
            icon: Icons.delete_sweep_rounded,
            title: '清空观看记录',
            onTap: () => _confirmClearHistory(context),
          ),
          const Divider(height: 1, color: kBg),
          _settingRow(
            context,
            icon: Icons.info_outline_rounded,
            title: '关于',
            trailing: 'v$kAppVersion',
            onTap: () => showAboutDialog(
              context: context,
              applicationName: '4K追剧',
              applicationVersion: kAppVersionFull,
              children: const [
                Text(
                  '第三方影视客户端，内容来自公开接口，仅用于学习交流。',
                  style: TextStyle(fontSize: 12, color: kTextDim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? trailing,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: kTextDim),
      title: Text(title, style: const TextStyle(fontSize: 13.5)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null) ...[
            Text(trailing,
                style: const TextStyle(fontSize: 11.5, color: kTextDim)),
            const SizedBox(width: 4),
          ],
          const Icon(Icons.chevron_right_rounded, size: 18, color: kTextDim),
        ],
      ),
      onTap: onTap,
    );
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('只清除观看进度记录，已下载的文件不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) HistoryStore.instance.clear();
  }

  String _dur(int sec) {
    if (sec <= 0) return '00:00';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}