/// 最近观看（完整列表）
///
/// 「我的」页只预览最近 3 条，完整列表放这里：
/// 支持单条移除、一键清空、按时间倒序。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/history.dart';
import '../core/layout.dart';
import '../theme.dart';
import 'detail_page.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('最近观看'),
        actions: [
          ValueListenableBuilder<List<WatchRecord>>(
            valueListenable: HistoryStore.instance.records,
            builder: (c, list, _) => list.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: '清空',
                    icon: const Icon(Icons.delete_sweep_rounded),
                    onPressed: () => _confirmClear(context),
                  ),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<WatchRecord>>(
        valueListenable: HistoryStore.instance.records,
        builder: (c, list, _) {
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history_rounded, color: kTextDim, size: 44),
                    SizedBox(height: 12),
                    Text('还没有观看记录',
                        style: TextStyle(fontSize: 13, color: kTextDim)),
                    SizedBox(height: 6),
                    Text('看过的剧会自动出现在这里',
                        style: TextStyle(fontSize: 11, color: kTextDim)),
                  ],
                ),
              ),
            );
          }
          return ContentClamp(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (c, i) => _row(context, list[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, WatchRecord r) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DetailPage(dramaId: r.dramaId, title: r.dramaName),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 68,
                height: 92,
                child: r.cover.isEmpty
                    ? Container(color: kCard)
                    : CachedNetworkImage(
                        imageUrl: r.cover,
                        fit: BoxFit.cover,
                        memCacheWidth: 220,
                        errorWidget: (_, __, ___) => Container(color: kCard),
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
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    r.epLabel.isEmpty ? '未知集数' : r.epLabel,
                    style: const TextStyle(fontSize: 11.5, color: kTextDim),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: r.progress,
                            minHeight: 3,
                            backgroundColor: kBg,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                kAccent),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        // 已看完的明确标出来，避免用户以为还剩很多
                        r.nearlyFinished
                            ? '已看完'
                            : '${_dur(r.positionSec)} / '
                                '${r.durationSec > 0 ? _dur(r.durationSec) : "--:--"}',
                        style: const TextStyle(
                            fontSize: 10.5, color: kTextDim),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '移除记录',
              icon: const Icon(Icons.close_rounded, size: 17),
              color: kTextDim,
              onPressed: () =>
                  HistoryStore.instance.remove(r.dramaId, r.dramaName),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
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