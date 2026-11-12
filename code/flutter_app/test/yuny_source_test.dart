/// 云影（yuny.app）适配器的离线回归测试。
///
/// 所有样本都取自 2026-11-12 的真实响应（字段名、嵌套层次原样保留），
/// 只把长文本截短、把无关字段删掉。
///
/// 这里重点钉四条**实测踩过或极易踩**的规则：
///   1. 业务失败也是 HTTP 200，只看状态码会把错误当成功；
///   2. 详情接口用 `videoChannelList` / `videoSelectResList`，
///      前端 bundle 里另一套代码用 `lines` / `selects`，两个都要认；
///   3. **各线路集数不一致**（实测 5/7/8/8/8），不能按最长线路铺满；
///   4. `resource` 本身就是 m3u8，播放不该再发请求。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/source/data_source.dart';
import 'package:zhuiju/core/source/registry.dart';
import 'package:zhuiju/core/source/yuny_source.dart';

// ------------------------------ 真实样本 ------------------------------

/// 搜索/分类/首页列表共用的一套记录字段（取自「权力」的搜索结果）。
const String _kListJson = '''
{"success":true,"code":200,"msg":"操作成功","data":{
  "records":[
    {"id":"259266","name":"权力交锋","cover":"https://static.yuny.bar/a.webp",
     "tags":null,"description":"剧情简介一","remark":"第8集","hot":"0",
     "score":null,"isDeleted":null,"doubanId":null,"totalCommentCount":null},
    {"id":"128480","name":"权力的游戏","cover":"https://static.yuny.bar/b.webp",
     "tags":"短片","description":"剧情简介二","remark":"2022年08月25日上映",
     "hot":"0","score":8.7,"isDeleted":null,"doubanId":null,"totalCommentCount":null}
  ],
  "total":43,"size":24,"current":1,"types":[],"corrected":null,"pages":2}}
''';

/// 首页「今日更新」：列表在 `list` 而不是 `records`。
const String _kHomeJson = '''
{"success":true,"code":200,"msg":"操作成功","data":{
  "list":[
    {"id":"199994","name":"今天是太阳雨","cover":"https://static.yuny.bar/c.webp",
     "tags":"","description":"&nbsp;生活困苦的生物系学生","remark":"共24集，更新至0集",
     "hot":"20261111000041","score":null,"isDeleted":null,"doubanId":null,
     "totalCommentCount":null}
  ],
  "total":638,"hasMore":true}}
''';

/// 业务失败：HTTP 200 但 success=false。
const String _kFailJson =
    '{"success":false,"code":500,"msg":"参数错误","data":null}';

/// 详情：5 条线路，集数 5/7/8/8/8（真实数据，id 也都是真的）。
const String _kDetailJson = '''
{"success":true,"code":200,"msg":"操作成功","data":{
  "id":"259266","name":"换座位后发现身后的男生好像喜欢我",
  "cover":"https://static.yuny.bar/app/video/info/cover/2026/08/06/a838a3dde4fd3cb45604d1163edc9420.webp",
  "remark":"第8集","hot":"0","score":null,
  "tagList":[{"tagName":"中山佳香","tagType":1},{"tagName":"小西咏斗","tagType":2}],
  "years":"2026","area":"日本","language":"日语","type":"剧集",
  "description":"我喜欢你，从很早以前就开始了。",
  "director":"中山佳香","performer":"小西咏斗,元之介",
  "actorList":[],
  "videoChannelList":[
    {"collectChannelName":"普通线路yz","collectNum":5,"videoSelectResList":[
      {"id":"15836917","series":"第01集","resourceType":1,
       "resource":"https://player.yzzyvip-35.com/20260806/12819_7b951cd0/index.m3u8","danmuUrl":null},
      {"id":"15836918","series":"第02集","resourceType":1,
       "resource":"https://player.yzzyvip-35.com/20260806/12819_b/index.m3u8","danmuUrl":null},
      {"id":"15836919","series":"第03集","resourceType":1,
       "resource":"https://player.yzzyvip-35.com/20260806/12819_c/index.m3u8","danmuUrl":null},
      {"id":"15836920","series":"第04集","resourceType":1,
       "resource":"https://player.yzzyvip-35.com/20260806/12819_d/index.m3u8","danmuUrl":null},
      {"id":"15836921","series":"第05集","resourceType":1,
       "resource":"https://player.yzzyvip-35.com/20260806/12819_e/index.m3u8","danmuUrl":null}
    ]},
    {"collectChannelName":"普通线路ik","collectNum":7,"videoSelectResList":[
      {"id":"15885545","series":"第01集","resourceType":1,
       "resource":"https://bfikuncdn.com/20260806/607Ttja4/index.m3u8","danmuUrl":null},
      {"id":"15885546","series":"第02集","resourceType":1,
       "resource":"https://bfikuncdn.com/20260806/607b/index.m3u8","danmuUrl":null},
      {"id":"15885547","series":"第03集","resourceType":1,
       "resource":"https://bfikuncdn.com/20260806/607c/index.m3u8","danmuUrl":null},
      {"id":"15885548","series":"第04集","resourceType":1,
       "resource":"https://bfikuncdn.com/20260806/607d/index.m3u8","danmuUrl":null},
      {"id":"15885549","series":"第05集","resourceType":1,
       "resource":"https://bfikuncdn.com/20260806/607e/index.m3u8","danmuUrl":null},
      {"id":"15885550","series":"第06集","resourceType":1,
       "resource":"https://bfikuncdn.com/20260806/607f/index.m3u8","danmuUrl":null},
      {"id":"15885551","series":"第07集","resourceType":1,
       "resource":"https://bfikuncdn.com/20260806/607g/index.m3u8","danmuUrl":null}
    ]},
    {"collectChannelName":"普通线路xg","collectNum":8,"videoSelectResList":[
      {"id":"19906854","series":"第01集","resourceType":1,
       "resource":"https://svip.xgplay20.com/2026-08-06/44348_a01/index.m3u8","danmuUrl":null},
      {"id":"19906855","series":"第02集","resourceType":1,
       "resource":"https://svip.xgplay20.com/2026-08-06/44348_a02/index.m3u8","danmuUrl":null},
      {"id":"19906856","series":"第03集","resourceType":1,
       "resource":"https://svip.xgplay20.com/2026-08-06/44348_a03/index.m3u8","danmuUrl":null},
      {"id":"19906857","series":"第04集","resourceType":1,
       "resource":"https://svip.xgplay20.com/2026-08-06/44348_a04/index.m3u8","danmuUrl":null},
      {"id":"19906858","series":"第05集","resourceType":1,
       "resource":"https://svip.xgplay20.com/2026-08-06/44348_a05/index.m3u8","danmuUrl":null},
      {"id":"19906859","series":"第06集","resourceType":1,
       "resource":"https://svip.xgplay20.com/2026-08-06/44348_a06/index.m3u8","danmuUrl":null},
      {"id":"19906860","series":"第07集","resourceType":1,
       "resource":"https://svip.xgplay20.com/2026-08-06/44348_a07/index.m3u8","danmuUrl":null},
      {"id":"19906861","series":"第08集","resourceType":1,
       "resource":"https://svip.xgplay20.com/2026-08-06/44348_a08/index.m3u8","danmuUrl":null}
    ]},
    {"collectChannelName":"普通线路js","collectNum":8,"videoSelectResList":[
      {"id":"15877891","series":"第1集","resourceType":1,
       "resource":"https://vv.jisuzyv.com/play/axk2YV9e/index.m3u8","danmuUrl":null},
      {"id":"15877892","series":"第2集","resourceType":1,
       "resource":"https://vv.jisuzyv.com/play/axk2b/index.m3u8","danmuUrl":null},
      {"id":"15877893","series":"第3集","resourceType":1,
       "resource":"https://vv.jisuzyv.com/play/axk2c/index.m3u8","danmuUrl":null},
      {"id":"15877894","series":"第4集","resourceType":1,
       "resource":"https://vv.jisuzyv.com/play/axk2d/index.m3u8","danmuUrl":null},
      {"id":"15877895","series":"第5集","resourceType":1,
       "resource":"https://vv.jisuzyv.com/play/axk2e/index.m3u8","danmuUrl":null},
      {"id":"15877896","series":"第6集","resourceType":1,
       "resource":"https://vv.jisuzyv.com/play/axk2f/index.m3u8","danmuUrl":null},
      {"id":"15877897","series":"第7集","resourceType":1,
       "resource":"https://vv.jisuzyv.com/play/axk2g/index.m3u8","danmuUrl":null},
      {"id":"15877898","series":"第8集","resourceType":1,
       "resource":"https://vv.jisuzyv.com/play/axk2h/index.m3u8","danmuUrl":null}
    ]},
    {"collectChannelName":"普通线路ry","collectNum":8,"videoSelectResList":[
      {"id":"15854569","series":"第01集","resourceType":1,
       "resource":"https://svip.ryplay14.com/20260806/17859_a/index.m3u8","danmuUrl":null},
      {"id":"15854570","series":"第02集","resourceType":1,
       "resource":"https://svip.ryplay14.com/20260806/17859_b/index.m3u8","danmuUrl":null},
      {"id":"15854571","series":"第03集","resourceType":1,
       "resource":"https://svip.ryplay14.com/20260806/17859_c/index.m3u8","danmuUrl":null},
      {"id":"15854572","series":"第04集","resourceType":1,
       "resource":"https://svip.ryplay14.com/20260806/17859_d/index.m3u8","danmuUrl":null},
      {"id":"15854573","series":"第05集","resourceType":1,
       "resource":"https://svip.ryplay14.com/20260806/17859_e/index.m3u8","danmuUrl":null},
      {"id":"15854574","series":"第06集","resourceType":1,
       "resource":"https://svip.ryplay14.com/20260806/17859_f/index.m3u8","danmuUrl":null},
      {"id":"15854575","series":"第07集","resourceType":1,
       "resource":"https://svip.ryplay14.com/20260806/17859_g/index.m3u8","danmuUrl":null},
      {"id":"15854576","series":"第08集","resourceType":1,
       "resource":"https://svip.ryplay14.com/20260806/17859_h/index.m3u8","danmuUrl":null}
    ]}
  ]}}
''';

/// 前端 bundle 里另一套命名：`lines` / `selects` / `lineSourceName`。
const String _kDetailAltJson = '''
{"success":true,"code":200,"msg":"操作成功","data":{
  "id":"1","name":"别名结构","cover":"",
  "lines":[{"lineSourceName":"线路A","selects":[
    {"id":"90001","series":"第01集","resourceType":1,"resource":"https://x/a.m3u8"},
    {"id":"90002","series":"第02集","resourceType":1,"resource":"https://x/b.m3u8"}
  ]}]}}
''';

void main() {
  // ---------------------------- 响应壳 ----------------------------

  group('yunyUnwrap', () {
    test('success=true 时取回 data', () {
      final d = yunyUnwrap(_kListJson);
      expect(d['total'], 43);
      expect((d['records'] as List).length, 2);
    });

    test('success=false 抛业务错误（HTTP 200 也可能是失败）', () {
      expect(
        () => yunyUnwrap(_kFailJson),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'msg',
          contains('参数错误'),
        )),
      );
    });

    test('不是 JSON 时给出可读错误', () {
      expect(() => yunyUnwrap('<html>502</html>'), throwsA(isA<Exception>()));
    });

    test('data 为 null 时返回空表而不是崩', () {
      const body = '{"success":true,"code":200,"msg":"ok","data":null}';
      expect(yunyUnwrap(body), isEmpty);
    });
  });

  // ---------------------------- 列表 ----------------------------

  group('parseYunyList', () {
    test('解析 records（分类/搜索）', () {
      final list = parseYunyList(_kListJson, sourceId: 'yuny');
      expect(list.length, 2);
      expect(list[0].id, '259266');
      expect(list[0].name, '权力交锋');
      expect(list[0].remark, '第8集');
      expect(list[0].sourceId, 'yuny');
      expect(list[0].cover.path, startsWith('https://'));
    });

    test('解析 list（首页今日更新用的是这个键）', () {
      final list = parseYunyList(_kHomeJson, sourceId: 'yuny');
      expect(list.length, 1);
      expect(list[0].id, '199994');
      expect(list[0].name, '今天是太阳雨');
    });

    test('&nbsp; 会被清成普通空格', () {
      final list = parseYunyList(_kHomeJson, sourceId: 'yuny');
      expect(list[0].brief.contains('\u00a0'), isFalse);
    });

    test('分数是字符串时也能取到', () {
      final list = parseYunyList(_kListJson, sourceId: 'yuny');
      expect(list[1].stars, 8.7);
    });

    test('空响应返回空表', () {
      expect(parseYunyList('{"success":true,"data":{}}', sourceId: 'yuny'),
          isEmpty);
    });
  });

  // ---------------------------- 详情 ----------------------------

  group('parseYunyDetail', () {
    final d = parseYunyDetail('259266', _kDetailJson, sourceId: 'yuny');

    test('元信息齐全', () {
      expect(d.id, '259266');
      expect(d.name, '换座位后发现身后的男生好像喜欢我');
      expect(d.area, '日本');
      expect(d.year, 2026);
      expect(d.director, '中山佳香');
      expect(d.actor, '小西咏斗,元之介');
      expect(d.brief, contains('我喜欢你'));
      expect(d.cover.path, startsWith('https://'));
    });

    test('五条线路各自独立，集数 5/7/8/8/8', () {
      final byLine = <String, int>{};
      for (final v in d.videos) {
        byLine[v.sourceCn] = (byLine[v.sourceCn] ?? 0) + 1;
      }
      expect(byLine.length, 5);
      expect(byLine['普通线路yz'], 5);
      expect(byLine['普通线路ik'], 7);
      expect(byLine['普通线路xg'], 8);
      expect(byLine['普通线路js'], 8);
      expect(byLine['普通线路ry'], 8);
      expect(d.videos.length, 5 + 7 + 8 + 8 + 8);
    });

    test('回归：不能按最长线路铺满短线路', () {
      // 早期实现用「最大集数」给所有线路生成条目，结果 yz 线路会多出
      // 3 条根本不存在的剧集。这里逐线路核对集号上限。
      final maxEp = <String, int>{};
      for (final v in d.videos) {
        final cur = maxEp[v.sourceCn] ?? 0;
        if (v.episode > cur) maxEp[v.sourceCn] = v.episode;
      }
      expect(maxEp['普通线路yz'], 5);
      expect(maxEp['普通线路ik'], 7);
      expect(d.videos.where((v) => v.sourceCn == '普通线路yz' && v.episode > 5),
          isEmpty);
    });

    test('path 直接就是 m3u8（播放零请求）', () {
      final v = d.videos.first;
      expect(v.path, startsWith('https://'));
      expect(v.path, contains('.m3u8'));
    });

    test('playToken 存的是选集 id（resource 缺失时兜底取址）', () {
      final v = d.videos.first;
      expect(v.playToken, '15836917');
    });

    test('「第1集」和「第01集」两种写法都能抠出集号', () {
      // js 线路用「第1集」，其它用「第01集」。
      final js = d.videos.firstWhere((v) => v.sourceCn == '普通线路js');
      expect(js.episode, 1);
      expect(js.title, '第1集');
      final yz = d.videos.firstWhere((v) => v.sourceCn == '普通线路yz');
      expect(yz.episode, 1);
    });

    test('兼容 lines/selects/lineSourceName 这套别名', () {
      final alt = parseYunyDetail('1', _kDetailAltJson, sourceId: 'yuny');
      expect(alt.videos.length, 2);
      expect(alt.videos.first.sourceCn, '线路A');
      expect(alt.videos.first.playToken, '90001');
    });

    test('剧集 id 带源前缀且全局唯一', () {
      final ids = d.videos.map((v) => v.id).toSet();
      expect(ids.length, d.videos.length);
      expect(d.videos.first.id, startsWith('yuny_259266_'));
    });

    // ===== 回归：用户报「好多点进去后没有播放线路、只能看到个详情」 =====

    test('resourceType=2 的选集全部丢弃（covip / 爱奇艺 / 腾讯网页）', () {
      // 全量实测 30 部剧 1500+ 条选集：resourceType 与形态一一对应没有例外。
      //   1 → 1701/1701 全是 m3u8
      //   2 → 1159/1159 全部不可播
      // 早先只按 URL 字符串判断，`covip_*` 这种「不是 http 开头」的编码
      // 虽然也被丢掉了，但语义不明确，站点换采集源就会漏。
      const json = '''
{"success":true,"code":200,"msg":"操作成功","data":{
 "id":"391085","name":"高危禁药我却越喝越强",
 "videoChannelList":[
  {"collectChannelName":"精品线路1","videoSelectResList":[
    {"id":"25399292","series":"第1集","resourceType":2,"resource":"covip_klb27zd6xi4age6twg6lzyi"},
    {"id":"25399293","series":"第2集","resourceType":2,"resource":"covip_klb27zd6xi4age6twg6lzyq"}
  ]},
  {"collectChannelName":"官方线路1","videoSelectResList":[
    {"id":"25559060","series":"第1集","resourceType":2,"resource":"http://www.iqiyi.com/v_1r92ohumtj4.html"},
    {"id":"25559061","series":"第2集","resourceType":2,"resource":"https://v.qq.com/x/cover/mzc002000s9f77y/k4102b5k1da.html"}
  ]},
  {"collectChannelName":"普通线路js","videoSelectResList":[
    {"id":"25559062","series":"第1集","resourceType":1,"resource":"https://vv.jisuzyv.com/play/ejRvB5ve/index.m3u8"}
  ]}
 ]}}
''';
      final r = parseYunyDetail('391085', json, sourceId: 'yuny');
      expect(r.videos.length, 1, reason: '只剩普通线路那 1 集可播');
      expect(r.videos.single.sourceCn, '普通线路js');
      expect(r.videos.single.path, contains('jisuzyv.com'));
      expect(r.videos.single.playToken, '25559062');
    });

    test('resourceType=1 即使 URL 无后缀也放行（以类型为准）', () {
      // 站点有些采集源给的是无后缀直链，靠字符串判断会误杀。
      const json = '''
{"success":true,"code":200,"data":{"id":"1","name":"某剧",
 "videoChannelList":[{"collectChannelName":"线路1","videoSelectResList":[
   {"id":"100","series":"第1集","resourceType":1,"resource":"https://cdn.example.com/stream/abc"}
 ]}]}}
''';
      final r = parseYunyDetail('1', json, sourceId: 'yuny');
      expect(r.videos.length, 1);
      expect(r.videos.single.path, 'https://cdn.example.com/stream/abc');
    });

    test('resourceType 缺失时才退回 URL 字符串判断', () {
      const json = '''
{"success":true,"code":200,"data":{"id":"1","name":"某剧",
 "videoChannelList":[{"collectChannelName":"线路1","videoSelectResList":[
   {"id":"100","series":"第1集","resource":"https://cdn.example.com/a.m3u8"},
   {"id":"101","series":"第2集","resource":"http://www.iqiyi.com/v_x.html"},
   {"id":"102","series":"第3集","resource":"covip_abc123"}
 ]}]}}
''';
      final r = parseYunyDetail('1', json, sourceId: 'yuny');
      expect(r.videos.length, 1, reason: '只有 .m3u8 那条能过');
      expect(r.videos.single.playToken, '100');
    });
  });

  // ---------------------------- 契约 ----------------------------

  group('YunySource 契约', () {
    final s = YunySource.instance;

    test('基本声明', () {
      expect(s.id, 'yuny');
      expect(s.displayName, '云影');
      expect(s.description, isNotEmpty);
      expect(s.supportsDanmaku, isFalse);
      expect(s.lineOrderPolicy, LineOrderPolicy.sourceOrder);
    });

    test('分类首位是推荐（空 id）', () {
      expect(s.categories.first.id, '');
      expect(s.categories.length, 6);
    });

    test('分类用中文名（label-v2 的 type 认中文，不认数字）', () {
      final ids = s.categories.map((c) => c.id).toList();
      expect(ids, containsAll(<String>['电影', '剧集', '动漫', '综艺', '短剧']));
    });
  });

  group('注册表', () {
    test('云影已登记在册', () {
      final registry = SourceRegistry.instance;
      expect(registry.byId('yuny').id, 'yuny');
      expect(SourceRegistry.all.any((e) => e.id == 'yuny'), isTrue);
    });
  });

  // ---------------------------- 真实响应复验 ----------------------------

  test('真实分类响应字段与解析器匹配', () {
    // 这条不读文件：把真实响应的「形状」写死在这里做结构断言，
    // 站点一旦改字段名（比如 records → rows），这里会先炸。
    final d = jsonDecode(_kListJson) as Map<String, dynamic>;
    final data = d['data'] as Map<String, dynamic>;
    expect(data.containsKey('records'), isTrue);
    expect(data.containsKey('total'), isTrue);
    expect(data.containsKey('pages'), isTrue);
    final r0 = (data['records'] as List).first as Map<String, dynamic>;
    for (final k in ['id', 'name', 'cover', 'description', 'remark']) {
      expect(r0.containsKey(k), isTrue, reason: '记录缺少字段 $k');
    }
  });
}