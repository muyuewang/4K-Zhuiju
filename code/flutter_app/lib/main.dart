import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'core/desktop_window.dart';
import 'core/download.dart';
import 'core/history.dart';
import 'core/layout.dart';
import 'core/theme_settings.dart';
import 'core/version.dart';
import 'pages/home_page.dart';
import 'pages/profile_page.dart';
import 'theme.dart';
import 'widgets/danmaku_overlay.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端崩溃要能定位。Release 版默认把异常吞成一块灰/白屏，
  // 用户在 Windows 上没有 logcat 可看，只能靠这里的输出落到 stderr。
  FlutterError.onError = (details) {
    debugPrint('[ERR] ${details.exceptionAsString()}');
    debugPrint('[ERR] ${details.stack}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[ERR] uncaught: $error');
    debugPrint('[ERR] $stack');
    return true;
  };
  // 绝不能在这里 await 磁盘恢复。
  //
  // 之前是 `await DownloadManager.restore()` + `await HistoryStore.restore()`
  // 之后才 runApp()，实测打开 App 要白屏很久才看到推荐页：
  //   - restore() 要先 getExternalStorageDirectory()（一次 binder 调用），
  //     再读 .tasks.json，然后对**每个**已完成任务做 File.exists()。
  //     任务多、文件在慢速外部存储上时，这一段是几百毫秒到数秒。
  //   - 这段时间 Flutter 连第一帧都没画，用户看到的就是纯白（或黑）屏。
  //   - 原来 launch_background 还是 @android:color/white，于是「白屏」。
  //
  // 现在改成：立刻 runApp 出 UI，恢复动作丢到后台跑。
  // 两个 store 都基于 ValueNotifier/Stream 通知，读完界面会自己刷新，
  // 不需要在启动路径上阻塞。restore() 内部有 _loaded 幂等保护。
  unawaited(_restoreInBackground());
  runApp(const ZhuijuApp());
}

Future<void> _restoreInBackground() async {
  // 顺序执行而不是并发：两者都要读外部存储，并发只会互相抢 IO，
  // 而且下载索引更大，先把它读出来，界面（首页/我的）就能先有内容。
  try {
    await DownloadManager.instance.restore();
  } catch (e) {
    debugPrint('[BOOT] download restore failed: $e');
  }
  try {
    await HistoryStore.instance.restore();
  } catch (e) {
    debugPrint('[BOOT] history restore failed: $e');
  }
  // 弹幕开关很小（一个 bool），放在最后读：它只影响播放页，
  // 而且 SharedPreferences 首次调用要加载整个 xml，不该挡在下载索引前面。
  try {
    await DanmakuSettings.instance.restore();
  } catch (e) {
    debugPrint('[BOOT] danmaku prefs restore failed: $e');
  }
  // 主题和弹幕开关同在 SharedPreferences，实例已缓存，这里几乎零成本。
  // 读到后 ThemeSettings.mode 会 notify，MaterialApp 自动换肤，
  // 所以首帧可能先按系统主题画一次再切换——这是刻意的取舍，
  // 不为一个设置项把启动路径改成 await。
  try {
    await ThemeSettings.instance.restore();
  } catch (e) {
    debugPrint('[BOOT] theme prefs restore failed: $e');
  }
  debugPrint('[BOOT] restore done');
}

class ZhuijuApp extends StatefulWidget {
  const ZhuijuApp({super.key});

  @override
  State<ZhuijuApp> createState() => _ZhuijuAppState();
}

class _ZhuijuAppState extends State<ZhuijuApp> {
  @override
  void initState() {
    super.initState();
    // 窗口能力（最小尺寸 / Esc 退出全屏）要等引擎起来才可用，
    // 放在首帧之后，失败也不该影响主流程。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(initDesktopWindow());
    });
  }

  @override
  Widget build(BuildContext context) {
    // 订阅主题设置：用户切一次主题，这里重建一次，
    // 下面所有页面靠 Theme.of / palette 自动跟随，不需要各自监听。
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeSettings.instance.mode,
      builder: (ctx, mode, _) => MaterialApp(
        title: kAppTitle,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode.material,
        home: const RootPage(),
      ),
    );
  }
}

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.home_outlined, selected: Icons.home_rounded, label: '首页'),
    (icon: Icons.person_outline_rounded, selected: Icons.person_rounded, label: '我的'),
  ];

  void _select(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    // 桌面/平板把导航挪到左侧：底部横条是手机形态，宽屏下既浪费
    // 纵向空间又不符合桌面软件的操作习惯（左上角才是导航区）。
    if (useSideNav(context)) {
      return Scaffold(
        body: Row(
          children: [
            _SideRail(index: _index, onSelect: _select),
            VerticalDivider(
                width: 1,
                thickness: 1,
                color: context.palette.divider),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: const [HomePage(), ProfilePage()],
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [HomePage(), ProfilePage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        backgroundColor: context.palette.card,
        indicatorColor: kAccent,
        height: 58,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              // 选中态图标必须是深色：indicatorColor 本身就是 kAccent，
              // 原来 selectedIcon 也用 kAccent，橙画在橙上等于隐形——
              // 实测底部「下载」Tab 只剩一个空橙色胶囊，图标完全看不见。
              // 用 kOnAccent 而不是 palette.bg：浅色主题下 bg 是浅灰，
              // 压在橙上同样看不见。
              selectedIcon: Icon(d.selected, color: kOnAccent),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

/// 左侧竖向导航栏
///
/// 宽度 208 是「图标 + 文字 + 选中背景」都舒展、又不至于挤压内容区的折中。
class _SideRail extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;

  const _SideRail({required this.index, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 208,
      color: context.palette.card.withValues(alpha: 0.6),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部品牌区
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 20, 14, 22),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFF8A4C), kAccent],
                      ),
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    kAppTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
            for (final (i, d) in _RootPageState._destinations.indexed)
              _RailItem(
                icon: d.icon,
                selectedIcon: d.selected,
                label: d.label,
                active: i == index,
                onTap: () => onSelect(i),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
              child: Text(
                'v$kAppVersion',
                style: TextStyle(
                    fontSize: 11, color: context.palette.textDim),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: active
                  ? kAccent.withValues(alpha: 0.16)
                  : (_hover ? context.palette.hover : null),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: [
                Icon(
                  active ? widget.selectedIcon : widget.icon,
                  size: 20,
                  color: active ? kAccent : context.palette.textDim,
                ),
                const SizedBox(width: 11),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? kAccent : context.palette.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}