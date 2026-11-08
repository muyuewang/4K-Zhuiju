/// 首页：分类 Tab + 分页列表
library;

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../widgets/common.dart';
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

  @override
  void dispose() {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('4K追剧'),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: Colors.transparent,
          tabs: kCategories.map((e) => Tab(text: e.name)).toList(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
          ),
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
    setState(() {
      _loading = true;
      _searched = true;
      _err = null;
    });
    try {
      final r = await ZhuijuApi.instance.search(q);
      if (!mounted) return;
      setState(() {
        _result = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = friendlyError(e);
      });
    }
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
                onPressed: () => setState(() {
                  _input.clear();
                  _result = const [];
                  _searched = false;
                }),
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
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 9,
        mainAxisSpacing: 14,
        childAspectRatio: 0.56,
      ),
      itemCount: _result.length,
      itemBuilder: (c, i) {
        final d = _result[i];
        return DramaCard(
          drama: d,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DetailPage(dramaId: d.id, title: d.name),
          )),
        );
      },
    );
  }

  Widget _hotWords() {
    const words = ['尚公主', '仙逆', '凡人修仙传', '吞噬星空', '完美世界', '兰香如故'];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('热门搜索',
              style: TextStyle(fontSize: 13, color: kTextDim)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: words
                .map((w) => ActionChip(
                      label: Text(w, style: const TextStyle(fontSize: 12)),
                      backgroundColor: kCard,
                      side: BorderSide.none,
                      onPressed: () => _doSearch(w),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}