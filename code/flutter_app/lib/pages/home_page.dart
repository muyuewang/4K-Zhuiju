/// 首页：分类 Tab + 分页列表
library;

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/layout.dart';
import '../core/models.dart';
import '../core/search_history.dart';
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

/// 热门搜索词（写死的兜底）
///
/// 接口没有热词榜，这几个词是长期在榜的剧/番，新装用户不知道搜什么时
/// 点一下就能看到内容。真实搜索过的词由 SearchHistory 排在它上面。
const List<String> kHotWords = [
  '尚公主',
  '仙逆',
  '凡人修仙传',
  '吞噬星空',
  '完美世界',
  '兰香如故',
];

class HomePage extends StatefulWidget {
  /// 仅测试用：替换真实接口请求
  ///
  /// 为什么留这个口子：PagedGrid 在 initState 就发请求，而 widget 测试
  /// 结束时只要还有未完成的定时器，`!timersPending` 断言就直接失败。
  /// Dio 在 fetch 内部会挂一个零时长定时器，用假 HttpClient 桩也拦不干净
  /// （请求链不止走 dart:io 这一层）。与其在测试里跟 Dio 内部实现缠斗，
  /// 不如让测试直接注入一个立即返回的 loader——布局测试本来就不该联网。
  @visibleForTesting
  final Future<List<Drama>> Function(int tabIndex, int page)? debugLoader;

  const HomePage({super.key, this.debugLoader});

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

  /// TV 下已经访问过的分类下标。
  ///
  /// TV 布局用 IndexedStack 而不是 TabBarView（见 _buildTv 的说明），
  /// 而 IndexedStack 会把 children 全部实例化 —— 7 个分类就等于
  /// 开机瞬间并发 7 个列表请求。这里只构建用户真正点过的分类，
  /// 没访问过的位置放空占位，既省流量又不影响保活。
  final Set<int> _visited = {0};

  @override
  void initState() {
    super.initState();
    _tab.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_tab.index == _tabIndex) return;
    setState(() => _tabIndex = _tab.index);
  }

  /// TV 切换分类：不经过 TabController，直接改下标
  void _selectCategory(int i) {
    if (i == _tabIndex) return;
    setState(() {
      _tabIndex = i;
      _visited.add(i);
    });
    // TabController 同步一下，避免之后若切回触摸布局时角标对不上
    if (_tab.index != i) _tab.index = i;
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
    // 测试注入优先：布局测试不该联网，也不该在树上留定时器
    final injected = widget.debugLoader;
    if (injected != null) return injected(tabIndex, page);

    final c = kCategories[tabIndex];
    if (c.id.isEmpty) {
      // 推荐 = 搜索接口空关键词（实测返回全量热门）
      return ZhuijuApi.instance.search('', page: page);
    }
    return ZhuijuApi.instance.category(c.id, page: page);
  }

  /// 刷新当前 Tab（TV 的刷新按钮用）
  ///
  /// 复用 PagedGrid 的 refresh()：清空列表、页码归 1、作废在飞的旧请求。
  /// 只刷当前 Tab —— 把 7 个分类全部重新请求一遍既慢又浪费流量。
  void _refreshCurrent() {
    final key = _keys[_tabIndex];
    final state = key?.currentState;
    if (state == null) return;
    state.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final tv = isTv(context);
    if (tv) return _buildTv(context);

    // 宽屏下左侧导航栏已有品牌区，AppBar 不再重复写「4K追剧」，
    // 把横向空间让给分类 Tab。
    final wide = useSideNav(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: wide ? null : const Text('4K追剧'),
        toolbarHeight: wide ? 54 : null,
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
            tooltip: '搜索',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
          ),
          const SizedBox(width: 4),
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
            autoFocusFirst: i == _tabIndex,
          );
        }),
      ),
    );
  }

  /// TV 首页：顶部横向频道条 + 下方海报墙
  ///
  /// 为什么不用 TabBarView：
  ///   1. 电视上滑动手势几乎没有（遥控器没有「横划」），TabBarView 的
  ///      翻页能力等于白给，只剩「点 Tab 切换」这一个入口；
  ///   2. TabBarView 会把相邻页一起留在树上并参与布局，配合 IndexedStack
  ///      的按需构建反而更省 —— 只实例化用户真正看过的分类。
  ///
  /// 布局对照 TV 版参考图：左侧导航在 RootPage 的 _SideRail（已存在），
  /// 这里负责右侧内容区的「频道胶囊行 + 海报网格」。
  Widget _buildTv(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _tvChannelBar(context),
            Expanded(
              child: IndexedStack(
                index: _tabIndex,
                children: List.generate(kCategories.length, (i) {
                  // 没访问过的分类不构建：IndexedStack 会实例化所有
                  // children，7 个分类等于开机并发 7 个请求。
                  if (!_visited.contains(i)) {
                    return const SizedBox.shrink();
                  }
                  final key =
                      _keys.putIfAbsent(i, () => GlobalKey<PagedGridState>());
                  return ExcludeFocus(
                    // 非当前分类必须摘掉焦点子树：IndexedStack 不绘制
                    // 非当前页，但焦点系统不认「看不见」，遥控器会走进
                    // 隐藏页的卡片，表现为「按方向键没反应」。
                    excluding: i != _tabIndex,
                    child: TickerMode(
                      enabled: i == _tabIndex,
                      child: PagedGrid(
                        key: key,
                        loader: (p) => _loader(i, p),
                        onTap: _open,
                        autoFocusFirst: i == _tabIndex,
                        padding: const EdgeInsets.fromLTRB(6, 8, 24, 28),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部频道条：频道胶囊 + 右侧搜索/刷新
  ///
  /// 只放**真实生效**的筛选维度。参考图里还有一排「排序方式
  /// （最新/高分/最热/日热度/周热度/月热度）」和「更多筛选」，
  /// 实测本接口对这些参数全部忽略（见 test/api_probe_test.dart：
  /// 10 个参数逐个试过，返回的前 5 条 id 与基准完全一致）。
  /// 摆一排点了没反应的按钮，比不摆更糟，所以这里不做。
  Widget _tvChannelBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Row(
        children: [
          Text(
            '频道',
            style: TextStyle(fontSize: 15, color: context.palette.textDim),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < kCategories.length; i++) ...[
                    _tvChannelChip(context, i),
                    if (i != kCategories.length - 1)
                      const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
          ),
          TvFocusRing(
            radius: 26,
            child: IconButton(
              iconSize: 26,
              icon: const Icon(Icons.search_rounded),
              tooltip: '搜索',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SearchPage()),
              ),
            ),
          ),
          TvFocusRing(
            radius: 26,
            child: IconButton(
              iconSize: 26,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新',
              onPressed: _refreshCurrent,
            ),
          ),
        ],
      ),
    );
  }

  /// 单个频道胶囊
  ///
  /// 选中态用实心强调色（对照参考图里高亮的「电视剧」），
  /// 未选中是描边胶囊。电视上没有鼠标指针，选中与不选中必须有
  /// 明显的明度差，不能只靠一圈细边区分。
  Widget _tvChannelChip(BuildContext context, int i) {
    final active = i == _tabIndex;
    final label = kCategories[i].name;
    final body = GestureDetector(
      onTap: () => _selectCategory(i),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        decoration: BoxDecoration(
          color: active ? kAccent : context.palette.card,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: active ? kAccent : context.palette.divider,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 17,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            // 选中时压在橙底上必须用深色前景，用 palette.bg 在浅色
            // 主题下会是浅灰压橙，对比度不足（同 kOnAccent 的注释）
            color: active ? kOnAccent : context.palette.onSurface,
          ),
        ),
      ),
    );
    return TvFocus(
      radius: 9,
      onActivate: () => _selectCategory(i),
      child: body,
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
    // 落一条搜索历史：用户下次进搜索页直接点，不用重打
    SearchHistory.instance.add(q);
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
    final tv = isTv(context);
    return ListView(
      padding: EdgeInsets.all(tv ? 24 : 16),
      children: [
        // 搜索历史排在热门之前：用户自己搜过的词，命中率远高于热词。
        // 没有历史时这一段整体不渲染（不留一个空标题）。
        ValueListenableBuilder<List<String>>(
          valueListenable: SearchHistory.instance.items,
          builder: (c, hist, _) {
            if (hist.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('搜索历史',
                        style: TextStyle(
                            fontSize: tv ? 16 : 13,
                            color: context.palette.textDim)),
                    const Spacer(),
                    TvFocusRing(
                      radius: 14,
                      child: TextButton.icon(
                        onPressed: () => _confirmClearHistory(hist.length),
                        style: TextButton.styleFrom(
                          minimumSize: Size(0, tv ? 38 : 28),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          foregroundColor: context.palette.textDim,
                        ),
                        icon: Icon(Icons.delete_outline_rounded,
                            size: tv ? 17 : 14),
                        label: Text('清空',
                            style: TextStyle(fontSize: tv ? 14 : 11.5)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 9,
                  runSpacing: 9,
                  children: [
                    for (final w in hist)
                      _historyChip(w, tv),
                  ],
                ),
                SizedBox(height: tv ? 26 : 20),
              ],
            );
          },
        ),
        Text('热门搜索',
            style: TextStyle(
                fontSize: tv ? 16 : 13, color: context.palette.textDim)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: kHotWords
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
    );
  }

  /// 一条历史关键词：点击即搜，右侧小叉单条删除
  ///
  /// 用自绘的胶囊而不是 InputChip：InputChip 的删除按钮在 TV 上
  /// 拿不到独立焦点，遥控器没法只删某一个词。这里把「搜」和「删」
  /// 做成两个可聚焦区域，遥控器左右就能走。
  Widget _historyChip(String w, bool tv) {
    final searchArea = GestureDetector(
      onTap: () => _doSearch(w),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.fromLTRB(tv ? 14 : 11, tv ? 9 : 6, 4,
            tv ? 9 : 6),
        child: Text(w, style: TextStyle(fontSize: tv ? 15 : 12)),
      ),
    );
    final delArea = GestureDetector(
      onTap: () => SearchHistory.instance.remove(w),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: tv ? 8 : 5, vertical: tv ? 9 : 6),
        child: Icon(Icons.close_rounded,
            size: tv ? 16 : 13, color: context.palette.textDim),
      ),
    );

    final chip = Container(
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tv) TvFocus(radius: 18, onActivate: () => _doSearch(w), child: searchArea) else searchArea,
          if (tv)
            TvFocus(
                radius: 18,
                onActivate: () => SearchHistory.instance.remove(w),
                child: delArea)
          else
            delArea,
        ],
      ),
    );
    if (tv) return TvFocusRing(radius: 18, child: chip);
    return chip;
  }

  /// 清空搜索历史前确认：这是本机数据，删了没法恢复
  Future<void> _confirmClearHistory(int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: context.palette.card,
        title: const Text('清空搜索历史？', style: TextStyle(fontSize: 15)),
        content: Text('将删除 $count 条搜索记录，此操作不可恢复。',
            style: TextStyle(fontSize: 12.5, color: context.palette.textDim)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) SearchHistory.instance.clear();
  }
}