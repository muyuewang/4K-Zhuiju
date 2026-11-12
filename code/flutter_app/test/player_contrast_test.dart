/// 播放器黑底栏的可读性回归（静态扫描，不渲染）。
///
/// ## 锁的是什么
///
/// 播放页必须永远是黑底（视频画面就该压在黑上，不跟主题走），但
/// `AppBar` 的前景（返回箭头、标题、右侧图标）默认取主题的 `onSurface`。
/// 浅色主题下 `onSurface` 是 `0xFF14161A`（近黑）——
///
/// ```
/// 黑底 + 近黑图标 = 返回按钮隐形
/// ```
///
/// 用户看到的现象是「不留意还真找不到，只有鼠标悬停到那个区域才出来」：
/// 鼠标悬停时 Material 会弹 tooltip（英文 `Back`），
/// 那个小方块是**唯一**可见的东西。
///
/// 修法是 `backgroundColor` 与 `foregroundColor` **成对声明**。
/// 全屏模式那套顶部栏一直是显式 `Colors.white`，所以没出问题；
/// 窗口模式这两处漏了。
///
/// ## 为什么用扫源码而不是 widget test
///
/// 播放页要真实视频源、播放器插件、网络才能构建出可断言的树，
/// widget test 里代价极高且不稳。而这个问题本质是**配置缺一项**，
/// 静态扫描能精确覆盖，跑起来只要几毫秒。
///
/// 扫描只针对 `AppBar(` 之后的一段窗口，不会误伤 `Scaffold`
/// 的 `backgroundColor`（那也是黑的，但它的前景不重要）。
///
/// ## 第二类问题：黑底容器里的「隐形正文」
///
/// AppBar 修完后又发现同一类问题出现在**面板内部**：宽屏播放页右栏、
/// 本地播放页控制面板、竖屏选集弹层的底色是 `kVideoBg` / `kVideoCard`
/// （恒深色，不跟主题走），但里面的剧名、集数、线路标签、按钮文字
/// 默认仍是主题的 `onSurface`。浅色主题下 `onSurface` 是 `#14161A`，
/// 压在这些深色底上对比度只有 1.0~1.1:1 —— 用户看到的
/// 「播放器上面的功能看不到」就是这些字。
///
/// 逐个 `Text` 补 `color: Colors.white` 治不住：以后往面板里加任何
/// 控件都会重新踩。所以改为整块区域套 `Theme(data: kVideoTheme)`，
/// 把「黑底 + 浅前景」这对搭配在语义上绑死。下面这条测试锁的就是
/// **凡是以这两个常量作整块底色的容器，必须在同一段里套 kVideoTheme**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 在 [text] 中定位所有 `AppBar(` 并返回其后的窗口片段。
List<String> _appBarScopes(String text) {
  final out = <String>[];
  for (final m in RegExp(r'AppBar\(').allMatches(text)) {
    // 1500 字符足够覆盖一个 AppBar 的配置（含长注释）；
    // 再往后就会串到下一个 widget 里去。
    final end = (m.end + 1500).clamp(0, text.length);
    out.add(text.substring(m.end, end));
  }
  return out;
}

void main() {
  test('黑底 AppBar 必须显式声明白色前景（否则返回按钮隐形）', () {
    final dir = Directory('lib/pages');
    expect(dir.existsSync(), isTrue, reason: '测试须在 flutter_app 目录下运行');

    final offenders = <String>[];

    for (final f in dir.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      if (!text.contains('AppBar(')) continue;

      for (var i = 0; i < _appBarScopes(text).length; i++) {
        final scope = _appBarScopes(text)[i];
        // 只关心「强制黑底」的 AppBar
        final isBlack = scope.contains('backgroundColor: Colors.black');
        if (!isBlack) continue;
        final hasWhiteFg = scope.contains('foregroundColor: Colors.white');
        if (!hasWhiteFg) {
          offenders.add('${f.path} 第 ${i + 1} 个 AppBar');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些黑底 AppBar 没有声明白色前景，浅色主题下图标会变成近黑色而不可见：\n'
          '${offenders.join('\n')}\n'
          '修法：AppBar 里同时写 backgroundColor: Colors.black '
          '和 foregroundColor: Colors.white。',
    );
  });

  test('以 kVideoBg / kVideoCard 作整块底色的容器必须套 kVideoTheme', () {
    final dir = Directory('lib/pages');
    expect(dir.existsSync(), isTrue, reason: '测试须在 flutter_app 目录下运行');

    // 只认「整块底色」的写法：`color: kVideoBg,` 单独成行。
    // 形如 `color: active ? kAccent : kVideoBg` 是网格里的小格子，
    // 它的文字已经显式写死 Colors.white70，不属于本条覆盖范围。
    final solidBg = RegExp(r'^\s*color:\s*(kVideoBg|kVideoCard),\s*$',
        multiLine: true);

    final offenders = <String>[];

    for (final f in dir.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      if (!text.contains('kVideoBg') && !text.contains('kVideoCard')) continue;
      // 主题文件本身是定义处，跳过
      if (f.path.endsWith('theme.dart')) continue;

      for (final m in solidBg.allMatches(text)) {
        // 从底色声明往后看 600 字符，够覆盖 `child: Theme(...)` 这一行；
        // 超过这个距离说明主题作用域没有包住这块底色。
        final end = (m.end + 600).clamp(0, text.length);
        final window = text.substring(m.end, end);
        if (!window.contains('kVideoTheme')) {
          // 报错里带上行号，改的时候不用自己数
          final line = '\n'.allMatches(text.substring(0, m.start)).length + 1;
          offenders.add('${f.path}:$line');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些容器的底色恒为深色（不随主题变），但没有套 kVideoTheme，\n'
          '里面的文字会继承浅色主题的 onSurface(#14161A)，变成黑底黑字：\n'
          '${offenders.join('\n')}\n'
          '修法：child 外包一层 Theme(data: kVideoTheme, child: ...)。',
    );
  });

  test('播放页不再用默认 BackButton（英文 tooltip「Back」）', () {
    for (final path in [
      'lib/pages/player_page.dart',
      'lib/pages/local_player_page.dart',
    ]) {
      final text = File(path).readAsStringSync();
      // 没配 localizationsDelegates，默认 BackButton 的 tooltip 是英文
      expect(
        RegExp(r"tooltip:\s*'返回'").hasMatch(text),
        isTrue,
        reason: '$path 的返回按钮应带中文 tooltip',
      );
    }
  });
}