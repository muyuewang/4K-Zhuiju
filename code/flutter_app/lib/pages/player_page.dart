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
import '../core/desktop_window.dart';
import '../core/download.dart';
import '../core/hls_proxy.dart';
import '../core/layout.dart';
import '../core/platform.dart';
import '../core/history.dart';
import '../core/models.dart';
import '../core/source_picker.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/player_controls.dart';

/// 接口返回了「不是地址」的结果（如独家短剧的专用令牌）
///
/// 单独建一个类型，是为了让错误页能给出人话提示，
/// 而不是把 UnrecognizedInputFormat 这种底层异常丢给用户。
class _UnplayableException implements Exception {
  final String message;
  _UnplayableException(String sourceName)
      : message = '「$sourceName」返回的是播放器专用令牌，不是可播放地址，请换一个源';
  @override
  String toString() => message;
}

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
    // 原生侧按 Esc 退出全屏时只改了窗口，Dart 的 _fullscreen 还是 true，
    // 界面会停在全屏布局里出不去。订阅通知把两边状态对齐。
    desktopFullscreen.addListener(_onNativeFullscreenChanged);
    // 桌面快捷键必须走全局监听，不能用 Focus(autofocus)。
    //
    // 实测：焦点一旦被页面里的按钮抢走（点过一次进度条、选集、下载都算），
    // Focus 子树就收不到按键了，表现为「F 键/空格/方向键全都没反应」，
    // 而点界面上的全屏按钮却正常——问题在焦点，不在原生通道。
    // HardwareKeyboard 的 handler 挂在引擎层，与焦点无关。
    if (isDesktop) {
      HardwareKeyboard.instance.addHandler(_onGlobalKey);
    }
    _resolve();
  }

  /// 全局按键处理：返回 true 表示已消费，不再向下传递。
  bool _onGlobalKey(KeyEvent e) {
    // 页面上没有文本输入框，但仍要防一手：焦点在可编辑控件时
    // 不要把空格/方向键吃掉，否则以后加搜索框会无法输入。
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null) {
      final w = focused.widget;
      if (w is EditableText) return false;
    }
    return _onKey(null, e) == KeyEventResult.handled;
  }

  /// 原生（窗口）侧的全屏状态回调
  void _onNativeFullscreenChanged() {
    if (!mounted) return;
    final native = desktopFullscreen.value;
    if (!native && _fullscreen) {
      setState(() {
        _fullscreen = false;
        _showEpisodes = false;
        _showSources = false;
        _showCtrl = true;
      });
    }
  }

  @override
  void dispose() {
    desktopFullscreen.removeListener(_onNativeFullscreenChanged);
    if (isDesktop) {
      HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    }
    _histTimer?.cancel();
    _countdownTimer?.cancel();
    _noticeTimer?.cancel();
    _saveHistory();
    _ctrl?.dispose();
    // 离开播放页就关掉本地 HLS 代理，别让 127.0.0.1 的端口一直挂着。
    // 不 await：dispose 是同步的，代理关闭失败也不该影响页面销毁。
    if (isDesktop) unawaited(HlsProxy.instance.shutdown());
    // 页面被销毁时务必还原屏幕方向，否则退出播放页后整个 App 还是横屏
    if (_fullscreen) {
      _restoreOrientation();
    }
    super.dispose();
  }

  // ---------------- 桌面键盘快捷键 ----------------
  //
  // 桌面用户看视频的习惯是手放在键盘上：空格暂停、左右快退快进、
  // 上下调音量、F 全屏、Esc 退出。做不到这些，桌面版就只是个
  // 「能播放的窗口」，鼠标来回点进度条很别扭。

  KeyEventResult _onKey(FocusNode? node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final c = _ctrl;
    final k = e.logicalKey;

    // 全屏时 Esc 由原生 WM_KEYDOWN 接管（会退出窗口全屏并回调），
    // 这里不再重复处理，避免一次按键退两次。
    if (k == LogicalKeyboardKey.escape) {
      if (_fullscreen) return KeyEventResult.handled;
      if (_showEpisodes || _showSources) {
        setState(() {
          _showEpisodes = false;
          _showSources = false;
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (k == LogicalKeyboardKey.space) {
      if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
      c.value.isPlaying ? c.pause() : c.play();
      setState(() => _showCtrl = true);
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
      // Shift + 方向键步子更大，和主流播放器一致
      final big = HardwareKeyboard.instance.isShiftPressed;
      final step = Duration(seconds: big ? 30 : 10);
      final fwd = k == LogicalKeyboardKey.arrowRight;
      final total = c.value.duration;
      var target = c.value.position + (fwd ? step : -step);
      if (target < Duration.zero) target = Duration.zero;
      if (target > total) target = total;
      c.seekTo(target);
      _showNotice(fwd ? '快进 ${big ? 30 : 10} 秒' : '快退 ${big ? 30 : 10} 秒');
      setState(() => _showCtrl = true);
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      if (c == null) return KeyEventResult.ignored;
      final up = k == LogicalKeyboardKey.arrowUp;
      final v = (c.value.volume + (up ? 0.1 : -0.1)).clamp(0.0, 1.0);
      c.setVolume(v);
      _showNotice('音量 ${(v * 100).round()}%');
      setState(() => _showCtrl = true);
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.keyM) {
      if (c == null) return KeyEventResult.ignored;
      final mute = c.value.volume > 0;
      c.setVolume(mute ? 0 : 1.0);
      _showNotice(mute ? '静音' : '取消静音');
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
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
  ///
  /// 策略：**先走接口，失败再退回直链**。顺序不能反，两个原因：
  ///   1. BL 源（bilibili）的 path 是番剧网页地址，只有接口能换出
  ///      带时效签名的 m3u8（`/9792d90c…/6AF10B57/…m3u8`）。
  ///      签名会过期，实测复用一个旧地址很快就 403，所以每次播放
  ///      都必须重新换一次，绝不能缓存。
  ///   2. B蓝光 的 path 虽是可直连的 `…/全集/index.m3u8`，但接口会
  ///      下发同一份清单的 CDN 镜像（122.228.193.79:6688），
  ///      响应快 4 倍左右，且原站随时可能加防盗链。
  /// 只有接口真的挂了（网络异常/返回空）才用直链兜底，保证不至于
  /// 因为接口单点故障而完全不能播。
  Future<String> _resolveUrl(DramaVideo v) async {
    final direct = ZhuijuApi.isDirectUrl(v.path) &&
        (v.path.endsWith('.m3u8') || v.path.endsWith('.mp4'));

    try {
      final info = await ZhuijuApi.instance.playUrl(v.source, v.path);
      final u = info.playUrl;
      if (u.isNotEmpty && ZhuijuApi.isDirectUrl(u)) {
        _tip = direct ? '接口解析(CDN)' : '接口解析';
        return u;
      }
      // 接口返回了非地址（独家短剧令牌）：直链可用就先用直链，
      // 否则把令牌原样返回，交给调用方抛「专用令牌」的明确错误。
      if (direct) {
        _tip = '直链';
        return v.path;
      }
      return u;
    } catch (e) {
      if (direct) {
        _tip = '直链（接口失败）';
        return v.path;
      }
      rethrow;
    }
  }

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
      url = await _resolveUrl(v);
      // 接口「成功」不代表拿到的是能播的地址。
      //
      // 独家短剧（hgdj）实测返回 code=200 且 playUrl 就是
      // `7512797350914444313&1` —— 这是原版播放器内部的令牌，
      // 必须由它自己的播放器去换取真实流，我们拿到手无法使用。
      // 不拦这一层的话，值会一路传到 VideoPlayerController，
      // 抛出 UnrecognizedInputFormat，用户看到的是
      // 「当前源无法播放（源站限制或分片失效）」，完全没说清原因。
      if (url.isEmpty) throw Exception('解析结果为空');
      if (!ZhuijuApi.isDirectUrl(url)) {
        throw _UnplayableException(v.sourceCn.isNotEmpty
            ? v.sourceCn
            : (v.source.isNotEmpty ? v.source : '当前线路'));
      }
      _realUrl = url;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _err = e is _UnplayableException ? e.message : friendlyError(e);
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

    // 诊断日志：把「线路名 / 接口解析方式 / 最终地址」打到 stdout。
    //
    // 排查「某条线路播不出来」时，光看界面截图分不清两件事：
    //   (a) 换源压根没生效（线路名没变）
    //   (b) 换源生效了，但这条线路的地址 Media Foundation 解析不了
    // 两者在界面上都表现成「正在加载视频…」，只能靠这行日志区分。
    // 级别用 debugPrint，release 包里也不会被裁掉。
    debugPrint('[PLAY] src=${_cur.sourceCn.isNotEmpty ? _cur.sourceCn : _cur.source}'
        ' tip=$_tip ep=${_cur.episode} url=$url');

    await _startPlay(url);
  }

  /// 启动播放器；失败只记录 _playErr，不影响下载/换源
  Future<void> _startPlay(String url) async {
    VideoPlayerController? ctrl;
    try {
      // 桌面端把 m3u8 包一层本地代理再交给 Media Foundation。
      //
      // MF 自带的 HLS 解析器对「相对分片地址 + 含百分号编码的基址」
      // 处理有缺陷，实测短剧 B蓝光（清单里是 `0000000.ts` 这种相对路径，
      // 基址是 `.../video/xxx/全集/index.m3u8`）会直接报
      // `MF_MEDIA_ENGINE_EVENT_ERROR: file not found / corrupted / not supported`，
      // 而分片地址是绝对路径的 BL 线路一直正常。
      // 代理负责把相对地址展开、清掉源站私货注释，具体原因见 hls_proxy.dart。
      //
      // 只对 m3u8 生效：mp4 直链在 MF 上一直没问题，没必要多一跳。
      // Android 走 ExoPlayer，原生支持相对地址，保持直连（少一层转发）。
      final playUrl = isDesktop ? await HlsProxy.instance.wrap(url) : url;

      ctrl = VideoPlayerController.networkUrl(
        Uri.parse(playUrl),
        // 桌面端绝不能带 httpHeaders，这是 HLS 在 Windows 上播不出来的死因。
        //
        // video_player_win 的原生实现（my_grabber_player.cpp:OpenURL）有两条分支：
        //     if (!httpHeaders.empty() && url 以 http 开头)
        //         → SetSourceFromByteStream(自己实现的 WinHttp 字节流)
        //     else
        //         → SetSource(url)   // 交给 Media Foundation 自己解析
        //
        // 也就是说：只要传了请求头，m3u8 就会被当成一个「普通字节流」喂给
        // Media Foundation，播放列表的语义彻底丢失（它拿到的是清单文本，
        // 而不是可解码的媒体流），于是直接报 SRC_NOT_SUPPORTED。
        // 短剧的 B蓝光 / BL 全是 HLS，因此桌面端一条都放不出来，
        // 而 Android 走 ExoPlayer 原生支持 HLS，同一地址一直正常——
        // 这就是「APK 能播、桌面版不能播」的全部原因。
        //
        // 不传请求头时走 SetSource(url)，Media Foundation 会自行处理
        // m3u8 清单与分片请求。实测 B蓝光 / BL 两条线路都不需要
        // 自定义 UA 或 Referer，所以桌面端去掉请求头不影响可用性。
        httpHeaders: isDesktop
            ? const {}
            : const {
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
          // 与播放共用同一套解析规则（接口优先、直链兜底），
          // 否则会出现「能播但下载下到的是原站地址/令牌」的割裂。
          final u = await _resolveUrl(_cur);
          if (u.isEmpty || !ZhuijuApi.isDirectUrl(u)) {
            throw Exception('该线路未返回可下载地址');
          }
          return u;
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
  ///
  /// 具体判定（含短剧「一条装全集」的兼容）见 core/source_picker.dart，
  /// 那边有单测覆盖，这里只负责组装。
  List<DramaVideo> get _switchCandidates {
    final out = switchCandidates(widget.sources, _cur, tried: _triedSrc);

    // 兜底：sources 为空（老调用方/本地播放）时退回快照
    if (widget.sources.isEmpty) {
      final curSrc = _srcKey(_cur);
      final seen = <String>{};
      for (final v in widget.alternates) {
        final k = _srcKey(v);
        if (k == curSrc) continue;
        if (_triedSrc.contains(k)) continue;
        if (v.epLabel != _cur.epLabel) continue;
        if (v.pathLooksPlayable && seen.add(k)) out.add(v);
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
    // 键盘监听不走 Focus 子树，改由 initState 里注册的
    // HardwareKeyboard handler 接管（原因见那边的注释）。
    // 这里保持纯布局，避免焦点被按钮抢走后快捷键整体失效。
    return _buildScaffold(context);
  }

  Widget _buildScaffold(BuildContext context) {
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

  Widget _episodeGrid({int crossAxisCount = 4, EdgeInsets? padding}) {
    final eps = _curEpisodes;
    return GridView.builder(
      padding: padding ?? const EdgeInsets.fromLTRB(12, 4, 12, 16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
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

    // 宽屏：左视频右选集，选集常驻可见。桌面窗口普遍是 16:9 横屏，
    // 把视频铺在顶部再往下滚信息，会造成大面积留白且选集要点弹窗，
    // 和「播放器」这个使用场景完全不搭。
    if (isWide(context)) return _wideBody();

    // 竖屏（短剧）专用修法。
    //
    // Column 里非弹性子项拿到的是**无界高度**约束，而视频区原来用
    // AspectRatio 按宽度定高：横屏片 16:9 时高 ≈ 宽×0.56 没问题，
    // 但竖屏短剧是 9:16，高 = 宽×1.78。360dp 宽的机器上就是 640dp，
    // 一屏根本放不下，Expanded 拿到负高度，直接报
    // BOTTOM OVERFLOWED BY 80 PIXELS，播放控制条和全屏按钮全被挤出屏幕。
    //
    // 这里给视频区一个明确的高度上限（可用高度的 62%），交给
    // ConstrainedBox + Center + AspectRatio：AspectRatio 在受限时会
    // 自动缩宽以维持比例，于是竖屏视频变成「居中 + 上下黑边」，
    // 控制条稳稳留在屏幕内。横屏片因为算出来的高度本来就小于上限，
    // 行为与之前完全一致。
    return LayoutBuilder(
      builder: (ctx, cons) {
        final avail = cons.maxHeight.isFinite
            ? cons.maxHeight
            : MediaQuery.sizeOf(ctx).height;
        final maxVideoH = avail * 0.62;
        return Column(
          children: [
            _videoArea(maxHeight: maxVideoH),
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
      },
    );
  }

  /// 宽屏布局：左视频 + 右面板
  ///
  /// 左栏自适应，视频按可用宽度撑满并保持原始宽高比；右栏固定 340，
  /// 上方是当前集信息与操作，下方是常驻的选集网格（没有集可换时
  /// 退化成换源列表）。
  Widget _wideBody() {
    final c = _ctrl;
    final inited = c != null && c.value.isInitialized;
    final aspect = inited && c.value.aspectRatio > 0
        ? c.value.aspectRatio
        : (16 / 9);

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
                        children: [
                          Positioned.fill(
                            child: inited
                                ? VideoPlayer(c)
                                : PlayerPlaceholder(
                                    loading: _playLoading,
                                    message: _playLoading
                                        ? '正在加载…'
                                        : (_playErr ?? '播放器未就绪'),
                                    hint: _playErr == null
                                        ? null
                                        : '可能是这一路源不稳定，换个线路试试',
                                    onRetry: _playLoading
                                        ? null
                                        : (_canSwitch
                                            ? _switchSource
                                            : () => _resolve()),
                                    retryLabel: _canSwitch ? '换个源试试' : '重新解析',
                                  ),
                          ),
                          if (_danmaku.isNotEmpty && inited)
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
                          if (_danmaku.isEmpty && _dmLoaded && inited)
                            const DanmakuEmptyHint(),
                        ],
                      ),
                    ),
                  ),
                ),
                // 控制条常驻：桌面上鼠标一移就能点，不需要「点画面唤出」
                if (inited)
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
        // 右栏
        Container(
          width: 340,
          color: kBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.dramaName.isEmpty
                          ? _cur.epLabel
                          : widget.dramaName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${_cur.epLabel} · ${_srcKey(_cur)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 11.5, color: kTextDim),
                    ),
                    const SizedBox(height: 10),
                    _statusRow(),
                    const SizedBox(height: 10),
                    _actionButtons(),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFF23262F)),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: Row(
                  children: [
                    Text(
                      _isSeries ? '选集' : '播放源',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isSeries
                          ? '共 ${_curEpisodes.length} 集'
                          : '${_sourceNames.length} 个源',
                      style: const TextStyle(fontSize: 11, color: kTextDim),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _isSeries
                    ? _episodeGrid(crossAxisCount: 5)
                    : _sourceList(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 播放区域
  Widget _videoArea({double? maxHeight}) {
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

    final aspect = c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio;

    final video = GestureDetector(
      onTap: () => setState(() => _showCtrl = !_showCtrl),
      child: Container(
        color: Colors.black,
        width: double.infinity,
        child: AspectRatio(
          aspectRatio: aspect,
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

    // 有高度上限时：把视频塞进「限高 + 居中」的盒子里。
    //
    // AspectRatio 在外层给了紧约束（BoxConstraints.tightFor(height)）之后，
    // 会自动反推宽度以维持比例，所以 9:16 的竖屏片会变成
    // 「两侧留黑边的窄条」而不是「顶到天的巨幅画面」，控制条因此
    // 永远留在可见区域。横屏片算出来的高度通常小于上限，
    // 这一层等于没生效，行为和原来一致。
    if (maxHeight == null) return video;
    return Container(
      color: Colors.black,
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: video,
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