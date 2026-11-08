import 'dart:async';

import 'package:flutter/material.dart';

import 'core/download.dart';
import 'core/history.dart';
import 'core/version.dart';
import 'pages/home_page.dart';
import 'pages/profile_page.dart';
import 'theme.dart';
import 'widgets/danmaku_overlay.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  debugPrint('[BOOT] restore done');
}

class ZhuijuApp extends StatelessWidget {
  const ZhuijuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppTitle,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const RootPage(),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [HomePage(), ProfilePage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: kCard,
        indicatorColor: kAccent,
        height: 58,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            // 选中态图标必须是深色：indicatorColor 本身就是 kAccent，
            // 原来 selectedIcon 也用 kAccent，橙画在橙上等于隐形——
            // 实测底部「下载」Tab 只剩一个空橙色胶囊，图标完全看不见。
            selectedIcon: Icon(Icons.home_rounded, color: kBg),
            label: '首页',
          ),
          NavigationDestination(
            // 第二个 Tab 由「下载」改为「我的」：下载只是其中一个功能，
            // 还需要承载最近观看、清理空间等入口。
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded, color: kBg),
            label: '我的',
          ),
        ],
      ),
    );
  }
}