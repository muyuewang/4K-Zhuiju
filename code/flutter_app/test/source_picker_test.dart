/// 播放源选择 / 换源决策的回归测试。
///
/// 用例里的数据不是编的，是 2026-11-09 对
/// `十八岁太奶奶驾到重整家族荣耀`（id=193501）调
/// /api/proto/v5/drama/getDetail 的实测结果：
///
///   独家短剧  source=hgdj      90 条  path=7512797350914444313&1（令牌，不可播）
///   B蓝光     source=bfzym3u8   1 条  path=https://p.b8bf.com/…/全集/index.m3u8
///   BL        source=bilibili  11 条  path=https://www.bilibili.com/bangumi/play/ep2234211
///
/// 这三个源刚好吃掉了原来「所有线路都不能用」的全部成因，
/// 所以直接拿它们当固定测试数据，改坏了会立刻报错。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/source_picker.dart';

DramaVideo v({
  required int episode,
  required String path,
  required String source,
  String sourceCn = '',
  String title = '',
}) =>
    DramaVideo(
      id: episode,
      title: title.isEmpty ? '$episode' : title,
      path: path,
      source: source,
      sourceCn: sourceCn,
      episode: episode,
    );

/// 独家短剧：整条线路 90 集，path 全是 `<数字>&<集数>` 形态的令牌
List<DramaVideo> exclusiveSource() => List.generate(
      90,
      (i) => v(
        episode: i + 1,
        path: '7512797350914444313&${i + 1}',
        source: 'hgdj',
        sourceCn: '独家短剧',
      ),
    );

/// B蓝光：只有 1 条，一条 index.m3u8 里装完整部 90 集（实测 2421 个分片）
List<DramaVideo> bLanGuangSource() => [
      v(
        episode: 1,
        title: '全集',
        path:
            'https://p.b8bf.com/video/shibasuitainainaijiadaozhongzhengjiazurongyao/全集/index.m3u8',
        source: 'bfzym3u8',
        sourceCn: 'B蓝光',
      ),
    ];

/// BL：11 条，path 是 bilibili 番剧网页，必须靠接口换带签名的 m3u8
List<DramaVideo> blSource() => List.generate(
      11,
      (i) => v(
        episode: i + 1,
        path: 'https://www.bilibili.com/bangumi/play/ep${2234211 + i}',
        source: 'bilibili',
        sourceCn: 'BL',
      ),
    );

Map<String, List<DramaVideo>> shortDramaSources() => {
      // 刻意保持接口原始顺序：独家短剧排第一，正是线上踩坑的排列
      '独家短剧': exclusiveSource(),
      'B蓝光': bLanGuangSource(),
      'BL': blSource(),
    };

void main() {
  group('pathLooksPlayable：识别「不是地址」的 path', () {
    test('独家短剧的令牌形态判为不可播', () {
      for (final p in [
        '7512797350914444313&1',
        '7512797350914444313&90',
        '123&7',
      ]) {
        expect(
          v(episode: 1, path: p, source: 'hgdj').pathLooksPlayable,
          isFalse,
          reason: '$p 是播放器专用令牌，不该被当成地址',
        );
      }
    });

    test('m3u8 直链、站内路径、带后缀地址都判为可播', () {
      for (final p in [
        'https://p.b8bf.com/video/xxx/全集/index.m3u8',
        'http://122.228.193.79:6688/qgg/Cache/BF/abc.m3u8',
        'https://www.bilibili.com/bangumi/play/ep2234211',
        '/api/video/play.m3u8',
        'index.php?data=xyz',
      ]) {
        expect(
          v(episode: 1, path: p, source: 'x').pathLooksPlayable,
          isTrue,
          reason: '$p 应被视为可播地址',
        );
      }
    });

    test('空 path 不可播', () {
      expect(v(episode: 1, path: '', source: 'x').pathLooksPlayable, isFalse);
      expect(v(episode: 1, path: '   ', source: 'x').pathLooksPlayable, isFalse);
    });
  });

  group('isSourcePlayable：整条线路判定', () {
    test('独家短剧整条线路不可播', () {
      expect(isSourcePlayable(exclusiveSource()), isFalse);
    });

    test('B蓝光 / BL 整条线路可播', () {
      expect(isSourcePlayable(bLanGuangSource()), isTrue);
      expect(isSourcePlayable(blSource()), isTrue);
    });

    test('空线路不可播', () {
      expect(isSourcePlayable(const []), isFalse);
    });
  });

  group('pickDefaultSource：默认选中谁', () {
    test('短剧不再默认选中「独家短剧」这条死线路（回归 #1）', () {
      final m = shortDramaSources();
      final picked = pickDefaultSource(m);
      expect(picked, isNot('独家短剧'),
          reason: '旧逻辑按集数最多选择，恰好选中 90 集的死线路，'
              '用户点任意一集都失败，表现就是「所有线路都不能用」');
      expect(isSourcePlayable(m[picked]!), isTrue);
    });

    test('短剧默认选中分集粒度更细的 BL（能对上更多集）', () {
      expect(pickDefaultSource(shortDramaSources()), 'BL');
    });

    test('只剩单条目源时仍会选它，而不是报错', () {
      final m = {
        '独家短剧': exclusiveSource(),
        'B蓝光': bLanGuangSource(),
      };
      expect(pickDefaultSource(m), 'B蓝光');
    });

    test('稳定 MP4 源优先于一切（可下载、token 不过期）', () {
      final m = {
        'BL': blSource(),
        'QQ': [v(episode: 1, path: 'http://x/1.mp4', source: 'qq', sourceCn: 'QQ')],
      };
      expect(pickDefaultSource(m), 'QQ');
    });

    test('全部不可播时退回集数最多，至少让用户有东西点', () {
      final m = {
        '死线路A': exclusiveSource(),
        '死线路B': exclusiveSource().take(3).toList(),
      };
      expect(pickDefaultSource(m), '死线路A');
    });
  });

  group('sortedSourceNames：源选择器排序', () {
    test('可播线路排在前，死线路沉到最后', () {
      final names = sortedSourceNames(shortDramaSources());
      expect(names.indexOf('独家短剧'), 2);
      expect(names.first, isNot('独家短剧'));
    });
  });

  group('switchCandidates：换源候选', () {
    test('从死线路点换源，能换到可播线路', () {
      final m = shortDramaSources();
      final cur = m['独家短剧']!.first;
      final cands = switchCandidates(m, cur);
      final names = cands.map(sourceKeyOf).toSet();
      expect(names, containsAll(['B蓝光', 'BL']));
    });

    test('第 12 集以后仍能换源到 B蓝光的「全集」单条目（回归 #2）', () {
      final m = shortDramaSources();
      // BL 只有 11 集，第 12 集串行播放时当前源就是 BL
      final cur = v(
        episode: 50,
        path: 'https://www.bilibili.com/bangumi/play/ep2299999',
        source: 'bilibili',
        sourceCn: 'BL',
      );
      final cands = switchCandidates(m, cur);
      expect(cands, isNotEmpty,
          reason: '旧逻辑要求集数精确相等，B蓝光只有 1 条 ep=1，'
              '第 12 集以后候选为空，直接提示「没有更多可用源了」');
      expect(sourceKeyOf(cands.first), 'B蓝光');
      expect(cands.first.path.contains('index.m3u8'), isTrue);
    });

    test('绝不给「独家短剧」这种整条不可播的线路当候选', () {
      final m = shortDramaSources();
      final cur = m['BL']!.first;
      final cands = switchCandidates(m, cur);
      expect(cands.map(sourceKeyOf).toSet(), isNot(contains('独家短剧')));
      expect(cands.every((e) => e.pathLooksPlayable), isTrue);
    });

    test('已试过的源不再重复出现', () {
      final m = shortDramaSources();
      final cur = m['独家短剧']!.first;
      final cands = switchCandidates(m, cur, tried: {'B蓝光'});
      expect(cands.map(sourceKeyOf).toSet(), {'BL'});
    });

    test('同集数优先：BL 内部按集对齐', () {
      final m = shortDramaSources();
      final cur = m['B蓝光']!.first;
      final cands = switchCandidates(m, cur);
      final bl = cands.firstWhere((e) => sourceKeyOf(e) == 'BL');
      // 当前是 ep=1，BL 也有 ep=1，应取 ep=1 而不是别的集
      expect(bl.episode, 1);
    });
  });

  group('isWholeSeriesEntry', () {
    test('单条目 + 全集标题 判定为整部剧', () {
      expect(isWholeSeriesEntry(bLanGuangSource().first), isTrue);
    });
    test('普通分集条目不误判', () {
      expect(isWholeSeriesEntry(blSource()[5]), isFalse);
    });
  });
}