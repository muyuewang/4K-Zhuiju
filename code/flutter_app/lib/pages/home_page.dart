/// 首页：分类 Tab + 分页列表
library;

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/layout.dart';
import '../core/models.dart';
import '../widgets/common.dart';
import '../widgets/tv_focus.dart';
import '../theme.dart';
import 'detail_page.dart';

/// typeId1 实测有效值（20-26）
class Category {
  final String id;
  final String name;
  const Category(this.id, this.name);
}

const List<Category> kCategories = [
  Category('', '推荐'),
  Category('20', '电影'),
  Category('21', '电视剧'),
  Category('22', '综艺'),
  Category('23', '动漫'),
  Category('24', '短剧'),
  Category('26', '其他'),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab =
      TabController(length: kCategories.length, vsync: this);

  final Map<int, GlobalKey<PagedGridState>> _keys = {};

  /// 当前 Tab 下标。TV 下要靠它决定「哪个网格的第一张卡拿初始焦点」：
  /// TabBarView 会把相邻页一起留在树上，若每个网格都 autofocus，
  /// 两个页面会争夺焦点，光标可能跑到看不见的隔壁 Tab。见 PagedGrid。
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tab.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_tab.index == _tabIndex) return;
    setState(() => _tabIndex = _tab.index);
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  void _open(Drama d) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailPage(dramaId: d.id, title: d.name),
    ));
  }

  Future<List<Drama>> _loader(int tabIndex, int page) {
    final c = kCategories[tabIndex];
    if (c.id.isEmpty) {
      // 推荐 = 搜索接口空关键词（实测返回全量热门）
      return ZhuijuApi.instance.search('', page: page);
    }
    return ZhuijuApi.instance.category(c.id, page: page);
  }

  @override
  Widget build(BuildContext context) {
    // 宽屏下左侧导航栏已有品牌区，AppBar 不再重复写「4K追剧」，
    // 把横向空间让给分类 Tab。
    final wide = useSideNav(context);
    final tv = isTv(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: (wide || tv) ? null : const Text('4K追剧'),
        toolbarHeight: tv ? 64 : (wide ? 54 : null),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: Colors.transparent,
          // TV 下把分类 Tab 整体放大：电视上 14pt 在 3 米外基本看不清，
          // Tab 也太窄，遥控器左右移动时容易一步跳过头。
          labelPadding: tv
              ? const EdgeInsets.symmetric(horizontal: 20)
              : null,
          labelStyle: tv
              ? const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)
              : null,
          unselectedLabelStyle:
              tv ? const TextStyle(fontSize: 18) : null,
          tabs: kCategories.map((e) => Tab(text: e.name)).toList(),
        ),
        actions: [
          if (tv)
            // TV 下放大搜索按钮并补焦点描边，否则遥控器移到右上角
            // 时看不出选中了没有。
            TvFocusRing(
              radius: 24,
              child: IconButton(
                iconSize: 28,
                icon: const Icon(Icons.search_rounded),
                tooltip: '搜索',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SearchPage()),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: '搜索',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SearchPage()),
              ),
            ),
          SizedBox(width: tv ? 12 : 4),
        ],
      ),
      body: TabBarView(
        controller: _tab,
        children: List.generate(kCategories.length, (i) {
          final key = _keys.putIfAbsent(i, () => GlobalKey<PagedGridState>());
          return PagedGrid(
            key: key,
            loader: (p) => _loader(i, p),
            onTap: _open,
            // 只有当前 Tab 的网格才拿初始焦点（TV 下）
            autoFocusFirst: i == _tabIndex,
          );
        }),
      ),
    );
  }
}

/// 搜索页
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  List<Drama> _result = const [];
  bool _loading = false;
  bool _searched = false;
  String? _err;

  /// 请求序号：只认最后一次发起的搜索。
  ///
  /// 没有它会出两种错：
  ///   1. 快速连着搜两次（改关键词再回车），先发的那个如果后回来，
  ///      会把后发的结果覆盖掉——界面上显示的是上一次的词。
  ///   2. 搜索进行中点「清空」，请求还在飞，回来后又把结果填回去，
  ///      清空等于没生效。
  /// 每次发起 +1，回来时对不上就直接丢弃。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _doSearch([String? kw]) async {
    final q = (kw ?? _input.text).trim();
    if (q.isEmpty) return;
    _input.text = q;
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _searched = true;
      _err = null;
    });
    try {
      final r = await ZhuijuApi.instance.search(q);
      if (!mounted || seq != _seq) return;
      setState(() {
        _result = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _err = friendlyError(e);
      });
    }
  }

  /// 清空输入：同时让在飞的请求作废，否则它回来还会把结果填上。
  void _clear() {
    _seq++;
    setState(() {
      _input.clear();
      _result = const [];
      _searched = false;
      _loading = false;
      _err = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            controller: _input,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _doSearch(),
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: '搜索影片、剧名',
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: _clear,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _doSearch(),
            child: const Text('搜索'),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Loading();
    if (_err != null) {
      return ErrorView(message: _err!, onRetry: () => _doSearch());
    }
    if (!_searched) {
      return _hotWords();
    }
    if (_result.isEmpty) {
      return const EmptyView(text: '没有找到相关影片');
    }
    return ContentClamp(
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
        gridDelegate: posterGridDelegate(tv: isTv(context)),
        itemCount: _result.length,
        itemBuilder: (c, i) {
          final d = _result[i];
          return DramaCard(
            drama: d,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DetailPage(dramaId: d.id, title: d.name),
            )),
            // 搜索结果列表没有 Tab 并存问题，第一张可直接拿焦点
            autofocus: i == 0,
          );
        },
      ),
    );
  }

  Widget _hotWords() {
    const words = ['尚公主', '仙逆', '凡人修仙传', '吞噬星空', '完美世界', '兰香如故'];
    final tv = isTv(context);
    return Padding(
      padding: EdgeInsets.all(tv ? 24 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('热门搜索',
              style: TextStyle(
                  fontSize: tv ? 16 : 13,
                  color: context.palette.textDim)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: words
                .map((w) => TvFocusRing(
                      radius: 18,
                      child: ActionChip(
                        label: Text(w,
                            style: TextStyle(fontSize: tv ? 15 : 12)),
                        backgroundColor: context.palette.card,
                        side: BorderSide.none,
                        // TV 下把热词做成更大的胶囊，遥控器好瞄准
                        padding: tv
                            ? const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5)
                            : null,
                        onPressed: () => _doSearch(w),
                      ),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}