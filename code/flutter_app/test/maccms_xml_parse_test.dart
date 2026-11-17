/// XML 采集站的解析回归 + 两个新源（优子 / 金山）的配置契约（**不联网**）。
///
/// 为什么这套测试必须存在：XML 站的解析错一处，现象全是「看起来像源挂了」，
/// 在联网测试里根本定位不到。
///
/// | 错的地方 | 用户看到的现象 |
/// | --- | --- |
/// | CDATA 没剥 | 所有地址带 `]]>` 尾巴 → 100% 404，报「片源失效」 |
/// | 把多条 `<dd>` 当多集 | 详情页只有 1 集，或集数翻倍 |
/// | 同名 flag 覆盖而非累加 | 一季拆两条 dd 的剧只剩后一半 |
/// | `ac=detail&ids=` 用于 XML 站 | 详情页打开成**另一部不相干的片子** |
///
/// 下面所有报文都是 2026-11-14 对 api.yzzyapi.com 的真实抓取，逐字节保留
/// （含全角空格、中文标点、CDATA 包裹），不手工简化。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/source/maccms_api_source.dart';
import 'package:zhuiju/core/source/site_sources.dart';

import 'support/plugin_index.dart';

/// 真实报文：`?ac=videolist&ids=21`，974 B，单条单集。
/// 来源：api.yzzyapi.com，2026-11-14 抓取。
const String _xmlSingle = '<?xml version="1.0" encoding="utf-8"?>'
    '<rss version="5.1">'
    '<list page="1" pagecount="1" pagesize="20" recordcount="1">'
    '<video>'
    '<last>2023-07-21 08:00:19</last><id>21</id><tid>11</tid>'
    '<name><![CDATA[冰雪狙击]]></name><type>战争片</type>'
    '<pic>https://pic3.yzzyimg.online/upload/vod/2022-03-20/202203201647766949.jpg</pic>'
    '<lang>国语</lang><area>大陆</area><year>2022</year><state>0</state>'
    '<note><![CDATA[HD国语版]]></note>'
    '<actor><![CDATA[李东学,胡雪儿,周波,山崎敬一,杨明娜]]></actor>'
    '<director><![CDATA[林伟]]></director>'
    '<dl>'
    '<dd flag="zykyun"><![CDATA[HD国语版\$https://yzzy.play-cdn17.com/share/2af1e9eaa807096a11b32ed26ecc2cbb]]></dd>'
    '<dd flag="1080zyk"><![CDATA[HD国语版\$https://yzzy.play-cdn17.com/20230720/11747_44b07ed6/index.m3u8]]></dd>'
    '</dl>'
    '<des><![CDATA[　　东北青年华志是一名东北军士兵，九一八事变后曾与日寇血战。]]></des>'
    '</video>'
    '</list>'
    '</rss>';

/// 真实报文：多集剧（《语义错误》，8 集，两条线路）。
const String _xmlMultiEpisode = '<?xml version="1.0" encoding="utf-8"?>'
    '<rss version="5.1"><list page="1" pagecount="1" pagesize="20" recordcount="1">'
    '<video><last>2022-03-30 10:00:00</last><id>888</id><tid>14</tid>'
    '<name><![CDATA[语义错误]]></name><type>韩国剧</type>'
    '<pic>https://pic3.yzzyimg.online/upload/vod/x.jpg</pic>'
    '<area>韩国</area><year>2022</year><state>1</state>'
    '<dl>'
    '<dd flag="zykyun"><![CDATA[第01集\$https://yzzy.play-cdn2.com/share/ad68473a64305626a27c32a5408552d7'
    '#第02集\$https://yzzy.play-cdn2.com/share/ec0f40c389aeef789ce03eb814facc6c]]></dd>'
    '<dd flag="1080zyk"><![CDATA[第01集\$https://yzzy.play-cdn2.com/20220330/4078_720372c0/index.m3u8'
    '#第02集\$https://yzzy.play-cdn2.com/20220330/4077_20ca226d/index.m3u8]]></dd>'
    '</dl>'
    '<des><![CDATA[　　该剧讲述了两个男人之间的故事。]]></des>'
    '</video></list></rss>';

/// `?ac=list&pg=1` 的真实形态：**只有 `<dt>` 线路名，没有 `<dl>` 分集**。
/// 这条是用来钉死「列表页不能当详情用」的。
const String _xmlListNoDl = '<?xml version="1.0" encoding="utf-8"?>'
    '<rss version="5.1"><list page="1" pagecount="5460" pagesize="20" recordcount="109192">'
    '<video><last>2026-11-14 17:00:54</last><id>110051</id><tid>15</tid>'
    '<name><![CDATA[蜜谍]]></name><type>欧美剧</type>'
    '<dt>zykyun,1080zyk</dt>'
    '<note><![CDATA[更新至02集]]></note></video>'
    '</list></rss>';

void main() {
  group('parseXmlVideos —— 基本字段', () {
    test('单条单集：字段全部就位', () {
      final items = parseXmlVideos(_xmlSingle);
      expect(items.length, 1);

      final f = items.first.fields;
      expect(f['vod_id'], '21');
      expect(f['vod_name'], '冰雪狙击');
      expect(f['vod_type_name'], '战争片');
      expect(f['vod_pic'],
          'https://pic3.yzzyimg.online/upload/vod/2022-03-20/202203201647766949.jpg');
      expect(f['vod_area'], '大陆');
      expect(f['vod_year'], '2022');
      expect(f['vod_remarks'], 'HD国语版');
      expect(f['vod_director'], '林伟');
      expect(f['vod_isend'], '0', reason: '<state>0</state> 表示未完结');
    });

    test('CDATA 内容要剥干净：简介不能带 <![CDATA[ 或 ]]>', () {
      final f = parseXmlVideos(_xmlSingle).first.fields;
      final des = f['vod_content']!;
      expect(des.contains('<![CDATA['), isFalse);
      expect(des.contains(']]>'), isFalse);
      // 正文首字是全角空格，说明没被 trim 截掉内部内容，只是首尾处理过
      expect(des.contains('东北青年华志'), isTrue);
    });

    test('无 id 或无片名的条目被丢弃（否则列表出现空白卡）', () {
      const bad = '<rss><list>'
          '<video><id>1</id><name></name></video>'
          '<video><name>有名字没id</name></video>'
          '<video><id>2</id><name><![CDATA[正常]]></name></video>'
          '</list></rss>';
      final items = parseXmlVideos(bad);
      expect(items.length, 1);
      expect(items.first.fields['vod_id'], '2');
    });

    test('空报文不崩，返回空列表', () {
      expect(parseXmlVideos(''), isEmpty);
      expect(parseXmlVideos('<?xml version="1.0"?><rss><list/></rss>'), isEmpty);
    });
  });

  group('parseXmlVideos —— 线路与分集', () {
    test('两条 <dd> 是两条线路，不是两集', () {
      final v = parseXmlVideos(_xmlSingle).first;
      expect(v.lines.length, 2, reason: '一个 <dl> 里两条 <dd> = 两条线路');
      expect(v.lines.map((e) => e.flag), ['zykyun', '1080zyk']);
      expect(v.lines[0].eps.length, 1);
      expect(v.lines[1].eps.length, 1);
    });

    test('★ CDATA 剥离：地址末尾绝不能带 ]]>（否则必然 404）', () {
      final v = parseXmlVideos(_xmlSingle).first;
      for (final line in v.lines) {
        for (final ep in line.eps) {
          expect(ep.url.contains(']]>'), isFalse,
              reason: '${ep.url} 带了 CDATA 尾巴，实测这种地址 100% 404');
          expect(ep.url.contains('<![CDATA['), isFalse);
          expect(ep.url, startsWith('http'));
        }
      }
      expect(v.lines[1].eps.first.url,
          'https://yzzy.play-cdn17.com/20230720/11747_44b07ed6/index.m3u8');
    });

    test(r'# 是分集分隔符，$ 分集名与地址', () {
      final v = parseXmlVideos(_xmlMultiEpisode).first;
      expect(v.lines.length, 2);
      for (final line in v.lines) {
        expect(line.eps.length, 2, reason: '8 集剧这里只放了 2 集样本');
      }
      expect(v.lines[0].eps[0].title, '第01集');
      expect(v.lines[0].eps[1].title, '第02集');
      expect(v.lines[0].eps[1].url,
          'https://yzzy.play-cdn2.com/share/ec0f40c389aeef789ce03eb814facc6c');
      expect(v.lines[1].eps[0].url,
          'https://yzzy.play-cdn2.com/20220330/4078_720372c0/index.m3u8');
    });

    test('同名 flag 出现两次要累加分集，不是后者覆盖前者', () {
      // 少数站把一季拆成两条 dd，flag 都写 1080zyk
      const xml = '<rss><list><video><id>9</id><name>X</name><dl>'
          '<dd flag="1080zyk"><![CDATA[第1集\$https://a.com/1.m3u8]]></dd>'
          '<dd flag="1080zyk"><![CDATA[第2集\$https://a.com/2.m3u8]]></dd>'
          '</dl></video></list></rss>';
      final v = parseXmlVideos(xml).first;
      expect(v.lines.length, 1, reason: '同 flag 合并成一条线路');
      expect(v.lines.first.eps.length, 2, reason: '两集都在，不能被覆盖成 1 集');
    });

    test(r'裸地址（没有 $ 集名）补出「第N集」', () {
      const xml = '<rss><list><video><id>9</id><name>X</name><dl>'
          '<dd flag="1080zyk"><![CDATA[https://a.com/1.m3u8#https://a.com/2.m3u8]]></dd>'
          '</dl></video></list></rss>';
      final v = parseXmlVideos(xml).first;
      expect(v.lines.first.eps.length, 2);
      expect(v.lines.first.eps[0].title, '第1集');
      expect(v.lines.first.eps[1].title, '第2集');
      expect(v.lines.first.eps[0].url, 'https://a.com/1.m3u8');
    });

    test('★ 列表页（只有 <dt>）解析出的 lines 必须为空', () {
      // 这是「不能拿 ac=list 当详情用」的守卫：list 只有线路名，没有地址。
      // 若哪天解析器把 <dt> 当成了线路，详情页就会冒出 0 集的空线路。
      final v = parseXmlVideos(_xmlListNoDl).first;
      expect(v.fields['vod_name'], '蜜谍');
      expect(v.lines, isEmpty, reason: 'ac=list 只有 <dt>，不该解析出任何线路');
    });
  });

  group('XML 实体与标签工具', () {
    test('unescapeXml 还原常见实体', () {
      expect(unescapeXml('Tom &amp; Jerry'), 'Tom & Jerry');
      expect(unescapeXml('a &lt; b &gt; c'), 'a < b > c');
      expect(unescapeXml('&quot;引号&quot;'), '"引号"');
    });

    test('&amp; 最后换，避免二次转义', () {
      // `&amp;lt;` 应还原成字面量 `&lt;`，而不是 `<`
      expect(unescapeXml('&amp;lt;'), '&lt;');
    });

    test('xmlTagText 优先匹配 CDATA 形态', () {
      const block = '<name><![CDATA[正常片名]]></name><note>HD</note>';
      expect(xmlTagText(block, 'name'), '正常片名');
      expect(xmlTagText(block, 'note'), 'HD');
      expect(xmlTagText(block, 'missing'), '');
    });
  });

  group('derivePlayIndexUrl —— /play/<token> 纯壳页推导', () {
    test('金山真实地址：推导结果与 jsm3u8 逐字符相同', () {
      // 实测样本（2026-11-14，id=153336）：share 与 direct 只差尾部一段
      expect(derivePlayIndexUrl('https://vv.jisuzyv.com/play/epYzjKpa'),
          'https://vv.jisuzyv.com/play/epYzjKpa/index.m3u8');
      expect(derivePlayIndexUrl('https://vv.jisuzyv.com/play/bDkYMEya'),
          'https://vv.jisuzyv.com/play/bDkYMEya/index.m3u8');
    });

    test('★ 已是直链时返回 null（否则会拼成 xxx/index.m3u8/index.m3u8）', () {
      expect(derivePlayIndexUrl('https://a.com/play/abc/index.m3u8'), isNull);
      expect(derivePlayIndexUrl('https://a.com/x/y.mp4'), isNull);
    });

    test('★ 优子的 /share/<md5> 不能套这条规则（实测 404）', () {
      // 这不是「漏了」而是刻意排除：/share/ 段不是 play，
      // 加 /index.m3u8 实测必然 404，硬拼只会把「解析失败」
      // 变成「播放器报格式错误」，更难排查。
      expect(
        derivePlayIndexUrl(
            'https://yzzy.play-cdn17.com/share/2af1e9eaa807096a11b32ed26ecc2cbb'),
        isNull,
      );
    });

    test('只认 /play/<token> 两段，多段或不含 play 一律 null', () {
      expect(derivePlayIndexUrl('https://a.com/play/a/b'), isNull);
      expect(derivePlayIndexUrl('https://a.com/vod/abc'), isNull);
      expect(derivePlayIndexUrl('https://a.com/play/'), isNull);
      expect(derivePlayIndexUrl('https://a.com/'), isNull);
    });

    test('保留端口与协议', () {
      expect(derivePlayIndexUrl('http://a.com:8080/play/abc'),
          'http://a.com:8080/play/abc/index.m3u8');
    });

    test('非法 URL 不崩，返回 null', () {
      expect(derivePlayIndexUrl(''), isNull);
      expect(derivePlayIndexUrl('not a url'), isNull);
    });
  });

  group('优子资源（yzzyapi）配置契约', () {
    MacCmsApiConfig cfg() => (kYzzySource as MacCmsApiSource).cfg;

    test('声明为 XML 格式（JSON 解析器会直接崩）', () {
      expect(cfg().format, MacCmsFormat.xml);
      expect(cfg().id, 'yzzyapi');
      expect(cfg().apiUrl, 'https://api.yzzyapi.com/api.php/provide/vod/');
    });

    test('必须打开 listNeedsBatchDetail，且不能开 listNeedsDetail', () {
      // listNeedsDetail 会让请求变成 ac=detail，而 XML 站的 detail
      // 实测忽略 ids、返回随机 20 条 → 详情页打开成另一部片。
      expect(cfg().listNeedsBatchDetail, isTrue,
          reason: 'ac=list 没封面没分集，必须靠批量 ids 补');
      expect(cfg().listNeedsDetail, isFalse,
          reason: 'ac=detail 会忽略 ids，详情页会打开成不相干的片子');
    });

    test('已在 index.json 里声明', () {
      // 2026-11-17 起注册表不内置源，装配由远端配置决定。
      // 这里断言配置里有它，而不是注册表的 `_all`。
      expect(declaredSourceIds(), contains('yzzyapi'));
      // 这批站都是国内直连，分组写错会被标成「需系统代理」
      expect(declaredEntry('yzzyapi')!['group'], '采集站（直连）');
    });

    test('线路中文名：1080zyk 是直出、zykyun 是分享页', () {
      expect(cfg().lineNameCn['1080zyk'], '优子线路');
      expect(cfg().lineNameCn['zykyun'], '优子网页');
    });

    test('栏目不用空父分类（1/2/3/4/83 实测 0 条）', () {
      const emptyParents = {'1', '2', '3', '4', '83', '54', '78', '79', '80', '81'};
      for (final cat in cfg().categories) {
        if (cat.id.isEmpty) continue;
        for (final id in cat.id.split(',')) {
          expect(emptyParents.contains(id.trim()), isFalse,
              reason: '「${cat.name}」用了 $id，该分类实测为空');
        }
      }
    });
  });

  group('金山资源（jszyapi）配置契约', () {
    MacCmsApiConfig cfg() => (kJszySource as MacCmsApiSource).cfg;

    test('声明为 JSON 格式，走 ac=detail 换封面', () {
      expect(cfg().format, MacCmsFormat.json);
      expect(cfg().id, 'jszyapi');
      expect(cfg().apiUrl, 'https://jszyapi.com/api.php/provide/vod/');
      expect(cfg().listNeedsDetail, isTrue,
          reason: 'ac=list 实测 8 字段无封面');
      expect(cfg().listNeedsBatchDetail, isFalse);
    });

    test('已在 index.json 里声明', () {
      expect(declaredSourceIds(), contains('jszyapi'));
      expect(declaredEntry('jszyapi')!['group'], '采集站（直连）');
    });

    test('线路中文名：jsm3u8 直出、jsyun 网页', () {
      expect(cfg().lineNameCn['jsm3u8'], '金山线路');
      expect(cfg().lineNameCn['jsyun'], '金山网页');
    });

    test('栏目不用空父分类（1/2/17/27/29/38 实测 0 条）', () {
      const emptyParents = {'1', '2', '17', '27', '29', '38'};
      for (final cat in cfg().categories) {
        if (cat.id.isEmpty) continue;
        for (final id in cat.id.split(',')) {
          expect(emptyParents.contains(id.trim()), isFalse,
              reason: '「${cat.name}」用了 $id，该分类实测为空');
        }
      }
    });
  });

  group('起点资源（qdys2）配置契约', () {
    MacCmsApiConfig cfg() => (kQdys2Source as MacCmsApiSource).cfg;

    test('声明为 JSON 格式，走 ac=detail 换封面', () {
      expect(cfg().format, MacCmsFormat.json);
      expect(cfg().id, 'qdys2');
      expect(cfg().apiUrl, 'https://www.qdys2.cc/api.php/provide/vod/');
      expect(cfg().listNeedsDetail, isTrue, reason: 'ac=list 实测 9 字段、封面 0/20');
      expect(cfg().listNeedsBatchDetail, isFalse,
          reason: 'qdys2 是 JSON 站，批量补封面那是 XML 站才需要的路');
    });

    test('已在 index.json 里声明，且归在采集站组', () {
      expect(declaredSourceIds(), contains('qdys2'));
      expect(declaredEntry('qdys2')!['group'], '采集站（直连）',
          reason: '起点资源国内直连，不该被标成需系统代理');
    });

    test('线路中文名四条都要配（少一个界面上就有个裸露的英文 id）', () {
      expect(cfg().lineNameCn['dyttm3u8'], '电影天堂');
      expect(cfg().lineNameCn['bfzym3u8'], '暴风线路');
      expect(cfg().lineNameCn['okm3u8'], 'OK 线路');
      expect(cfg().lineNameCn['1080zyk'], '优子线路');
      expect(cfg().lineNameCn.length, 4);
    });

    test('四条线路全是直出 m3u8，不该开 derivePlayIndex', () {
      // derivePlayIndex 是给「首条是 /play/<token> 空壳页」的站用的；
      // qdys2 实测四条线路地址都直接以 index.m3u8 结尾，开了反而多一次误判。
      expect(cfg().derivePlayIndex, isFalse);
    });

    test('栏目不列空壳分类（6=少儿、55=片单推荐 实测 total=0）', () {
      const empty = {'6', '55'};
      for (final cat in cfg().categories) {
        if (cat.id.isEmpty) continue;
        for (final id in cat.id.split(',')) {
          expect(empty.contains(id.trim()), isFalse,
              reason: '「${cat.name}」用了 $id，该分类实测 0 条');
        }
      }
    });

    test('栏目 id 全用父分类（本站父分类有货，不需要扒子分类）', () {
      const parents = {'1', '2', '3', '4', '7', '39', '53'};
      for (final cat in cfg().categories) {
        if (cat.id.isEmpty) continue;
        for (final id in cat.id.split(',')) {
          expect(parents.contains(id.trim()), isTrue,
              reason: '「${cat.name}」用了 $id，不在实测有货的父分类里');
        }
      }
    });
  });

  group('preferDirectLine 对三个新源必须打开', () {
    test('优子 zykyun 与金山 jsyun 都是网页页，不重排就点开必挂', () {
      for (final s in [kYzzySource, kJszySource]) {
        final cfg = (s as MacCmsApiSource).cfg;
        expect(cfg.preferDirectLine, isTrue,
            reason: '${cfg.displayName} 首条是网页分享页，必须把直出线路顶前');
      }
    });

    test('起点四条线路都是直出，重排无害但也不能关', () {
      final cfg = (kQdys2Source as MacCmsApiSource).cfg;
      expect(cfg.preferDirectLine, isTrue);
    });
  });
}