// 投屏设备模型 + 续播参数回归测试
//
// 这两块都不方便直接跑真机验证（一个要局域网电视，一个要真实播放），
// 所以把「能被改坏的数据契约」单独锁住：
//   - 设备去重按 controlURL，名字只是显示用；
//   - 观看记录序列化往返必须保住集数/源/进度，否则续播会退化成
//     「打开详情页」，正是这次修掉的那个 bug。

import 'package:flutter_test/flutter_test.dart';

import 'package:zhuiju/core/dlna.dart';
import 'package:zhuiju/core/history.dart';
import 'package:zhuiju/core/models.dart';
import 'package:zhuiju/pages/detail_page.dart';
import 'package:zhuiju/pages/player_page.dart';

void main() {
  group('投屏设备模型', () {
    test('同一个控制地址视为同一台设备，即便名字不同', () {
      const a = DlnaDevice(
        name: '客厅电视',
        location: 'http://192.168.1.8:8080/desc.xml',
        controlUrl: 'http://192.168.1.8:8080/AVTransport/control',
        model: 'MiTV',
      );
      const b = DlnaDevice(
        name: '客厅电视（2）',
        location: 'http://192.168.1.8:8080/desc.xml',
        controlUrl: 'http://192.168.1.8:8080/AVTransport/control',
        model: 'MiTV',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect({a, b}.length, 1);
    });

    test('不同控制地址视为不同设备', () {
      const a = DlnaDevice(
        name: '电视',
        location: 'http://192.168.1.8/desc.xml',
        controlUrl: 'http://192.168.1.8/av',
      );
      const b = DlnaDevice(
        name: '电视',
        location: 'http://192.168.1.9/desc.xml',
        controlUrl: 'http://192.168.1.9/av',
      );
      expect(a, isNot(b));
      expect({a, b}.length, 2);
    });

    test('副标题：有型号显示型号，没有则退回地址', () {
      const withModel = DlnaDevice(
        name: '电视',
        location: 'http://192.168.1.8/desc.xml',
        controlUrl: 'http://192.168.1.8/av',
        model: 'MiTV-A55',
      );
      const without = DlnaDevice(
        name: '电视',
        location: 'http://192.168.1.8/desc.xml',
        controlUrl: 'http://192.168.1.8/av',
      );
      expect(withModel.subtitle, 'MiTV-A55');
      expect(without.subtitle, 'http://192.168.1.8/desc.xml');
    });

    test('默认没有投屏会话', () {
      expect(Dlna.instance.session, isNull);
    });
  });

  group('续播数据契约', () {
    test('观看记录序列化往返保住集数、源和进度', () {
      final r = WatchRecord(
        dramaId: '12345',
        dramaName: '测试剧',
        epLabel: '第7集',
        source: 'bfzym3u8',
        path: 'https://example.com/7/index.m3u8',
        episode: 7,
        cover: 'https://example.com/c.jpg',
        positionSec: 1234,
        durationSec: 2400,
      );
      final back = WatchRecord.fromJson(r.toJson());
      expect(back, isNotNull);
      expect(back!.episode, 7);
      expect(back.source, 'bfzym3u8');
      expect(back.path, 'https://example.com/7/index.m3u8');
      expect(back.positionSec, 1234);
      expect(back.durationSec, 2400);
      // 进度过半但没到 95%，不该被标成「已看完」
      expect(back.nearlyFinished, isFalse);
      expect(back.progress, closeTo(1234 / 2400, 0.0001));
    });

    test('详情页默认不自动续播，带集数才续播', () {
      const plain = DetailPage(dramaId: '1', title: '片名');
      expect(plain.wantsResume, isFalse);
      expect(plain.resumeSec, 0);

      const resume = DetailPage(
        dramaId: '1',
        title: '片名',
        resumeEpisode: 7,
        resumeSource: 'bfzym3u8',
        resumeSec: 1234,
      );
      expect(resume.wantsResume, isTrue);
      expect(resume.resumeEpisode, 7);
      expect(resume.resumeSec, 1234);
    });

    test('播放页默认从头播，续播页带起始秒数', () {
      // DramaVideo 必填项，构造一条最小可用数据即可
      final v = DramaVideo(
        id: '1',
        title: '第7集',
        path: 'https://example.com/7/index.m3u8',
        source: 'bfzym3u8',
        episode: 7,
      );
      final normal = PlayerPage(video: v);
      final resume = PlayerPage(video: v, startAtSec: 1234);
      expect(normal.startAtSec, 0);
      expect(resume.startAtSec, 1234);
      expect(v.epLabel, '第7集');
    });
  });
}