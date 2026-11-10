/// 探测现有接口是否支持排序 / 筛选参数
///
/// 为什么用 print 而不是 logger：这个文件不是断言型单元测试，
/// 是一份手动执行的联网探针，目的是把「服务端到底认不认这些参数」
/// 的结果打给人看。断言失败与否无法表达「参数被静默忽略」这件事。
// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认装了一个把所有请求打成 400 的 HttpOverrides，
  // 这里置空恢复真实 HttpClient —— 本文件是联网探针，不是单元测试。
  HttpOverrides.global = null;

  String ids(List<dynamic> l) =>
      l.take(5).map((d) => '${d.id}:${d.name}').join(' | ');

  test('分类接口对额外参数的反应', () async {
    final api = ZhuijuApi.instance;

    // 探针不能因为断网就让整个测试套件变红：它不是断言型测试，
    // 拿不到数据时打印「跳过」并正常结束即可。
    final List<dynamic> base;
    try {
      base = await api.category('21'); // 电视剧
    } catch (e) {
      print('网络不可用，跳过本探针: $e');
      return;
    }
    print('基准          : ${ids(base)}');
    print('基准 year 样本: ${base.take(5).map((d) => d.year).toList()}');
    print('基准 remark   : ${base.take(5).map((d) => d.remark).toList()}');

    // 逐个试单个参数
    final params = <String, String>{
      'sort': 'hot',
      'order': 'desc',
      'sortType': '1',
      'orderBy': 'hot',
      'year': '2024',
      'area': '国产',
      'class': '电视剧',
      'typeId1': '21',
      'filter': 'year=2024',
      'isHot': '1',
    };

    for (final e in params.entries) {
      try {
        final r = await api.search('',
            page: 1, pageSize: 20, typeId1: '21', extra: {e.key: e.value});
        final same = ids(r) == ids(base);
        print('${e.key}=${e.value}'.padRight(16) +
            (same ? '→ 无变化（参数被忽略）' : '→ 有变化: ${ids(r)}'));
      } catch (err) {
        print('${e.key}=${e.value}'.padRight(16) + '→ 报错: $err');
      }
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}