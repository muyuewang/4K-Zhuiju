/// 2026-11-14 复测挖回的三个采集站（索尼 / 无尽 / 金鹰）的**配置契约**。
///
/// ## 为什么这三个站值得单独一个测试文件
///
/// 它们不是「又一个同类源」，而是**一次误判的纠错**：11-13 那轮初筛
/// 只测父分类（`t=1` 电影 / `t=2` 电视剧 / `t=3` 综艺 / `t=4` 动漫），
/// 三站全部返回 0 条，于是被当作「没有分类结构」跳过。
///
/// 逐个遍历 `class` 数组才发现货全在别处：索尼/无尽是**扁平结构**
/// （父分类是空壳，`t=6 动作片` 这类看着像子分类的才是顶层），
/// 金鹰是真两级树（父空、子有货）。
///
/// 所以这里除了常规契约，**专门锁死「不许再用空壳父分类」**这一条：
/// 以后有人「顺手简化」把 `6,7,8,9,10,11,12` 改成 `1 电影`，
/// 界面上会立刻变成点开全空的 Tab，而不会报任何错。
///
/// 纯离线，不联网。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/source/maccms_api_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/source/site_sources.dart';

/// 三站在实测中**确认 0 条**的父分类。
///
/// 索尼/无尽：`1,2,3,4` 全空 + 无尽多一个 `5 资讯`；
/// 金鹰：`1,27,29,30`，其中 `30` 还是「短剧」父级（子级 40~48 才有货）。
const Map<String, Set<String>> kEmptyParents = {
  'suoni': {'1', '2', '3', '4', '48', '52', '74'},
  'wujin': {'1', '2', '3', '4', '5', '17', '18', '38'},
  'jinying': {'1', '17', '27', '29', '30'},
};

void main() {
  MacCmsApiConfig cfgOf(Object src) => (src as MacCmsApiSource).cfg;

  group('三个新源的基本契约', () {
    final sources = <String, Object>{
      'suoni': kSuoniSource,
      'wujin': kWujinSource,
      'jinying': kJinyingSource,
    };

    test('都是 JSON 格式、都走 ac=detail 换封面', () {
      for (final e in sources.entries) {
        final c = cfgOf(e.value);
        expect(c.id, e.key);
        expect(c.format, MacCmsFormat.json,
            reason: '${c.displayName} 是标准 JSON 采集站');
        expect(c.listNeedsDetail, isTrue,
            reason: '${c.displayName} 的 ac=list 实测封面 0/20，必须走 detail');
        // 批量补封面是 XML 站（优子）才会用到的路径，JSON 站不该开
        expect(c.listNeedsBatchDetail, isFalse, reason: '${c.displayName} 是 JSON 站');
      }
    });

    test('apiUrl 都以结尾斜杠收口（否则拼 query 会吃掉最后一段）', () {
      for (final e in sources.entries) {
        final url = cfgOf(e.value).apiUrl;
        expect(url.endsWith('/'), isTrue, reason: '$url 缺结尾斜杠');
        expect(url.startsWith('https://'), isTrue,
            reason: '$url 应该走 https（三站实测 https 均可用）');
      }
    });

    test('都已登记进注册表，且归到「采集站（直连）」组、不需代理', () {
      for (final id in sources.keys) {
        expect(SourceRegistry.all.any((s) => s.id == id), isTrue,
            reason: '$id 没进 SourceRegistry._all，界面里根本看不到');
      }
      for (final e in sources.entries) {
        expect(SourceRegistry.groupOf(e.value as dynamic), '采集站（直连）');
        expect(SourceRegistry.needsProxy(e.value as dynamic), isFalse);
      }
    });

    test('每个源都有「推荐」首位（空 id）', () {
      for (final e in sources.entries) {
        final cats = cfgOf(e.value).categories;
        expect(cats.first.id, isEmpty, reason: '${e.key} 首位必须是推荐位');
        expect(cats.first.name, '推荐');
      }
    });
  });

  group('分类配置：不许出现实测为空的父分类', () {
    test('索尼 / 无尽 / 金鹰的栏目 id 全部落在「有货」集合里', () {
      for (final e in <String, Object>{
        'suoni': kSuoniSource,
        'wujin': kWujinSource,
        'jinying': kJinyingSource,
      }.entries) {
        final empty = kEmptyParents[e.key]!;
        for (final cat in cfgOf(e.value).categories) {
          if (cat.id.isEmpty) continue;
          for (final id in cat.id.split(',')) {
            expect(empty.contains(id.trim()), isFalse,
                reason: '${e.key} 的「${cat.name}」用了 ${id.trim()}，'
                    '该分类实测 total=0，点进去会是空 Tab');
          }
        }
      }
    });

    test('索尼是扁平结构：必须有 6/11 这类「看着像子分类」的顶层 id', () {
      final ids = cfgOf(kSuoniSource)
          .categories
          .expand((c) => c.id.split(','))
          .where((s) => s.isNotEmpty)
          .toSet();
      // 剧情片 26118、动作片 5707 —— 这站最大的两个分类
      expect(ids.contains('11'), isTrue, reason: '剧情片 26,118 条，不能漏');
      expect(ids.contains('6'), isTrue, reason: '动作片 5,707 条');
      expect(ids.contains('69'), isTrue, reason: '现代都市 12,362 条');
    });

    test('金鹰的短剧必须用子分类 40~48，不能用父级 30', () {
      final shortDrama = cfgOf(kJinyingSource)
          .categories
          .firstWhere((c) => c.name == '短剧');
      final ids = shortDrama.id.split(',').map((s) => s.trim()).toSet();
      expect(ids.contains('30'), isFalse, reason: 't=30 是空壳父分类');
      // 现代都市 15823 是这站最大分类之一，必须在
      expect(ids.contains('41'), isTrue);
      expect(ids.length, greaterThanOrEqualTo(6),
          reason: '金鹰短剧有 8 个子分类，只配 2~3 个会丢掉大部分内容');
    });

    test('三站都配了独立「短剧」栏目（这类站短剧体量最大）', () {
      for (final e in <String, Object>{
        'suoni': kSuoniSource,
        'wujin': kWujinSource,
        'jinying': kJinyingSource,
      }.entries) {
        final names = cfgOf(e.value).categories.map((c) => c.name).toList();
        expect(names.contains('短剧'), isTrue, reason: '${e.key} 缺短剧栏目');
      }
    });

    test('刻意不收的成人类栏目不能出现在配置里', () {
      // 这些分类源站确实有（索尼 4000+ 条），但本项目明确不做入口。
      // 用名字断言而不是 id：id 各站不同，名字是稳定的。
      const banned = {'伦理', '港台三级', '韩国伦理', '西方伦理', '日本伦理',
          '两性课堂', '写真热舞', '伦理片'};
      for (final e in <Object, String>{
        kSuoniSource: 'suoni',
        kWujinSource: 'wujin',
        kJinyingSource: 'jinying',
      }.entries) {
        for (final cat in cfgOf(e.key).categories) {
          expect(banned.contains(cat.name), isFalse,
              reason: '${e.value} 收了「${cat.name}」，这个栏目明确不做');
        }
      }
    });
  });

  group('线路配置', () {
    test('索尼 / 无尽 是单线路，中文名必须配上', () {
      expect(cfgOf(kSuoniSource).lineNameCn['snm3u8'], '索尼线路');
      expect(cfgOf(kWujinSource).lineNameCn['wjm3u8'], '无尽线路');
    });

    test('金鹰两条线路都要有中文名（jinyingyun 是网页页，也得给名字）', () {
      final m = cfgOf(kJinyingSource).lineNameCn;
      expect(m['jinyingm3u8'], '金鹰线路');
      expect(m['jinyingyun'], '金鹰网页');
      expect(m.length, 2);
    });

    test('三站都靠 preferDirectLine 把直出顶前（金鹰首条是网页页）', () {
      for (final s in [kSuoniSource, kWujinSource, kJinyingSource]) {
        expect(cfgOf(s).preferDirectLine, isTrue,
            reason: '${cfgOf(s).displayName} 需要把 m3u8 线路排到网页线路前面');
      }
    });

    test('都不开 derivePlayIndex（没有 /play/<token> 空壳页的推导需求）', () {
      for (final s in [kSuoniSource, kWujinSource, kJinyingSource]) {
        expect(cfgOf(s).derivePlayIndex, isFalse,
            reason: '${cfgOf(s).displayName} 实测线路地址本身就是完整 m3u8');
      }
    });
  });
}