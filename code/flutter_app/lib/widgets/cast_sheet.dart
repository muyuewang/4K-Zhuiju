/// 投屏 UI：设备选择弹层 + 投屏状态条
///
/// 交互设计（照着主流视频 App 的投屏来，用户不用重新学）：
///   1. 点「投屏」→ 立刻开始搜索，弹层里实时把找到的设备填进来；
///   2. 点某台设备 → 推流，成功后弹层自动关闭、页面顶部出现状态条；
///   3. 状态条上可以直接「停止投屏」，不用再进弹层。
///
/// 为什么不做成「扫描完再弹」：SSDP 收满 4 秒才准，
/// 让用户对着一个空白等待 4 秒会以为功能坏了。边搜边列，
/// 第一台设备通常 300ms 内就出来了，感知快得多。
library;

import 'package:flutter/material.dart';

import '../core/dlna.dart';
import '../core/layout.dart';
import '../theme.dart';
import 'tv_focus.dart';
import '../core/tokens.dart';

/// 弹出设备选择面板，返回用户选中的设备（取消返回 null）。
///
/// [onPick] 不在这里调用，交给调用方处理——投屏成功与否的提示、
/// 本地播放器要不要暂停，都属于播放页的职责。
Future<DlnaDevice?> showCastSheet(
  BuildContext context, {
  Future<bool> Function(DlnaDevice)? onPick,
}) {
  return showModalBottomSheet<DlnaDevice>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _CastSheet(onPick: onPick),
  );
}

class _CastSheet extends StatefulWidget {
  final Future<bool> Function(DlnaDevice)? onPick;

  const _CastSheet({this.onPick});

  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  List<DlnaDevice> _devices = const [];
  bool _scanning = true;
  String? _busy; // 正在连接的设备 controlUrl
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _devices = const [];
    });
    final list = await Dlna.instance.discover();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _scanning = false;
      if (list.isEmpty) {
        _error = '没找到可投屏的设备';
      }
    });
  }

  Future<void> _pick(DlnaDevice d) async {
    setState(() => _busy = d.controlUrl);
    final ok = await widget.onPick?.call(d) ?? true;
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(d);
      return;
    }
    setState(() {
      _busy = null;
      _error = '连接「${d.name}」失败，确认电视和手机在同一网络';
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.72;
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(R.pill)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽指示条
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 6),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: context.palette.textDim.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(R.bar),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.cast_rounded,
                      size: 20, color: context.palette.onSurface),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '投屏到电视',
                      style: TextStyle(
                        fontSize: Ts.subtitle,
                        fontWeight: FontWeight.w600,
                        color: context.palette.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '重新搜索',
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    onPressed: _scanning ? null : _scan,
                  ),
                ],
              ),
            ),
            // 搜索中：细进度条，不占位置也不挡视线
            if (_scanning)
              LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: context.palette.bg,
                valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
              ),
            // 连接失败时设备列表并不为空，错误若只在空态里显示就永远看不到
            if (_error != null && _devices.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(R.card),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(fontSize: Ts.bodySm, color: Colors.orange),
                ),
              ),
            Flexible(child: _body()),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Text(
                '手机与电视需连接同一局域网。若列表为空，请确认路由器未开启'
                '「AP 隔离」，或改用电视自带的投屏功能。',
                style: TextStyle(
                  fontSize: Ts.caption,
                  height: 1.5,
                  color: context.palette.textDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_devices.isEmpty) {
      return SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 24),
          child: Column(
            children: [
              Icon(
                _scanning ? Icons.wifi_tethering_rounded : Icons.tv_off_rounded,
                size: 40,
                color: context.palette.textDim,
              ),
              const SizedBox(height: 12),
              Text(
                _scanning ? '正在搜索设备…' : (_error ?? '没找到可投屏的设备'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: Ts.body,
                  color: context.palette.textDim,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      itemCount: _devices.length,
      itemBuilder: (c, i) {
        final d = _devices[i];
        final busy = _busy == d.controlUrl;
        final row = InkWell(
          borderRadius: BorderRadius.circular(R.card),
          onTap: _busy == null ? () => _pick(d) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.tv_rounded,
                    size: 22, color: context.palette.textDim),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        d.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: Ts.bodyLg,
                          fontWeight: FontWeight.w600,
                          color: context.palette.onSurface,
                        ),
                      ),
                      if (d.model.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          d.model,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Ts.caption,
                            color: context.palette.textDim,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(Icons.chevron_right_rounded,
                      size: 20, color: context.palette.textDim),
              ],
            ),
          ),
        );
        // TV 端也要能选设备：遥控器无法「点」，必须有焦点描边 + 确定键
        return isTv(c) ? TvFocusRing(radius: 10, child: row) : row;
      },
    );
  }
}

/// 正在投屏时贴在播放页顶部的状态条
class CastBar extends StatelessWidget {
  final String deviceName;
  final VoidCallback onStop;

  const CastBar({
    super.key,
    required this.deviceName,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: kAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(R.card),
        border: Border.all(color: kAccent.withValues(alpha: 0.45), width: 0.8),
      ),
      child: Row(
        children: [
          const Icon(Icons.cast_connected_rounded, size: 18, color: kAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '正在投屏到「$deviceName」',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: Ts.body, color: Colors.white),
            ),
          ),
          TextButton(
            onPressed: onStop,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: kAccent,
            ),
            child: const Text('停止', style: TextStyle(fontSize: Ts.body)),
          ),
        ],
      ),
    );
  }
}