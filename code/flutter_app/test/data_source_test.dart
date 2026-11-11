/// 数据源抽象层 / 注册表 / kanju 适配器的回归测试
///
/// 锁住三件最容易在后续改动中悄悄坏掉的事：
///
/// 1. **id 归一**：`idToStr` 把 int 0 归一成空串。收藏/历史里所有
///    「判空」都依赖这个语义，一旦有人改成 `return '$v'`，旧数据里的
///    `dramaId: 0` 就会变成字符串 `"0"`，界面上冒出一堆幽灵条目。
///
/// 2. **签名串**：kanju 的 HMAC 一旦拼错（少个换行、中文没编码），
///    服务端只回 401 `invalid_request_signature`，与「密钥失效」
///    「接口改版」表现完全一致，线上无法定位。这里对着固定输入
///    钉死输出，改坏了立刻红。
///
/// 3. **空串兜底**：`byId('')` 必须返回橘汁。升级前的老收藏没有
///    sourceId 字段，读出来是空串——这是它们还能打开的唯一原因。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/kanju_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/source/zhuiju_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('id 归一（旧数据兼容的基础）', () {
    test('空值统一成空串', () {
      expect(idToStr(null), '');
      expect(idToStr(''), '');
    });

    test('int 0 归一成空串，而不是 "0"', () {
      // 这是整个兼容层的基石：旧数据里「没有 id」就是 int 0，
      // 变成 "0" 会让 isEmpty 判空全部失效。
      expect(idToStr(0), '');
      expect(idToStr(0.0), '');
      // 非零保持原样
      expect(idToStr(7), '7');
      expect(idToStr(949937), '949937');
    });

    test('double 的整数值按整数处理', () {
      expect(idToStr(12.0), '12');
      expect(idToStr(12.9), '12');
    });

    test('字符串原样返回：kanju 的 av_ 长串不被改写', () {
      const kj = 'av_nH2ZeKZ0Ft4qABCDEF';
      expect(idToStr(kj), kj);
    });
  });

  group('pathLooksPlayable（线路可用性判定）', () {
    DramaVideo v(String path) => DramaVideo(
          id: '1',
          title: 'x',
          path: path,
          source: 's',
        );

    test('http/https 直链可播', () {
      expect(v('https://a/b.m3u8').pathLooksPlayable, isTrue);
      expect(v('http://a/b.mp4').pathLooksPlayable, isTrue);
    });

    test('resolve:// 占位也算可播', () {
      // 这条分支是 kanju 官方线能被 source_picker 保留的唯一原因：
      // 判成不可播会让「1080P-官方」这些线路整条消失。
      expect(v('resolve://abc123').pathLooksPlayable, isTrue);
    });

    test('空串与令牌不算可播', () {
      expect(v('').pathLooksPlayable, isFalse);
      expect(v('7512797350914444313&1').pathLooksPlayable, isFalse);
    });
  });

  group('kanju 签名与编码', () {
    test('query 编码：中文/空格/& 都被百分号编码', () {
      expect(KanjuSource.encodeQuery({'q': '沙'}), 'q=%E6%B2%99');
      expect(KanjuSource.encodeQuery({'q': 'a b'}), 'q=a+b');
      // 值里的 & 必须编码，否则会被服务端当成参数分隔符
      expect(KanjuSource.encodeQuery({'q': 'a&b'}), 'q=a%26b');
    });

    test('空参数返回空串，不产生多余的 ?', () {
      expect(KanjuSource.encodeQuery(const {}), '');
    });

    test('多参数按顺序拼接', () {
      final s = KanjuSource.encodeQuery({'page': '1', 'limit': '20'});
      expect(s, 'page=1&limit=20');
    });

    test('签名对固定输入产出确定的 64 位 hex', () {
      // 四行拼接是协议约定：METHOD\nPATH?QUERY\nTS\nNONCE
      // 少一个 \n 服务端就算不出同样的哈希，直接 401。
      //
      // 这里的期望值不是从本实现抄来的（那是自证），而是用 Python
      // 标准库 hmac/hashlib 独立算出来的同一份密钥下的结果。
      // 两边对得上，说明 Dart 侧的拼接顺序、编码、hex 小写都与协议一致。
      const msg = 'GET\n/v1/suggest?q=%E6%B2%99\n1700000000000\nabcdef0123456789';
      expect(
        KanjuSource.signHex(msg),
        '3a7fcaf6dc1689546b6873a494e3ca90448b5aa0dc61abb18a6dc583f7610d8f',
      );
    });

    test('榜单请求的签名同样与外部实现一致', () {
      // 榜单用到的编码后查询串，逐字对齐 _get 内部拼出来的形态，
      // 参数顺序必须与 _encodeQuery 遍历顺序一致。
      const msg = 'GET\n/v1/feed/home?scope=public&mode=page&sections=3&cards=12'
          '\n1700000000000\n0123456789abcdef';
      expect(
        KanjuSource.signHex(msg),
        '5d7b9a5dfb60b7ad1c3ef0e080f9126192e19aa8a1ba8bbef0f0874bf8eb1b3e',
      );
    });

    test('签名对输入极度敏感：差一个换行就完全不同', () {
      final a = KanjuSource.signHex('GET\n/a\n1\nn');
      final b = KanjuSource.signHex('GET\n/a\n1\nn\n');
      expect(a, isNot(b));
    });

    test('中文未编码 vs 已编码，签名必须不同', () {
      // 踩过的坑：对原文 q=沙 签名、却把 %E6%B2%99 发出去 → 401。
      // 这条断言锁住「必须用编码后的串签名」这个结论。
      final raw = KanjuSource.signHex('GET\n/v1/suggest?q=沙\n1\nn');
      final enc =
          KanjuSource.signHex('GET\n/v1/suggest?q=%E6%B2%99\n1\nn');
      expect(raw, isNot(enc));
    });
  });

  group('源注册表', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('至少注册了两个源，且 id 唯一', () {
      final ids = SourceRegistry.all.map((e) => e.id).toList();
      expect(ids.length, greaterThanOrEqualTo(2));
      expect(ids.toSet().length, ids.length, reason: 'id 重复会让持久化串源');
    });

    test('默认源是橘汁（老用户升级后行为不变）', () {
      expect(SourceRegistry.instance.now.id, 'zhuiju');
    });

    test('空串 / null / 未知 id 一律退回橘汁', () {
      // 这是升级兼容的唯一保证：老收藏没有 sourceId，读出来是空串
      expect(SourceRegistry.instance.byId('').id, 'zhuiju');
      expect(SourceRegistry.instance.byId(null).id, 'zhuiju');
      expect(SourceRegistry.instance.byId('nonexistent').id, 'zhuiju');
    });

    test('按 id 能找回 kanju', () {
      expect(SourceRegistry.instance.byId('kanju').id, 'kanju');
    });

    test('切换后 now 跟着变，且 switch 后持久化可读回', () async {
      await SourceRegistry.instance.selectById('kanju');
      expect(SourceRegistry.instance.now.id, 'kanju');

      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('app.dataSourceId'), 'kanju');

      // 切回来，避免影响同进程内的其它用例
      await SourceRegistry.instance.selectById('zhuiju');
      expect(SourceRegistry.instance.now.id, 'zhuiju');
    });
  });

  group('两个源的分类体系', () {
    test('都以「推荐」（空 id）开头', () {
      // 首页靠「分类 id 为空」判断这一栏走推荐逻辑
      expect(kZhuijuCategories.first.id, '');
      expect(kKanjuCategories.first.id, '');
    });

    test('分类 id 不自重复', () {
      for (final cats in [kZhuijuCategories, kKanjuCategories]) {
        final ids = cats.map((e) => e.id).toList();
        expect(ids.toSet().length, ids.length);
      }
    });

    test('kanju 的分类 id 是 content_kind 枚举值', () {
      const kinds = {
        'movie',
        'series',
        'short_drama',
        'anime',
        'variety',
        'documentary',
        // sports / adult 未放进分类条，但枚举里存在
      };
      for (final c in kKanjuCategories) {
        if (c.id.isEmpty) continue;
        expect(kinds.contains(c.id), isTrue, reason: '未知 content_kind: ${c.id}');
      }
    });

    test('kanju 声明无弹幕，橘汁声明有', () {
      // 播放页据此跳过请求；判错会让 kanju 的片反复拉一个必然空的接口
      expect(KanjuSource.instance.supportsDanmaku, isFalse);
      expect(ZhuijuSource.instance.supportsDanmaku, isTrue);
    });
  });

  group('榜单能力（可选接口）', () {
    test('kanju 实现 SectionedFeed，橘汁不实现', () {
      // 首页用 `is SectionedFeed` 决定走榜单视图还是分页网格，
      // 这个判断错了两边都不对：kanju 会退化成扁平列表，
      // 橘汁会去请求一个它没有的接口。
      //
      // 必须声明成 DataSource 再判：直接用 KanjuSource.instance 的话，
      // 静态类型已经实现了 SectionedFeed，`is` 恒为 true，测了个寂寞
      // （analyzer 会直接报 unnecessary_type_check）。
      // 声明成 DataSource 才是首页真实的视角——它只持有接口类型。
      final DataSource kj = KanjuSource.instance;
      final DataSource zj = ZhuijuSource.instance;
      expect(kj is SectionedFeed, isTrue);
      expect(zj is SectionedFeed, isFalse);
    });

    test('HomeFeed 的 cursor 为空表示没有更多分区', () {
      const f = HomeFeed(sections: []);
      expect(f.nextCursor, isNull);
      expect(f.sections, isEmpty);
    });

    test('FeedSection 存得住标题/副标题/卡片', () {
      const s = FeedSection(
        id: 'feed_sec_everyone_watching',
        title: '大家都在看',
        subtitle: '今晚打开就能接上的热播片单',
        cards: [],
      );
      expect(s.title, '大家都在看');
      expect(s.subtitle.isNotEmpty, isTrue);
    });
  });
}