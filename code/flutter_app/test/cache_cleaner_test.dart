/// 缓存清理
///
/// 重点覆盖两件事：
///   1. `CacheUsage.human` 的分档换算——设置页那一行文字直接用它，
///      算错会让用户看到「1024.0 KB」这种别扭的数字；
///   2. 平台通道不可用时不能崩。`getTemporaryDirectory()` 依赖
///      path_provider 的原生实现，在测试环境（以及某些异常机型上）
///      会抛 MissingPluginException，清理功能必须安静降级，
///      绝不能因为「清理缓存」把整个设置页打挂。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/cache_cleaner.dart';

void main() {
  // path_provider 需要 binding 才能查平台通道；不初始化的话
  // measure/clear 会抛 "Binding has not yet been initialized"，
  // 虽然被兜底 catch 住，但日志会刷屏、也测不到真实路径。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CacheUsage 体积换算', () {
    test('小于 1KB 显示字节', () {
      expect(const CacheUsage(bytes: 0, files: 0).human, '0 B');
      expect(const CacheUsage(bytes: 1, files: 1).human, '1 B');
      expect(const CacheUsage(bytes: 1023, files: 1).human, '1023 B');
    });

    test('整数不拖小数点，非整数保留一位', () {
      expect(const CacheUsage(bytes: 1024, files: 1).human, '1 KB');
      expect(const CacheUsage(bytes: 5120, files: 1).human, '5 KB');
      expect(const CacheUsage(bytes: 20480, files: 1).human, '20 KB');
      // 1.5 KB
      expect(const CacheUsage(bytes: 1536, files: 1).human, '1.5 KB');
    });

    test('MB 档', () {
      expect(const CacheUsage(bytes: 1048576, files: 1).human, '1 MB');
      // 50.5 MB —— 半兆必须保留，不能被取整成 51 MB
      expect(
        const CacheUsage(bytes: 52953088, files: 1).human,
        '50.5 MB',
      );
      // 200 MB
      expect(const CacheUsage(bytes: 209715200, files: 1).human, '200 MB');
      // 12.5 MB
      expect(const CacheUsage(bytes: 13107200, files: 1).human, '12.5 MB');
    });

    test('GB 档', () {
      expect(
        const CacheUsage(bytes: 1073741824, files: 1).human,
        '1 GB',
      );
      expect(
        const CacheUsage(bytes: 1610612736, files: 1).human,
        '1.5 GB',
      );
    });

    test('边界：差 1 字节到 1MB 时归入 MB 而不是 1024 KB', () {
      // 1048575 B = 1023.999 KB，四舍五入后正好是 1024 KB。
      // 只要不出现「1023.9 KB」这种带小数的 KB 就算对。
      final u = CacheUsage(bytes: 1048575, files: 1);
      expect(u.human, '1024 KB');
    });
  });

  group('平台通道不可用时安静降级', () {
    test('measure 返回零而不是抛异常', () async {
      // 测试环境没有 path_provider 的原生实现，
      // getTemporaryDirectory() 会抛 MissingPluginException。
      // 这里断言的是「被 catch 住并返回零」，不是「能读到目录」。
      final u = await CacheCleaner.measure();
      expect(u.bytes, greaterThanOrEqualTo(0));
      expect(u.files, greaterThanOrEqualTo(0));
    });

    test('clear 返回零而不是抛异常', () async {
      final u = await CacheCleaner.clear();
      expect(u.bytes, greaterThanOrEqualTo(0));
      expect(u.files, greaterThanOrEqualTo(0));
    });
  });
}