/// 线路排序策略：按数据源声明分流（2026-11-11 真实回归）
///
/// 用户反馈：「橘汁官网带『自建』的线路在前面，咱这边都是 QQ、B蓝光在前，
/// 这线路不行，没有自建的清晰流畅。线路排序按照官方来的。」
///
/// 实测「走马上任」12 条线路，接口下发顺序本来就是
///   自建蓝光 → 自建4K-4 → 自建4K-3 → … → B蓝光 → JD4K → QQ
/// 是早期统一按「是不是直出 MP4」重排把它们打乱了。更严重的是
/// 10 条自建线给的是令牌（v0d5aag… / vod_1080-…），
/// 旧 pathLooksPlayable 只认 URL，把它们整条判成不可播。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/core/playback_prefs.dart';
import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/kanju_source.dart';
import 'package:zhuiju/core/source/zhuiju_source.dart';
import 'package:zhuiju/core/source_picker.dart';

/// 真实接口下发的 12 条线路（顺序、source、path 形态均取自线上抓包）
Map<String, List<DramaVideo>> zhuijuReal() {
  const rows = <List<String>>[
    ['自建蓝光', 'pylg', 'v0d5aag10002dbk6tdvog65q84mufc70'],
    ['自建4K-4', 'tocyyds', 'tos-cn-i-3jr8j4ixpe/90372116c2a748f0a86465b484e837'],
    ['自建4K-3', 'newxfyun', 'xfy-8+NQpd6GfzXD+kFeoxWhajU14CS1GxSqiM7Jb1LExqSgkm'],
    ['NN蓝光', 'vod_1080', 'vod_1080-2d5eea94b50490bccb4af14ab14dd83e'],
    ['VIP4K', 'SH4K', 'SH4K-b002a8b424c11a9911c9bce46a932cbe'],
    ['神话蓝光', 'qsvip', 'qsvip-w0gKE54s5ZK245vs7U0uGTBWrRZNg_9Z2njz2WQmT0SY'],
    ['NS蓝光-1', 'PAN1', 'PAN1--jHz5R2X2X3uJlKxGcrWmj7dWHD-TEIIGKNWFPUjoPFS9'],
    ['VIP蓝光', 'shvip', 'shvip-da57d0f7a7f3a1f62db2bf752503b9cb'],
    ['OO蓝光', 'zy1080_01', 'zy1080_01-ed2513d2eaa64105032df2545d228fd8'],
    ['B蓝光', 'bfzym3u8', 'https://v.fengbao14.com/video/zoumashangren/489c85/index.m3u8'],
    ['JD4K-可下载', 'JD4K', 'JD-aa35b83ae14d4cb2e28887b53ebde41f0'],
    ['QQ', 'qq', 'https://v.qq.com/x/cover/mzc00200zsqz54y/v4102cvly'],
  ];
  return <String, List<DramaVideo>>{
    for (final r in rows)
      r[0]: [
        DramaVideo(
          id: r[0],
          title: '第1集',
          path: r[2],
          source: r[1],
          sourceCn: r[0],
          episode: 1,
        ),
      ],
  };
}

Map<String, List<DramaVideo>> withDeadLine(Map<String, List<DramaVideo>> m) {
  // 独家短剧：整条 90 集全是 `<数字>&<集数>` 播放器专用令牌
  return <String, List<DramaVideo>>{
    '独家短剧': [
      for (var i = 1; i <= 90; i++)
        DramaVideo(
          id: 'ex$i',
          title: '第$i集',
          path: '7512797350914444313&$i',
          source: 'hgdj',
          sourceCn: '独家短剧',
          episode: i,
        ),
    ],
    ...m,
  };
}

DramaVideo kanjuLine(String name, String source, bool needsResolve) => DramaVideo(
      id: name,
      title: '第1集',
      path: needsResolve
          ? 'resolve://av_test_ticket'
          : 'https://cdn.example.com/a/1/index.m3u8',
      source: source,
      sourceCn: name,
      episode: 1,
      playToken: 'av_test_ticket',
      needsResolve: needsResolve,
    );

void main() {
  group('数据源声明的策略', () {
    test('橘汁按接口顺序、kanju 按用户偏好', () {
      expect(ZhuijuSource.instance.lineOrderPolicy,
          LineOrderPolicy.sourceOrder);
      expect(KanjuSource.instance.lineOrderPolicy,
          LineOrderPolicy.byPreference);
    });
  });

  group('pathLooksPlayable：橘汁令牌不是死线路', () {
    test('自建/蓝光令牌可经 videoUsableUrl 换址，判为可播', () {
      for (final p in [
        'v0d5aag10002dbk6tdvog65q84mufc70',
        'tos-cn-i-3jr8j4ixpe/90372116c2a748f0a86465b484e837',
        'vod_1080-2d5eea94b50490bccb4af14ab14dd83e',
        'qsvip-w0gKE54s5ZK245vs7U0uGTBWrRZNg_9Z2njz2WQmT0SY',
      ]) {
        expect(
          DramaVideo(
                  id: 'x',
                  title: 'x',
                  path: p,
                  source: 'pylg',
                  sourceCn: '自建蓝光',
                  episode: 1)
              .pathLooksPlayable,
          isTrue,
          reason: '$p 是橘汁令牌，resolveUrl 能换出真实地址',
        );
      }
    });

    test('播放器专用数字令牌仍判死', () {
      expect(
        DramaVideo(
                id: 'x',
                title: 'x',
                path: '7512797350914444313&1',
                source: 'hgdj',
                sourceCn: '独家短剧',
                episode: 1)
            .pathLooksPlayable,
        isFalse,
      );
    });
  });

  group('sourceOrder：按官方顺序', () {
    test('12 条线路原样保留接口顺序，自建在前、QQ 垫底', () {
      final m = zhuijuReal();
      final names = sortedSourceNames(
        m,
        policy: LineOrderPolicy.sourceOrder,
      );
      expect(names, m.keys.toList(),
          reason: '橘汁接口顺序就是编辑推荐顺序，任何重排都是帮倒忙');
      expect(names.first, '自建蓝光');
      expect(names.last, 'QQ');
    });

    test('默认选中的是自建蓝光，不是 QQ / B蓝光', () {
      final picked = pickDefaultSource(
        zhuijuReal(),
        policy: LineOrderPolicy.sourceOrder,
      );
      expect(picked, '自建蓝光');
      expect(picked, isNot('QQ'));
      expect(picked, isNot('B蓝光'));
    });

    test('整条不可播的独家短剧沉底，且不会被默认选中', () {
      final m = withDeadLine(zhuijuReal());
      final names = sortedSourceNames(
        m,
        policy: LineOrderPolicy.sourceOrder,
      );
      expect(names.last, '独家短剧');
      expect(names.first, '自建蓝光');
      expect(
        pickDefaultSource(m, policy: LineOrderPolicy.sourceOrder),
        '自建蓝光',
      );
    });

    test('换源候选包含令牌线路，不再只剩 QQ / B蓝光', () {
      final m = zhuijuReal();
      final cands = switchCandidates(
        m,
        m['自建蓝光']!.first,
        policy: LineOrderPolicy.sourceOrder,
      );
      final keys = cands.map(sourceKeyOf).toList();
      expect(keys, contains('自建4K-4'));
      expect(keys, contains('NN蓝光'));
      expect(keys.length, greaterThanOrEqualTo(10),
          reason: '10 条令牌线路过去被误判死、换源时全被过滤掉');
      expect(keys.first, '自建4K-4');
    });

    test('多次调用顺序稳定，不抖动', () {
      final m = zhuijuReal();
      final first = sortedSourceNames(m, policy: LineOrderPolicy.sourceOrder);
      for (var i = 0; i < 20; i++) {
        expect(sortedSourceNames(m, policy: LineOrderPolicy.sourceOrder), first);
      }
    });
  });

  group('byPreference：kanju 行为不被破坏', () {
    Map<String, List<DramaVideo>> kj() => <String, List<DramaVideo>>{
          '红牛资源': [kanjuLine('红牛资源', 'hnm3u8', false)],
          '1080P-官方Z': [kanjuLine('1080P-官方Z', 'bytedance', true)],
          '极速资源': [kanjuLine('极速资源', 'wsym3u8', false)],
        };

    test('官方优先：官方线排最前、默认选中', () {
      final m = kj();
      final names = sortedSourceNames(m);
      expect(names.first, '1080P-官方Z');
      expect(pickDefaultSource(m), '1080P-官方Z');
    });

    test('普通优先：直出线排最前', () {
      final names = sortedSourceNames(
        kj(),
        pref: LinePreference.directFirst,
      );
      expect(names.first, '红牛资源');
    });

    test('显式传 byPreference 与默认行为一致', () {
      expect(
        sortedSourceNames(kj(), policy: LineOrderPolicy.byPreference),
        sortedSourceNames(kj()),
      );
    });
  });
}
