/// 榜单「装不满一屏就自动续拉」的回归测试。
///
/// ## 这个修复解决什么
///
/// 翻页只挂在 ScrollController 监听上。如果某一页的内容装不满一屏，
/// 页面**根本不能滚动**，滚动监听永远不触发 → 用户看到几个分区
/// 加一个一直转的圈，后面几页永远出不来。
///
/// **实测数据（2026-11-11，flutter_test 里量的）**：
/// 3 个分区（手机行高 208 + 标题行）实际占**约 1013px**，
/// 主流手机逻辑高度约 800px，所以手机首屏本来就能滚动，原逻辑可用。
/// 我最初按「约 700px」估算得出的「手机上必然卡住」是错的，已按实测修正。
///
/// 真会踩到的是：**视口很高**（平板横屏 / TV 行高 300 + 1080p）或
/// **服务端某一页只回 1~2 个分区**（分区快照更新时会出现）。
///
/// ## 两个测试写法上的坑（都踩过）
///
/// 1. **不能用 `SizedBox(height: ...)` 撑视口**：flutter_test 默认画布
///    只有 800×600，SizedBox 会被父级约束压回 600，写了 1100 也没用，
///    结果「装不满一屏」的前提根本不成立。必须用 `tester.view`
///    显式改画布尺寸。
/// 2. **不能用 `pumpAndSettle`**：底部状态位是
///    CircularProgressIndicator（无限动画），内容装不满时它就在屏上，
///    pumpAndSettle 永远等不到静止，直接 timed out。用固定帧数 pump。
///
/// ## 为什么断言不依赖精确的分区高度
///
/// 单个分区高度会随字体/字号/密度变化。这里只用两个宽松但确定的边界：
/// 3 个分区一定装不满 3000 高（需单分区 >1000 才可能，实际约 338）、
/// 12 个分区一定能撑满 3000 高（需单分区 <250 才可能，实际约 338）。
/// 这样测试不会因为调了几个像素的间距就红。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/theme.dart';
import 'package:zhuiju/widgets/feed_view.dart';

Drama card(String id) => Drama(
      id: id,
      name: '剧$id',
      remark: '全24集',
      year: 2026,
    );

FeedSection section(String id, String title, {int cards = 6}) => FeedSection(
      id: id,
      title: title,
      cards: List.generate(cards, (i) => card('$id-$i')),
    );

/// 直接把画布设成指定逻辑尺寸，绕开父级约束压缩。
void setView(WidgetTester tester, {double height = 3000}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(1000, height);
  addTearDown(tester.view.reset);
}

Widget wrap(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: child),
    );

/// 有界推进若干帧：每帧 50ms，14 帧 = 700ms，
/// 足够 async loader 的微任务 + post-frame 回调连续跑完几轮续拉。
Future<void> pumpFrames(WidgetTester tester, {int frames = 14}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('视口装不满一屏时自动续拉，撑满后立即停手', (tester) async {
    // 3000 高：3 个分区（约 1013）远装不满 → 必须续拉
    setView(tester, height: 3000);

    final page1 = HomeFeed(
      sections: [
        section('s1', '大家都在看'),
        section('s2', '韩剧在追'),
        section('s3', '日剧上新'),
      ],
      nextCursor: 'c1',
    );
    // 第二页给 12 个分区（约 4000）→ 一定撑满，必须在此停手
    final page2 = HomeFeed(
      sections: [
        section('s4', '美剧续看'),
        section('s5', '国产新剧'),
        section('s6', '高分电影'),
        for (var i = 0; i < 9; i++) section('x$i', '填充$i'),
      ],
      nextCursor: 'c2',
    );

    var calls = 0;
    final cursorSeen = <String?>[];

    await tester.pumpWidget(wrap(
      FeedView(
        loader: (cursor) async {
          cursorSeen.add(cursor);
          final p = (calls == 0) ? page1 : page2;
          calls++;
          return p;
        },
        onTap: (_) {},
      ),
    ));

    await pumpFrames(tester);

    expect(calls, greaterThan(1),
        reason: '视口 3000 装不下 3 个分区（约 1013），页面不能滚动、'
            '滚动监听不触发。必须靠 post-frame 续拉，'
            '否则第二页的「美剧续看/国产新剧/高分电影」永远出不来');

    // 游标必须真的传给下一层
    expect(cursorSeen.first, isNull, reason: '首页不该带游标');
    expect(cursorSeen[1], 'c1', reason: '续拉必须带上服务端给的 nextCursor');

    // 第二页必须已经出来
    expect(find.text('美剧续看'), findsOneWidget);

    // 关键：撑满一屏就停手，不能把后面几页全预加载掉
    expect(calls, 2, reason: '12 个分区（约 4000）已能滚动，应立即停止续拉');
    expect(cursorSeen, [null, 'c1']);
  });

  testWidgets('内容足够撑满一屏时不该白拉下一页', (tester) async {
    setView(tester, height: 3000);

    var calls = 0;
    final cursorSeen = <String?>[];

    await tester.pumpWidget(wrap(
      FeedView(
        loader: (cursor) async {
          cursorSeen.add(cursor);
          calls++;
          // 一页 15 个分区（约 5000），必然超出 3000
          return HomeFeed(
            sections: List.generate(15, (i) => section('big$i', '分区$i')),
            nextCursor: 'next',
          );
        },
        onTap: (_) {},
      ),
    ));
    await pumpFrames(tester);

    expect(calls, 1,
        reason: '内容已经能滚动，翻页应交给滚动监听，'
            '不能在 post-frame 里抢着多拉一页浪费流量');
    expect(cursorSeen, [null]);
  });

  testWidgets('服务端只回重复分区时必须停下，不能死循环', (tester) async {
    setView(tester, height: 3000);

    var calls = 0;

    await tester.pumpWidget(wrap(
      FeedView(
        loader: (cursor) async {
          calls++;
          // 每次都返回同一批分区 + 一直给新游标：
          // 这是最恶劣的情况，若无「新增数为 0 就停」的保护会无限请求
          return HomeFeed(
            sections: [
              section('dup1', '大家都在看'),
              section('dup2', '韩剧在追'),
            ],
            nextCursor: 'calls$calls',
          );
        },
        onTap: (_) {},
      ),
    ));
    await pumpFrames(tester);

    expect(calls, 2,
        reason: '第一次拉回 2 个新区块 → 仍装不满 → 再拉一次；'
            '第二次全是重复分区（_lastAdded=0）→ 必须停止。'
            '否则一屏装不满 → 一直拉 → 一直重复 → 无限请求打爆源站');
  });

  testWidgets('到底了（nextCursor 为空）不再续拉', (tester) async {
    setView(tester, height: 3000);

    var calls = 0;

    await tester.pumpWidget(wrap(
      FeedView(
        loader: (_) async {
          calls++;
          return HomeFeed(
            sections: [section('only', '唯一分区')],
            nextCursor: null,
          );
        },
        onTap: (_) {},
      ),
    ));
    await pumpFrames(tester);

    expect(calls, 1, reason: '只有一页、nextCursor 为 null，不该再拉');
    expect(find.text('已经到底啦'), findsOneWidget);
  });
}