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
import '../core/dlna.dart';
import '../core/download.dart';
import '../core/hls_proxy.dart';
import '../core/layout.dart';
import '../core/platform.dart';
import '../core/history.dart';
import '../core/models.dart';
import '../core/screen_awake.dart';
import '../core/source/data_source.dart';
import '../core/source/registry.dart';
import '../core/playback_prefs.dart';
import '../core/source_picker.dart';
import '../core/tv.dart';
import '../theme.dart';
import '../widgets/cast_sheet.dart';
import '../widgets/common.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/episode_nav_bar.dart';
import '../widgets/player_controls.dart';
import '../widgets/tv_focus.dart';
import '../core/tokens.dart';

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

/// 手势过程中顶部/中央显示的指示器类型
enum _GestureHud { volume, brightness, seek }

class PlayerPage extends StatefulWidget {
  final DramaVideo video;
  final String dramaName;
  final String cover;

  /// 所属剧集 id，用于写入观看历史（空串表示未知）
  final String dramaId;

  /// 同集其它可切换的源（detail 页传入），用于播放失败时换源
  final List<DramaVideo> alternates;

  /// 全部源 → 该源的剧集列表（detail 页传入）。
  /// 用于全屏选集、按源名精确换源，以及判断「有没有下一集」。
  final Map<String, List<DramaVideo>> sources;

  /// 起播位置（秒）。从「最近观看」直接续播时传入，
  /// 播放器初始化完成后自动跳到该位置。
  final int startAtSec;

  /// 本剧所属数据源（`zhuiju` / `kanju`），空串按当前源处理。
  ///
  /// 取址逻辑完全由数据源负责：橘汁是一次 playUrl，kanju 是两阶段
  /// resolve。播放器不该知道这些差异，也绝不能用「当前源」去解析
  /// 一条来自旧源的条目——那会拿着 av_ 长串去调数字 id 的接口。
  final String sourceId;

  const PlayerPage({
    super.key,
    required this.video,
    this.dramaName = '',
    this.cover = '',
    this.dramaId = '',
    this.sourceId = '',
    this.alternates = const [],
    this.sources = const {},
    this.startAtSec = 0,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _ctrl;

  /// 本条线路所属的数据源，进入页面时定死。
  ///
  /// 不能在每次取址时读「当前源」：播放中途用户可能在别处切了源，
  /// 那样换集会拿 A 源的 id 去 B 源解析，必然 404。
  late final DataSource _src =
      SourceRegistry.instance.byId(widget.sourceId);

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

  /// 当前投屏的设备名（null 表示没在投屏）。
  /// 用 Dlna.instance.session 也能查，但它是普通字段不触发重建，
  /// 状态条不会自己出现，所以这里保存一份并配合 setState。
  String? _castDeviceName;

  /// 本集是否已经处理过「播完」，防止 listener 每帧重复触发自动连播
  bool _autoNextHandled = false;

  /// 续播只做一次。
  ///
  /// widget.startAtSec 是「上次看到哪」的快照，只在进页面时有效。
  /// 换集/换源后如果还拿它去 seek，用户点了下一集却会被拽回上一集
  /// 的进度，是最容易被当成「换集没反应」的坑。
  bool _resumeApplied = false;

  /// 自动连播倒计时（null 表示没有在等待）
  Timer? _countdownTimer;
  int _countdown = 0;
  DramaVideo? _pendingNext;

  /// 轻提示（全屏时用自绘浮层，SnackBar 在横屏沉浸式下会被系统 UI 挡住）
  String? _notice;
  Timer? _noticeTimer;

  // ---------------- 手势 ----------------

  /// 画面亮度 0.15~1.0，用一层黑色遮罩实现。
  ///
  /// 为什么不调系统亮度：那要走原生通道，Android 需要 WRITE_SETTINGS 权限
  /// （用户得去系统设置里手动授权，劝退率高），Windows 端更是另一套 API。
  /// 遮罩层纯 Dart，三端行为一致、不需要任何权限，对看视频这个场景
  /// 已经够用（用户要的是「太亮了调暗点」，不是调台灯）。
  double _brightness = 1.0;

  /// 亮度遮罩层控制器：直接改 opacity 比重建整棵树便宜得多，
  /// 滑动时每帧 setState 会让整个播放页重建，手感会掉帧。
  final ValueNotifier<double> _brightnessFx = ValueNotifier<double>(0);

  /// 手势中正在显示哪个指示器（音量/亮度/快进）
  _GestureHud? _hud;

  /// 快进预览：滑动过程中显示的「目标位置」，松手才真正 seek。
  ///
  /// 边滑边 seek 会让解码器疯狂重定位，4K 片源直接卡死；
  /// 松手才跳转是 B 站/爱奇艺的做法。
  int? _seekPreview;

  /// 横向拖动开始时的基准位置（秒）
  int _seekBase = 0;

  /// 横向累计位移（像素）。用累计而不是单帧 delta，
  /// 因为单帧 delta 在低帧率下会丢精度，快速一划可能只走了几十秒。
  double _hDragDx = 0;

  /// 纵向累计位移（像素），向上为正
  double _vDragDy = 0;

  /// 纵向滑动：这次滑的是音量还是亮度（左半屏亮度、右半屏音量）
  bool _vDragIsVolume = false;

  /// 纵向滑动开始时的起始值（0~1），后续按位移增量累加，
  /// 不用「当前位置 ± 绝对位移」——那样手指一落就能让值从 0 跳到 1。
  double _vDragStart = 1.0;

  /// 手势指示器自动隐藏计时器
  Timer? _hudTimer;

  /// 指示器实时数值（0~1）。滑动时只改这个，不 setState 整页，
  /// 否则每帧重建播放页，滑动会明显掉帧。
  final ValueNotifier<double> _hudLevel = ValueNotifier<double>(0);

  /// 指示器文案（音量 45% / 亮度 80% / 01:23 / 45:00）
  final ValueNotifier<String> _hudText = ValueNotifier<String>('');

  /// 上一次点击的时间，用于手动判定双击。
  ///
  /// 不用 GestureDetector 的 onDoubleTap：它一旦注册，onTap 就必须
  /// 等约 300ms 的双击窗口过去才触发，用户点一下画面要等半拍控制条才出来，
  /// 手感明显发黏。这里自己计时，单击立刻响应，300ms 内来第二下就升级成双击。
  DateTime? _lastTapAt;

  /// 长按临时 2 倍速前的原倍速，松手恢复
  double? _speedBeforeBoost;

  /// 本集弹幕（按时间升序）；空列表表示本集确实没有弹幕
  List<DanmakuItem> _danmaku = const [];

  /// 弹幕是否已经拉取完成（用来区分「还在拉」和「确实没有」，
  /// 否则加载中就会先闪一下「本集暂无弹幕」）
  bool _dmLoaded = false;

  /// 当前源是否支持弹幕。
  ///
  /// 界面上所有弹幕相关的控件（空提示、全屏开关、竖屏开关）都必须
  /// 先过这一关：kanju 没有弹幕池，挂一个点了没反应的开关比不显示更糟。
  bool get _dmOn => _src.supportsDanmaku;

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
  ///
  /// 按「源名」缓存：同一线路下这 54 集是固定的，变的是 _cur。
  /// 原来每次访问都 List.from + sort 一遍，而这个 getter 在全文件里
  /// 被调用 10 次（下一集/上一集/下标/选集网格/竖屏选集/顶部标题…），
  /// 播放页每帧都可能触发其中几个，kanju 54 集时是实打实的重复开销。
  String? _epsCacheKey;
  List<DramaVideo>? _epsCache;

  List<DramaVideo> get _curEpisodes {
    final key = _srcKey(_cur);
    final cached = _epsCache;
    if (cached != null && _epsCacheKey == key) return cached;

    final list = widget.sources[key];
    final result = (list == null || list.isEmpty)
        ? <DramaVideo>[_cur]
        : (List<DramaVideo>.from(list)
          ..sort((a, b) => a.episode.compareTo(b.episode)));
    _epsCacheKey = key;
    _epsCache = result;
    return result;
  }

  /// 线路列表按等级排（直出在前、需二次解析的官方线在后）。
  ///
  /// 不能用 `widget.sources.keys.toList()`：kanju 一部剧 14~28 条线路，
  /// 接口原始顺序把官方线排在前面，面板第一屏全是「要登录」的那几条，
  /// 用户得往下翻很久才能找到真能播的直出线路。
  ///
  /// widget.sources 在页面生命周期内不变，排序结果只算一次。
  /// 每次 setState 都重排 28 条线路并计算等级，会白掉不少帧。
  List<String>? _namesCache;

  List<String> get _sourceNames => _namesCache ??= sortedSourceNames(
        widget.sources,
        pref: PlaybackPrefs.instance.linePref.value,
        policy: _src.lineOrderPolicy,
      );

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
    //
    // TV 也走这条路，理由更硬：遥控器按下左右键时，焦点可能正停在
    // 选集面板的某一集上，走 Focus 子树的话方向键会被「移动焦点」
    // 吃掉，根本到不了快进逻辑。全局监听才能保证按的每个键都落到
    // 播放控制上。
    if (isDesktop || tvModeOn) {
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
    if (isDesktop || tvModeOn) {
      HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    }
    // 离开播放页必须放开常亮，否则回到列表页手机还一直亮着屏。
    // 不 await：dispose 是同步的，且平台调用失败也不该拦住页面销毁。
    unawaited(ScreenAwake.release());
    _histTimer?.cancel();
    _countdownTimer?.cancel();
    _noticeTimer?.cancel();
    _hudTimer?.cancel();
    _brightnessFx.dispose();
    _hudLevel.dispose();
    _hudText.dispose();
    _saveHistory();
    _ctrl?.dispose();
    // 退出播放页时结束投屏：不主动 Stop，电视会停在最后一帧，
    // 用户还得自己拿遥控器退出投屏 App。异步发出即可，dispose 不能 await。
    if (Dlna.instance.session != null) {
      unawaited(Dlna.instance.stop());
    }
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
    final tv = tvModeOn;

    // 全屏时 Esc 由原生 WM_KEYDOWN 接管（会退出窗口全屏并回调），
    // 这里不再重复处理，避免一次按键退两次。
    if (k == LogicalKeyboardKey.escape) {
      if (_fullscreen && isDesktop) return KeyEventResult.handled;
      if (_showEpisodes || _showSources) {
        setState(() {
          _showEpisodes = false;
          _showSources = false;
        });
        return KeyEventResult.handled;
      }
      // TV 上没有 Esc，遥控器的返回键在 Flutter 里映射成 goBack，
      // 由 PopScope 接管；这里处理的是外接键盘场景。
      return KeyEventResult.ignored;
    }

    // ---- 遥控器「确定 / OK」键 ----
    //
    // 电视上的确定键在 Flutter 里是 select（对应 Android 的
    // KEYCODE_DPAD_CENTER），部分盒子报 enter。两种都认。
    //
    // 行为按主流电视播放器：控制条藏着时先呼出来，已经出来时切播放/暂停。
    // 直接做成「一按就暂停」的话，用户想调音量按一下确定，画面停了，
    // 反而添乱。
    if (tv &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter ||
            k == LogicalKeyboardKey.gameButtonA)) {
      if (_showEpisodes || _showSources) {
        // 面板开着时确定键不做事，交给面板里的焦点项处理
        return KeyEventResult.ignored;
      }
      if (!_showCtrl) {
        setState(() => _showCtrl = true);
        return KeyEventResult.handled;
      }
      if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
      c.value.isPlaying ? c.pause() : c.play();
      return KeyEventResult.handled;
    }

    // ---- 遥控器多媒体键 ----
    //
    // 不少遥控器（尤其电视自带的那种）带播放/暂停、快进、快退的专用键，
    // 上报的是 mediaPlayPause / mediaFastForward 这类 key。
    // 不处理的话这些键完全没反应，而它们恰恰是用户最想按的。
    if (tv) {
      if (k == LogicalKeyboardKey.mediaPlayPause) {
        if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
        c.value.isPlaying ? c.pause() : c.play();
        setState(() => _showCtrl = true);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.mediaPlay) {
        if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
        c.play();
        setState(() => _showCtrl = true);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.mediaPause) {
        if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
        c.pause();
        setState(() => _showCtrl = true);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.mediaFastForward ||
          k == LogicalKeyboardKey.mediaTrackNext) {
        if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
        _seekBy(c, const Duration(seconds: 10));
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.mediaRewind ||
          k == LogicalKeyboardKey.mediaTrackPrevious) {
        if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
        _seekBy(c, const Duration(seconds: -10));
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.mediaStop) {
        if (c == null) return KeyEventResult.ignored;
        c.pause();
        c.seekTo(Duration.zero);
        setState(() => _showCtrl = true);
        return KeyEventResult.handled;
      }
    }

    if (k == LogicalKeyboardKey.space) {
      if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
      c.value.isPlaying ? c.pause() : c.play();
      setState(() => _showCtrl = true);
      return KeyEventResult.handled;
    }

    // ---- 方向键 ----
    //
    // TV 上左右键被选中面板时应该用来选集/选源，而不是快进；
    // 但本项目的面板项是靠焦点系统走的，方向键会先被焦点消费掉，
    // 到不了这里（HardwareKeyboard 的 handler 在焦点之前）。
    // 所以这里统一按「快进/快退」处理，面板内的移动交给焦点系统：
    // 只要面板打开时把左右键让出去就行。
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      if (c == null || !c.value.isInitialized) return KeyEventResult.ignored;
      // 面板打开时左右键让给焦点系统（选集网格里横向移动）
      if (tv && (_showEpisodes || _showSources)) {
        return KeyEventResult.ignored;
      }
      // Shift + 方向键步子更大，和主流播放器一致
      final big = HardwareKeyboard.instance.isShiftPressed;
      final fwd = k == LogicalKeyboardKey.arrowRight;
      final secs = big ? 30 : 10;
      _seekBy(c, Duration(seconds: fwd ? secs : -secs));
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      if (c == null) return KeyEventResult.ignored;
      // 面板打开时上下键让给焦点系统（选集列表里纵向移动）
      if (tv && (_showEpisodes || _showSources)) {
        return KeyEventResult.ignored;
      }
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

  /// 相对当前位置跳转（负数表示后退），并夹在 [0, duration] 内
  void _seekBy(VideoPlayerController c, Duration delta) {
    final total = c.value.duration;
    var target = c.value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    c.seekTo(target);
    final secs = delta.inSeconds.abs();
    _showNotice('${delta.isNegative ? '快退' : '快进'} $secs 秒');
    setState(() => _showCtrl = true);
  }

  // ---------------- 手势：双击 / 滑动 / 长按 ----------------

  /// 双击播放/暂停
  ///
  /// 主流播放器（B 站、爱奇艺、YouTube）双击画面都是暂停，
  /// 单手操作时比去找底部那个小按钮方便得多。横屏全屏时尤其明显——
  /// 控制条会自动隐藏，想暂停还得先点一下唤出来。
  void _onDoubleTap() {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
      _showNotice('已暂停');
    } else {
      c.play();
      _showNotice('继续播放');
    }
    setState(() => _showCtrl = true);
  }

  /// 亮度调节：改遮罩透明度
  ///
  /// 遮罩 alpha = 1 - brightness，brightness 越低遮得越黑。
  /// 下限给 0.15 而不是 0：全黑等于看不见画面，用户会以为卡死了。
  void _applyBrightness(double v) {
    final b = v.clamp(0.15, 1.0);
    _brightness = b;
    _brightnessFx.value = (1 - b).clamp(0.0, 1.0);
    _keepHud(_GestureHud.brightness,
        level: b, text: '亮度 ${(b * 100).round()}%');
  }

  /// 音量调节：夹在 0~1，并给出百分比提示
  void _applyVolume(double v) {
    final c = _ctrl;
    if (c == null) return;
    final vol = v.clamp(0.0, 1.0);
    c.setVolume(vol);
    _keepHud(_GestureHud.volume,
        level: vol, text: vol <= 0 ? '静音' : '音量 ${(vol * 100).round()}%');
  }

  /// 显示指示器并重置自动隐藏计时
  ///
  /// [text] 是浮标上那行字。手指连续滑动时每帧都会调到这里，
  /// 所以只在类型变化时才 setState，数值和文案都走 ValueNotifier
  /// 单独刷新——否则每帧重建整个播放页，滑动明显掉帧。
  void _keepHud(_GestureHud kind, {double? level, String? text}) {
    if (level != null) _hudLevel.value = level.clamp(0.0, 1.0);
    if (text != null) _hudText.value = text;
    if (_hud != kind) {
      setState(() => _hud = kind);
    }
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() {
        _hud = null;
        _seekPreview = null;
      });
    });
  }

  /// 横向拖动结束：真正跳转
  ///
  /// 滑动过程中只更新 `_seekPreview`（界面显示目标时间），
  /// 松手才 seek。边滑边 seek 会让解码器不停重定位，
  /// 4K 片源直接卡死；这也是 B 站/爱奇艺的做法。
  void _commitSeek() {
    final c = _ctrl;
    final target = _seekPreview;
    if (c != null && target != null && c.value.isInitialized) {
      c.seekTo(Duration(seconds: target));
      _showNotice('已跳转到 ${_clock(target)}');
    }
    setState(() {
      _seekPreview = null;
      _hud = null;
    });
  }

  /// 长按开始：临时 2 倍速
  ///
  /// 记住原倍速，松手恢复。用户可能原本就用 1.25x 看，
  /// 直接恢复到 1.0x 会显得「长按一下把倍速搞乱了」。
  void _startBoost() {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (!c.value.isPlaying) return;
    _speedBeforeBoost = c.value.playbackSpeed;
    c.setPlaybackSpeed(2.0);
    _showNotice('2 倍速播放中，松手恢复');
  }

  /// 长按结束：恢复原倍速
  void _endBoost() {
    final c = _ctrl;
    final back = _speedBeforeBoost;
    _speedBeforeBoost = null;
    if (c == null || back == null || !c.value.isInitialized) return;
    c.setPlaybackSpeed(back);
  }

  /// 秒 → mm:ss / h:mm:ss
  String _clock(int sec) {
    if (sec < 0) sec = 0;
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
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
    // 取址策略完全下沉到数据源：橘汁「接口优先、直链兜底」、
    // kanju「resolve 拿线路 + resolve-line 换地址」都不该出现在页面里。
    // 这里只负责把结果翻译成一句给用户看的提示。
    final direct = ZhuijuApi.isDirectUrl(v.path) &&
        (v.path.endsWith('.m3u8') || v.path.endsWith('.mp4'));
    final u = await _src.resolveUrl(v);
    if (u.isNotEmpty && u != v.path) {
      _tip = direct ? '接口解析(CDN)' : '接口解析';
    } else if (u.isNotEmpty) {
      _tip = '直链';
    }
    return u;
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

    // 投屏中换集/换源：地址变了，同步推给电视。不等待结果，
    // 推流和本地播放器初始化各走各的，互不拖慢。
    if (Dlna.instance.session != null) {
      unawaited(_recast(url));
    }

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

      // 续播：仅首次进入、且调用方给了进度时跳一次。
      // 必须在 play() 之前 seek —— 先 play 再 seek，用户会先听到
      // 开头的几百毫秒声音再跳走，观感很差。
      if (!_resumeApplied && widget.startAtSec > 0) {
        _resumeApplied = true;
        final total = ctrl.value.duration;
        var target = Duration(seconds: widget.startAtSec);
        // 已经看到结尾（差 5 秒以内）就别再跳过去了，那样一进去就是
        // 结束画面、还会立刻触发自动连播。从头开始更符合预期。
        if (total > Duration.zero &&
            target >= total - const Duration(seconds: 5)) {
          target = Duration.zero;
        }
        if (target > Duration.zero) {
          try {
            await ctrl.seekTo(target);
            _tip = '已续播到 ${_mmss(target)}';
          } catch (_) {
            // seek 失败不影响正常播放，静默降级
          }
        }
      }

      // 投屏中：本地只解码、不出声也不继续走进度。
      // 换集/换源会走到这里，若照常 play()，手机会和电视同时播，
      // 两个声音叠在一起基本没法听。
      if (Dlna.instance.session != null) {
        await ctrl.pause();
        await ctrl.setVolume(0);
      } else {
        await ctrl.play();
      }

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
      // 真正开始播放后才保持常亮。放在这里而不是 initState：
      // 解析失败或一直转圈时不该阻止系统息屏，否则用户放着不管
      // 手机一直亮着，纯耗电。
      await ScreenAwake.set(true);
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
    final i = _curEpisodeIndex();
    final eps = _curEpisodes;
    if (i < 0 || i >= eps.length - 1) return null;
    return eps[i + 1];
  }

  /// 找到当前集的上一集；第一集返回 null
  ///
  /// 之前只有自动连播（播完才切下一集），想回看上一集只能退回详情页重选。
  /// 主流播放器（B站/爱奇艺/YouTube）都有显式的上一集/下一集按钮，
  /// 遥控器上更是刚需——没有它，看第二遍某一段要按很多次快退。
  DramaVideo? _prevEpisode() {
    final i = _curEpisodeIndex();
    if (i <= 0) return null;
    return _curEpisodes[i - 1];
  }

  /// 当前集在 _curEpisodes 里的下标（找不到返回 -1）
  int _curEpisodeIndex() {
    final eps = _curEpisodes;
    if (eps.length <= 1) return -1;
    var i = eps.indexWhere((e) => e.path == _cur.path);
    if (i < 0) i = eps.indexWhere((e) => e.epLabel == _cur.epLabel);
    return i;
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
    // 该源根本没有弹幕池（kanju），不必发请求、也不该显示「暂无弹幕」。
    // 这个能力位原来只在 DataSource 里定义、没人读，导致切到 kanju 后
    // 播放页仍会挂一个永远点不出东西的弹幕开关。
    if (!_src.supportsDanmaku) {
      if (mounted) setState(() => _dmLoaded = true);
      return;
    }
    // 本地播放/未知剧集时没有 id，直接标记完成，避免「暂无弹幕」永远不出现
    // danmaku 接口只认橘汁的数字 id，非数字（kanju 的 av_ 长串）也会被跳过
    if (id.isEmpty || ep <= 0) {
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
      // 记住这条记录属于哪个源：从「最近观看」回跳详情时按它取数据，
      // 否则切源后旧记录会拿错 id 去打另一个源
      sourceId: widget.sourceId.isNotEmpty
          ? widget.sourceId
          : SourceRegistry.instance.now.id,
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

  /// 把时长格式化成 mm:ss（超过 1 小时则是 h:mm:ss）
  String _mmss(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ---------------- 投屏 ----------------

  /// 打开设备列表并投屏。
  ///
  /// 投屏成功后把本地播放器暂停：电视和手机同时出声是最刺耳的体验，
  /// 而且手机继续解码会白耗电。用户点「停止投屏」再恢复本地播放。
  Future<void> _openCast() async {
    if (_realUrl.isEmpty) {
      _toast('地址还没解析好，稍等一下');
      return;
    }
    // 记录当前地址：用户在列表里挑设备的这几秒里可能刚好换集，
    // 推流必须用「点确定那一刻」的最新地址。
    await showCastSheet(
      context,
      onPick: (d) async {
        final url = _realUrl;
        if (url.isEmpty) return false;
        final title = widget.dramaName.isEmpty
            ? _cur.epLabel
            : '${widget.dramaName} ${_cur.epLabel}';
        final ok = await Dlna.instance.play(d, url, title: title);
        if (!ok || !mounted) return ok;
        // 本地静音并暂停，画面留着方便用户看进度
        await _ctrl?.pause();
        setState(() => _castDeviceName = d.name);
        _toast('已投屏到 ${d.name}');
        return true;
      },
    );
  }

  Future<void> _stopCast() async {
    await Dlna.instance.stop();
    if (!mounted) return;
    setState(() => _castDeviceName = null);
    // 恢复本地播放：用户点「停止投屏」通常就是想接着在手机上看了
    try {
      await _ctrl?.play();
    } catch (_) {}
    _toast('已停止投屏');
  }

  /// 投屏中换集/换源：把新地址重新推给同一台电视。
  ///
  /// 不重新推的话，手机已经播下一集、电视还停在上一集，
  /// 用户会以为「投屏后选集失效了」。
  Future<void> _recast(String url) async {
    final s = Dlna.instance.session;
    if (s == null) return;
    final title = widget.dramaName.isEmpty
        ? _cur.epLabel
        : '${widget.dramaName} ${_cur.epLabel}';
    final ok = await Dlna.instance.play(s.device, url, title: title);
    if (!mounted) return;
    if (!ok) {
      _toast('换集后重新投屏失败，请手动停止再投一次');
    }
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
    final out = switchCandidates(
      widget.sources,
      _cur,
      tried: _triedSrc,
      pref: PlaybackPrefs.instance.linePref.value,
      policy: _src.lineOrderPolicy,
    );

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
          style: const TextStyle(fontSize: Ts.subtitle),
        ),
        actions: [
          // 投屏只在 Android 提供：DLNA 走的是局域网 SSDP 多播，
          // 桌面端虽然技术上能发，但用户投屏的对象通常是客厅电视，
          // 且本地 HLS 代理地址（127.0.0.1）电视根本访问不到。
          if (!isDesktop && _realUrl.isNotEmpty)
            IconButton(
              tooltip: _castDeviceName == null ? '投屏' : '投屏中',
              icon: Icon(_castDeviceName == null
                  ? Icons.cast_rounded
                  : Icons.cast_connected_rounded),
              color: _castDeviceName == null ? null : kAccent,
              onPressed: _openCast,
            ),
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
          // 技术信息入口。原来是内容区里一整块常驻面板，用户反馈两件事：
          // 一是固定黑底不跟主题走（浅色模式下一条突兀的黑带），
          // 二是太占位置。现在收进标题栏，点开是跟主题色的底部弹窗，
          // 平时一行都不占。排障信息本来就该是「需要时才看」的东西。
          IconButton(
            tooltip: '技术信息',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: _openTechSheet,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  /// 统一手势层：单击显隐 / 双击暂停 / 左右快进 / 上下调亮度音量 / 长按倍速
  ///
  /// 为什么自己算双击而不挂 onDoubleTap：见 `_lastTapAt` 的注释——
  /// 挂了 onDoubleTap 之后单击要等 300ms 才响应，控制条出来会慢半拍。
  ///
  /// 为什么横纵滑动都交给同一个 GestureDetector：它们会进同一个
  /// 手势竞技场，由首帧位移方向决定谁胜出。拆成两层嵌套反而会让
  /// 外层抢走内层的手势，出现「横滑偶尔变成调速」这类随机 bug。
  Widget _gestureLayer({required Widget child, bool enabled = true}) {
    return GestureDetector(
      // 不拦截面板上的点击：面板自己在外层，这里只处理画面区域
      behavior: HitTestBehavior.opaque,

      onTapUp: (d) {
        final now = DateTime.now();
        final last = _lastTapAt;
        _lastTapAt = now;
        // 300ms 内的第二下 → 双击暂停
        if (last != null &&
            now.difference(last) < const Duration(milliseconds: 300)) {
          _lastTapAt = null;
          _onDoubleTap();
          return;
        }
        // 单击：立刻响应，不等双击窗口
        setState(() {
          _showCtrl = !_showCtrl;
          if (!_showCtrl) {
            _showEpisodes = false;
            _showSources = false;
          }
        });
      },

      onHorizontalDragStart: enabled
          ? (d) {
              final c = _ctrl;
              if (c == null || !c.value.isInitialized) return;
              _hDragDx = 0;
              _seekBase = c.value.position.inSeconds;
              _seekPreview = _seekBase;
            }
          : null,

      onHorizontalDragUpdate: enabled
          ? (d) {
              final c = _ctrl;
              if (c == null || !c.value.isInitialized) return;
              _hDragDx += d.delta.dx;
              // 每秒对应多少像素：按屏幕宽度折算，宽屏滑一下跨度更大。
              // 1080p 手机横屏约 2400 逻辑像素，÷90 得到每秒 ~26px，
              // 划满一屏约 90 秒，和 B 站手感接近。
              final w = MediaQuery.of(context).size.width;
              final secPerPx = 90 / (w <= 0 ? 800 : w);
              final total = c.value.duration.inSeconds;
              var target = _seekBase + (_hDragDx * secPerPx).round();
              if (target < 0) target = 0;
              if (total > 0 && target > total) target = total;
              _seekPreview = target;
              // 实时更新指示器的进度条与时间文字，但不 setState 整页
              _keepHud(
                _GestureHud.seek,
                level: total <= 0 ? 0 : target / total,
                text: '${_clock(target)} / ${_clock(total)}',
              );
            }
          : null,

      onHorizontalDragEnd: enabled ? (_) => _commitSeek() : null,

      onVerticalDragStart: enabled
          ? (d) {
              _vDragDy = 0;
              // 左半屏调亮度、右半屏调音量，和主流播放器一致。
              // 用按下点的横坐标判断，不是手指之后滑到哪——
              // 否则从左边滑到右边会中途从亮度切成音量，数值直接跳。
              final w = MediaQuery.of(context).size.width;
              _vDragIsVolume = d.globalPosition.dx > w / 2;
              final c = _ctrl;
              _vDragStart = _vDragIsVolume
                  ? (c?.value.volume ?? 1.0)
                  : _brightness;
            }
          : null,

      onVerticalDragUpdate: enabled
          ? (d) {
              _vDragDy += d.delta.dy;
              // 向上滑是增大，所以取负；除以屏高再放大 1.4 倍，
              // 让「从屏幕底部滑到顶部」大致走完 0~1 的全程。
              final h = MediaQuery.of(context).size.height;
              final delta = -_vDragDy / (h <= 0 ? 800 : h) * 1.4;
              final v = _vDragStart + delta;
              if (_vDragIsVolume) {
                _applyVolume(v);
              } else {
                _applyBrightness(v);
              }
            }
          : null,

      onVerticalDragEnd: enabled
          ? (_) {
              // 数值已经在滑动过程中生效了，这里只收起指示器
              _hudTimer?.cancel();
              _hudTimer = Timer(const Duration(milliseconds: 400), () {
                if (!mounted) return;
                setState(() => _hud = null);
              });
            }
          : null,

      onLongPressStart: enabled ? (_) => _startBoost() : null,
      onLongPressEnd: enabled ? (_) => _endBoost() : null,
      // 长按被系统打断（来电、切后台）也要恢复倍速，
      // 否则回来就是一直 2 倍速，用户会以为播放器坏了
      onLongPressCancel: enabled ? _endBoost : null,

      child: child,
    );
  }

  /// 全屏布局：视频铺满，控制条浮在底部，点画面切换显隐
  Widget _fullscreenBody() {
    final c = _ctrl;
    final inited = c != null && c.value.isInitialized;
    return _gestureLayer(
      enabled: inited,
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
                                          fontSize: Ts.subtitle,
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            if (_dmOn && _danmaku.isEmpty && _dmLoaded)
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

            // 亮度遮罩：压在画面之上、控制条之下。
            // 若放在控制条之上，按钮会跟着一起变暗，用户滑到很暗时
            // 连「退出全屏」都找不着了。
            _brightnessOverlay(),

            // 顶部：标题 + 选集/换源 + 退出全屏
            if (_showCtrl)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _fullscreenTopBar(),
              ),

            // 投屏状态条：贴在顶栏下方。跟着控制条一起显隐，
            // 否则沉浸看片时一条横幅会一直压在画面上。
            if (_showCtrl && _castDeviceName != null)
              Positioned(
                top: 48,
                left: 0,
                right: 0,
                child: SafeArea(
                  top: false,
                  bottom: false,
                  child: CastBar(
                    deviceName: _castDeviceName!,
                    onStop: _stopCast,
                  ),
                ),
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
                          // 无弹幕池的源（kanju）不显示，否则是个死开关。
                          if (_dmOn) const DanmakuToggleButton(),
                          // 下一集：枕在沙发上看剧最高频的动作。
                          // 原来全屏只能等播完自动连播，或者退出全屏去选集，
                          // 和主流播放器（B站/爱奇艺的「下一集」）差得很远。
                          if (_nextEpisode() != null)
                            IconButton(
                              iconSize: 22,
                              color: Colors.white,
                              tooltip: '下一集',
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              constraints: const BoxConstraints(
                                  minWidth: 34, minHeight: 34),
                              icon: const Icon(Icons.skip_next_rounded),
                              onPressed: () {
                                final n = _nextEpisode();
                                if (n != null) _playEpisode(n);
                              },
                            ),
                          // 投屏：横屏看剧时想换到大屏是高频动作
                          if (!isDesktop && _realUrl.isNotEmpty)
                            IconButton(
                              iconSize: 22,
                              color: _castDeviceName == null
                                  ? Colors.white
                                  : kAccent,
                              tooltip: '投屏',
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              constraints: const BoxConstraints(
                                  minWidth: 34, minHeight: 34),
                              icon: Icon(_castDeviceName == null
                                  ? Icons.cast_rounded
                                  : Icons.cast_connected_rounded),
                              onPressed: _openCast,
                            ),
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

            // 手势指示器（音量/亮度/快进预览）
            if (_hud != null && !_showSources && !_showEpisodes) _gestureHud(),

            // 自动连播倒计时
            if (_pendingNext != null) _autoNextCard(),

            // 轻提示
            if (_notice != null) _noticeBar(),
          ],
        ),
      ),
    );
  }

  /// 亮度遮罩层。
  ///
  /// 用 IgnorePointer 包住：这层铺满整个画面，一旦参与命中测试，
  /// 下面所有手势和按钮都会点不到。
  Widget _brightnessOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<double>(
          valueListenable: _brightnessFx,
          builder: (c, v, _) => v <= 0
              ? const SizedBox.shrink()
              : ColoredBox(color: Colors.black.withValues(alpha: v)),
        ),
      ),
    );
  }

  /// 手势指示器：音量 / 亮度 / 快进预览，显示在画面正上方居中
  ///
  /// 数值和文字都走 ValueListenable：滑动过程中每帧都在变，
  /// 用 setState 会让整个播放页（含视频、弹幕、控制条）跟着重建，
  /// 实机上表现为越滑越卡。这里只重建这个几十像素的浮标。
  Widget _gestureHud() {
    final kind = _hud!;
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(R.panel),
            ),
            child: ValueListenableBuilder<double>(
              valueListenable: _hudLevel,
              builder: (c, level, _) => ValueListenableBuilder<String>(
                valueListenable: _hudText,
                builder: (c, text, _) {
                  final mute = kind == _GestureHud.volume && level <= 0;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        switch (kind) {
                          _GestureHud.seek => Icons.fast_forward_rounded,
                          _GestureHud.volume => mute
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          _GestureHud.brightness => Icons.brightness_6_rounded,
                        },
                        color: Colors.white,
                        size: 26,
                      ),
                      const SizedBox(height: 8),
                      Text(text,
                          style: const TextStyle(
                              fontSize: Ts.body,
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                      // 快进时进度条没有意义（用户看的是时间），隐掉
                      if (kind != _GestureHud.seek) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: 132,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(R.bar),
                            child: LinearProgressIndicator(
                              value: level.clamp(0.0, 1.0),
                              minHeight: 4,
                              backgroundColor: Colors.white24,
                              valueColor:
                                  const AlwaysStoppedAnimation(kAccent),
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
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
                    fontSize: Ts.bodyLg,
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
      label: Text(label, style: const TextStyle(fontSize: Ts.body)),
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
                              fontSize: Ts.bodyLg,
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
    final tv = tvModeOn;
    return GridView.builder(
      padding: padding ?? const EdgeInsets.fromLTRB(12, 4, 12, 16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: tv ? 1.5 : 1.75,
      ),
      itemCount: eps.length,
      itemBuilder: (c, i) {
        final e = eps[i];
        final active = e.path == _cur.path;
        final body = GestureDetector(
          onTap: () => _playEpisode(e),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? kAccent : Colors.white12,
              borderRadius: BorderRadius.circular(R.sm),
            ),
            child: Text(
              e.epLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: tv ? Ts.bodyLg : Ts.bodySm,
                color: active ? Colors.white : Colors.white70,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        );
        if (!tv) return body;
        return TvFocus(
          radius: 7,
          onActivate: () => _playEpisode(e),
          child: body,
        );
      },
    );
  }

  Widget _sourceList() {
    final cur = _srcKey(_cur);
    final tv = tvModeOn;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      itemCount: _sourceNames.length,
      itemBuilder: (c, i) {
        final n = _sourceNames[i];
        final active = n == cur;
        final cnt = widget.sources[n]?.length ?? 0;
        final body = GestureDetector(
          onTap: active ? null : () => _switchToSource(n),
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: 12, vertical: tv ? Ts.bodyLg : Ts.caption),
            decoration: BoxDecoration(
              color: active ? kAccent.withValues(alpha: 0.18) : Colors.white10,
              borderRadius: BorderRadius.circular(R.card),
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
                      fontSize: tv ? Ts.subtitle : Ts.body,
                      color: active ? kAccent : Colors.white,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                Text('$cnt 集',
                    style: TextStyle(
                        fontSize: tv ? Ts.body : Ts.caption,
                        color: Colors.white38)),
                if (active) ...[
                  const SizedBox(width: 6),
                  Text('播放中',
                      style: TextStyle(
                          fontSize: tv ? Ts.body : Ts.caption, color: kAccent)),
                ],
              ],
            ),
          ),
        );
        if (!tv) {
          return Padding(padding: const EdgeInsets.only(bottom: 8), child: body);
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TvFocus(
            radius: 8,
            onActivate: () {
              if (!active) _switchToSource(n);
            },
            child: body,
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
            borderRadius: BorderRadius.circular(R.card),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$_countdown 秒后自动播放 ${n.epLabel}',
                style: const TextStyle(fontSize: Ts.body, color: Colors.white),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _cancelAutoNext,
                style: TextButton.styleFrom(
                  foregroundColor: kAccent,
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('取消', style: TextStyle(fontSize: Ts.body)),
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
              borderRadius: BorderRadius.circular(R.pill),
            ),
            child: Text(
              _notice!,
              style: const TextStyle(fontSize: Ts.body, color: Colors.white),
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
      backgroundColor: kVideoCard,
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
                            fontSize: Ts.subtitle, fontWeight: FontWeight.w600)),
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
                          color: active ? kAccent : kVideoBg,
                          borderRadius: BorderRadius.circular(R.card),
                        ),
                        child: Text(
                          e.epLabel,
                          style: TextStyle(
                            fontSize: Ts.bodySm,
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
                style: TextStyle(color: kOnVideoDim, fontSize: Ts.bodySm)),
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
            // 信息区：只要拿到地址就一直可用。
            // 分区式布局，见 [_portraitInfo]。
            Expanded(
              child: Container(
                width: double.infinity,
                color: context.palette.card,
                child: _portraitInfo(),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 竖屏信息区：分区式布局（参考主流播放页）。
  ///
  /// 旧版是黑底上垂直堆一串按钮，线路和选集都要点弹窗才看得到，
  /// 层次全靠间距硬撑。现在按「剧名 → 功能图标 → 来源 → 选集」分区，
  /// 线路和选集直接横排可见，并把上一集/下一集做成常显按钮：
  /// 第一集/最后一集时置灰而不是消失，位置永远固定。
  ///
  /// 配色跟随主题：浅色主题下是白色内容区（视频区仍为黑色），
  /// 控制条和技术信息单独装进深色面板，避免白底白字。
  Widget _portraitInfo() {
    final p = context.palette;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_castDeviceName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: CastBar(
                  deviceName: _castDeviceName!, onStop: _stopCast),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.dramaName.isEmpty ? _cur.epLabel : widget.dramaName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: Ts.title,
                    fontWeight: FontWeight.w700,
                    color: p.onSurface,
                    height: Lh.title,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _portraitBadge(_isSeries ? '共 ${_curEpisodes.length} 集' : '单集'),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              _cur.epLabel,
              if (_cur.sourceCn.isNotEmpty) _cur.sourceCn else _cur.source,
              if (_tip.isNotEmpty) _tip,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: Ts.bodySm, color: p.textDim),
          ),
          const SizedBox(height: 16),
          _portraitActions(),
          // 技术信息已移到标题栏的信息按钮里（见 AppBar 的 actions）。
          // 它只是排障用，常驻一块面板既占竖直空间、又因为固定黑底
          // 在浅色主题下突兀地切成一条黑带，是竖屏页里最"碍眼"的一行。
          const SizedBox(height: 18),
          _portraitSectionTitle('来源', trailing: '${_sourceNames.length} 个可用'),
          const SizedBox(height: 10),
          _portraitSourceChips(),
          const SizedBox(height: 18),
          _portraitSectionTitle('选集', right: _portraitEpisodeNav()),
          const SizedBox(height: 10),
          _portraitEpisodeChips(),
        ],
      ),
    );
  }

  Widget _portraitBadge(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: context.palette.bg,
          borderRadius: BorderRadius.circular(R.sm),
        ),
        child: Text(s,
            style: TextStyle(
                fontSize: Ts.caption, color: context.palette.textDim)),
      );

  Widget _portraitSectionTitle(
    String title, {
    String? trailing,
    Widget? right,
  }) {
    final p = context.palette;
    return Row(
      children: [
        Text(title,
            style: TextStyle(
                fontSize: Ts.subtitle,
                fontWeight: FontWeight.w700,
                color: p.onSurface)),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(trailing,
              style: TextStyle(fontSize: Ts.bodySm, color: p.textDim)),
        ],
        const Spacer(),
        if (right != null) right,
      ],
    );
  }

  /// 图标 + 文字竖排，与参考设计的五个功能入口一致。
  /// 只放我们真实有的能力，不摆「一起看」这类点了没反应的假按钮。
  Widget _portraitActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _portraitAction(
            Icons.refresh_rounded, '重新解析', () => _resolve()),
        if (_canSwitch)
          _portraitAction(
              Icons.swap_horiz_rounded, '换源', () => _switchSource()),
        _portraitAction(Icons.download_rounded, '下载',
            _realUrl.isEmpty ? null : () => _download()),
        if (!isDesktop && _realUrl.isNotEmpty)
          _portraitAction(Icons.cast_rounded, '投屏', () => _openCast()),
        if (_isSeries)
          _portraitAction(Icons.grid_view_rounded, '选集',
              () => _openEpisodeSheet(context)),
      ],
    );
  }

  Widget _portraitAction(IconData icon, String label, VoidCallback? onTap) {
    final p = context.palette;
    final c = onTap == null
        ? p.textDim.withValues(alpha: 0.45)
        : p.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(R.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: c),
            const SizedBox(height: 5),
            Text(label, style: TextStyle(fontSize: Ts.caption, color: c)),
          ],
        ),
      ),
    );
  }

  /// 线路横排 chip，右上角带集数角标（参考设计的「自建蓝光 30」）。
  Widget _portraitSourceChips() {
    final p = context.palette;
    final cur = _srcKey(_cur);
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _sourceNames.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final n = _sourceNames[i];
          final active = n == cur;
          final cnt = widget.sources[n]?.length ?? 0;
          return GestureDetector(
            onTap: active ? null : () => _switchToSource(n),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? kAccent.withValues(alpha: 0.12) : p.bg,
                borderRadius: BorderRadius.circular(R.card),
                border: active ? Border.all(color: kAccent) : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    n,
                    style: TextStyle(
                      fontSize: Ts.body,
                      color: active ? kAccent : p.onSurface,
                      fontWeight:
                          active ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                  if (cnt > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: p.divider,
                        borderRadius: BorderRadius.circular(R.sm),
                      ),
                      child: Text('$cnt',
                          style: TextStyle(
                              fontSize: Ts.caption, color: p.textDim)),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 上一集 / 下一集：**两个按钮永远都在**。
  ///
  /// 第一集时上一集置灰、最后一集时下一集置灰，单集剧两个都置灰。
  /// 旧版 `_episodeNav` 在两个方向都为空时整块隐藏，用户反馈
  /// 「上一集、下一集都显示出来」——位置跳动比按钮不可用更难用。
  Widget _portraitEpisodeNav() {
    final prev = _prevEpisode();
    final next = _nextEpisode();
    return EpisodeNavBar(
      onPrev: prev == null ? null : () => _playEpisode(prev),
      onNext: next == null ? null : () => _playEpisode(next),
    );
  }

  /// 选集横排，编号补零成 01 / 02，当前集高亮。
  Widget _portraitEpisodeChips() {
    final p = context.palette;
    final eps = _curEpisodes;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: eps.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final e = eps[i];
          final active = e.path == _cur.path;
          return GestureDetector(
            onTap: () => _playEpisode(e),
            child: Container(
              width: 58,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? kAccent : p.bg,
                borderRadius: BorderRadius.circular(R.card),
              ),
              child: Text(
                e.episode > 0
                    ? e.episode.toString().padLeft(2, '0')
                    : e.epLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Ts.bodyLg,
                  color: active ? Colors.white : p.onSurface,
                  fontWeight:
                      active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 技术信息：跟随主题的底部弹窗。
  ///
  /// 原来是内容区里一块常驻面板，两个问题（用户实测反馈）：
  ///   1. 底色写死 `kVideoBg`（纯黑），浅色主题下像一条硬切的黑带；
  ///   2. 占一整行高度，而它只是排障时才看的东西。
  ///
  /// 现在改成标题栏一个图标入口 + 按需弹出的 sheet：
  ///   - 背景用 `palette.card`、文字用 `palette.onSurface` / `textDim`，
  ///     深浅色主题都自动适配，不需要再写 `kOnVideoDim` 这种固定色；
  ///   - 关闭后一行都不占，竖屏的信息区因此能多放内容。
  void _openTechSheet() {
    final p = context.palette;
    final rows = <(String, String)>[
      ('播放地址', _realUrl.isEmpty ? '（尚未解析出地址）' : _realUrl),
      ('当前线路', _srcKey(_cur)),
      ('剧集 / 集数', '${widget.dramaName.isEmpty ? _cur.epLabel : widget.dramaName}'
          ' · ${_cur.epLabel}'),
      ('可用来源', '${_sourceNames.length} 个'),
      ('解析方式', _realUrl.contains('127.0.0.1') ? '本地 HLS 代理' : '直连'),
    ];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.card,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: ConstrainedBox(
          // 地址可能很长，限制最大高度并允许内部滚动，
          // 免得竖屏小屏上一弹就顶到状态栏。
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('技术信息',
                    style: TextStyle(
                      fontSize: Ts.subtitle,
                      fontWeight: FontWeight.w600,
                      color: p.onSurface,
                    )),
                const SizedBox(height: 4),
                Text('排障用，正常观看不需要关心',
                    style: TextStyle(fontSize: Ts.caption, color: p.textDim)),
                const SizedBox(height: 14),
                for (final (k, v) in rows) ...[
                  Text(k,
                      style: TextStyle(
                          fontSize: Ts.caption, color: p.textDim)),
                  const SizedBox(height: 3),
                  SelectableText(
                    v,
                    style: TextStyle(
                        fontSize: Ts.bodySm, color: p.onSurface),
                  ),
                  const SizedBox(height: 12),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: _realUrl.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: _realUrl));
                            Navigator.pop(ctx);
                            _toast('地址已复制');
                          },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('复制播放地址'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
                                        fontSize: Ts.subtitle,
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          if (_dmOn && _danmaku.isEmpty && _dmLoaded && inited)
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
                      extraActions: [
                        if (_dmOn) const DanmakuToggleButton(),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 右栏
        Container(
          width: 340,
          color: kVideoBg,
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
                        fontSize: Ts.subtitle,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${_cur.epLabel} · ${_srcKey(_cur)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: Ts.bodySm, color: kOnVideoDim),
                    ),
                    const SizedBox(height: 10),
                    if (_castDeviceName != null)
                      CastBar(
                        deviceName: _castDeviceName!,
                        onStop: _stopCast,
                      ),
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
                          fontSize: Ts.body, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isSeries
                          ? '共 ${_curEpisodes.length} 集'
                          : '${_sourceNames.length} 个源',
                      style: const TextStyle(fontSize: Ts.caption, color: kOnVideoDim),
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

    final video = _gestureLayer(
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
                            fontSize: Ts.bodySm,
                            travel: const Duration(milliseconds: 6500),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              if (_dmOn && _danmaku.isEmpty && _dmLoaded) const DanmakuEmptyHint(),
              // 亮度遮罩：压在画面之上、控制条之下，理由同全屏
              _brightnessOverlay(),
              if (_showCtrl) _overlay(c),
              if (_hud != null) _gestureHud(),
              if (_pendingNext != null)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(R.card),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$_countdown 秒后播放 ${_pendingNext!.epLabel}',
                            style: const TextStyle(
                                fontSize: Ts.bodySm, color: Colors.white)),
                        TextButton(
                          onPressed: _cancelAutoNext,
                          style: TextButton.styleFrom(
                            foregroundColor: kAccent,
                            minimumSize: const Size(0, 26),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                          child: const Text('取消',
                              style: TextStyle(fontSize: Ts.bodySm)),
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
    //
    // **容器高度必须取「画面自然高度」和「上限」的较小值**，
    // 不能直接给 maxHeight：截面截图里视频上方那块大黑边就是这么来的——
    // 16:9 片在 62% 限高的盒子里只需要 宽度×0.56 的高度，剩下的
    // 140+ dp 全被 Center 均分成上下黑边，视觉上像「视频被推到了下面」。
    // 改成按需收缩后，盒子恰好贴合画面，黑边消失，省下的高度让给信息区。
    final frame = maxHeight == null
        ? video
        : LayoutBuilder(
            builder: (lctx, box) {
              final w = box.maxWidth.isFinite
                  ? box.maxWidth
                  : MediaQuery.sizeOf(lctx).width;
              final natural = w / aspect;
              final h = natural < maxHeight ? natural : maxHeight;
              return Container(
                color: Colors.black,
                width: double.infinity,
                height: h,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: video,
                  ),
                ),
              );
            },
          );

    // 控制条浮在视频区域底部（不是另起一块黑色面板）。
    // 竖屏常显：视频区只占一屏的 62%，下面紧接信息区，没有「沉浸观看」
    // 的场景；点一下画面就把进度条藏起来，只会让用户以为控制条没了。
    // 显隐切换留给全屏（[_fullscreenBody]），那才是需要清爽画面的地方。
    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        frame,
        _floatingControls(c),
      ],
    );
  }

  /// 浮在视频画面底部的控制条。
  ///
  /// 主流播放器（橘汁 / B站 / 爱奇艺）都把播放控制压在视频区域内：
  /// 拖进度、倍速、全屏不用离开画面往下滚。原来它被塞进信息区一个
  /// 独立黑面板里，和画面分家，是竖屏页最明显的违和点。
  ///
  /// 渐变背景而不是纯色块：白字在亮画面上也读得清，又不会硬切掉
  /// 画面底部一条。外层 GestureDetector 吃掉渐变区的点击，否则
  /// [_gestureLayer] 会把它当成「点画面」而切换显隐。
  Widget _floatingControls(VideoPlayerController c) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(8, 18, 8, 2),
        child: PlayerControlBar(
          ctrl: c,
          fullscreen: false,
          onToggleFullscreen: _toggleFullscreen,
          extraActions: [
            if (_dmOn) const DanmakuToggleButton(),
          ],
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
              style: TextStyle(fontSize: Ts.caption, color: kOnVideoDim)),
      ],
    );
  }

  /// 上一集 / 下一集
  ///
  /// 只在真的有相邻集时才出现；对应方向没有集时按钮禁用而不是隐藏——
  /// 位置固定，用户不用每次重新找「下一集在哪」。
  Widget _episodeNav() {
    final prev = _prevEpisode();
    final next = _nextEpisode();
    if (prev == null && next == null) return const SizedBox.shrink();
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: prev == null ? null : () => _playEpisode(prev),
            icon: const Icon(Icons.skip_previous_rounded, size: 19),
            label: Text(
              prev == null ? '已是第一集' : '上一集',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: next == null ? null : () => _playEpisode(next),
            icon: const Icon(Icons.skip_next_rounded, size: 19),
            label: Text(
              next == null ? '已是最后一集' : '下一集',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  Widget _actionButtons() {
    final row = Row(
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

    // 版式从「功能密度」而不是「有什么就堆什么」出发：
    //   1. 上一集/下一集   —— 追剧最高频，放最上面、整行大按钮
    //   2. 投屏            —— 次高频，整行
    //   3. 重新解析/换源/下载 —— 兜底操作，挤在一行
    // 之前把「重新解析」放在第一行最左，用户最常点的「下一集」根本不存在，
    // 只能等自动连播——和主流播放器的习惯差得很远。
    final hasNav = _prevEpisode() != null || _nextEpisode() != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasNav) ...[
          _episodeNav(),
          const SizedBox(height: 10),
        ],
        if (!isDesktop && _realUrl.isNotEmpty) ...[
          OutlinedButton.icon(
            onPressed: _openCast,
            icon: Icon(_castDeviceName == null
                ? Icons.cast_rounded
                : Icons.cast_connected_rounded),
            label: Text(_castDeviceName == null
                ? '投屏到电视'
                : '投屏中 · $_castDeviceName（点此切换设备）'),
          ),
          const SizedBox(height: 10),
        ],
        row,
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
          color: dim ? kVideoCard : kAccent.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(R.sm),
        ),
        child: Text(
          s,
          style: TextStyle(
            fontSize: Ts.caption,
            color: dim ? kOnVideoDim : kAccent,
          ),
        ),
      );
}