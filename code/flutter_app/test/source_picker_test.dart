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
import 'package:zhuiju/core/playback_prefs.dart';
import 'package:zhuiju/core/source_picker.dart';

DramaVideo v({
  required int episode,
  required String path,
  required String source,
  String sourceCn = '',
  String title = '',
  bool needsResolve = false,
}) =>
    DramaVideo(
      id: '$episode',
      title: title.isEmpty ? '$episode' : title,
      path: path,
      source: source,
      sourceCn: sourceCn,
      episode: episode,
      playToken: path.startsWith('resolve://')
          ? path.substring('resolve://'.length)
          : '',
      needsResolve: needsResolve,
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

// ==================== kanju 多线路夹具 ====================
//
// 下面的数据不是编的，是 2026-11-11 对 kanju.ai 真实调用的结果：
//
//   沙海        54 集，14 条线路 = 12 条直出(m3u8) + 2 条官方线(需二次解析)
//   庆余年 第2季  36 集，28 条线路 = 23 条直出 + 5 条官方线
//
// 关键特征（也是这次要修的东西）：
//   1. **每条线路的条目数完全相等**（每集一条），所以「按条目数排序」
//      这个判据在 kanju 上完全失效，比较器恒返回 0
//   2. **接口原始顺序把官方线排最前面**，庆余年S2 前 3 条全是官方线，
//      且第一条带 selected:true
//   3. 官方线靠 `resolve://` 占位通过 pathLooksPlayable，看着「可播」，
//      但实际要多发一次 resolve 请求，部分新片还会 401 要登录
//
// 结论：旧逻辑在 kanju 上必然默认选中一条官方线。

/// kanju 官方线：url 是 `resolve://<ticket>`，运行时要再 POST 一次换真地址
List<DramaVideo> kanjuOfficialLine(String label, String playFrom,
        {int episodes = 54, bool requiresLogin = false}) =>
    List.generate(
      episodes,
      (i) => v(
        episode: i + 1,
        path: 'resolve://av_${playFrom}_ep${i + 1}',
        source: playFrom,
        sourceCn: label,
        needsResolve: true,
      ),
    );

/// kanju 直出线路：url 直接就是 m3u8，拿来就播
List<DramaVideo> kanjuDirectLine(String label, String playFrom,
        {int episodes = 54}) =>
    List.generate(
      episodes,
      (i) => v(
        episode: i + 1,
        path: 'https://cdn.example.com/$playFrom/${i + 1}/index.m3u8',
        source: playFrom,
        sourceCn: label,
      ),
    );

/// 沙海（54 集）的线路表，**严格按接口原始顺序**：官方线在最前
Map<String, List<DramaVideo>> kanjuShaHai() => {
      '高清-官方B': kanjuOfficialLine('高清-官方B', 'bytedance'),
      '1080P-官方R': kanjuOfficialLine('1080P-官方R', 'rrys'),
      '无水印资源': kanjuDirectLine('无水印资源', 'wsym3u8'),
      '红牛资源': kanjuDirectLine('红牛资源', 'hnm3u8'),
      '极速资源': kanjuDirectLine('极速资源', 'jsm3u8'),
      '豆瓣资源': kanjuDirectLine('豆瓣资源', 'dbm3u8'),
    };

/// 庆余年 第2季（36 集）：官方线有 5 条，且原始顺序前三全是官方线
Map<String, List<DramaVideo>> kanjuQingYuNian() => {
      '1080P-官方Z': kanjuOfficialLine('1080P-官方Z', 'zzy',
          episodes: 36, requiresLogin: true),
      '高清-官方B': kanjuOfficialLine('高清-官方B', 'bytedance',
          episodes: 36, requiresLogin: true),
      '1080P-官方R': kanjuOfficialLine('1080P-官方R', 'rrys', episodes: 36),
      '红牛资源': kanjuDirectLine('红牛资源', 'hnm3u8', episodes: 36),
      '极速资源': kanjuDirectLine('极速资源', 'jsm3u8', episodes: 36),
      '豆瓣资源': kanjuDirectLine('豆瓣资源', 'dbm3u8', episodes: 36),
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

  // ==================== kanju 多线路（14~28 条并行） ====================
  //
  // 这组是 2026-11-11 的真实回归：接入第二数据源后，
  // kanju 的线路形态和橘汁完全相反，旧的两档判定直接失效。
  //
  // 2026-11-11 下午又翻了一次：接入游客会话后实测官方线 100% 可播
  // （沙海 16/16、庆余年 27/27），用户反馈普通源很卡，
  // 于是默认从「直出优先」改成「官方优先」。下面用双偏好对照来锁行为，
  // 只断言「两种偏好下官方线与直出线的相对顺序互换」，
  // 不断言具体数值——数值是实现细节，翻转默认值时不该连测试一起改。

  group('lineRankOf：线路等级受偏好驱动', () {
    final official = v(
      episode: 1,
      path: 'resolve://av_xxx',
      source: 'bytedance',
      needsResolve: true,
    );
    final direct = v(
      episode: 1,
      path: 'https://cdn.example.com/a/1/index.m3u8',
      source: 'hnm3u8',
    );

    test('官方优先：官方线比直出线靠前', () {
      expect(
        lineRankOf(official, pref: LinePreference.officialFirst),
        lessThan(lineRankOf(direct, pref: LinePreference.officialFirst)),
      );
    });

    test('普通优先：直出线比官方线靠前（与上一档正好互换）', () {
      expect(
        lineRankOf(direct, pref: LinePreference.directFirst),
        lessThan(lineRankOf(official, pref: LinePreference.directFirst)),
      );
    });

    test('稳定 MP4 源恒定最前，不受偏好影响', () {
      final qq = v(episode: 1, path: 'http://x/1.mp4', source: 'qq');
      for (final p in LinePreference.values) {
        expect(lineRankOf(qq, pref: p), kRankStableMp4);
      }
    });

    test('令牌形态恒定判死，不受偏好影响', () {
      final d = v(episode: 1, path: '7512797350914444313&1', source: 'hgdj');
      for (final p in LinePreference.values) {
        expect(lineRankOf(d, pref: p), kRankDead);
      }
    });

    test('整条线路取最好的一条：有直链就不因个别条目下沉', () {
      final mixed = <DramaVideo>[
        v(episode: 1, path: '7512797350914444313&1', source: 'x'),
        v(episode: 2, path: 'https://cdn/a/2.m3u8', source: 'x'),
      ];
      expect(lineRankOfAll(mixed), kRankSecondary,
          reason: '默认官方优先时，整条线路里最好的那条是直出线（次选档）');
    });

    test('空线路判死', () {
      expect(lineRankOfAll(const []), kRankDead);
    });
  });

  group('pickDefaultSource：kanju 默认线路', () {
    test('官方优先时默认选中官方线（画质最高，实测 100% 可播）', () {
      final m = kanjuShaHai();
      final picked = pickDefaultSource(m);
      expect(m[picked]!.first.needsResolve, isTrue,
          reason: '官方线已接游客会话，沙海 8 集抽样 16/16 可播；'
              '用户实测普通源很卡，默认应给官方线');
      expect(const ['高清-官方B', '1080P-官方R'], contains(picked));
    });

    test('普通优先时默认选中直出线（老行为，可手动切回）', () {
      final m = kanjuShaHai();
      final picked = pickDefaultSource(m, pref: LinePreference.directFirst);
      expect(m[picked]!.first.needsResolve, isFalse);
      expect(
        const ['无水印资源', '红牛资源', '极速资源', '豆瓣资源'],
        contains(picked),
      );
    });

    test('两种偏好各选一条，且不是同一条', () {
      final m = kanjuQingYuNian();
      final off = pickDefaultSource(m, pref: LinePreference.officialFirst);
      final dir = pickDefaultSource(m, pref: LinePreference.directFirst);
      expect(off, isNot(dir));
      expect(m[off]!.first.needsResolve, isTrue);
      expect(m[dir]!.first.needsResolve, isFalse);
    });

    test('条目数相等时结果稳定，多次调用不抖动', () {
      final m = kanjuShaHai();
      for (final p in LinePreference.values) {
        final first = pickDefaultSource(m, pref: p);
        for (var i = 0; i < 20; i++) {
          expect(pickDefaultSource(m, pref: p), first,
              reason: '比较器必须能区分同条目数的线路，否则每次打开详情页'
                  '默认选中项都可能变，用户会以为「源乱了」');
        }
      }
    });

    test('同是直出线路时优先给条目多的（能对上更多集）', () {
      final m = {
        '短线路': kanjuDirectLine('短线路', 'a', episodes: 10),
        '长线路': kanjuDirectLine('长线路', 'b', episodes: 54),
      };
      expect(pickDefaultSource(m, pref: LinePreference.directFirst), '长线路');
    });

    test('同等级且同条目数时按接口原始顺序，取第一个', () {
      final m = {
        '甲': kanjuDirectLine('甲', 'a', episodes: 36),
        '乙': kanjuDirectLine('乙', 'b', episodes: 36),
      };
      expect(pickDefaultSource(m, pref: LinePreference.directFirst), '甲');
    });
  });

  group('sortedSourceNames：kanju 线路面板顺序', () {
    test('官方优先：官方线排在最前', () {
      final names = sortedSourceNames(kanjuQingYuNian());
      final firstDirect = names.indexOf('红牛资源');
      for (final off in ['1080P-官方Z', '高清-官方B', '1080P-官方R']) {
        expect(names.indexOf(off), lessThan(firstDirect),
            reason: '默认官方优先，面板第一屏就该是画质最好的官方线');
      }
    });

    test('普通优先：官方线沉到直出线之后（与上面互为镜像）', () {
      final names = sortedSourceNames(kanjuQingYuNian(),
          pref: LinePreference.directFirst);
      final firstDirect = names.indexOf('红牛资源');
      for (final off in ['1080P-官方Z', '高清-官方B', '1080P-官方R']) {
        expect(names.indexOf(off), greaterThan(firstDirect));
      }
    });

    test('普通优先时排在最前的是直出线路', () {
      final names = sortedSourceNames(kanjuShaHai(),
          pref: LinePreference.directFirst);
      expect(
        const ['无水印资源', '红牛资源', '极速资源', '豆瓣资源'],
        contains(names.first),
      );
    });

    test('同等级保持接口原始顺序，不抖动', () {
      for (final p in LinePreference.values) {
        final a = sortedSourceNames(kanjuShaHai(), pref: p);
        final b = sortedSourceNames(kanjuShaHai(), pref: p);
        expect(a, b);
      }
    });

    test('橘汁的死线路仍沉到最后（旧行为不被破坏）', () {
      for (final p in LinePreference.values) {
        final names = sortedSourceNames(shortDramaSources(), pref: p);
        expect(names.last, '独家短剧');
      }
    });
  });

  group('switchCandidates：kanju 换源候选顺序', () {
    test('从官方线换源时，官方优先下先给另一条官方线', () {
      final m = kanjuQingYuNian();
      final cur = m['1080P-官方Z']!.first;
      final cands = switchCandidates(m, cur);
      expect(cands, isNotEmpty);
      // 默认官方优先：先消耗完 5 条官方线，再落到直出线
      expect(cands.first.needsResolve, isTrue);
    });

    test('普通优先时，从官方线换源先给直出线', () {
      final m = kanjuQingYuNian();
      final cur = m['1080P-官方Z']!.first;
      final cands = switchCandidates(m, cur, pref: LinePreference.directFirst);
      expect(cands, isNotEmpty);
      final first = sourceKeyOf(cands.first);
      expect(const ['红牛资源', '极速资源', '豆瓣资源'], contains(first));
    });

    test('候选顺序整体按等级单调，两种偏好都成立', () {
      for (final p in LinePreference.values) {
        final m = kanjuQingYuNian();
        final cur = v(
          episode: 1,
          path: 'https://cdn.example.com/_/1/index.m3u8',
          source: '_',
          sourceCn: '_',
        );
        final cands = switchCandidates(m, cur, pref: p);
        final ranks = cands.map((e) => lineRankOfAll([e], pref: p)).toList();
        // 非递减：档位一旦下沉，后面不能再回升
        for (var i = 1; i < ranks.length; i++) {
          expect(ranks[i], greaterThanOrEqualTo(ranks[i - 1]),
              reason: '偏好 $p 的候选顺序不是按等级排的：$ranks');
        }
      }
    });

    test('kanju 换源仍按集对齐', () {
      final m = kanjuShaHai();
      final cur = m['无水印资源']![7]; // ep 8
      final cands = switchCandidates(m, cur);
      final target = cands.firstWhere((e) => sourceKeyOf(e) == '红牛资源');
      expect(target.episode, 8);
    });
  });
}