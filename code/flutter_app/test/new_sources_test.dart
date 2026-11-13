/// 2026-11-13 新接入的 5 个采集站：配置契约 + 线路重排回归（不联网）。
///
/// 为什么这些配置需要被测试钉住：它们每一条都是**实测出来的常量**，
/// 而错一个的表现都极其隐蔽，靠人眼看不出来。
///
/// | 配错的东西 | 用户看到的现象 |
/// | --- | --- |
/// | 分类填了父分类 `1/2/3/4` | 点「电影」进去一片空白，以为源坏了 |
/// | `apiUrl` 少了结尾斜杠 | 请求 404，报「源站暂时不可用」 |
/// | 樱花没开 `searchViaPost` | 搜索永远 403，报「搜索失败」 |
/// | 线路没重排 | 详情页正常，点播放一直转圈 |
///
/// 这四类问题在联网测试里都很难定位（要么看起来像网络问题，要么像源站挂了），
/// 所以在这里用纯离线断言把它们钉死。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/maccms_api_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/source/site_sources.dart';

/// 从 [DataSource] 取回采集接口配置，顺便断言它确实是采集站。
MacCmsApiConfig cfgOf(Object source) {
  expect(source, isA<MacCmsApiSource>());
  return (source as MacCmsApiSource).cfg;
}

/// 把栏目里的逗号串拆成单个分类 id。
List<String> splitIds(String raw) =>
    raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

void main() {
  group('5 个新源的配置契约', () {
    final sources = <String, Object>{
      'dytt': kDyttSource,
      'guangsu': kGuangsuSource,
      'feifan': kFeifanSource,
      'maoyan': kMaoyanSource,
      'yinghua': kYinghuaSource,
    };

    test('id 与注册表里登记的一致', () {
      for (final entry in sources.entries) {
        final cfg = cfgOf(entry.value);
        expect(cfg.id, entry.key, reason: '${cfg.displayName} 的 id 被改过');
        // SourceRegistry.byId 在查不到时会**静默回退到默认源**，
        // 所以「id 没登记」不会报错，只会让用户点进去查到橘汁的片库。
        expect(
          SourceRegistry.all.any((s) => s.id == cfg.id),
          isTrue,
          reason: '${cfg.displayName} 没有在 registry.dart 里登记',
        );
      }
    });

    test('displayName / description 都非空', () {
      for (final s in sources.values) {
        final cfg = cfgOf(s);
        expect(cfg.displayName.trim(), isNotEmpty);
        expect(cfg.description.trim(), isNotEmpty,
            reason: '${cfg.displayName} 缺 description，设置页会显示空白');
      }
    });

    test('apiUrl 带结尾斜杠（否则 Dio 拼 query 会把末段当文件名吃掉）', () {
      for (final s in sources.values) {
        final cfg = cfgOf(s);
        expect(cfg.apiUrl.endsWith('/'), isTrue,
            reason: '${cfg.displayName} 的 apiUrl 少了结尾斜杠：${cfg.apiUrl}');
        expect(cfg.apiUrl, startsWith('http'));
        expect(cfg.apiUrl, contains('/api.php/provide/vod/'));
      }
    });

    test('分类首位是推荐（空 id）', () {
      for (final s in sources.values) {
        final cfg = cfgOf(s);
        expect(cfg.categories, isNotEmpty);
        expect(cfg.categories.first.id, '',
            reason: '${cfg.displayName} 的分类首位不是推荐');
        expect(cfg.categories.first.name, '推荐');
      }
    });

    test('分类名不重复，id 组合不重复', () {
      for (final s in sources.values) {
        final cfg = cfgOf(s);
        final names = cfg.categories.map((c) => c.name).toList();
        expect(names.toSet().length, names.length,
            reason: '${cfg.displayName} 有重名栏目');
        final ids = cfg.categories.map((c) => c.id).toList();
        expect(ids.toSet().length, ids.length,
            reason: '${cfg.displayName} 有两个栏目指向完全相同的分类串');
      }
    });
  });

  group('分类必须是子分类（父分类恒为空）', () {
    /// 父分类 id：1 电影 / 2 连续剧 / 3 综艺 / 4 动漫。
    /// 实测这批站点的 `t=1` 等父分类在 `ac=list` 下**一条都不返回**，
    /// 数据全挂在子分类上。填了父分类等于让用户点进一个空页。
    const parentIds = {'1', '2', '3', '4'};

    final sources = <String, Object>{
      'dytt': kDyttSource,
      'guangsu': kGuangsuSource,
      'feifan': kFeifanSource,
      'maoyan': kMaoyanSource,
      'yinghua': kYinghuaSource,
    };

    test('没有任何栏目直接使用父分类 id', () {
      for (final entry in sources.entries) {
        final cfg = cfgOf(entry.value);
        for (final cat in cfg.categories) {
          if (cat.id.isEmpty) continue; // 推荐位不传 t
          final ids = splitIds(cat.id);
          expect(ids, isNotEmpty);
          for (final id in ids) {
            expect(parentIds.contains(id), isFalse,
                reason: '${cfg.displayName} 的「${cat.name}」用了父分类 $id，'
                    '该分类在 ac=list 下是空的');
          }
        }
      }
    });

    test('分类 id 都是纯数字（逗号串逐项校验）', () {
      for (final s in sources.values) {
        final cfg = cfgOf(s);
        for (final cat in cfg.categories) {
          if (cat.id.isEmpty) continue;
          for (final id in splitIds(cat.id)) {
            expect(RegExp(r'^\d+$').hasMatch(id), isTrue,
                reason: '${cfg.displayName} 的「${cat.name}」有非法 id：$id');
          }
        }
      }
    });

    test('逗号串内部不留空格、不以逗号开头或结尾', () {
      // 逗号后面带空格在服务端是否被忽略无法保证，这里只保证我们发出去的是净串
      for (final s in sources.values) {
        final cfg = cfgOf(s);
        for (final cat in cfg.categories) {
          expect(cat.id, cat.id.trim());
          expect(cat.id.startsWith(','), isFalse);
          expect(cat.id.endsWith(','), isFalse);
          expect(cat.id.contains(' '), isFalse);
        }
      }
    });
  });

  group('searchViaPost 只对樱花打开', () {
    test('樱花必须走 POST（GET 会被 nginx 拦成 403）', () {
      expect(cfgOf(kYinghuaSource).searchViaPost, isTrue);
    });

    test('其余 4 个源保持 GET（GET 可被缓存，能用就别换）', () {
      for (final s in [kDyttSource, kGuangsuSource, kFeifanSource, kMaoyanSource]) {
        expect(cfgOf(s).searchViaPost, isFalse,
            reason: '${cfgOf(s).displayName} 没有 403 问题，不该走 POST');
      }
    });
  });

  group('preferDirectLine 全部打开', () {
    test('5 个源都要求把直出线路提到前面', () {
      // 非凡 / 电影天堂的分享页里抠不出 m3u8（靠 JS 渲染），
      // 不重排就会「点进去播放没出来」。默认值是 true，但不能只靠默认值——
      // 显式断言能防止以后有人改默认值把这批源一起带崩。
      for (final s in [
        kDyttSource,
        kGuangsuSource,
        kFeifanSource,
        kMaoyanSource,
        kYinghuaSource,
      ]) {
        expect(cfgOf(s).preferDirectLine, isTrue,
            reason: '${cfgOf(s).displayName} 关掉了线路重排');
      }
    });
  });

  group('线路名映射', () {
    test('每个源都给直出线路配了中文名（不然面板显示 ym3u8 这种标识）', () {
      final expectM3u8 = <Object, String>{
        kDyttSource: 'dyttm3u8',
        kGuangsuSource: 'gsm3u8',
        kFeifanSource: 'ffm3u8',
        kMaoyanSource: 'mym3u8',
        kYinghuaSource: 'yhm3u8',
      };
      for (final entry in expectM3u8.entries) {
        final cfg = cfgOf(entry.key);
        expect(cfg.lineNameCn.containsKey(entry.value), isTrue,
            reason: '${cfg.displayName} 缺 ${entry.value} 的中文名');
        expect(cfg.lineNameCn[entry.value]!.trim(), isNotEmpty);
      }
    });

    test('中文名不重复（同名会让线路面板分不清哪条是哪条）', () {
      for (final s in [
        kDyttSource,
        kGuangsuSource,
        kFeifanSource,
        kMaoyanSource,
        kYinghuaSource,
      ]) {
        final cfg = cfgOf(s);
        final names = cfg.lineNameCn.values.toList();
        expect(names.toSet().length, names.length,
            reason: '${cfg.displayName} 有重名线路');
      }
    });
  });

  group('sortDirectLinesFirst（播放能不能出来全靠它）', () {
    ApiLine line(String flag, String url) => ApiLine(
          flag: flag,
          name: flag,
          eps: [ApiEpisode(title: '第1集', url: url)],
        );

    test('网页分享页在后 → 直出提到最前', () {
      // 真实形态：feifan 源给的第 1 条是 share 页，第 2 条才是 m3u8
      final out = sortDirectLinesFirst([
        line('feifan', 'https://super.ffzy-online6.com/share/3df77411'),
        line('ffm3u8', 'https://cdn.ffzy.com/20261102/44636_3df77411/index.m3u8'),
      ]);
      expect(out.first.flag, 'ffm3u8');
      expect(out.last.flag, 'feifan');
      expect(out.length, 2, reason: '网页线路不能丢，少数能二次解析出来');
    });

    test('本来就是直出在前时顺序不变（不做无意义的洗牌）', () {
      final out = sortDirectLinesFirst([
        line('a', 'https://a.com/1.m3u8'),
        line('b', 'https://b.com/share/xxx'),
      ]);
      expect(out.map((e) => e.flag).toList(), ['a', 'b']);
    });

    test('全直出时保持站方原有次序（sort 不稳定会打乱质量排序）', () {
      final out = sortDirectLinesFirst([
        line('1', 'https://a.com/1.m3u8'),
        line('2', 'https://a.com/2.m3u8'),
        line('3', 'https://a.com/3.mp4'),
      ]);
      expect(out.map((e) => e.flag).toList(), ['1', '2', '3']);
    });

    test('全网页时原样返回，长度与顺序都不变', () {
      final input = [
        line('x', 'https://a.com/share/1'),
        line('y', 'https://a.com/share/2'),
      ];
      final out = sortDirectLinesFirst(input);
      expect(out.map((e) => e.flag).toList(), ['x', 'y']);
    });

    test('0 条 / 1 条不炸', () {
      expect(sortDirectLinesFirst(const []).length, 0);
      final one = [line('only', 'https://a.com/share/1')];
      expect(sortDirectLinesFirst(one).single.flag, 'only');
    });

    test('空线路（没有集）不进 direct 组，沉到后面', () {
      const empty = ApiLine(flag: 'empty', name: 'empty', eps: []);
      final out = sortDirectLinesFirst([
        empty,
        line('real', 'https://a.com/1.m3u8'),
      ]);
      expect(out.first.flag, 'real');
      expect(out.last.flag, 'empty');
    });

    test('大小写混写的 M3U8 / MP4 也认', () {
      final out = sortDirectLinesFirst([
        line('web', 'https://a.com/share/x'),
        line('up', 'https://a.com/1.M3U8'),
        line('mp', 'https://a.com/1.MP4'),
      ]);
      expect(out.first.flag, 'up');
      expect(out[1].flag, 'mp');
      expect(out.last.flag, 'web');
    });
  });

  group('注册表分组与排序', () {
    test('5 个新源归在「采集站（直连）」组', () {
      for (final s in [
        kDyttSource,
        kGuangsuSource,
        kFeifanSource,
        kMaoyanSource,
        kYinghuaSource,
      ]) {
        expect(SourceRegistry.groupOf(s), '采集站（直连）');
        expect(SourceRegistry.needsProxy(s), isFalse,
            reason: '${s.displayName} 国内直连可用，不该被标成需代理');
      }
    });

    test('橘汁仍在第一位（用户指定的默认源）', () {
      expect(SourceRegistry.all.first.id, 'zhuiju');
      expect(SourceRegistry.groupOf(SourceRegistry.all.first), '默认');
    });

    test('前 6 个的相对次序不变', () {
      // 用户明确要求：默认橘汁，后面依次追剧 / 暴风 / 量子 / 片库 / 可可影视
      const want = ['zhuiju', 'kanju', 'bofeng', 'liangzi', 'pianku', 'keke1'];
      expect(SourceRegistry.all.take(6).map((e) => e.id).toList(), want);
    });

    test('采集站按实测速度升序：dytt < guangsu < feifan < maoyan < yinghua', () {
      const want = ['dytt', 'guangsu', 'feifan', 'maoyan', 'yinghua'];
      final ids = SourceRegistry.all.map((e) => e.id).toList();
      final pos = want.map(ids.indexOf).toList();
      expect(pos.every((i) => i >= 0), isTrue, reason: '有源没登记');
      for (var i = 1; i < pos.length; i++) {
        expect(pos[i] > pos[i - 1], isTrue,
            reason: '${want[i]} 应排在 ${want[i - 1]} 之后（实测更快）');
      }
    });

    test('需代理的源全部排在 5 个采集站之后', () {
      final ids = SourceRegistry.all.map((e) => e.id).toList();
      final lastDirect = ids.indexOf('yinghua');
      for (final id in ['kvm4k', 'jisu', 'yuny', 'ddys']) {
        final at = ids.indexOf(id);
        expect(at, greaterThan(lastDirect),
            reason: '$id 需要代理，必须沉到直连源后面');
        expect(SourceRegistry.needsProxy(SourceRegistry.instance.byId(id)), isTrue);
      }
    });

    test('分组顺序固定：默认 → 常用 → 采集站（直连）→ 需系统代理', () {
      expect(SourceRegistry.groupOrder,
          ['默认', '常用', '采集站（直连）', '需系统代理']);
    });
  });
}