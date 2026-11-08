/// 播放页：解析真实地址 + 播放 + 下载 + 选集/换源 + 自动连播
///
/// 关键设计：
///   1. 三种状态严格分开，避免「一进页面就说播放器未就绪」：
///        - 解析中 / 播放器初始化中 → loading（不给任何错误提示）
///        - 解析失败 → 整页错误 + 重试
///        - 播放失败（超时、解码不支持、403…）→ 才提示换线路
///      原来的实现把「还没初始化完」和「真的失败了」混成一个
///      `_playErr ?? '播放器未就绪'`，用户一进页面就看到「未就绪 + 换源」，
///      误以为片子放不了，实际只是加载还没完成。
///   2. 支持换源：同一集在不同播放源下内容相同，当前源放不出来时可直接切下一个源。
///   3. 下载按钮只要拿到 _realUrl 就可用，不依赖播放器是否初始化成功。
///   4. 倍速 / 音量 / 全屏由公共组件 PlayerControlBar 提供，
///      与本地播放页共用同一套控件。
///   5. 全屏时也能选集和换源：全屏是「看剧」的常态，为了换一集
///      退到竖屏详情页再点回来，体验很差。所以横屏下把选集/换源
///      做成右侧滑出面板，不打断播放。
///   6. 电视剧自动连播：一集播完自动接下一集，并给 3 秒可取消的倒计时，
///      避免用户看完想关掉时被硬塞下一集。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/api.dart';
import '../core/danmaku.dart';
import '../core/download.dart';
import '../core/platform.dart';
import '../core/history.dart';
import '../core/models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/player_controls.dart';

class PlayerPage extends StatefulWidget {
  final DramaVideo video;
  final String dramaName;
  final String cover;

  /// 所属剧集 id，用于写入观看历史（0 表示未知）
  final int dramaId;

  /// 同集其它可切换的源（detail 页传入），用于播放失败时换源
  final List<DramaVideo> alternates;

  /// 全部源 → 该源的剧集列表（detail 页传入）。
  /// 用于全屏选集、按源名精确换源，以及判断「有没有下一集」。
  final Map<String, List<DramaVideo>> sources;

  const PlayerPage({
    super.key,
    required this.video,
    this.dramaName = '',
    this.cover = '',
    this.dramaId = 0,
    this.alternates = const [],
    this.sources = const {},
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _ctrl;

  /// 解析阶段错误（接口不通/为空）
  String? _err;

  /// 播放阶段错误（解析成功但初始化超时/解码失败）
  String? _playErr;

  /// 正在解析地址
  bool _resolving = true;

  /// 地址已就绪、播放器正在初始化（这里绝不能显示「失败」）
  bool _playLoading = false;

  String _realUrl = '';
  String _tip = '';
  bool _showCtrl = true;

  /// 全屏（横屏沉浸式）
  bool _fullscreen = false;

  late DramaVideo _cur = widget.video;

  /// 播放进度上报定时器：每 8 秒写一次观看历史
  Timer? _histTimer;

  /// 全屏右侧面板：选集 / 换源（互斥）
  bool _showEpisodes = false;
  bool _showSources = false;

  /// 本集是否已经处理过「播完」，防止 listener 每帧重复触发自动连播
  bool _autoNextHandled = false;

  /// 自动连播倒计时（null 表示没有在等待）
  Timer? _countdownTimer;
  int _countdown = 0;
  DramaVideo? _pendingNext;

  /// 轻提示（全屏时用自绘浮层，SnackBar 在横屏沉浸式下会被系统 UI 挡住）
  String? _notice;
  Timer? _noticeTimer;

  /// 本集弹幕（按时间升序）；空列表表示本集确实没有弹幕
  List<DanmakuItem> _danmaku = const [];

  /// 弹幕是否已经拉取完成（用来区分「还在拉」和「确实没有」，
  /// 否则加载中就会先闪一下「本集暂无弹幕」）
  bool _dmLoaded = false;

  /// 已尝试过的源（按「源名」去重，不是按 path）
  ///
  /// 原来按 path 记录，实测有坑：同一集在同一个源下往往有多条线路
  /// （同一 sourceCn 对应多个 path）。第一次换源换到 4K-4 的第 2 条线，
  /// 第二次换源时因为这条 path 还没进 _tried，又选中了 4K-4 的第 3 条线，
  /// 界面上的源名不变、报错也一模一样，用户看起来就是「换源没反应」。
  /// 用户点「换源」的意图是「换个源试试」，所以粒度必须是源，不是线路。
  final Set<String> _triedSrc = <String>{};

  /// 源的唯一键：优先中文名，退化到 source 标识
  String _srcKey(DramaVideo v) =>
      v.sourceCn.isNotEmpty ? v.sourceCn : v.source;

  /// 当前源的全部剧集（按集数排序）
  List<DramaVideo> get _curEpisodes {
    final list = widget.sources[_srcKey(_cur)];
    if (list == null || list.isEmpty) return <DramaVideo>[_cur];
    final l = List<DramaVideo>.from(list)
      ..sort((a, b) => a.episode.compareTo(b.episode));
    return l;
  }

  List<String> get _sourceNames => widget.sources.keys.toList();

  bool get _isSeries => _curEpisodes.length > 1;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void dispose() {
    _histTimer?.cancel();
    _countdownTimer?.cancel();
    _noticeTimer?.cancel();
    _saveHistory();
    _ctrl?.dispose();
    // 页面被销毁时务必还原屏幕方向，否则退出播放页后整个 App 还是横屏
    if (_fullscreen) {
      _restoreOrientation();
    }
    super.dispose();
  }

  /// 释放旧播放器（换源/重新解析前必须调用，否则会泄漏解码器）
  Future<void> _disposeCtrl() async {
    final old = _ctrl;
    _ctrl = null;
    if (old != null) {
      try {
        old.removeListener(_onPlayTick);
        await old.dispose();
      } catch (_) {}
    }
  }

  /// 解析真实播放地址
  Future<void> _resolve({DramaVideo? video}) async {
    if (video != null) _cur = video;

    // 换集/换源一律取消待播的自动连播，避免倒计时结束后又把用户拉回去
    _countdownTimer?.cancel();
    _pendingNext = null;
    _countdown = 0;
    _autoNextHandled = false;

    await _disposeCtrl();

    setState(() {
      _resolving = true;
      _playLoading = false;
      _err = null;
      _playErr = null;
      _realUrl = '';
      _tip = '';
      _danmaku = const [];
      _dmLoaded = false;
    });

    // 弹幕与地址解析并行：两者互不依赖，串行会让首帧多等一次往返。
    // 失败不抛异常也不提示——弹幕拉不到不影响播放。
    unawaited(_loadDanmaku());

    String url;
    try {
      final v = _cur;
      if (ZhuijuApi.isDirectUrl(v.path) &&
          (v.path.endsWith('.m3u8') || v.path.endsWith('.mp4'))) {
        url = v.path;
        _tip = '直链';
      } else {
        final info = await ZhuijuApi.instance.playUrl(v.source, v.path);
        url = info.playUrl;
        _tip = '接口解析';
      }
      if (url.isEmpty) throw Exception('解析结果为空');
      _realUrl = url;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _err = friendlyError(e);
      });
      return;
    }

    // 地址已拿到：立刻结束骨架屏，进入「播放器初始化中」的 loading 态。
    // 这个阶段下载按钮就该能点，所以不能等播放器就绪。
    if (!mounted) return;
    setState(() {
      _resolving = false;
      _playLoading = true;
      _err = null;
    });

    await _startPlay(url);
  }

  /// 启动播放器；失败只记录 _playErr，不影响下载/换源
  Future<void> _startPlay(String url) async {
    VideoPlayerController? ctrl;
    try {
      ctrl = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 9; SM-N9700) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
        },
      );
      // 超时保护：源站半死不活时 initialize 可能挂几分钟，
      // 没有超时用户只会看到一个永远转圈的 loading。
      await ctrl.initialize().timeout(const Duration(seconds: 30));
      await ctrl.play();

      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      // 自动连播靠这个 listener：video_player 的 isCompleted 只在
      // 播放到结尾时置 true，用它判断比「position == duration」稳。
      ctrl.addListener(_onPlayTick);
      setState(() {
        _ctrl = ctrl;
        _playErr = null;
        _playLoading = false;
      });
      _startHistTimer();
      _saveHistory();
    } catch (e) {
      try {
        await ctrl?.dispose();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _ctrl = null;
        _playLoading = false;
        _playErr = _humanPlayError(e);
      });
    }
  }

  // ---------------- 自动连播 ----------------

  void _onPlayTick() {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (_autoNextHandled) return;
    if (_pendingNext != null) return; // 倒计时中

    final v = c.value;
    final total = v.duration;
    if (total <= Duration.zero) return;

    // 双条件：isCompleted 最准；position 兜底（部分解码器不回报 completed）
    final ended = v.isCompleted ||
        (v.position >= total - const Duration(milliseconds: 350));
    if (!ended) return;

    _autoNextHandled = true;
    _scheduleAutoNext();
  }

  /// 找到当前集的下一集（在当前源内按集数顺序）
  DramaVideo? _nextEpisode() {
    final eps = _curEpisodes;
    if (eps.length <= 1) return null;
    var i = eps.indexWhere((e) => e.path == _cur.path);
    if (i < 0) i = eps.indexWhere((e) => e.epLabel == _cur.epLabel);
    if (i < 0 || i >= eps.length - 1) return null;
    return eps[i + 1];
  }

  void _scheduleAutoNext() {
    final next = _nextEpisode();
    if (next == null) {
      // 最后一集：不弹任何东西，安静停在结尾
      return;
    }
    setState(() {
      _pendingNext = next;
      _countdown = 3;
      _showCtrl = true;
      _showEpisodes = false;
      _showSources = false;
    });
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final left = _countdown - 1;
      if (left <= 0) {
        t.cancel();
        final target = _pendingNext;
        setState(() {
          _pendingNext = null;
          _countdown = 0;
        });
        if (target != null) _playEpisode(target, auto: true);
        return;
      }
      setState(() => _countdown = left);
    });
  }

  void _cancelAutoNext() {
    _countdownTimer?.cancel();
    setState(() {
      _pendingNext = null;
      _countdown = 0;
    });
  }

  // ---------------- 选集 / 换源 ----------------

  Future<void> _playEpisode(DramaVideo v, {bool auto = false}) async {
    if (v.path == _cur.path) return;
    _countdownTimer?.cancel();
    setState(() {
      _pendingNext = null;
      _countdown = 0;
      _showEpisodes = false;
      _showCtrl = true;
    });
    if (auto) _showNotice('自动播放 ${v.epLabel}');
    // 同一集换了剧集条目，之前试过的源记录也要清掉（新的集各源都可能能播）
    _triedSrc.clear();
    await _resolve(video: v);
  }

  Future<void> _switchToSource(String name) async {
    final list = widget.sources[name];
    if (list == null || list.isEmpty) {
      _showNotice('该源没有可用剧集');
      return;
    }
    // 优先同名集，其次同集数，都没有才退到第一集
    DramaVideo? target;
    for (final v in list) {
      if (v.epLabel == _cur.epLabel) {
        target = v;
        break;
      }
    }
    if (target == null) {
      for (final v in list) {
        if (v.episode == _cur.episode) {
          target = v;
          break;
        }
      }
    }
    final fellBack = target == null;
    target ??= list.first;

    setState(() {
      _showSources = false;
      _showCtrl = true;
    });
    _showNotice(fellBack ? '「$name」没有${_cur.epLabel}，已切到${target.epLabel}' : '切换到「$name」');
    _triedSrc.clear();
    await _resolve(video: target);
  }

  void _showNotice(String s) {
    _noticeTimer?.cancel();
    setState(() => _notice = s);
    _noticeTimer = Timer(const Duration(milliseconds: 2200), () {
      if (!mounted) return;
      setState(() => _notice = null);
    });
  }

  /// 拉取本集弹幕。
  ///
  /// 定位用的两个参数都不是剧名/链接，而是「剧集 id + 集数序号」：
  /// 服务端按这两者索引每一集的弹幕池（实测传剧名返回 0 条）。
  Future<void> _loadDanmaku() async {
    final ep = _cur.episode;
    final id = widget.dramaId;
    // 本地播放/未知剧集时没有 id，直接标记完成，避免「暂无弹幕」永远不出现
    if (id <= 0 || ep <= 0) {
      if (mounted) setState(() => _dmLoaded = true);
      return;
    }
    final list = await DanmakuApi.instance.fetch(
      dramaId: id,
      episode: ep,
      host: ZhuijuApi.baseUrl,
    );
    if (!mounted) return;
    // 拉取期间用户可能已经换了集，回来晚的结果不能覆盖新集的弹幕
    if (_cur.episode != ep) return;
    setState(() {
      _danmaku = list;
      _dmLoaded = true;
    });
  }

  String _humanPlayError(Object e) {
    final s = e.toString();
    if (s.contains('TimeoutException') || s.contains('timed out')) {
      return '源站响应超时';
    }
    if (s.contains('NO_EXCEEDS_CAPABILITIES')) {
      // 实测雷电模拟器只支持到 1080p，4K HEVC 直接报这个
      return '当前设备解码不了这个清晰度（如 4K HEVC），换一个源试试';
    }
    if (s.contains('Source error') || s.contains('UnrecognizedInputFormat')) {
      return '当前源无法播放（源站限制或分片失效）';
    }
    if (s.contains('403')) return '源站拒绝访问（403）';
    if (s.contains('404')) return '源站资源不存在（404）';
    return '播放失败：$s';
  }

  // ---------------- 观看历史 ----------------

  void _startHistTimer() {
    _histTimer?.cancel();
    _histTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _saveHistory(updateOnly: true);
    });
  }

  /// 写观看历史。
  ///
  /// [updateOnly] 为 true 时只刷新进度，不新增记录（避免播放中途
  /// 反复把同一部剧顶到列表最前，导致「我的」页面每 8 秒跳一次）。
  void _saveHistory({bool updateOnly = false}) {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (widget.dramaName.isEmpty) return;
    final pos = c.value.position.inSeconds;
    final dur = c.value.duration.inSeconds;
    if (pos <= 0) return;

    if (updateOnly) {
      HistoryStore.instance.updateProgress(
        dramaId: widget.dramaId,
        dramaName: widget.dramaName,
        positionSec: pos,
        durationSec: dur,
      );
      return;
    }
    HistoryStore.instance.upsert(WatchRecord(
      dramaId: widget.dramaId,
      dramaName: widget.dramaName,
      epLabel: _cur.epLabel,
      source: _cur.source,
      path: _cur.path,
      episode: _cur.episode,
      cover: widget.cover,
      positionSec: pos,
      durationSec: dur,
    ));
  }

  // ---------------- 全屏 ----------------

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() {
      _fullscreen = next;
      _showCtrl = true;
      if (!next) {
        _showEpisodes = false;
        _showSources = false;
      }
    });
    // 桌面端锁横屏/隐藏系统栏都是无效调用（窗口不会变），
    // 统一交给 platform 层分流，桌面直接 no-op，避免「点了没反应」的错觉。
    await setFullscreen(next);
  }

  Future<void> _restoreOrientation() async {
    await restorePortrait();
  }

  void _toast(String s) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  void _download() {
    if (_realUrl.isEmpty) {
      _toast('尚未解析到地址');
      return;
    }
    final title = '${widget.dramaName}_${_cur.epLabel}';
    // 先看这一集在下载器里的既有状态，否则用户重复点下载时
    // 界面会毫无反应（start 直接复用旧任务），看起来像按钮坏了。
    final before = _findTask(title);
    // 不传 preferExt：实测有源把 m3u8 标成 image/png、octet-stream，
    // 也有些 m3u8 地址根本没有 .m3u8 后缀（形如 /m.php?data=...）。
    // 真实类型交给下载器读首字节嗅探，嗅到 #EXTM3U 会自动转 HLS 流程。
    try {
      final t = DownloadManager.instance.start(
        title: title,
        url: _realUrl,
        // 把剧集标识带进下载索引：本地播放页靠它拉弹幕
        dramaId: widget.dramaId,
        episode: _cur.episode,
        resolver: () async {
          final v = _cur;
          if (ZhuijuApi.isDirectUrl(v.path) &&
              (v.path.endsWith('.m3u8') || v.path.endsWith('.mp4'))) {
            return v.path;
          }
          final info = await ZhuijuApi.instance.playUrl(v.source, v.path);
          return info.playUrl;
        },
      );

      if (before != null && t.id == before.id) {
        switch (t.state) {
          case DownloadState.done:
            _toast('这一集已下载完成，可在「我的 → 下载管理」直接播放');
            return;
          case DownloadState.running:
            _toast('这一集正在下载中');
            return;
          case DownloadState.paused:
          case DownloadState.failed:
            _toast('继续上次进度：${t.title}');
            return;
          default:
            break;
        }
      }
      _toast('已加入下载：${t.title}');
    } catch (e) {
      _toast('加入下载失败：$e');
    }
  }

  /// 按标题找已有任务（下载器内部用 safeName 归一化 id，这里做同样换算）
  DownloadTask? _findTask(String title) {
    final id = DownloadManager.safeName(title);
    for (final t in DownloadManager.instance.tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 当前这一集在不同源下的候选（每个源取一条，已排除当前源与试过的源）
  ///
  /// 必须按「当前集」实时算，不能直接用 widget.alternates：
  /// alternates 是详情页进入播放器时按**初始那一集**算好的静态快照。
  /// 一旦自动连播/选集切到别的集，快照里根本没有新一集的候选，
  /// 于是 _canSwitch 变成 false，「换源」按钮凭空消失——这个 bug 实测
  /// 在自动连播到第 3 集后复现。sources 是「源 → 全部剧集」，才能按集重算。
  List<DramaVideo> get _switchCandidates {
    final curSrc = _srcKey(_cur);
    final out = <DramaVideo>[];
    final seen = <String>{};

    // 首选：从 sources 里按集精确取（能覆盖切集后的场景）
    for (final entry in widget.sources.entries) {
      final name = entry.key;
      if (name == curSrc) continue;
      if (_triedSrc.contains(name)) continue;
      DramaVideo? pick;
      for (final v in entry.value) {
        if (v.episode == _cur.episode) {
          pick = v;
          break;
        }
      }
      // 没有同集就用同集数标签兜底（少数源集数编号不一致）
      if (pick == null) {
        for (final v in entry.value) {
          if (v.epLabel == _cur.epLabel) {
            pick = v;
            break;
          }
        }
      }
      if (pick == null) continue;
      if (seen.add(name)) out.add(pick);
    }

    // 兜底：sources 为空（老调用方/本地播放）时退回快照
    if (widget.sources.isEmpty) {
      for (final v in widget.alternates) {
        final k = _srcKey(v);
        if (k == curSrc) continue;
        if (_triedSrc.contains(k)) continue;
        if (v.epLabel != _cur.epLabel) continue;
        if (seen.add(k)) out.add(v);
      }
    }
    return out;
  }

  /// 换到下一个未尝试过的源（按源名去重）
  void _switchSource() {
    final cands = _switchCandidates;
    if (cands.isEmpty) {
      _toast('没有更多可用源了');
      return;
    }
    // 当前源连同它下面的其它线路一起标记为已试，
    // 避免下次又从同一个源的别的线路「换」回来。
    _triedSrc.add(_srcKey(_cur));
    final pick = cands.first;
    _showNotice('切换到「${_srcKey(pick)}」');
    _resolve(video: pick);
  }

  bool get _canSwitch => _switchCandidates.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (_fullscreen) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          // 面板开着时，返回键先收面板，而不是直接退出全屏
          if (_showEpisodes || _showSources) {
            setState(() {
              _showEpisodes = false;
              _showSources = false;
            });
          } else {
            _toggleFullscreen();
          }
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
        title: Text(
          widget.dramaName.isEmpty
              ? _cur.epLabel
              : '${widget.dramaName} · ${_cur.epLabel}',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          if (_isSeries)
            IconButton(
              tooltip: '选集',
              icon: const Icon(Icons.grid_view_rounded),
              onPressed: () => _openEpisodeSheet(context),
            ),
          IconButton(
            tooltip: '下载',
            icon: const Icon(Icons.download_rounded),
            onPressed: _realUrl.isEmpty ? null : _download,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  /// 全屏布局：视频铺满，控制条浮在底部，点画面切换显隐
  Widget _fullscreenBody() {
    final c = _ctrl;
    final inited = c != null && c.value.isInitialized;
    return GestureDetector(
      onTap: () => setState(() {
        _showCtrl = !_showCtrl;
        if (!_showCtrl) {
          _showEpisodes = false;
          _showSources = false;
        }
      }),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: inited
                  ? Center(
                      child: AspectRatio(
                        aspectRatio: c.value.aspectRatio == 0
                            ? 16 / 9
                            : c.value.aspectRatio,
                        // 弹幕必须叠在画面内、而不是铺满整屏：
                        // 铺满会在上下黑边里滚字，横屏宽银幕片尤其难看。
                        child: Stack(
                          children: [
                            Positioned.fill(child: VideoPlayer(c)),
                            if (_danmaku.isNotEmpty)
                              ValueListenableBuilder<bool>(
                                valueListenable:
                                    DanmakuSettings.instance.enabled,
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
                            if (_danmaku.isEmpty && _dmLoaded)
                              const DanmakuEmptyHint(),
                          ],
                        ),
                      ),
                    )
                  : PlayerPlaceholder(
                      loading: _playLoading || _resolving,
                      message: _playLoading || _resolving
                          ? '正在加载…'
                          : (_playErr ?? '播放器未就绪'),
                      hint: (_playErr == null || _playLoading)
                          ? null
                          : '可能是这一路源不稳定，换个线路试试',
                      onRetry: (_playLoading || _resolving)
                          ? null
                          : (_canSwitch ? _switchSource : () => _resolve()),
                      retryLabel: _canSwitch ? '换个源试试' : '重新解析',
                    ),
            ),

            // 顶部：标题 + 选集/换源 + 退出全屏
            if (_showCtrl)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _fullscreenTopBar(),
              ),

            // 底部控制条
            if (inited && _showCtrl)
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
                      padding: const EdgeInsets.fromLTRB(10, 20, 10, 4),
                      child: PlayerControlBar(
                        ctrl: c,
                        fullscreen: true,
                        onToggleFullscreen: _toggleFullscreen,
                        extraActions: [
                          // 弹幕开关：全屏是最常用的看弹幕场景，
                          // 开关必须在这里就能按到，不用退回竖屏。
                          const DanmakuToggleButton(),
                          IconButton(
                            iconSize: 22,
                            color: Colors.white,
                            tooltip: '下载',
                            padding:
                                const EdgeInsets.symmetric(horizontal: 6),
                            constraints: const BoxConstraints(
                                minWidth: 34, minHeight: 34),
                            icon: const Icon(Icons.download_rounded),
                            onPressed: _realUrl.isEmpty ? null : _download,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // 右侧面板：选集 / 换源
            if (_showEpisodes) _sidePanel(title: '选集', child: _episodeGrid()),
            if (_showSources) _sidePanel(title: '换源', child: _sourceList()),

            // 自动连播倒计时
            if (_pendingNext != null) _autoNextCard(),

            // 轻提示
            if (_notice != null) _noticeBar(),
          ],
        ),
      ),
    );
  }

  Widget _fullscreenTopBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.transparent, Colors.black54],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 46,
          child: Row(
            children: [
              IconButton(
                color: Colors.white,
                tooltip: '退出全屏',
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                onPressed: _toggleFullscreen,
              ),
              Expanded(
                child: Text(
                  widget.dramaName.isEmpty
                      ? _cur.epLabel
                      : '${widget.dramaName} · ${_cur.epLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (_isSeries)
                _topAction(
                  icon: Icons.grid_view_rounded,
                  label: '选集',
                  onTap: () => setState(() {
                    _showEpisodes = !_showEpisodes;
                    _showSources = false;
                    _showCtrl = true;
                  }),
                ),
              if (_sourceNames.length > 1)
                _topAction(
                  icon: Icons.swap_horiz_rounded,
                  label: '换源',
                  onTap: () => setState(() {
                    _showSources = !_showSources;
                    _showEpisodes = false;
                    _showCtrl = true;
                  }),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }

  /// 右侧滑出面板外壳：吸收点击，避免点面板空白处把整层控件关掉
  Widget _sidePanel({required String title, required Widget child}) {
    final w = MediaQuery.of(context).size.width;
    final panelW = (w * 0.44).clamp(220.0, 400.0);
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      width: panelW,
      child: GestureDetector(
        onTap: () {},
        child: Container(
          color: Colors.black.withValues(alpha: 0.9),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
                  child: Row(
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14,
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      IconButton(
                        iconSize: 18,
                        color: Colors.white70,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() {
                          _showEpisodes = false;
                          _showSources = false;
                        }),
                      ),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _episodeGrid() {
    final eps = _curEpisodes;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1.75,
      ),
      itemCount: eps.length,
      itemBuilder: (c, i) {
        final e = eps[i];
        final active = e.path == _cur.path;
        return GestureDetector(
          onTap: () => _playEpisode(e),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? kAccent : Colors.white12,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              e.epLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: active ? Colors.white : Colors.white70,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sourceList() {
    final cur = _srcKey(_cur);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      itemCount: _sourceNames.length,
      itemBuilder: (c, i) {
        final n = _sourceNames[i];
        final active = n == cur;
        final cnt = widget.sources[n]?.length ?? 0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: active ? null : () => _switchToSource(n),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: active ? kAccent.withValues(alpha: 0.18) : Colors.white10,
                borderRadius: BorderRadius.circular(8),
                border: active ? Border.all(color: kAccent, width: 1) : null,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      n,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: active ? kAccent : Colors.white,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  Text('$cnt 集',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.white38)),
                  if (active) ...[
                    const SizedBox(width: 6),
                    const Text('播放中',
                        style: TextStyle(fontSize: 11, color: kAccent)),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _autoNextCard() {
    final n = _pendingNext!;
    return Positioned(
      right: 18,
      bottom: 92,
      child: GestureDetector(
        onTap: () {},
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$_countdown 秒后自动播放 ${n.epLabel}',
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _cancelAutoNext,
                style: TextButton.styleFrom(
                  foregroundColor: kAccent,
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('取消', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noticeBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 100,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              _notice!,
              style: const TextStyle(fontSize: 12.5, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  /// 竖屏选集：底部弹层，复用同一份剧集数据
  void _openEpisodeSheet(BuildContext context) {
    final eps = _curEpisodes;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.55,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                child: Row(
                  children: [
                    Text('选集（共 ${eps.length} 集）',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 2.1,
                  ),
                  itemCount: eps.length,
                  itemBuilder: (c, i) {
                    final e = eps[i];
                    final active = e.path == _cur.path;
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _playEpisode(e);
                      },
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: active ? kAccent : kBg,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          e.epLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: active ? Colors.white : Colors.white70,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    // 解析中：骨架 loading，不给任何错误提示
    if (_resolving) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2.4),
            SizedBox(height: 14),
            Text('正在解析播放地址…',
                style: TextStyle(color: kTextDim, fontSize: 12)),
          ],
        ),
      );
    }
    // 解析阶段失败：整页错误，可重试
    if (_err != null) {
      return ErrorView(message: _err!, onRetry: () => _resolve());
    }

    return Column(
      children: [
        _videoArea(),
        // 信息区：只要拿到地址就一直可用
        Expanded(
          child: Container(
            width: double.infinity,
            color: kBg,
            padding: const EdgeInsets.all(14),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _statusRow(),
                  const SizedBox(height: 10),
                  if (_ctrl != null)
                    PlayerControlBar(
                      ctrl: _ctrl!,
                      fullscreen: false,
                      onToggleFullscreen: _toggleFullscreen,
                      extraActions: const [DanmakuToggleButton()],
                    ),
                  const SizedBox(height: 12),
                  const Text('播放地址',
                      style: TextStyle(fontSize: 12, color: kTextDim)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          _realUrl,
                          maxLines: 3,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white54),
                        ),
                      ),
                      IconButton(
                        tooltip: '复制',
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _realUrl));
                          _toast('地址已复制');
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _actionButtons(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 播放区域
  Widget _videoArea() {
    final c = _ctrl;

    // 播放器还没就绪
    if (c == null || !c.value.isInitialized) {
      // 正在初始化 → loading，不提示换源
      if (_playLoading) {
        return const SizedBox(
          height: 210,
          child: PlayerPlaceholder(loading: true, message: '正在加载视频…'),
        );
      }
      // 真的失败了 → 这时才提示换线路
      return SizedBox(
        height: 210,
        child: PlayerPlaceholder(
          message: _playErr ?? '播放器未就绪',
          hint: '可能是这一路源不稳定，换个线路试试',
          onRetry: _canSwitch ? _switchSource : () => _resolve(),
          retryLabel: _canSwitch ? '换个源试试' : '重新解析',
        ),
      );
    }

    return GestureDetector(
      onTap: () => setState(() => _showCtrl = !_showCtrl),
      child: Container(
        color: Colors.black,
        width: double.infinity,
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(c),
              // 竖屏小窗同样要显示弹幕：用户在竖屏看剧时不能没弹幕
              if (_danmaku.isNotEmpty)
                ValueListenableBuilder<bool>(
                  valueListenable: DanmakuSettings.instance.enabled,
                  builder: (ctx, on, _) => on
                      ? Positioned.fill(
                          child: DanmakuOverlay(
                            ctrl: c,
                            items: _danmaku,
                            // 竖屏画面窄，字号必须比全屏小，
                            // 否则一条长弹幕滚过去要占满整行
                            fontSize: 12,
                            travel: const Duration(milliseconds: 6500),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              if (_danmaku.isEmpty && _dmLoaded) const DanmakuEmptyHint(),
              if (_showCtrl) _overlay(c),
              if (_pendingNext != null)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$_countdown 秒后播放 ${_pendingNext!.epLabel}',
                            style: const TextStyle(
                                fontSize: 11.5, color: Colors.white)),
                        TextButton(
                          onPressed: _cancelAutoNext,
                          style: TextButton.styleFrom(
                            foregroundColor: kAccent,
                            minimumSize: const Size(0, 26),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                          child: const Text('取消',
                              style: TextStyle(fontSize: 11.5)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusRow() {
    return Row(
      children: [
        _chip(_cur.sourceCn.isNotEmpty ? _cur.sourceCn : _cur.source),
        const SizedBox(width: 8),
        _chip(_tip, dim: true),
        if (_isSeries) ...[
          const SizedBox(width: 8),
          _chip('共 ${_curEpisodes.length} 集', dim: true),
        ],
        const Spacer(),
        if (_playLoading)
          const Text('加载中…',
              style: TextStyle(fontSize: 11, color: kTextDim)),
      ],
    );
  }

  Widget _actionButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _resolve(),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('重新解析'),
          ),
        ),
        if (_canSwitch) ...[
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _switchSource,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('换源'),
            ),
          ),
        ],
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            onPressed: _realUrl.isEmpty ? null : _download,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('下载本集'),
          ),
        ),
      ],
    );
  }

  Widget _overlay(VideoPlayerController c) {
    return Container(
      color: Colors.black26,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 播放/暂停图标随 controller 变化，订阅后无需 setState 整页重建
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: c,
            builder: (ctx, v, _) => IconButton(
              iconSize: 46,
              color: Colors.white,
              icon: Icon(v.isPlaying
                  ? Icons.pause_circle_filled_rounded
                  : Icons.play_circle_fill_rounded),
              onPressed: () {
                v.isPlaying ? c.pause() : c.play();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String s, {bool dim = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: dim ? kCard : kAccent.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          s,
          style: TextStyle(
            fontSize: 11,
            color: dim ? kTextDim : kAccent,
          ),
        ),
      );
}