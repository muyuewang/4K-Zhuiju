/// JS 插件运行时：在独立 isolate 里执行远程脚本。
///
/// ## 为什么用 JS 而不是 dart_eval
///
/// 项目里之前的评估（见 `doc/源插件化评估.md`）测的是 `dart_eval`，结论是
/// 「async 不可用、null 语义是坏的」。JS 这边完全不同——实测（QuickJS，
/// 2026-11-17）：
///
///   | 能力 | 结果 |
///   | --- | --- |
///   | `JSON` / 正则 / 中文 / emoji | ✅ 全部正常 |
///   | `async` / `await` / `Promise` | ✅ 真能用（`await` 后拿到真实值） |
///   | 宿主 ⇄ JS 双向消息 | ✅ 可用 |
///   | `require` / `dart:io` 逃逸 | ✅ 不存在（QuickJS 无这些全局对象） |
///
/// 也就是说 JS 这边没有 dart_eval 那堆语义坑，作者写起来是正常的 JS。
///
/// ## 沙箱的真实边界（重要，别把这里想得太强）
///
/// **做了的**：
///   - 独立 isolate：插件崩了/卡了，不拖累 UI 线程（实测主 isolate 不受影响）
///   - 全局对象裁剪：QuickJS 本身就没有 Node 的 `require`/`process`/`fs`
///   - 结果体积上限：解析出个 50MB 字符串也不会把内存吃爆
///   - 调用超时：宿主不再无限等待
///
/// **做不到的（实测确认，写在这免得后人误判）**：
///
///   1. `QuickJsRuntime2(timeout: N)` 这个参数**完全无效**。
///      实测 `timeout: 1` 跑 `while(true){}`，89 秒后仍未返回。
///      Emscripten 那层的中断回调没有真正接上。
///
///   2. `Isolate.kill()` **也杀不掉**卡在原生 FFI 里的 isolate。
///      实测 kill 之后 15 秒都没有收到 onExit，主 isolate 仍能正常 spawn
///      新 isolate 干活（说明不是全局冻结，而是那个线程继续空转）。
///
///   所以在当前引擎下，「插件写死循环」这件事**无法被真正中止**。
///   能做的是**限制代价**，见下面 [_poisonBudget]。
///
/// ## 代价限制策略
///
///   - 所有插件共用一个 worker isolate，不每次 spawn（省 15–25ms 编译开销）
///   - 一旦某次调用超时，就给这个 worker 记一次「中毒」，换一个新的顶上。
///     中毒的旧 worker 会在后台继续烧 CPU，所以**有毒上限**：
///     整个进程最多容忍 [_poisonBudget] 次，用完就彻底停用插件执行，
///     并对用户明说「插件已停用」——这比让手机默默发烫好。
///   - 脚本装载前做一次「明显死循环」的静态筛查（见 [looksLikeInfiniteLoop]）。
///     这不是安全边界，是防手滑：正经插件不会写 `while(true)`，
///     而写错了的情况占实际踩坑的绝大多数。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';

import 'plugin_host_api.dart';

/// 一次调用的结果。
class PluginCallResult {
  const PluginCallResult._({
    required this.ok,
    this.value = '',
    this.error = '',
    this.elapsed = Duration.zero,
  });

  factory PluginCallResult.ok(String value, Duration elapsed) =>
      PluginCallResult._(ok: true, value: value, elapsed: elapsed);

  factory PluginCallResult.fail(String error, Duration elapsed) =>
      PluginCallResult._(ok: false, error: error, elapsed: elapsed);

  final bool ok;
  final String value;
  final String error;
  final Duration elapsed;

  @override
  String toString() =>
      ok ? 'ok(${value.length}B, ${elapsed.inMilliseconds}ms)'
          : 'fail($error)';
}

/// 插件运行时。
class PluginRuntime {
  PluginRuntime._();
  static final PluginRuntime instance = PluginRuntime._();

  /// 单次插件调用的等待上限。
  ///
  /// 3 秒的取法：正常解析实测 0.9–1.4ms / 10 条（dart_eval 探针口径），
  /// JS 只会更快；3 秒意味着「慢 2000 倍」才会被判超时，
  /// 足够覆盖低端机 + 超大响应体，同时用户不会觉得像卡死。
  static const Duration defaultDeadline = Duration(seconds: 3);

  /// 整个进程允许「中毒」（=超时且杀不掉）的次数。
  ///
  /// 为什么是 2 而不是更多：每中毒一次，后台就多一个跑满单核的线程。
  /// 2 次已经能让手机明显发热，再多就是事故。用完即停用，
  /// 让用户看见「插件已停用」比让他们握着烫手的手机好。
  static const int _poisonBudget = 2;

  int _poisoned = 0;
  bool _disabled = false;
  bool get isDisabled => _disabled;
  int get poisonCount => _poisoned;

  _Worker? _worker;

  /// 串行队列。worker 一次只处理一个调用，并发进来必须排队，
  /// 否则两个脚本会在同一个 JS 上下文里互相踩（共享全局变量）。
  Future<void> _queue = Future<void>.value();

  /// 调用插件里的一个函数。
  ///
  /// [script] 是插件源码（整段），[entry] 是要调的函数名，
  /// [argsJson] 是 JSON 字符串形式的参数数组（`[a, b]`）。
  ///
  /// 返回值统一是字符串（插件自己 `JSON.stringify` 过），不用 Map，
  /// 避免跨 isolate 传复杂对象时的类型丢失。
  Future<PluginCallResult> call({
    required String script,
    required String entry,
    required String argsJson,
    Duration deadline = defaultDeadline,
  }) async {
    if (_disabled) {
      return PluginCallResult.fail(
          '插件执行已停用（本次运行已多次超时）', Duration.zero);
    }

    // 串行化：把这次调用接在队尾，等前面跑完
    final completer = Completer<PluginCallResult>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(
            await _callOnce(script, entry, argsJson, deadline));
      } catch (e) {
        completer.complete(PluginCallResult.fail('$e', Duration.zero));
      }
    });
    return completer.future;
  }

  Future<PluginCallResult> _callOnce(
    String script,
    String entry,
    String argsJson,
    Duration deadline,
  ) async {
    final sw = Stopwatch()..start();
    final w = await _ensureWorker();
    if (w == null) {
      return PluginCallResult.fail('JS 引擎启动失败', sw.elapsed);
    }

    try {
      final raw = await w.request(
        script: script,
        entry: entry,
        argsJson: argsJson,
      ).timeout(deadline);

      sw.stop();
      if (raw.startsWith('__ERR__')) {
        return PluginCallResult.fail(raw.substring(7), sw.elapsed);
      }
      return PluginCallResult.ok(raw, sw.elapsed);
    } on TimeoutException {
      sw.stop();
      // 这里就是那个「杀不掉」的情况：isolate.kill 对它无效，
      // 只能放弃这个 worker，让它在后台自生自灭，并记账。
      _poison(w, '$entry 超时 ${deadline.inMilliseconds}ms');
      return PluginCallResult.fail(
          '插件执行超时（${deadline.inMilliseconds}ms）', sw.elapsed);
    } catch (e) {
      sw.stop();
      _poison(w, '$e');
      return PluginCallResult.fail('插件调用失败：$e', sw.elapsed);
    }
  }

  void _poison(_Worker w, String why) {
    _poisoned++;
    // 不关端口、不 kill：kill 对卡死的 isolate 无效，还会让状态更混乱。
    // 直接把引用丢掉，下次调用自然 spawn 新的。
    if (identical(_worker, w)) _worker = null;
    debugPrint('[PLUGIN] worker poisoned ($why)，累计 $_poisoned/$_poisonBudget');
    if (_poisoned >= _poisonBudget) {
      _disabled = true;
      debugPrint('[PLUGIN] 超时次数达上限，本次运行停用插件执行');
    }
  }

  Future<_Worker?> _ensureWorker() async {
    if (_worker != null) return _worker;
    try {
      _worker = await _Worker.spawn();
      return _worker;
    } catch (e) {
      debugPrint('[PLUGIN] spawn worker failed: $e');
      return null;
    }
  }

  /// 启动时预热一个 worker（省掉首次调用的 spawn 延迟）。
  Future<void> warmUp() async {
    if (_disabled) return;
    await _ensureWorker();
  }

  /// 仅供测试：重置状态。
  @visibleForTesting
  void resetForTest() {
    _worker = null;
    _poisoned = 0;
    _disabled = false;
    _queue = Future<void>.value();
  }
}

/// 一个后台 worker isolate 的句柄。
///
/// 生命周期：spawn → 收第一条消息（worker 发来的 SendPort）→ 之后每次
/// request 走同一个端口，用自增 id 配对请求与应答。
class _Worker {
  _Worker._(this._iso, this._from);

  final Isolate _iso;
  final ReceivePort _from;

  /// worker 的收件端口。spawn 完成后才拿到（见 [spawn]），
  /// 所以是 late ——这点是 `Isolate.spawn` 的固有形状，不是随便为之。
  late final SendPort _to;
  late final StreamSubscription<dynamic> _sub;

  int _seq = 0;
  final Map<int, Completer<String>> _pending = <int, Completer<String>>{};

  static Future<_Worker> spawn() async {
    final from = ReceivePort();
    final iso = await Isolate.spawn(
      _workerMain,
      from.sendPort,
      debugName: 'plugin-js',
    );

    final w = _Worker._(iso, from);
    final ready = Completer<SendPort>();

    w._sub = from.listen((msg) {
      // 第一条消息必须是 worker 回传的 SendPort，否则它根本没起来
      if (!ready.isCompleted) {
        if (msg is SendPort) {
          ready.complete(msg);
          return;
        }
      }
      w._onMessage(msg);
    });

    w._to = await ready.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError('worker 启动超时'),
    );
    return w;
  }

  void _onMessage(dynamic msg) {
    if (msg is! List || msg.length < 2) return;
    final id = msg[0];
    if (id is! int) return;
    final c = _pending.remove(id);
    if (c == null) return;
    c.complete(msg[1] is String ? msg[1] as String : '${msg[1]}');
  }

  Future<String> request({
    required String script,
    required String entry,
    required String argsJson,
  }) {
    final id = ++_seq;
    final c = Completer<String>();
    _pending[id] = c;
    _to.send(<Object>[id, script, entry, argsJson]);
    return c.future;
  }

  void dispose() {
    _sub.cancel();
    _from.close();
    try {
      _iso.kill(priority: Isolate.immediate);
    } catch (_) {}
  }
}

/// 插件入口返回 Promise 时，worker 用这个标记抛出异常来把信号带回宿主。
///
/// 为什么不用返回值携带标记：`JsEvalResult.stringResult` 跨 FFI 是
/// C 字符串，任何 `\u0000` 都会把内容截断，标记会凭空消失。走异常
/// 通道没有这个限制，而且与正常返回值天然不会混淆。
///
/// 值本身要足够独特，避免和脚本自己的报错文案撞上。
const String kAsyncEntryMark = '__PLUGIN_ASYNC_ENTRY__';

/// 宿主能给插件用的函数名（与 [dispatchHostCall] 的分派表严格一一对应）。
///
/// 显式列出而不是从 Dart 反射生成：反射在 AOT 下会被裁掉，而且
/// 插件作者需要一份**可查阅的清单**——写在 JS 里的 `host.xxx` 拼错了，
/// 应当立刻得到「没有这个函数」，而不是一个运行时的幽灵报错。
const List<String> kHostFunctions = <String>[
  // 摘要
  'md5', 'sha1', 'sha256', 'hmac',
  // 对称加密
  'aesEcbEncrypt', 'aesEcbDecrypt', 'aesCbcEncrypt', 'aesCbcDecrypt',
  // 非对称
  'rsaEncrypt',
  // 编码
  'b64e', 'b64d', 'hex', 'unhex',
  // 结构
  'xml2json',
  // 随机
  'randomHex', 'randomAlnum',
];

/// 在 worker 里装好 `host` 通道，让插件能同步调用宿主能力。
///
/// ## 同步是怎么做到的
///
/// `flutter_js` 的 `sendMessage` 在 QuickJS 里被注册成一个 JSInvokable，
/// 调用时直接跳进 Dart 回调，回调的**返回值原路返回给 JS**
/// （`_dartToJs(ctx, func.invoke(...))`）。所以 JS 这边拿到的是同步值，
/// 不是 Promise。
///
/// 这一点很关键：如果它是异步的，那插件入口就被迫是 `async`，
/// 而入口强制同步是整套设计的地基（见 `_workerMain` 里的 Promise 拒绝）。
///
/// ## 为什么返回 JSON 字符串而不是直接返回对象
///
/// `_dartToJs` 对 Map/List 的支持是「逐个递归建 JS 对象」，能用，
/// 但跨语言边界传结构化对象时，类型细节（int vs double、null vs
/// undefined）容易出岔子。统一走 JSON 字符串，两边各解析一次，
/// 语义完全确定——而且 0.15ms 的单次往返开销下，这点解析成本无所谓。
void _installHostBridge(JavascriptRuntime js, void Function() onCall, int max) {
  js.onMessage('hostCall', (dynamic args) {
    onCall();
    // args 是 jsonDecode 之后的形态：JS 传来的是 `[fn, {...}]`
    String fn;
    Map<String, Object?> params = <String, Object?>{};
    if (args is List) {
      fn = args.isNotEmpty ? '${args[0]}' : '';
      final raw = args.length > 1 ? args[1] : null;
      if (raw is Map) params = raw.cast<String, Object?>();
    } else {
      fn = '$args';
    }
    return jsonEncode(dispatchHostCall(fn, params));
  });

  // 注入 `host` 全局对象。用 evaluate 而不是逐个 setProperty：
  // 一次性建好闭包，比来回跨边界建十几个函数便宜得多。
  //
  // 中间层做三件事：
  //   1. 统一把参数包成对象（位置参数在 JS 里太容易错位）
  //   2. 把 `{"__err": ...}` 转成**抛出异常**——作者该看到的是
  //      `catch(e)` 能抓到的东西，而不是一个看起来像正常返回值的对象
  //   3. 提供 `available()` 让脚本自检，方便写降级逻辑
  js.evaluate('''
var host = (function () {
  var NAMES = ${jsonEncode(kHostFunctions)};
  var budget = $max;

  function call(fn, args) {
    if (budget-- <= 0) {
      throw new Error('host 调用次数超出上限（' + $max + ' 次），疑似在循环里反复调用');
    }
    var raw = sendMessage('hostCall', JSON.stringify([fn, args || {}]));
    if (typeof raw !== 'string') return raw;
    var v = JSON.parse(raw);
    if (v && typeof v === 'object' && !Array.isArray(v) &&
        typeof v.__err === 'string') {
      throw new Error('host.' + fn + ' 失败：' + v.__err);
    }
    return v;
  }

  function str(v) { return v === undefined || v === null ? '' : String(v); }

  var api = {
    // ---- 摘要 ----
    md5:    function (s) { return call('md5',    { s: str(s) }); },
    sha1:   function (s) { return call('sha1',   { s: str(s) }); },
    sha256: function (s) { return call('sha256', { s: str(s) }); },
    hmac:   function (algo, key, msg) {
      return call('hmac', { algo: str(algo), key: str(key), msg: str(msg) });
    },

    // ---- AES ----
    aesEcbEncrypt: function (o) { return call('aesEcbEncrypt', o); },
    aesEcbDecrypt: function (o) { return call('aesEcbDecrypt', o); },
    aesCbcEncrypt: function (o) { return call('aesCbcEncrypt', o); },
    aesCbcDecrypt: function (o) { return call('aesCbcDecrypt', o); },

    // ---- RSA（公钥加密，不是签名；见 plugin_host_api.dart 的说明）----
    rsaEncrypt: function (o) { return call('rsaEncrypt', o); },

    // ---- 编码 ----
    b64e:  function (s, fmt) { return call('b64e',  { s: str(s), fmt: fmt || 'utf8' }); },
    b64d:  function (s, outFmt) { return call('b64d', { s: str(s), outFmt: outFmt || 'utf8' }); },
    hex:   function (s, fmt) { return call('hex',   { s: str(s), fmt: fmt || 'utf8' }); },
    unhex: function (s, outFmt) { return call('unhex', { s: str(s), outFmt: outFmt || 'utf8' }); },

    // ---- 结构 ----
    // MacCMS XML 站靠这个：把 <rss>...</rss> 变成普通 JS 对象
    xml2json: function (xml) { return call('xml2json', { xml: str(xml) }); },

    // ---- 随机 ----
    randomHex:   function (n) { return call('randomHex',   { bytes: n || 8 }); },
    randomAlnum: function (n) { return call('randomAlnum', { n: n || 8 }); },

    // ---- 自检 ----
    // 脚本里可以写 `if (!host.available('rsaEncrypt')) { ...降级... }`
    available: function (name) { return NAMES.indexOf(name) >= 0; },
    names: function () { return NAMES.slice(); }
  };
  return api;
})();
1
''', sourceUrl: 'host_api.js');
}

/// worker isolate 的入口。
///
/// 注意：这个函数必须是顶层函数（`Isolate.spawn` 的限制）。
void _workerMain(SendPort reply) {
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);

  JavascriptRuntime? js;
  // 已装载脚本的指纹，避免每次调用都重编译（编译一次 15–25ms）
  String loadedSig = '';

  /// 本次调用已用掉的宿主函数调用次数。
  ///
  /// 为什么需要：`host.*` 是**同步**调用，插件在循环里狂调会把
  /// worker 线程彻底占住——和死循环一样的后果，而且连超时都拿不到
  /// 干净的中断点。给个上限，超了就返回错误让脚本自己炸在明面上。
  ///
  /// 5000 的取法：一次列表解析最多几十条，每条就算做一次 AES 解密
  /// 也就几十次；5000 已经宽到不可能误伤正常插件。
  int hostCalls = 0;
  const int maxHostCalls = 5000;

  inbox.listen((msg) {
    if (msg is! List || msg.length < 4) return;
    final id = msg[0] as int;
    final script = msg[1] as String;
    final entry = msg[2] as String;
    final argsJson = msg[3] as String;

    try {
      if (js == null) {
        js = getJavascriptRuntime(xhr: false);
        _installHostBridge(js!, () => hostCalls++, maxHostCalls);
      }
      hostCalls = 0;

      // 同一份脚本只编译一次。指纹用长度+首尾片段，
      // 足够区分「换了一份脚本」，又比算 hash 便宜。
      final sig = '${script.length}:${script.hashCode}';
      if (sig != loadedSig) {
        final r = js!.evaluate(script, sourceUrl: 'plugin.js');
        if (r.isError) {
          reply.send(<Object>[id, '__ERR__装载脚本失败：${r.stringResult}']);
          return;
        }
        loadedSig = sig;
      }

      // 用 JSON.parse 传参而不是拼字符串：参数里可能有引号、反斜杠、
      // 换行（响应体里全是这些），拼字符串必然出错。
      //
      // **入口函数必须是同步的。**
      //
      // 为什么直接拒掉 Promise 而不是跑微任务把值取出来：
      // 宿主承担了全部网络 IO，插件只做「字符串 → 字符串」的解析，
      // 没有任何需要 await 的东西。允许 async 只会带来两种后果——
      // 作者以为 await 生效了（实际拿到的是 Promise），或者
      // 插件里去做本该由宿主做的请求（那就绕过了 SSRF 防护）。
      //
      // 检查必须发生在 JSON.stringify **之前**：`JSON.stringify(Promise)`
      // 的结果是 `"{}"`（Promise 没有可枚举的自有属性），一旦先序列化，
      // 到 Dart 这边就只能看到一个正常的空对象，Promise 这件事彻底丢了。
      // 早期版本就是先 stringify 再判断 `res.isPromise`，那条判断
      // 从来没生效过——用 `Promise.resolve(1)` 当入口，宿主会当成
      // 成功返回 `{}`，作者拿到的是一句莫名其妙的「空结果」。
      //
      // 怎么把「这是 Promise」这个信号传回来：**抛一个带标记的异常**。
      // 试过返回带标记的字符串，用 `\u0000` 之类的控制字符做前缀——
      // 不行：`stringResult` 跨 FFI 是 C 字符串，NUL 直接把它截成空串，
      // 标记凭空消失。走 error 分支没有这个问题，而且和正常返回值
      // 天然不会混淆（正常路径不可能进 isError）。
      final code = '(function(){'
          'var __r = $entry.apply(null, JSON.parse(${jsonEncode(argsJson)}));'
          'if (__r && typeof __r.then === "function") {'
          '  throw new Error(${jsonEncode(kAsyncEntryMark)});'
          '}'
          "return typeof __r === 'string' ? __r : JSON.stringify(__r);"
          '})()';
      final res = js!.evaluate(code);

      if (res.isError) {
        if (res.stringResult.contains(kAsyncEntryMark)) {
          reply.send(<Object>[
            id,
            '__ERR__$entry 返回了 Promise（或声明成了 async 函数）。插件入口'
                '必须是同步函数：所有网络请求由宿主发起，脚本只负责解析响应体。'
                '如果确实需要异步逻辑，请把它拆给宿主，不要用 async/await。'
          ]);
          return;
        }
        reply.send(<Object>[id, '__ERR__${res.stringResult}']);
        return;
      }

      // 兜底：万一引擎直接把 Promise 对象交了出来（不同版本行为可能不同）
      if (res.isPromise) {
        reply.send(<Object>[
          id,
          '__ERR__$entry 返回了 Promise（或声明成了 async 函数）。插件入口'
              '必须是同步函数：所有网络请求由宿主发起，脚本只负责解析响应体。'
        ]);
        return;
      }

      final out = res.stringResult;
      // 结果体积上限：插件返回个超大字符串会让跨 isolate 传输把内存顶爆
      const maxOut = 4 * 1024 * 1024;
      if (out.length > maxOut) {
        reply.send(<Object>[id, '__ERR__结果过大（${out.length} 字符）']);
        return;
      }
      reply.send(<Object>[id, out]);
    } catch (e) {
      reply.send(<Object>[id, '__ERR__$e']);
    }
  });
}

/// 静态筛查：脚本里是否出现「明显的死循环」。
///
/// **这不是安全边界**，是防手滑。真正的恶意脚本绕过它轻而易举，
/// 但实际踩坑的绝大多数是作者写错了循环条件。抓到就直接拒掉，
/// 比让用户手机发烫好。
///
/// 只认三种最常见的写法：
///   - `while(true)` / `while (1)` / `while(!!1)`
///   - `for(;;)`
bool looksLikeInfiniteLoop(String script) {
  // 去掉字符串字面量和行注释，避免把 `"while(true)"` 这种误判
  final stripped = script
      .replaceAll(RegExp(r'//[^\n]*'), '')
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r"""'(?:[^'\\]|\\.)*'"""), "''")
      .replaceAll(RegExp(r'"(?:[^"\\]|\\.)*"'), '""');

  if (RegExp(r'for\s*\(\s*;\s*;\s*\)').hasMatch(stripped)) return true;
  if (RegExp(r'while\s*\(\s*(?:true|1|!!1)\s*\)').hasMatch(stripped)) return true;
  return false;
}