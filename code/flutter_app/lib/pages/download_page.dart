/// 下载管理页
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/download.dart';
import '../core/layout.dart';
import '../theme.dart';
import '../widgets/tv_focus.dart';
import 'local_player_page.dart';
import '../core/tokens.dart';

class DownloadPage extends StatefulWidget {
  /// 是否嵌入在「我的」页面里展示。
  /// 嵌入时不画自己的 AppBar——外层已经有标题栏，否则会出现两条标题栏。
  final bool embedded;

  const DownloadPage({super.key, this.embedded = false});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  /// 被用户折叠起来的剧集分组（按组名记）
  ///
  /// 记「折叠了哪些」而不是「展开了哪些」：默认全展开，新下载完一部剧
  /// 立刻就能看到每一集；用户主动收起长列表后，后续新任务也不会
  /// 因为「不在展开集合里」而莫名隐藏。
  final Set<String> _collapsed = <String>{};

  /// 独立成页时的标题栏；嵌入「我的」时由外层提供标题，这里返回 null
  PreferredSizeWidget _appBar(BuildContext context) {
    return AppBar(
        title: const Text('下载管理'),
        actions: [
          IconButton(
            tooltip: '保存路径',
            icon: const Icon(Icons.folder_open_rounded),
            onPressed: () {
              final p = DownloadManager.instance.rootPath;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(p.isEmpty ? '尚未创建下载目录' : '保存到：$p',
                    style: const TextStyle(fontSize: Ts.bodySm)),
                duration: const Duration(seconds: 5),
              ));
            },
          ),
          // 「全部开始 / 全部暂停」必须成对出现。
          //
          // 原来只有「全部开始」：用户一次加了十几集，想出门前先停下
          // 省流量，只能一集一集点暂停——手机上点十几次，电视上更没法做。
          // 主流下载管理器都有这个成对的批量开关。
          //
          // 用 StreamBuilder 订阅任务列表，按钮的可点状态跟着实际状态走：
          // 没有待恢复的任务时「全部开始」置灰，没有在跑的任务时
          // 「全部暂停」置灰，用户一眼能看出当前能做什么。
          StreamBuilder<List<DownloadTask>>(
            stream: DownloadManager.instance.stream,
            initialData: DownloadManager.instance.tasks,
            builder: (c, snap) {
              final list = snap.data ?? const <DownloadTask>[];
              final canResume = list.any((t) =>
                  t.state == DownloadState.paused ||
                  t.state == DownloadState.failed);
              final canPause =
                  list.any((t) => t.state == DownloadState.running);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '全部开始',
                    icon: const Icon(Icons.play_arrow_rounded),
                    onPressed: canResume
                        ? () {
                            for (final t in list) {
                              if (t.state == DownloadState.paused ||
                                  t.state == DownloadState.failed) {
                                DownloadManager.instance.resume(t.id);
                              }
                            }
                          }
                        : null,
                  ),
                  IconButton(
                    tooltip: '全部暂停',
                    icon: const Icon(Icons.pause_rounded),
                    onPressed: canPause
                        ? () {
                            for (final t in list) {
                              if (t.state == DownloadState.running) {
                                DownloadManager.instance.pause(t.id);
                              }
                            }
                          }
                        : null,
                  ),
                ],
              );
            },
          ),
        ],
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : _appBar(context),
      body: StreamBuilder<List<DownloadTask>>(
        stream: DownloadManager.instance.stream,
        initialData: DownloadManager.instance.tasks,
        builder: (c, snap) {
          final list = snap.data ?? const <DownloadTask>[];
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.download_done_rounded,
                        color: context.palette.textDim, size: 44),
                    const SizedBox(height: 12),
                    Text('暂无下载任务',
                        style: TextStyle(color: context.palette.textDim, fontSize: Ts.body)),
                    const SizedBox(height: 6),
                    Text('在播放页点右上角下载按钮即可加入',
                        style: TextStyle(color: context.palette.textDim, fontSize: Ts.caption)),
                  ],
                ),
              ),
            );
          }
          // 宽屏下把列表夹在舒适宽度内：一条任务只有图标+标题+进度，
          // 拉满 1400 宽会显得空荡，右侧进度条离标题远到难以对应。
          //
          // 列表按剧集分组：先摊平成 [组头, 成员..., 组头, 成员...]，
          // 再交给 ListView.builder 按需构建。不用 Column/ListView(children:)
          // 是因为 40 集×几部剧就有上百行，全量建 widget 会明显卡顿。
          final rows = <Widget>[];
          for (final g in groupTasks(list)) {
            rows.add(_groupHeader(g));
            if (_collapsed.contains(g.name)) continue;
            for (var i = 0; i < g.items.length; i++) {
              rows.add(Column(
                children: [
                  _tile(c, g.items[i]),
                  if (i != g.items.length - 1)
                    Divider(
                      height: 1,
                      indent: 68,
                      endIndent: 16,
                      color: context.palette.divider,
                    ),
                ],
              ));
            }
          }
          return ContentClamp(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: rows.length,
              itemBuilder: (c, i) => rows[i],
            ),
          );
        },
      ),
    );
  }

  /// 剧集分组头：剧名 + 集数汇总 + 折叠开关 + 整组操作
  Widget _groupHeader(DownloadGroup g) {
    final tv = isTv(context);
    final name = g.name;
    final folded = _collapsed.contains(name);

    // 汇总信息一眼能看出这组下到哪了：光看「40 集」不知道完成多少
    final parts = <String>['共 ${g.items.length} 集'];
    if (g.doneCount > 0) parts.add('已完成 ${g.doneCount}');
    if (g.runningCount > 0) parts.add('下载中 ${g.runningCount}');

    return InkWell(
      onTap: () => setState(() {
        if (!_collapsed.remove(name)) _collapsed.add(name);
      }),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, tv ? 14 : 10, 8, tv ? 10 : 6),
        child: Row(
          children: [
            Icon(
              folded
                  ? Icons.keyboard_arrow_right_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: context.palette.textDim,
            ),
            const SizedBox(width: 6),
            const Icon(Icons.folder_rounded, size: 17, color: kAccent),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: tv ? Ts.bodyLg : Ts.body,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              parts.join(' · '),
              style: TextStyle(
                  fontSize: Ts.caption, color: context.palette.textDim),
            ),
            const SizedBox(width: 4),
            // 整组删除：一部剧下完想清空间，一个个点删除太费劲。
            // 双击才确认，避免误触——这个操作会删掉几十个文件。
            IconButton(
              tooltip: '删除整组',
              iconSize: 18,
              color: context.palette.textDim,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _confirmDeleteGroup(g),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, DownloadTask t) {
    final isDone = t.state == DownloadState.done;
    final isRunning = t.state == DownloadState.running;
    final tv = isTv(context);

    final body = InkWell(
      // 已完成的文件点一下直接本地播放：之前这页只有「删除」，
      // 用户下完几百 MB 却没有任何播放入口，等于白下。
      onTap: isDone && (t.filePath?.isNotEmpty ?? false)
          ? () => _play(t)
          : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, tv ? Ts.subtitle : Ts.caption, 8, tv ? Ts.subtitle : Ts.caption),
        child: Row(
          children: [
            Container(
              width: tv ? 48 : 40,
              height: tv ? 48 : 40,
              decoration: BoxDecoration(
                color: context.palette.card,
                borderRadius: BorderRadius.circular(R.card),
              ),
              child: Icon(
                isDone
                    ? Icons.play_circle_fill_rounded
                    : (isRunning
                        ? Icons.downloading_rounded
                        : Icons.pause_circle_outline_rounded),
                color: isDone ? kAccent : kAccent,
                size: isDone ? (tv ? 32 : 26) : (tv ? 26 : 22),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // 组内只显示集名，剧名由组头承担
                    shortTitleOf(t),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: tv ? Ts.subtitle : Ts.bodyLg,
                        fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 5),
                  if (isDone)
                    Text(
                      '已完成 · ${t.ext.toUpperCase()}'
                      '${t.total > 0 ? ' · ${_size(t.total)}' : ''}',
                      style: TextStyle(fontSize: Ts.caption, color: context.palette.textDim),
                    )
                  else if (t.state == DownloadState.failed)
                    Text(
                      t.error ?? '下载失败',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: Ts.caption, color: Colors.redAccent),
                    )
                  else ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(R.bar),
                      child: LinearProgressIndicator(
                        value: t.progress <= 0 ? null : t.progress,
                        minHeight: 3.5,
                        backgroundColor: context.palette.divider,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(kAccent),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _progressText(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Ts.caption, color: context.palette.textDim),
                    ),
                  ],
                ],
              ),
            ),
            // 运行中：可暂停；已暂停/失败：可继续 + 删除；
            // 已完成：可播放 + 删除（含同时删除已下载文件）
            if (isRunning)
              IconButton(
                tooltip: '暂停',
                icon: const Icon(Icons.pause_rounded, size: 20),
                onPressed: () => DownloadManager.instance.pause(t.id),
              )
            else if (isDone)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '播放',
                    icon: const Icon(Icons.play_arrow_rounded, size: 22),
                    onPressed: () => _play(t),
                  ),
                  IconButton(
                    tooltip: '删除任务和文件',
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    onPressed: () => _confirmDelete(t, withFile: true),
                  ),
                ],
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '继续',
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    onPressed: () => DownloadManager.instance.resume(t.id),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => _confirmDelete(t),
                  ),
                ],
              ),
          ],
        ),
      ),
    );

    // InkWell 自身能聚焦并响应确定键，这里只补一圈可见描边：
    // 电视上没有鼠标指针，看不出选中哪一行就没法操作。
    if (!tv) return body;
    return TvFocusRing(radius: 10, child: body);
  }

  /// 进度文案：带速率与剩余时间，光一个百分比看不出还要等多久
  String _progressText(DownloadTask t) {
    final base = t.isHls
        ? '分片 ${t.received}/${t.total}'
        : '${_size(t.received)}${t.total > 0 ? " / ${_size(t.total)}" : ""}';
    if (t.state != DownloadState.running) return base;

    // 重试中有明确状态就优先显示：大分片连续超时可能要等好几分钟，
    // 只显示一个不动的「分片 93/94」会让人以为卡死了。
    final stage = t.stage;
    if (stage != null && stage.isNotEmpty) return stage;

    final parts = <String>[base];
    if (t.speed > 0) parts.add('${_size(t.speed.round())}/s');
    final eta = t.etaSeconds;
    if (eta > 0) {
      parts.add(eta >= 60
          ? '剩余 ${eta ~/ 60}分${(eta % 60).toString().padLeft(2, '0')}秒'
          : '剩余 $eta 秒');
    }
    return parts.join(' · ');
  }

  void _play(DownloadTask t) {
    final p = t.filePath;
    if (p == null || p.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LocalPlayerPage(
        filePath: p,
        title: t.title,
        // 带上入队时记下的剧集标识，本地播放才能拉到同一集的弹幕
        dramaId: t.dramaId,
        episode: t.episode,
      ),
    ));
  }

  /// 删除任务；[withFile] 为 true 时连同已落盘文件一并删除
  Future<void> _confirmDelete(DownloadTask t, {bool withFile = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: context.palette.card,
        title: Text(
          withFile ? '删除任务和文件？' : '删除这个任务？',
          style: const TextStyle(fontSize: Ts.subtitle),
        ),
        content: Text(
          withFile
              ? '「${t.title}」已下载的文件会一并删除，此操作不可恢复。'
              : '「${t.title}」尚未下载完成，已缓存的临时分片会被清除。',
          style: TextStyle(fontSize: Ts.body, color: context.palette.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final path = t.filePath;
    DownloadManager.instance.remove(t.id);
    if (path != null && await File(path).exists()) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1073741824).toStringAsFixed(2)}G';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1048576).toStringAsFixed(1)}M';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)}K';
    return '${bytes}B';
  }

  /// 删除整组：一次清掉这部剧下的所有任务和已落盘文件
  ///
  /// 必须弹确认框——一次可能删几十个文件、几个 G。文案里把集数和体积
  /// 都算出来，让用户知道自己在删什么，而不是只看到一个「确定」。
  Future<void> _confirmDeleteGroup(DownloadGroup g) async {
    final name = g.name;
    final items = g.items;
    final bytes = g.totalBytes;
    final sizeText = bytes > 0 ? '，约 ${_size(bytes)}' : '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: context.palette.card,
        title: const Text('删除整组？', style: TextStyle(fontSize: Ts.subtitle)),
        content: Text(
          '「$name」共 ${items.length} 集$sizeText。\n'
          '任务和已下载的文件都会删除，此操作不可恢复。',
          style: TextStyle(fontSize: Ts.body, color: context.palette.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child:
                const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // 先把文件路径抄出来：remove() 之后任务对象就从索引里消失了
    final paths = <String>[];
    for (final t in items) {
      final p = t.filePath;
      if (p != null && p.isNotEmpty) paths.add(p);
      DownloadManager.instance.remove(t.id);
    }
    for (final p in paths) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 单个文件删不掉（被占用/权限）不该中断整组清理
      }
    }

    // 目录空了就顺手删掉，否则 downloads/<剧名>/ 会留下一堆空文件夹。
    // 非空（还有别的文件、或用户自己往里放了东西）则保留——宁可留个空壳，
    // 也不能删掉不属于本次操作的文件。
    final root = DownloadManager.instance.rootPath;
    if (root.isNotEmpty) {
      try {
        final dir = Directory('$root/$name');
        if (await dir.exists() &&
            (await dir.list().toList()).isEmpty) {
          await dir.delete();
        }
      } catch (_) {}
    }

    if (mounted) setState(() => _collapsed.remove(name));
  }
}