/// 游客会话的真实路径回归：验证 App 代码能把官方线解锁。
///
/// 为什么必须单独跑这一份：tools/probe_guest*.py 已经用 Python 证明
/// 「POST /v1/users/anonymous → 带 Cookie → 官方线 100% 可播」，
/// 但那是另一套实现。Dart 侧的 _ensureSession / Cookie 提取 / 401 重试
/// 有没有接对，只有走 KanjuSource.resolveUrl 才能确认。
///
///   沙海第 10 集：不带会话时官方线必 401，带会话必须成功
///
/// 这条断言真的抓到过 bug：Cookie 提取取了第一条同名 Cookie（空值的
/// 删除指令），导致会话被主动清掉，官方线全 401。纯 Python 探针看不出来，
/// 因为 Python 侧用的是 http.cookiejar 的完整语义。
///
/// 断网时安静跳过，不让整个套件变红。
///
/// 跑法：
///   flutter test test/integration/guest_session_probe_test.dart
// 联网探针靠 print 输出诊断信息，与 kanju_live_test.dart 同处理
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/source/kanju_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认把请求打成 400，这里恢复真实 HttpClient
  HttpOverrides.global = null;

  setUp(() {
    // KanjuSource 会读写 SharedPreferences，测试环境必须给个假后端
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('游客会话：官方线在 Dart 真实路径下可解析', () async {
    final kj = KanjuSource.instance;

    // 1. 找剧（断网时安静跳过，别把整个套件弄红）
    List<Drama> list;
    try {
      list = await kj.search('沙海');
    } catch (e) {
      print('[SKIP] 搜索失败（可能断网）：$e');
      return;
    }
    if (list.isEmpty) {
      print('[SKIP] 拿不到搜索结果（可能断网）');
      return;
    }

    DramaDetail d;
    try {
      d = await kj.detail(list.first.id);
    } catch (e) {
      print('[SKIP] 详情拉取失败：$e');
      return;
    }
    final m = d.sourcesByCn;

    // 2. 找一条官方线（needsResolve=true）
    String? officialName;
    for (final e in m.entries) {
      if (e.value.isNotEmpty && e.value.first.needsResolve) {
        officialName = e.key;
        break;
      }
    }
    if (officialName == null) {
      print('[SKIP] 该剧当前没有官方线');
      return;
    }
    print('官方线：$officialName，共 ${m.length} 条线路');

    // 3. 挑靠后的集（早期实测第 1 集本来就能播，第 10 集起才 401）
    final eps = m[officialName]!;
    final target = eps.length >= 10 ? eps[9] : eps.last;
    print('测试集数：第 ${target.episode} 集');

    // 4. 走真实 resolveUrl：内部会 _ensureSession → resolve-line
    final url = await kj.resolveUrl(target);
    print('解析结果：${url.substring(0, url.length > 70 ? 70 : url.length)}');

    expect(url, isNotEmpty, reason: '官方线解析不出地址');
    expect(url.startsWith('http'), isTrue,
        reason: '官方线应返回真实 http 地址，实际：$url');
  }, timeout: const Timeout(Duration(minutes: 3)));
}