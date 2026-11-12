/// 下载按剧集分组
///
/// 覆盖三件容易悄悄错的事：
///   1. 老索引没有 `group` 字段，只能从 `title` 反推剧名。推错了，
///      升级前下的那些集会被拆成一堆「只有一集」的组；
///   2. 组内条目的短标题。剥错了用户就看不到是第几集；
///   3. 分组不能丢任务、不能重复。这是纯数据整形，错了会直接表现为
///      「下完的剧在列表里消失了」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhuiju/core/download.dart';

DownloadTask _task({
  required String title,
  String group = '',
  DownloadState state = DownloadState.done,
  int total = 100,
}) {
  final t = DownloadTask(
    id: title,
    title: title,
    sourceUrl: '',
    ext: 'mp4',
    isHls: false,
  );
  t.group = group;
  t.state = state;
  t.total = total;
  return t;
}

void main() {
  group('groupOfTitle 从标题反推剧名', () {
    test('常规「剧名_集名」', () {
      expect(groupOfTitle('兰香如故_第01集'), '兰香如故');
      expect(groupOfTitle('狂飙_第1集'), '狂飙');
    });

    test('剧名自身带下划线时取最后一个分隔符', () {
      // 「我的_前半生_第01集」不该被切成「我的」
      expect(groupOfTitle('我的_前半生_第01集'), '我的_前半生');
    });

    test('没有分隔符时整条都是剧名', () {
      expect(groupOfTitle('单集片段'), '单集片段');
    });

    test('分隔符在开头时不当分隔处理', () {
      // 「_第01集」这种畸形标题，lastIndexOf 返回 0，
      // 切成空剧名会让整组显示成空白，必须退回整条标题
      expect(groupOfTitle('_第01集'), '_第01集');
    });
  });

  group('groupKeyOf 优先用显式分组', () {
    test('有 group 字段时直接用它', () {
      final t = _task(title: '任意标题', group: '兰香如故');
      expect(groupKeyOf(t), '兰香如故');
    });

    test('group 为空时回退到标题反推', () {
      // 升级前入队的任务就是这种形态
      final t = _task(title: '兰香如故_第03集');
      expect(groupKeyOf(t), '兰香如故');
    });
  });

  group('shortTitleOf 组内短标题', () {
    test('剥掉剧名前缀，只留集名', () {
      expect(shortTitleOf(_task(title: '兰香如故_第01集')), '第01集');
      expect(
          shortTitleOf(_task(title: '兰香如故_第01集', group: '兰香如故')), '第01集');
    });

    test('标题与组名相同时原样返回，不返回空串', () {
      // 单集下载：title 和 group 都是剧名本身
      final t = _task(title: '兰香如故', group: '兰香如故');
      expect(shortTitleOf(t), '兰香如故');
    });

    test('前缀不匹配时原样返回', () {
      final t = _task(title: '别的剧_第01集', group: '兰香如故');
      expect(shortTitleOf(t), '别的剧_第01集');
    });
  });

  group('groupTasks 分组结果', () {
    test('同剧的集聚到一起，顺序保持', () {
      final list = [
        _task(title: '兰香如故_第01集'),
        _task(title: '狂飙_第01集'),
        _task(title: '兰香如故_第02集'),
        _task(title: '狂飙_第02集'),
      ];
      final gs = groupTasks(list);
      expect(gs.length, 2);
      // Map 保留插入顺序：先出现的剧名排前面
      expect(gs[0].name, '兰香如故');
      expect(gs[0].items.length, 2);
      expect(gs[0].items.map((t) => shortTitleOf(t)).toList(),
          ['第01集', '第02集']);
      expect(gs[1].name, '狂飙');
      expect(gs[1].items.length, 2);
    });

    test('不丢任务、不重复', () {
      final list = [
        _task(title: 'A_第01集'),
        _task(title: 'B_第01集'),
        _task(title: 'A_第02集'),
      ];
      final gs = groupTasks(list);
      final flat = gs.expand((g) => g.items).toList();
      expect(flat.length, list.length);
      // 每个原始对象都还在（同一个实例）
      for (final t in list) {
        expect(flat.contains(t), isTrue);
      }
    });

    test('空列表返回空分组', () {
      expect(groupTasks(const <DownloadTask>[]), isEmpty);
    });

    test('单集任务自成一个组', () {
      final gs = groupTasks([_task(title: '某电影')]);
      expect(gs.length, 1);
      expect(gs.first.name, '某电影');
      expect(gs.first.items.length, 1);
    });

    test('显式 group 与标题反推的同一部剧会合并', () {
      // 升级前的老任务（无 group）+ 新任务（有 group）必须落在同一组，
      // 否则同一部剧在列表里会裂成两块
      final list = [
        _task(title: '兰香如故_第01集'), // 老任务
        _task(title: '兰香如故_第02集', group: '兰香如故'), // 新任务
      ];
      final gs = groupTasks(list);
      expect(gs.length, 1);
      expect(gs.first.items.length, 2);
    });
  });

  group('DownloadGroup 汇总', () {
    test('doneCount / runningCount 按状态统计', () {
      final g = groupTasks([
        _task(title: 'A_第01集', state: DownloadState.done),
        _task(title: 'A_第02集', state: DownloadState.running),
        _task(title: 'A_第03集', state: DownloadState.paused),
      ]).first;
      expect(g.items.length, 3);
      expect(g.doneCount, 1);
      expect(g.runningCount, 1);
    });

    test('totalBytes 逐条累加', () {
      final g = groupTasks([
        _task(title: 'A_第01集', total: 100),
        _task(title: 'A_第02集', total: 250),
      ]).first;
      expect(g.totalBytes, 350);
    });
  });

  group('toJson / fromJson 保住分组字段', () {
    test('group 与 fileBase 往返一致', () {
      final t = _task(title: '兰香如故_第01集', group: '兰香如故');
      t.fileBase = '第01集';
      final back = DownloadTask.fromJson(t.toJson());
      expect(back.group, '兰香如故');
      expect(back.fileBase, '第01集');
    });

    test('老索引缺字段时回落为空串，不抛异常', () {
      // 升级前写下的 JSON 根本没有这两个键
      final j = {
        'id': '兰香如故_第01集',
        'title': '兰香如故_第01集',
        'sourceUrl': '',
        'ext': 'mp4',
        'isHls': false,
        'state': 'done',
      };
      final t = DownloadTask.fromJson(j);
      expect(t.group, '');
      expect(t.fileBase, '');
      // 空 group 时分组要靠标题反推，这条链路必须还通
      expect(groupKeyOf(t), '兰香如故');
      expect(shortTitleOf(t), '第01集');
    });
  });
}