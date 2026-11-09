/// 搜索历史（本机）
///
/// 主流影视 App 的搜索页都有「搜索历史」：追剧是个连续动作，用户搜过
/// 「凡人修仙传」之后隔几天还会再搜同一个词，重新一个字一个字打很烦。
/// 之前这个 App 只有一个写死的「热门搜索」列表，用户搜过的词过目即忘。
///
/// 设计取舍：
///   1. 只用 SharedPreferences 存字符串列表，不引数据库。
///      几十条关键词，用不着 SQLite。
///   2. 最近搜过的排最前、去重、限制长度。重复搜同一个词只是把它顶到
///      最前，不会在列表里出现两次。
///   3. **不做云同步**：本 App 没有账号体系，历史只在本机，
///      避免为了一个关键词列表引入登录。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SearchHistory {
  SearchHistory._();
  static final SearchHistory instance = SearchHistory._();

  static const String _prefsKey = 'search_history';

  /// 最多保留条数。太多会挤满搜索页，用户反而找不到想要的那个。
  static const int maxItems = 20;

  /// 单个关键词最大长度。防止用户粘贴一整段文本进来把列表撑爆。
  static const int maxKeywordLen = 40;

  /// 搜索历史列表（最近的在最前）。空列表表示没有历史。
  final ValueNotifier<List<String>> items = ValueNotifier<List<String>>([]);

  bool _restored = false;

  /// 启动时调用；不 await 也能用，读回来会自动刷新 notifier。
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getStringList(_prefsKey) ?? const <String>[];
      items.value = _sanitize(raw);
    } catch (e) {
      debugPrint('[SEARCH] restore failed: $e');
    }
  }

  /// 记录一次搜索。空关键词直接忽略（清空输入框不该产生一条记录）。
  void add(String keyword) {
    final k = _normalize(keyword);
    if (k.isEmpty) return;
    final list = List<String>.from(items.value)..remove(k);
    list.insert(0, k);
    if (list.length > maxItems) list.removeRange(maxItems, list.length);
    items.value = list;
    _persist();
  }

  /// 删除单个关键词
  void remove(String keyword) {
    final list = List<String>.from(items.value)..remove(keyword);
    if (list.length == items.value.length) return;
    items.value = list;
    _persist();
  }

  void clear() {
    if (items.value.isEmpty) return;
    items.value = const [];
    _persist();
  }

  /// 去掉首尾空白、内部换行压成空格、截断超长
  String _normalize(String s) {
    var t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length > maxKeywordLen) t = t.substring(0, maxKeywordLen);
    return t;
  }

  /// 读盘后的清洗：去掉空白项、去重、截断到上限。
  /// 旧版本写坏的数据（比如手工改过 prefs）不该让搜索页崩掉。
  List<String> _sanitize(List<String> raw) {
    final out = <String>[];
    final seen = <String>{};
    for (final r in raw) {
      final k = _normalize(r);
      if (k.isEmpty || !seen.add(k)) continue;
      out.add(k);
      if (out.length >= maxItems) break;
    }
    return out;
  }

  void _persist() {
    // 串行化写盘，并且**以最新快照为准**。
    //
    // 原来的写法是每次直接 `getInstance().then(setStringList(当次快照))`，
    // 看起来没问题，实测有竞态：用户快速连搜两个词时会发起两次写入，
    // 两者并发，先发起的那次可能最后落盘，把新列表用旧列表覆盖回去——
    // 表现就是「刚搜过的词，下次进搜索页不见了」。
    // test/search_history_test.dart 的「写盘后能读回」用例抓到过这个。
    //
    // 现在用一个 in-flight 标记 + dirty 重试：同一时刻只有一次写入在飞，
    // 期间的新变更只置 dirty，等当前这次结束后再按最新的 items.value 写一遍。
    if (_saving) {
      _dirty = true;
      return;
    }
    unawaited(_flush());
  }

  bool _saving = false;
  bool _dirty = false;

  Future<void> _flush() async {
    _saving = true;
    try {
      do {
        _dirty = false;
        final v = List<String>.from(items.value);
        final sp = await SharedPreferences.getInstance();
        await sp.setStringList(_prefsKey, v);
      } while (_dirty);
    } catch (e) {
      debugPrint('[SEARCH] persist failed: $e');
    } finally {
      _saving = false;
    }
  }
}