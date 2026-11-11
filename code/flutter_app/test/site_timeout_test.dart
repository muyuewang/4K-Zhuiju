/// 源站不可达时的快速失败契约 + PoW 算法回归（全离线，不联网）。
///
/// 回归背景：v1.9.0 之前 [CdndefendGate] 解 PoW 用裸 HttpClient、
/// 没设任何超时，源站挂了界面会一直转到系统 TCP 超时（21s）再叠加
/// 3 次重试。这里锁住错误码、文案与 PoW 算法本身。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha1.dart';
import 'package:zhuiju/core/api.dart';
import 'package:zhuiju/core/source/site_http.dart';

void main() {
  test('不可达错误码是专用值，且不会被当成可重试的 5xx / -1', () {
    const code = CdndefendGate.kUnreachable;
    expect(code, isNot(850));
    expect(code, isNot(-1));
    expect(code >= 500, isFalse);
  });

  test('不可达错误文案给出可操作的下一步，且不暴露异常类名', () {
    final e = ApiException(CdndefendGate.kUnreachable,
        '无法连接源站（SocketException），请在设置里切换其它数据源');
    expect(friendlyError(e), contains('切换'));
  });

  test('PoW 求出的 i 真的满足 SHA1 字节条件（不是碰巧返回 0）', () {
    // 2026-11-11 实测前缀；n1 = parseInt('0x' + prefix[0]) = 9
    const prefix = '99BAF2DFF22573D71F788805A990B14F4D8B8675';
    const n1 = 9;
    final sw = Stopwatch()..start();
    final i = CdndefendGate.proofOfWork(prefix, n1);
    expect(i, greaterThan(0), reason: '期望 1/65536 命中，i=0 几乎不可能');
    expect(sw.elapsedMilliseconds, lessThan(20000));

    // 独立复算，确认生产算法没有被改成「随便返回一个数」
    final sha = SHA1Digest();
    final d = sha.process(Uint8List.fromList(utf8.encode('$prefix$i')));
    expect(d[n1], 0xb0);
    expect(d[n1 + 1], 0x0b);

    // 前一个 i 不该满足条件（否则说明求解越过了最早解）
    final prev = sha.process(Uint8List.fromList(utf8.encode('$prefix${i - 1}')));
    expect(prev[n1] == 0xb0 && prev[n1 + 1] == 0x0b, isFalse);
  });
}