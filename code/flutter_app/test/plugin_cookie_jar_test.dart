/// 插件 Cookie 会话（[PluginCookieJar]）的单元测试。
///
/// ## 为什么这段逻辑值得单独测
///
/// 它是**错了也不报错**的典型：cookie 没吸收到，请求就是 403；403 之后
/// 宿主不会再重试（只试一次），用户看到的是「搜索没结果」——和「站里真没
/// 这部剧」完全一样。剧踪站就是这个形态，靠肉眼看不出区别。
///
/// 另外两个容易踩的点也在这里钉死：
///
/// - 挑战 cookie 是在 **403 那次响应**里下发的，所以必须「先吸收再看状态码」，
///   反过来写就永远拿不到 cookie
/// - `Max-Age=0` 是删除指令，得真的从袋子里删掉，不能当成一条空值存进去
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/plugin/plugin_cookie_jar.dart';

void main() {
  late PluginCookieJar jar;

  setUp(() {
    jar = PluginCookieJar.instance;
    jar.clearAll();
  });

  tearDown(() => jar.clearAll());

  group('吸收 Set-Cookie', () {
    test('只取 name=value，丢弃 Path/HttpOnly/Expires 等属性', () {
      jar.absorb('https://www.juzong01.me/vodsearch/x.html', [
        'search_verify=abc123; Path=/; HttpOnly; SameSite=Lax',
      ]);
      expect(
        jar.headerFor('https://www.juzong01.me/vodsearch/y.html'),
        'search_verify=abc123',
      );
    });

    test('多条 cookie 拼成一个 Cookie 头（分号+空格分隔）', () {
      jar.absorb('https://a.test/', ['x=1; Path=/', 'y=2; Path=/']);
      final h = jar.headerFor('https://a.test/p');
      expect(h, isNotNull);
      // 顺序按写入顺序，值是 name=value
      expect(h!.split('; ').toSet(), {'x=1', 'y=2'});
    });

    test('Max-Age=0 是删除指令，要把已有条目删掉', () {
      jar.absorb('https://a.test/', ['keep=1; Path=/', 'drop=2; Path=/']);
      expect(jar.countFor('https://a.test/'), 2);

      jar.absorb('https://a.test/', ['drop=; Path=/; Max-Age=0']);
      expect(jar.countFor('https://a.test/'), 1);
      expect(jar.headerFor('https://a.test/'), 'keep=1');
    });

    test('同名 cookie 后写覆盖先写（站点续期会话靠这个）', () {
      jar.absorb('https://a.test/', ['sid=old; Path=/']);
      jar.absorb('https://a.test/', ['sid=new; Path=/']);
      expect(jar.headerFor('https://a.test/'), 'sid=new');
      expect(jar.countFor('https://a.test/'), 1);
    });

    test('畸形条目直接跳过，不抛异常（宁可少带也不能把请求拦掉）', () {
      jar.absorb('https://a.test/', [
        '',
        '   ',
        'novalue',
        '=noName',
        'good=1; Path=/',
      ]);
      expect(jar.headerFor('https://a.test/'), 'good=1');
    });

    test('null / 空列表是常态（大多数响应不带 Set-Cookie），必须安全', () {
      expect(() => jar.absorb('https://a.test/', null), returnsNormally);
      expect(() => jar.absorb('https://a.test/', <String>[]), returnsNormally);
      expect(jar.headerFor('https://a.test/'), isNull);
    });
  });

  group('按 host 隔离', () {
    test('不把 A 站的 cookie 发给 B 站', () {
      jar.absorb('https://a.test/', ['token=aaa; Path=/']);
      expect(jar.headerFor('https://b.test/'), isNull);
      expect(jar.headerFor('https://a.test/'), 'token=aaa');
    });

    test('host 大小写不敏感（同一个站不会因为大小写分裂成两份会话）', () {
      jar.absorb('https://WWW.JuZong01.ME/', ['t=1; Path=/']);
      expect(jar.headerFor('https://www.juzong01.me/x'), 't=1');
      expect(jar.hostCount, 1);
    });

    test('path 不参与匹配：同一 host 下任意路径都回送', () {
      // 挑战 cookie 落在 Path=/，而目标路径是 /vodsearch/…，
      // 只按 host 匹配才不会漏带
      jar.absorb('https://a.test/', ['t=1; Path=/']);
      expect(jar.headerFor('https://a.test/deep/nested/path?q=1'), 't=1');
    });

    test('非法 URL 返回 null 而不是抛异常', () {
      jar.absorb('not-a-url', ['t=1; Path=/']);
      expect(jar.headerFor('not-a-url'), isNull);
      expect(jar.headerFor(''), isNull);
      expect(jar.hostCount, 0);
    });
  });

  group('容量上限', () {
    test('单 host 超过 kCookieMaxPerHost 条时淘汰最早的', () {
      final many = <String>[
        for (var i = 0; i < kCookieMaxPerHost + 5; i++) 'c$i=v$i; Path=/',
      ];
      jar.absorb('https://a.test/', many);
      expect(jar.countFor('https://a.test/'), kCookieMaxPerHost);
      // 最早那几条被淘汰了
      final h = jar.headerFor('https://a.test/')!;
      expect(h.contains('c0=v0'), isFalse);
      expect(h.contains('c${kCookieMaxPerHost + 4}='), isTrue);
    });

    test('host 数超过 kCookieMaxHosts 时淘汰最久未写入的', () {
      for (var i = 0; i < kCookieMaxHosts + 3; i++) {
        jar.absorb('https://h$i.test/', ['t=$i; Path=/']);
      }
      expect(jar.hostCount, kCookieMaxHosts);
      expect(jar.headerFor('https://h0.test/'), isNull, reason: '最早那个应被淘汰');
      expect(jar.headerFor('https://h${kCookieMaxHosts + 2}.test/'), isNotNull);
    });
  });

  group('清理', () {
    test('clearHost 只清指定 host', () {
      jar.absorb('https://a.test/', ['x=1; Path=/']);
      jar.absorb('https://b.test/', ['y=2; Path=/']);
      jar.clearHost('https://a.test/');
      expect(jar.headerFor('https://a.test/'), isNull);
      expect(jar.headerFor('https://b.test/'), 'y=2');
    });

    test('clearAll 清空全部', () {
      jar.absorb('https://a.test/', ['x=1; Path=/']);
      jar.absorb('https://b.test/', ['y=2; Path=/']);
      jar.clearAll();
      expect(jar.hostCount, 0);
    });
  });

  test('单例共享：两次取到的是同一个袋子（挑战 cookie 靠这个续上）', () {
    // 挑战 cookie 是上一个请求下发的，如果每次 new 一个，永远接不上
    expect(identical(PluginCookieJar.instance, PluginCookieJar.instance), isTrue);
    PluginCookieJar.instance.absorb('https://a.test/', ['t=1; Path=/']);
    expect(PluginCookieJar.instance.headerFor('https://a.test/'), 't=1');
  });
}