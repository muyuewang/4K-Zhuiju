/// MacCMS **XML** 站的端到端验证。
///
/// 这条测试和 `plugin_script_test.dart` 是一对：那个测 JSON 版脚本，
/// 这个测 XML 版。两者输出结构必须一致，否则 index.json 里换个
/// script 字段就会让源的字段突然少一半。
///
/// 响应体是**离线固定样本**，取自 MacCMS 官方 XML 接口的真实结构
/// （`api.php/provide/vod/?ac=list` 不传 `at=json` 时的形态）。
/// 不用实时请求：测试要能重复跑，也不能因为源站今天挂了就红。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_runtime.dart';

import 'support/quickjs_env.dart';

/// 真实 MacCMS `ac=list` 的 XML 应答（2 条，字段与线上一致）。
///
/// 特意包含了三种容易出错的形态：
///   - `<pic>` 是站内相对路径 → 要补 baseUrl
///   - `<year>` 是空元素       → 要变成 0 而不是 "null"
///   - `<note>` 缺失           → 要变成空串而不是 undefined
const String _listXml = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="5.1">
<list page="1" pagecount="120" pagesize="20" recordcount="2380">
<video>
  <last>2026-11-17 09:12:33</last>
  <id>173310</id>
  <tid>26</tid>
  <name><![CDATA[男子气概]]></name>
  <type>剧情片</type>
  <pic>/upload/vod/20261117-1/e78e7834.webp</pic>
  <lang>英语</lang>
  <area>美国</area>
  <year>2026</year>
  <state>0</state>
  <note><![CDATA[更新至HD]]></note>
  <actor><![CDATA[某人]]></actor>
  <director><![CDATA[某导]]></director>
  <des><![CDATA[一个男人的故事]]></des>
</video>
<video>
  <id>173169</id>
  <tid>26</tid>
  <name><![CDATA[寒鸦之冬]]></name>
  <type>剧情片</type>
  <pic>//cdn.example.com/b.webp</pic>
  <area>英国</area>
  <year></year>
  <des><![CDATA[]]></des>
</video>
</list>
</rss>''';

/// 真实 MacCMS `ac=detail` 的 XML 应答（含多线路 `<dd flag>` 与多集）。
const String _detailXml = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="5.1">
<list page="1" pagecount="1" pagesize="20" recordcount="1">
<video>
  <id>173310</id>
  <tid>26</tid>
  <name><![CDATA[男子气概]]></name>
  <type>剧情片</type>
  <pic>/upload/vod/20261117-1/e78e7834.webp</pic>
  <area>美国</area>
  <year>2026</year>
  <note><![CDATA[更新至HD]]></note>
  <des><![CDATA[<p>简介正文</p>]]></des>
  <director><![CDATA[某导]]></director>
  <actor><![CDATA[某人]]></actor>
  <dl>
    <dd flag="bfzym3u8"><![CDATA[HD\$https://v.fengbao14.com/a/index.m3u8#第2集\$https://v.fengbao14.com/b/index.m3u8]]></dd>
    <dd flag="lzm3u8"><![CDATA[HD\$https://v.lz.com/x/index.m3u8]]></dd>
  </dl>
</video>
</list>
</rss>''';

void main() {
  late String script;
  late Map<String, dynamic> ctx;

  setUpAll(() {
    expect(
      ensureQuickJsLibrary(),
      isTrue,
      reason: 'quickjs_c_bridge.dll 不可用，无法验证 XML 脚本',
    );

    final f = File('../../config/plugins/maccms-xml.js');
    expect(f.existsSync(), isTrue, reason: '找不到 XML 脚本：${f.absolute.path}');
    script = f.readAsStringSync();

    expect(looksLikeInfiniteLoop(script), isFalse,
        reason: 'XML 脚本含疑似死循环，宿主会拒绝装载');

    ctx = <String, dynamic>{
      'vars': <String, dynamic>{},
      'baseUrl': 'https://xml.example.com',
      'finalUrl': 'https://xml.example.com/api.php/provide/vod/',
      'sourceId': 'js_xml_demo',
    };
  });

  tearDownAll(() => PluginRuntime.instance.resetForTest());

  Future<Map> call(String entry, List<Object?> args) async {
    final r = await PluginRuntime.instance.call(
      script: script,
      entry: entry,
      argsJson: jsonEncode(args),
    );
    expect(r.ok, isTrue, reason: '执行 $entry 失败：${r.error}');
    return jsonDecode(r.value) as Map;
  }

  group('装载与语法', () {
    test('脚本能在 QuickJS 里装载', () async {
      final out = await call('parseList', [_listXml, ctx]);
      expect(out.containsKey('items'), isTrue);
    });
  });

  group('parseList 解析真实 XML 应答', () {
    test('条目数与核心字段', () async {
      final out = await call('parseList', [_listXml, ctx]);
      final items = out['items'] as List;
      expect(items.length, 2);

      final a = items[0] as Map;
      expect(a['id'], '173310');
      expect(a['name'], '男子气概', reason: 'CDATA 里的片名要能取出');
      expect(a['type'], '剧情片');
      expect(a['remark'], '更新至HD');
      expect(a['area'], '美国');
      expect(a['year'], 2026, reason: 'year 是文本，要转成 int');
      expect(a['brief'], '一个男人的故事');
    });

    test('相对封面补成绝对地址', () async {
      final items = (await call('parseList', [_listXml, ctx]))['items'] as List;
      expect((items[0] as Map)['pic'],
          'https://xml.example.com/upload/vod/20261117-1/e78e7834.webp',
          reason: 'XML 站大量用相对路径，不补全都得是破图');
    });

    test('协议相对封面补 https:', () async {
      final items = (await call('parseList', [_listXml, ctx]))['items'] as List;
      expect((items[1] as Map)['pic'], 'https://cdn.example.com/b.webp');
    });

    test('空 <year> 变成 0，不是 NaN 也不是 null', () async {
      final items = (await call('parseList', [_listXml, ctx]))['items'] as List;
      expect((items[1] as Map)['year'], 0);
    });

    test('缺失 <note> 变成空串，不是字符串 "undefined"', () async {
      final items = (await call('parseList', [_listXml, ctx]))['items'] as List;
      expect((items[1] as Map)['remark'], '');
    });
  });

  group('单元素不是数组（XML 最经典的坑）', () {
    test('只有一个 <video> 时也能正常解析', () async {
      // xml2js 的固有行为：一个子元素是对象，多个才是数组。
      // 不兜这个的话，只有 1 条结果时整个列表会变成空的——
      // 而且只在「结果恰好一条」时复现，极难查。
      const one = '<rss><list><video><id>1</id><name>单片</name>'
          '<pic>/a.jpg</pic></video></list></rss>';
      final items = (await call('parseList', [one, ctx]))['items'] as List;
      expect(items.length, 1);
      expect((items[0] as Map)['name'], '单片');
    });

    test('只有一条 <dd> 时线路也能取出', () async {
      const one = '<rss><list><video><id>1</id><name>单片</name>'
          '<dl><dd flag="only"><![CDATA[HD\$https://a.com/1.m3u8]]></dd></dl>'
          '</video></list></rss>';
      final out = await call('parseDetail', [one, ctx]);
      final lines = out['lines'] as List;
      expect(lines.length, 1);
      expect((lines[0] as Map)['line'], 'only');
    });
  });

  group('parseDetail 解析真实 XML 应答', () {
    test('基本信息与简介', () async {
      final out = await call('parseDetail', [_detailXml, ctx]);
      expect(out['id'], '173310');
      expect(out['name'], '男子气概');
      expect(out['content'], '<p>简介正文</p>');
      expect(out['year'], 2026);
      expect(out['director'], '某导');
      expect(out['actor'], '某人');
      expect(out['pic'],
          'https://xml.example.com/upload/vod/20261117-1/e78e7834.webp');
    });

    test('多线路来自 <dd flag>，线路名不能是「线路1」', () async {
      final out = await call('parseDetail', [_detailXml, ctx]);
      final lines = out['lines'] as List;
      expect(lines.length, 2, reason: '两个 <dd> 应拆成两条线路');

      expect((lines[0] as Map)['line'], 'bfzym3u8',
          reason: '线路名在 flag 属性里，丢了就全变成「线路1」');
      expect((lines[1] as Map)['line'], 'lzm3u8');
    });

    test('线路内多集按 # 拆开', () async {
      final out = await call('parseDetail', [_detailXml, ctx]);
      final eps = (out['lines'] as List)[0]['episodes'] as List;
      expect(eps.length, 2);
      expect((eps[0] as Map)['name'], 'HD');
      expect((eps[0] as Map)['url'], 'https://v.fengbao14.com/a/index.m3u8');
      expect((eps[1] as Map)['name'], '第2集');
      expect((eps[1] as Map)['url'], 'https://v.fengbao14.com/b/index.m3u8');
    });
  });

  group('坏响应的处理', () {
    test('HTML 错误页 → 空列表，不抛异常', () async {
      // 被 WAF 拦时返回 HTML。必须给空列表（界面显示空态），
      // 抛异常只会让用户看到一句「解析失败」，分不清是源挂了还是脚本坏了。
      final out = await call('parseList',
          ['<html><body>503 Service Unavailable</body></html>', ctx]);
      expect(out['items'], isEmpty);
    });

    test('空响应 → 空列表', () async {
      expect((await call('parseList', ['', ctx]))['items'], isEmpty);
      expect((await call('parseList', ['   ', ctx]))['items'], isEmpty);
    });

    test('带 BOM 的 XML 能正常解析', () async {
      // 老 PHP 站导出的 XML 常带 \uFEFF。不剥掉的话
      // XmlDocument.parse 直接报「unexpected character」，
      // 而且看不出是 BOM 导致的。
      const withBom = '\uFEFF$_listXml';
      final items = (await call('parseList', [withBom, ctx]))['items'] as List;
      expect(items.length, 2, reason: 'BOM 没剥掉会导致整份响应解析失败');
    });

    test('配了 XML 但站方返回 JSON 时也能吃下', () async {
      // 有些站升级后默认格式变了。两端都认，源就不会突然空掉。
      const json = '{"code":1,"list":[{"vod_id":9,"vod_name":"JSON剧",'
          '"vod_pic":"/x.jpg","vod_year":"2025"}]}';
      final items = (await call('parseList', [json, ctx]))['items'] as List;
      expect(items.length, 1);
      expect((items[0] as Map)['name'], 'JSON剧');
    });
  });

  group('与 JSON 版脚本的输出一致性', () {
    test('两个脚本的 items 字段集合完全相同', () async {
      // 这条是「换个 script 字段就能切格式」这个承诺的守门人。
      // 字段少了会导致界面某几列突然空白，而且很难联想到是脚本换了。
      final jsonScript =
          File('../../config/plugins/maccms-json.js').readAsStringSync();

      const jsonBody = '{"code":1,"list":[{"vod_id":173310,'
          '"vod_name":"男子气概","vod_pic":"/a.webp","vod_remarks":"更新至HD",'
          '"vod_area":"美国","vod_year":"2026","type_name":"剧情片",'
          '"vod_blurb":"简介"}]}';

      final rJson = await PluginRuntime.instance.call(
        script: jsonScript,
        entry: 'parseList',
        argsJson: jsonEncode([jsonBody, ctx]),
      );
      expect(rJson.ok, isTrue, reason: rJson.error);
      final jsonItem = ((jsonDecode(rJson.value) as Map)['items'] as List)[0] as Map;

      final xmlItem =
          ((await call('parseList', [_listXml, ctx]))['items'] as List)[0] as Map;

      expect(xmlItem.keys.toSet(), jsonItem.keys.toSet(),
          reason: 'XML 版与 JSON 版的字段集合必须一致');
    });
  });

  group('parseResolve', () {
    test('从 HTML 里抠 m3u8', () async {
      const html =
          '<html><script>var main = "https://a.com/x/index.m3u8?sign=1";</script></html>';
      final out = await call('parseResolve', [html, ctx]);
      expect(out['url'], 'https://a.com/x/index.m3u8?sign=1');
    });

    test('取不到时返回空串而不是崩', () async {
      final out = await call('parseResolve', ['<html>nothing here</html>', ctx]);
      expect(out['url'], '');
    });
  });

  group('性能', () {
    test('解析 20 条 XML 在 3 秒预算内绰绰有余', () async {
      final sb = StringBuffer('<rss><list page="1">');
      for (var n = 0; n < 20; n++) {
        sb.write('<video><id>$n</id><name>剧$n</name>'
            '<pic>/u/$n.webp</pic><year>2026</year></video>');
      }
      sb.write('</list></rss>');
      final body = sb.toString();

      // 热身（首次含脚本编译）
      await call('parseList', [body, ctx]);

      final sw = Stopwatch()..start();
      final items = (await call('parseList', [body, ctx]))['items'] as List;
      sw.stop();

      expect(items.length, 20);
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: '解析 20 条用了 ${sw.elapsedMilliseconds}ms');
    });
  });
}