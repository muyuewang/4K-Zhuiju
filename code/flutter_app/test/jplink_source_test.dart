/// 金牌影院（jplink）源的回归测试。
///
/// 这个源的签名算法是逆向出来的，一旦写错，服务端只会回
/// `122001 应用签名失败`。它和「站点改版」「密钥轮换」「网络异常」
/// 表现完全一样，线上几乎无法定位。所以这里拿**固定的参数 + 固定时间戳**
/// 把输出钉死：期望值全部对着真实服务端跑通过一次的 Python 实现生成，
/// 两边逐字节一致才算过。
///
/// 三组最容易写错的地方各有一组用例：
///
/// 1. **参数按 key 排序**：不排序的话 `pageSize=10&pageNum=1` 和
///    `pageNum=1&pageSize=10` 算出不同签名，而两者都"看起来合理"。
/// 2. **中文不编码**：签名串用的是原始中文（`keyword=狂飙`），
///    URL 编码只能出现在查询串里。混用必错。
/// 3. **md5 的 hex 字符串再 sha1**：不是 md5 原始字节直接喂给 sha1。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/jplink_source.dart';
import 'package:zhuiju/core/source/registry.dart';

void main() {
  group('签名算法（对着真实服务端校验过）', () {
    const ts = 1794530000000;

    test('列表：参数按 key 排序后参与签名', () {
      // h = pageNum=1&pageSize=10&type1=1&key=cb8085...&t=1794530000000
      expect(
        JplinkSource.computeSign(
          {'pageSize': 10, 'type1': 1, 'pageNum': 1},
          ts,
        ),
        '685611c329b06cc9b58d585c4779e0c3273c0639',
      );
    });

    test('搜索：中文按原文参与签名，不做 URL 编码', () {
      // h = keyword=狂飙&pageNum=1&pageSize=5&key=...&t=...
      expect(
        JplinkSource.computeSign(
          {'keyword': '狂飙', 'pageNum': 1, 'pageSize': 5},
          ts,
        ),
        '09f2e55439a1877c6b1a374daa26e03928632a67',
      );
    });

    test('详情：单参数', () {
      expect(
        JplinkSource.computeSign({'id': 59618}, ts),
        '505d9b1956f585cdc036862fb9b5191ed3c02ea4',
      );
    });

    test('取流：双参数 id + nid', () {
      expect(
        JplinkSource.computeSign({'id': 59618, 'nid': 19279}, ts),
        'fb29eb07dd4c1d38db36599a663320c23faddf28',
      );
    });

    test('无参数：拼接串不能出现孤立的 &', () {
      // 错误实现会拼出 "&key=...&t=..."，多一个前导 &，签名全错
      expect(
        JplinkSource.computeSign(const {}, ts),
        'c61dd68c57ac74f8622219b5e9da4a7379d6059a',
      );
    });

    test('参数顺序不影响结果', () {
      final a = JplinkSource.computeSign({'id': 59618, 'nid': 19279}, ts);
      final b = JplinkSource.computeSign({'nid': 19279, 'id': 59618}, ts);
      expect(a, b);
    });

    test('时间戳变化必须改变签名', () {
      final a = JplinkSource.computeSign({'id': 1}, ts);
      final b = JplinkSource.computeSign({'id': 1}, ts + 1);
      expect(a, isNot(b));
    });
  });

  group('数据源契约', () {
    final src = JplinkSource.instance;

    test('id 与展示名', () {
      expect(src.id, 'jplink');
      expect(src.displayName.isNotEmpty, isTrue);
      expect(src.description.isNotEmpty, isTrue);
    });

    test('分类首位是推荐（空 id），且覆盖电影/电视剧/综艺/动漫四类', () {
      final cats = src.categories;
      expect(cats.first.id, isEmpty);
      final ids = cats.map((e) => e.id).toSet();
      // type1: 1 电影 / 2 电视剧 / 3 综艺 / 4 动漫 —— 实测总量分别
      // 10000 / 10000 / 3061 / 4429，都是真实片库而非占位
      expect(ids.containsAll({'1', '2', '3', '4'}), isTrue);
    });

    test('支持首页分区流（SectionedFeed）', () {
      expect(src, isA<SectionedFeed>());
    });

    test('无弹幕', () {
      expect(src.supportsDanmaku, isFalse);
    });

    test('线路顺序沿用接口下发顺序', () {
      expect(src.lineOrderPolicy, LineOrderPolicy.sourceOrder);
    });

    test('已登记进注册表', () {
      final hit = SourceRegistry.all.where((e) => e.id == 'jplink');
      expect(hit.length, 1, reason: '金牌影院必须且只能登记一次');
    });
  });
}