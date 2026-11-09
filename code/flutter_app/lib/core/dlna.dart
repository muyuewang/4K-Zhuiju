/// DLNA 投屏（SSDP 发现 + AVTransport 控制）
///
/// 为什么自己写而不是用包：
///   pub 上现成的投屏包基本都年久失修，且大多绑定特定平台实现。
///   投屏真正要用的协议只有两段，都很短且稳定十几年没变：
///     1. SSDP：UDP 多播发 M-SEARCH，设备用单播回 LOCATION；
///     2. AVTransport：往设备的 controlURL POST 一段 SOAP，
///        告诉它「播这个地址」「开始播」「暂停」「停止」。
///   自己实现反而可控：不会被依赖拖死，出问题能直接看日志。
///
/// 能力边界（必须说清楚，否则用户会以为「投屏坏了」）：
///   - 只能投「直链」：MP4 这类渐进式文件各电视都认；
///     HLS（.m3u8）要看电视固件，部分盒子不支持，会表现为
///     电视上转圈或直接报错，而手机端一切正常。
///   - 无法携带自定义请求头：有些源要求特定 UA/Referer，
///     这类地址推到电视上会被源站拒绝（电视拿到的就是 403）。
///   - 手机和电视必须同一个局域网，且路由器不能开「AP 隔离」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 发现到的一个可投屏设备
class DlnaDevice {
  /// 友好名称（设备描述里的 friendlyName，如「客厅电视」）
  final String name;

  /// 设备描述 XML 的地址（SSDP 响应里的 LOCATION）
  final String location;

  /// AVTransport 控制地址（绝对 URL）
  final String controlUrl;

  /// 型号描述，用来在列表里区分同名的多台设备
  final String model;

  const DlnaDevice({
    required this.name,
    required this.location,
    required this.controlUrl,
    this.model = '',
  });

  /// 列表里的副标题
  String get subtitle {
    final m = model.trim();
    if (m.isEmpty) return location;
    return m;
  }

  @override
  bool operator ==(Object other) =>
      other is DlnaDevice && other.controlUrl == controlUrl;

  @override
  int get hashCode => controlUrl.hashCode;
}

/// 投屏会话：记住当前投到哪台设备，方便「停止投屏」和状态查询
class DlnaSession {
  final DlnaDevice device;
  final String url;

  const DlnaSession({required this.device, required this.url});
}

class Dlna {
  Dlna._();
  static final Dlna instance = Dlna._();

  /// Android 上多播需要 MulticastLock，否则收不到 SSDP 响应。
  /// 这个锁在系统层面是「省电优化」的一部分：没有它，Wi-Fi 芯片会
  /// 过滤掉目的地址不是本机的多播包，程序表现为「一台设备都搜不到」，
  /// 但同一网络里别的投屏 App 都正常，非常容易误判成代码问题。
  static const MethodChannel _ch = MethodChannel('com.zhuiju.app/tv');

  DlnaSession? session;

  Timer? _keepAlive;

  static const String _ssdpHost = '239.255.255.250';
  static const int _ssdpPort = 1900;

  /// 搜索目标：只要「能渲染音视频」的设备。
  /// 用 MediaRenderer 而不是 MediaServer —— 电视对前者才接受推流。
  static const String _searchTarget =
      'urn:schemas-upnp-org:device:MediaRenderer:1';

  // ---------------- 发现 ----------------

  /// 搜索局域网内的投屏设备。
  ///
  /// [timeout] 内收到的设备都会汇总返回。UDP 会丢包，所以隔 700ms
  /// 补发一次 M-SEARCH，发三轮覆盖绝大多数设备。
  Future<List<DlnaDevice>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final found = <String, DlnaDevice>{};
    RawDatagramSocket? sock;

    try {
      await _acquireMulticast(true);
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      try {
        sock.multicastHops = 4;
      } catch (_) {
        // 个别系统不允许设置，忽略即可
      }

      // 待解析的 LOCATION，收敛到 set 里避免重复拉 XML
      final locations = <String>{};

      sock.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = sock?.receive();
        if (dg == null) return;
        final text = utf8.decode(dg.data, allowMalformed: true);
        // 只处理 HTTP/1.1 200 OK 的搜索响应
        if (!text.startsWith('HTTP/1.1 200') && !text.startsWith('HTTP/1.0 200')) {
          return;
        }
        final loc = _header(text, 'location');
        if (loc == null || loc.isEmpty) return;
        // 只接受 http 的 LOCATION：少数设备会填主机名，
        // 在部分网络里解析不了，直接用会卡住整个发现流程。
        if (!loc.startsWith('http://')) return;
        locations.add(loc);
      });

      Future<void> probe() async {
        const msg = 'M-SEARCH * HTTP/1.1\r\n'
            'HOST: $_ssdpHost:$_ssdpPort\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 2\r\n'
            'ST: $_searchTarget\r\n'
            'USER-AGENT: Android/9 UPnP/1.1 4KZhuiju/1.0\r\n'
            '\r\n';
        final data = utf8.encode(msg);
        final target = InternetAddress(_ssdpHost);
        for (var i = 0; i < 3; i++) {
          try {
            sock?.send(data, target, _ssdpPort);
          } catch (e) {
            debugPrint('[DLNA] send failed: $e');
          }
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      }

      final sw = Stopwatch()..start();
      // probe 自带 3 轮 ×700ms 的等待，本身就是一个 Future；
      // 让它并行跑，主流程只按 timeout 计总时长。
      unawaited(probe());
      // 收满 timeout 再收尾：设备响应快慢差别很大，
      // 提前结束会漏掉慢的那几台。
      await Future<void>.delayed(timeout);
      sw.stop();

      // 并发拉设备描述，解析出 friendlyName 和 controlURL
      final results = await Future.wait(
        locations.map(_loadDescription),
      );
      for (final d in results) {
        if (d != null) found[d.controlUrl] = d;
      }
      debugPrint('[DLNA] discover done: ${found.length} device(s), '
          '${locations.length} location(s) in ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      debugPrint('[DLNA] discover failed: $e');
    } finally {
      try {
        sock?.close();
      } catch (_) {}
      await _acquireMulticast(false);
    }

    final list = found.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// 取 LOCATION 指向的设备描述 XML，抽出名字和控制地址
  Future<DlnaDevice?> _loadDescription(String location) async {
    try {
      final xml = await _httpGet(location);
      if (xml.isEmpty) return null;

      // 只认 AVTransport 服务：有的设备同时暴露 RenderingControl
      // 和 ConnectionManager，取错了就控制不了播放。
      final control = _pickControlUrl(xml, location);
      if (control == null) return null;

      final name = _tag(xml, 'friendlyName') ?? '未知设备';
      final model = _tag(xml, 'modelName') ?? '';
      return DlnaDevice(
        name: name,
        location: location,
        controlUrl: control,
        model: model,
      );
    } catch (e) {
      debugPrint('[DLNA] desc failed ($location): $e');
      return null;
    }
  }

  /// 从设备描述里找 AVTransport 的 controlURL，并补成绝对地址。
  ///
  /// XML 结构大致是：
  ///   <service>
  ///     <serviceType>urn:...:service:AVTransport:1</serviceType>
  ///     <controlURL>/upnp/control/AVTransport1</controlURL>
  ///   </service>
  /// 相对地址要以 LOCATION 的 origin 为基址拼接。
  String? _pickControlUrl(String xml, String location) {
    final blocks = RegExp(
      r'<service>(.*?)</service>',
      dotAll: true,
      caseSensitive: false,
    ).allMatches(xml);

    for (final b in blocks) {
      final body = b.group(1) ?? '';
      if (!body.toLowerCase().contains('avtransport')) continue;
      final cu = _tag(body, 'controlURL');
      if (cu == null || cu.trim().isEmpty) continue;
      return _absolutize(location, cu.trim());
    }

    // 有些精简固件不写 <service> 包裹，退化成直接找 AVTransport 段
    final idx = xml.toLowerCase().indexOf('avtransport');
    if (idx > 0) {
      final tail = xml.substring(idx);
      final cu = _tag(tail, 'controlURL');
      if (cu != null && cu.trim().isNotEmpty) {
        return _absolutize(location, cu.trim());
      }
    }
    return null;
  }

  String _absolutize(String base, String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final u = Uri.parse(base);
    final origin = '${u.scheme}://${u.authority}';
    if (path.startsWith('/')) return '$origin$path';
    // 相对当前目录
    final dir = u.path.substring(0, u.path.lastIndexOf('/') + 1);
    return '$origin$dir$path';
  }

  // ---------------- 控制 ----------------

  /// 把视频推到设备并开始播放
  Future<bool> play(DlnaDevice device, String url, {String title = ''}) async {
    try {
      final meta = _didl(title, url);
      final r1 = await _soap(device, 'SetAVTransportURI', '''
<InstanceID>0</InstanceID>
<CurrentURI>${_esc(url)}</CurrentURI>
<CurrentURIMetaData>${_esc(meta)}</CurrentURIMetaData>''');
      if (r1 == null) return false;

      // 有些电视收到 URI 后不会自动播，必须显式再发一条 Play
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final r2 = await _soap(device, 'Play', '''
<InstanceID>0</InstanceID>
<Speed>1</Speed>''');
      if (r2 == null) return false;

      session = DlnaSession(device: device, url: url);
      _startKeepAlive();
      return true;
    } catch (e) {
      debugPrint('[DLNA] play failed: $e');
      return false;
    }
  }

  Future<bool> pause() async {
    final s = session;
    if (s == null) return false;
    return await _soap(s.device, 'Pause', '<InstanceID>0</InstanceID>') != null;
  }

  Future<bool> resume() async {
    final s = session;
    if (s == null) return false;
    return await _soap(s.device, 'Play', '''
<InstanceID>0</InstanceID>
<Speed>1</Speed>''') != null;
  }

  /// 停止投屏：停播放并把设备上的 URI 清空，
  /// 否则电视会停在最后一帧，用户得自己拿遥控器退出
  Future<void> stop() async {
    final s = session;
    _keepAlive?.cancel();
    _keepAlive = null;
    session = null;
    if (s == null) return;
    try {
      await _soap(s.device, 'Stop', '<InstanceID>0</InstanceID>');
      await _soap(s.device, 'SetAVTransportURI', '''
<InstanceID>0</InstanceID>
<CurrentURI></CurrentURI>
<CurrentURIMetaData></CurrentURIMetaData>''');
    } catch (e) {
      debugPrint('[DLNA] stop failed: $e');
    }
  }

  /// 投屏期间定期询问设备是否还在播。
  ///
  /// 电视被关机、拔网线、切到别的输入源时，手机这边是没有任何通知的。
  /// 不轮询的话，App 会一直显示「正在投屏」，用户点暂停毫无反应。
  void _startKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(const Duration(seconds: 10), (t) async {
      final s = session;
      if (s == null) {
        t.cancel();
        return;
      }
      final st = await _soap(s.device, 'GetTransportInfo', '''
<InstanceID>0</InstanceID>''');
      // 拿不到状态说明设备已经不可达，直接结束会话
      if (st == null) {
        debugPrint('[DLNA] device unreachable, drop session');
        session = null;
        t.cancel();
      }
    });
  }

  /// 发一条 AVTransport SOAP 请求。
  ///
  /// 成功返回响应体（可能为空字符串），失败返回 null。
  /// 用「是否为 null」判断成败，而不是判空字符串——很多设备对
  /// Play/Stop 这类动作就是回一个空的 Envelope，用 isEmpty 判断
  /// 会把成功当成失败。
  Future<String?> _soap(
    DlnaDevice device,
    String action,
    String inner,
  ) async {
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        '$inner'
        '</u:$action>'
        '</s:Body></s:Envelope>';

    return _httpPost(
      device.controlUrl,
      body,
      soapAction: '"urn:schemas-upnp-org:service:AVTransport:1#$action"',
    );
  }

  // ---------------- HTTP ----------------

  Future<String?> _httpPost(String url, String body,
      {required String soapAction}) async {
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..idleTimeout = const Duration(seconds: 5);
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set('SOAPACTION', soapAction);
      final bytes = utf8.encode(body);
      req.contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode >= 400) {
        debugPrint('[DLNA] soap $soapAction -> ${resp.statusCode} $text');
        return null;
      }
      return text;
    } catch (e) {
      debugPrint('[DLNA] soap error: $e');
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<String> _httpGet(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..idleTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return '';
      return await resp.transform(utf8.decoder).join();
    } catch (e) {
      debugPrint('[DLNA] get error ($url): $e');
      return '';
    } finally {
      client?.close(force: true);
    }
  }

  /// 申请/释放 Android 多播锁（非 Android 平台直接跳过）
  Future<void> _acquireMulticast(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod<bool>(on ? 'acquireMulticast' : 'releaseMulticast');
    } catch (_) {
      // 没有实现这个方法的旧版本直接忽略
    }
  }

  // ---------------- 工具 ----------------

  /// 从 SSDP/HTTP 响应头里取字段（大小写不敏感）
  String? _header(String text, String key) {
    for (final line in const LineSplitter().convert(text)) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      if (line.substring(0, i).trim().toLowerCase() == key) {
        return line.substring(i + 1).trim();
      }
    }
    return null;
  }

  /// 取第一个标签的文本内容
  String? _tag(String xml, String name) {
    final m = RegExp(
      '<$name[^>]*>(.*?)</$name>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(xml);
    final v = m?.group(1);
    if (v == null) return null;
    return _unesc(v.trim());
  }

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  String _unesc(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  /// DIDL-Lite 元数据。很多电视不看这个字段，但三星/LG 这类
  /// 会用它决定用什么解码器打开，缺失时表现为「接受指令但不播」。
  String _didl(String title, String url) {
    final t = _esc(title.isEmpty ? '视频' : title);
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="1" parentID="0" restricted="1">'
        '<dc:title>$t</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:video/*:*">${_esc(url)}</res>'
        '</item></DIDL-Lite>';
  }
}