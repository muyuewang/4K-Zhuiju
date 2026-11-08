/// 下载管理页
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/download.dart';
import '../theme.dart';
import 'local_player_page.dart';

class DownloadPage extends StatefulWidget {
  /// 是否嵌入在「我的」页面里展示。
  /// 嵌入时不画自己的 AppBar——外层已经有标题栏，否则会出现两条标题栏。
  final bool embedded;

  const DownloadPage({super.key, this.embedded = false});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
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
                    style: const TextStyle(fontSize: 12)),
                duration: const Duration(seconds: 5),
              ));
            },
          ),
          IconButton(
            tooltip: '全部开始',
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: () {
              for (final t in DownloadManager.instance.tasks) {
                if (t.state == DownloadState.paused ||
                    t.state == DownloadState.failed) {
                  DownloadManager.instance.resume(t.id);
                }
              }
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
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.download_done_rounded,
                        color: kTextDim, size: 44),
                    SizedBox(height: 12),
                    Text('暂无下载任务',
                        style: TextStyle(color: kTextDim, fontSize: 13)),
                    SizedBox(height: 6),
                    Text('在播放页点右上角下载按钮即可加入',
                        style: TextStyle(color: kTextDim, fontSize: 11)),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: Color(0xFF23262F),
            ),
            itemBuilder: (c, i) => _tile(list[i]),
          );
        },
      ),
    );
  }

  Widget _tile(DownloadTask t) {
    final isDone = t.state == DownloadState.done;
    final isRunning = t.state == DownloadState.running;

    return InkWell(
      // 已完成的文件点一下直接本地播放：之前这页只有「删除」，
      // 用户下完几百 MB 却没有任何播放入口，等于白下。
      onTap: isDone && (t.filePath?.isNotEmpty ?? false)
          ? () => _play(t)
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                isDone
                    ? Icons.play_circle_fill_rounded
                    : (isRunning
                        ? Icons.downloading_rounded
                        : Icons.pause_circle_outline_rounded),
                color: isDone ? kAccent : kAccent,
                size: isDone ? 26 : 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 5),
                  if (isDone)
                    Text(
                      '已完成 · ${t.ext.toUpperCase()}'
                      '${t.total > 0 ? ' · ${_size(t.total)}' : ''}',
                      style: const TextStyle(fontSize: 11, color: kTextDim),
                    )
                  else if (t.state == DownloadState.failed)
                    Text(
                      t.error ?? '下载失败',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.redAccent),
                    )
                  else ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: t.progress <= 0 ? null : t.progress,
                        minHeight: 3.5,
                        backgroundColor: const Color(0xFF23262F),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(kAccent),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _progressText(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: kTextDim),
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
        backgroundColor: kCard,
        title: Text(
          withFile ? '删除任务和文件？' : '删除这个任务？',
          style: const TextStyle(fontSize: 15),
        ),
        content: Text(
          withFile
              ? '「${t.title}」已下载的文件会一并删除，此操作不可恢复。'
              : '「${t.title}」尚未下载完成，已缓存的临时分片会被清除。',
          style: const TextStyle(fontSize: 12.5, color: kTextDim),
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
}