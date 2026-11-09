/// 本地播放页：播放已下载到本机的 mp4 / ts
///
/// 为什么不复用 PlayerPage：那一页整套逻辑都围绕「解析接口地址」，
/// 拿到的 _realUrl 要参与换源、重新解析、下载，本地文件这三样都不需要。
/// 硬塞进去会变成一堆 `if (isLocal)` 分支，反而更难维护。
///
/// 但控制条（倍速/音量/全屏/进度）必须是同一套，否则两处行为不一致，
/// 所以统一用 widgets/player_controls.dart 里的 PlayerControlBar。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/api.dart';
import '../core/danmaku.dart';
import '../core/layout.dart';
import '../core/platform.dart';
import '../core/screen_awake.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/player_controls.dart';

class LocalPlayerPage extends StatefulWidget {
  final String filePath;
  final String title;

  /// 已经下载好的文件本身不含剧集信息，弹幕要靠这两个参数单独请求。
  /// 老版本下载的任务没有记录，取到 0 时静默跳过（不显示弹幕，也不报错）。
  final int dramaId;
  final int episode;

  const LocalPlayerPage({
    super.key,
    required this.filePath,
    required this.title,
    this.dramaId = 0,
    this.episode = 0,
  });

  @override
  State<LocalPlayerPage> createState() => _LocalPlayerPageState();
}

class _LocalPlayerPageState extends State<LocalPlayerPage> {
  VideoPlayerController? _ctrl;
  String? _err;
  bool _loading = true;
  bool _fullscreen = false;

  /// 本集弹幕（按时间升序）
  List<DanmakuItem> _danmaku = const [];

  /// 是否已拉取完成：用来区分「还在拉」和「本集确实没有」
  bool _dmLoaded = false;

  @override
  void initState() {
    super.initState();
    _init();
    // 弹幕与文件初始化并行，互不依赖；本地文件打开可能要几十秒，
    // 串行会让弹幕白等到文件就绪才开始请求。
    _loadDanmaku();
  }

  Future<void> _loadDanmaku() async {
    if (widget.dramaId <= 0 || widget.episode <= 0) {
      if (mounted) setState(() => _dmLoaded = true);
      return;
    }
    final list = await DanmakuApi.instance.fetch(
      dramaId: widget.dramaId,
      episode: widget.episode,
      host: ZhuijuApi.baseUrl,
    );
    if (!mounted) return;
    setState(() {
      _danmaku = list;
      _dmLoaded = true;
    });
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    final f = File(widget.filePath);
    // 文件被外部删掉时给出明确提示，而不是停在「播放器未就绪」
    if (!await f.exists()) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '文件已不存在，可能被清理了';
      });
      return;
    }
    final len = await f.length();
    if (len <= 0) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = '文件为空（0 字节）';
      });
      return;
    }

    VideoPlayerController? c;
    try {
      c = VideoPlayerController.file(f);
      // 大文件（HLS 拼出来动辄 2GB）初始化可能很久，给个宽松但存在的上限
      await c.initialize().timeout(const Duration(seconds: 45));
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _ctrl = c;
        _loading = false;
        _err = null;
      });
      // 播放成功才保持常亮，加载失败时不该阻止系统息屏
      await ScreenAwake.set(true);
    } catch (e) {
      try {
        await c?.dispose();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _ctrl = null;
        _loading = false;
        _err = _humanError(e);
      });
    }
  }

  String _humanError(Object e) {
    final s = e.toString();
    if (s.contains('TimeoutException')) return '读取文件超时，文件可能损坏';
    if (s.contains('NO_EXCEEDS_CAPABILITIES')) {
      return '当前设备解码不了这个清晰度（如 4K HEVC）';
    }
    if (s.contains('UnrecognizedInputFormat') ||
        s.contains('Source error')) {
      return '文件格式不被支持，可能下载不完整';
    }
    return '无法播放该文件：$s';
  }

  @override
  void dispose() {
    // 离开就放开常亮，否则回到列表页屏幕还一直亮着
    unawaited(ScreenAwake.release());
    _ctrl?.dispose();
    if (_fullscreen) _restoreOrientation();
    super.dispose();
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    // 桌面端没有横竖屏概念，统一交给 platform 层分流（桌面为 no-op）
    await setFullscreen(next);
  }

  Future<void> _restoreOrientation() async {
    await restorePortrait();
  }

  void _toast(String s) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_fullscreen) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _toggleFullscreen();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: _fullscreenBody(),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.title, style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            tooltip: '文件信息',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () async {
              final f = File(widget.filePath);
              final ok = await f.exists();
              final size = ok ? await f.length() : 0;
              _toast(ok
                  ? '${_size(size)}｜${widget.filePath.split('/').last}'
                  : '文件已不存在');
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _fullscreenBody() {
    final c = _ctrl;
    return GestureDetector(
      onTap: () => setState(() {}),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: (c != null && c.value.isInitialized)
                  ? Center(
                      child: AspectRatio(
                        aspectRatio: c.value.aspectRatio == 0
                            ? 16 / 9
                            : c.value.aspectRatio,
                        child: VideoPlayer(c),
                      ),
                    )
                  : PlayerPlaceholder(
                      loading: _loading,
                      message: _loading ? '正在打开本地文件…' : (_err ?? '无法播放'),
                      onRetry: _loading ? null : _init,
                    ),
            ),
            // 弹幕叠在画面上、控制条下方：本地播放和在线播放的观感保持一致
            if (c != null && c.value.isInitialized)
              Positioned.fill(
                child: ValueListenableBuilder<bool>(
                  valueListenable: DanmakuSettings.instance.enabled,
                  builder: (ctx, on, _) {
                    if (!on) return const SizedBox.shrink();
                    return DanmakuOverlay(
                      ctrl: c,
                      items: _danmaku,
                      fontSize: 15,
                    );
                  },
                ),
              ),
            // 只有「确实知道这是哪一集」且拉到了 0 条时才提示。
            // 老版本下载的任务没有记录剧集标识（dramaId=0），此时不是
            // 「本集没有弹幕」，而是根本不知道是哪一集，提示会误导用户
            // 以为这部剧真的没人发弹幕。
            if (c != null &&
                c.value.isInitialized &&
                widget.dramaId > 0 &&
                _dmLoaded &&
                _danmaku.isEmpty)
              const Positioned(
                left: 0,
                right: 0,
                top: 8,
                child: DanmakuEmptyHint(),
              ),
            if (c != null && c.value.isInitialized)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 24, 10, 6),
                      child: PlayerControlBar(
                        ctrl: c,
                        fullscreen: true,
                        onToggleFullscreen: _toggleFullscreen,
                        extraActions: [
                          const DanmakuToggleButton(),
                          IconButton(
                            iconSize: 22,
                            color: Colors.white,
                            tooltip: '从头播',
                            icon: const Icon(Icons.replay_rounded),
                            onPressed: () => c.seekTo(Duration.zero),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const PlayerPlaceholder(loading: true, message: '正在打开本地文件…');
    }
    if (_err != null) return ErrorView(message: _err!, onRetry: _init);

    final c = _ctrl!;
    // 宽屏：左视频右控制，与在线播放页保持一致的形态
    if (isWide(context)) return _wideBody(c);

    return Column(
      children: [
        GestureDetector(
          onTap: () => setState(() {}),
          child: Container(
            color: Colors.black,
            width: double.infinity,
            child: AspectRatio(
              aspectRatio:
                  c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  VideoPlayer(c),
                  // 竖屏小窗也显示弹幕，字号收小、滚动放慢，否则一屏挤不下几条
                  ValueListenableBuilder<bool>(
                    valueListenable: DanmakuSettings.instance.enabled,
                    builder: (ctx, on, _) {
                      if (!on) return const SizedBox.shrink();
                      return DanmakuOverlay(
                        ctrl: c,
                        items: _danmaku,
                        fontSize: 12,
                        travel: const Duration(milliseconds: 6500),
                      );
                    },
                  ),
                  // 只在暂停时叠播放按钮，播放中不挡画面
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: c,
                    builder: (ctx, v, _) => v.isPlaying
                        ? const SizedBox.shrink()
                        : IconButton(
                            iconSize: 52,
                            color: Colors.white,
                            icon: const Icon(Icons.play_circle_fill_rounded),
                            onPressed: c.play,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Container(
            width: double.infinity,
            color: kVideoBg,
            padding: const EdgeInsets.all(14),
            child: SingleChildScrollView(
              child: _controlPanel(c),
            ),
          ),
        ),
      ],
    );
  }

  /// 宽屏：视频铺满左侧，右侧固定宽度放控制
  Widget _wideBody(VideoPlayerController c) {
    final aspect = c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            color: Colors.black,
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: aspect,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          VideoPlayer(c),
                          ValueListenableBuilder<bool>(
                            valueListenable: DanmakuSettings.instance.enabled,
                            builder: (ctx, on, _) => on
                                ? Positioned.fill(
                                    child: DanmakuOverlay(
                                      ctrl: c,
                                      items: _danmaku,
                                      fontSize: 15,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          ValueListenableBuilder<VideoPlayerValue>(
                            valueListenable: c,
                            builder: (ctx, v, _) => v.isPlaying
                                ? const SizedBox.shrink()
                                : IconButton(
                                    iconSize: 56,
                                    color: Colors.white,
                                    icon: const Icon(
                                        Icons.play_circle_fill_rounded),
                                    onPressed: c.play,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 控制条常驻底部：桌面上不需要「点画面唤出」
                Container(
                  color: Colors.black,
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                  child: PlayerControlBar(
                    ctrl: c,
                    fullscreen: false,
                    onToggleFullscreen: _toggleFullscreen,
                    extraActions: const [DanmakuToggleButton()],
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(
          width: 320,
          color: kVideoBg,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: SingleChildScrollView(child: _controlPanel(c, compact: true)),
        ),
      ],
    );
  }

  /// 控制面板内容（手机竖屏与宽屏右栏共用）
  Widget _controlPanel(VideoPlayerController c, {bool compact = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Text(
              '本地播放',
              style: TextStyle(fontSize: 11, color: kAccent),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (compact) ...[
          Text(
            widget.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
        ],
        // 进度 / 倍速 / 音量 / 全屏，与在线播放页完全一致
        PlayerControlBar(
          ctrl: c,
          fullscreen: false,
          onToggleFullscreen: _toggleFullscreen,
          extraActions: const [DanmakuToggleButton()],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  c.value.isPlaying ? c.pause() : c.play();
                },
                icon: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (ctx, v, _) => Icon(
                    v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                ),
                label: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (ctx, v, _) => Text(v.isPlaying ? '暂停' : '播放'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => c.seekTo(Duration.zero),
                icon: const Icon(Icons.replay_rounded, size: 18),
                label: const Text('从头播'),
              ),
            ),
          ],
        ),
      ],
    );
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