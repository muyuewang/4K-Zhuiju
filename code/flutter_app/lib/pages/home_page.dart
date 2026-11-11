/// 首页：分类 Tab + 分页列表
library;

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/layout.dart';
import '../core/models.dart';
import '../core/search_history.dart';
import '../core/source/data_source.dart';
import '../core/source/registry.dart';
import '../core/source/zhuiju_source.dart';
import '../widgets/common.dart';
import '../widgets/feed_view.dart';
import '../widgets/tv_focus.dart';
import '../theme.dart';
import 'detail_page.dart';
import '../core/tokens.dart';

/// 分类项。
///
/// 保留这个类只是为了兼容既有测试（tv_home_layout_test 会遍历 kCategories
/// 检查每种分类的布局）。运行时不再用它 —— 真正的分类来自当前数据源，
/// 见 [SourceRegistry.now].categories，因为不同源的分类体系完全不同：
/// 橘汁是 typeId1 = 20/21/22…，kanju 是 content_kind = movie/series…
class Category {
  final String id;
  final String name;
  const Category(this.id, this.name);
}

/// 橘汁频道快照，仅测试与兼容用。
///
/// 直接从 [kZhuijuCategories] 派生，不再手抄一份：v1.9.0 补「直播 /
/// Netflix / 漫剧」时这份快照忘了同步，`tv_home_layout_test` 遍历旧列表
/// 去断言「其他」这个已经不存在的频道，整套测试直接红。改成派生后，
/// 以后加减频道测试自动跟上。
final List<Category> kCategories = [
  for (final c in kZhuijuCategories) Category(c.id, c.name),
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
  /// 当前数据源的分类。换源后条数会变（橘汁 7 个、kanju 7 个但内容不同），
  /// 所以 TabController 也必须跟着重建，不能是 late final。
  List<SourceCategory> get _cats => SourceRegistry.instance.now.categories;

  late TabController _tab = TabController(length: _cats.length, vsync: this);

  final Map<int, GlobalKey<PagedGridState>> _keys = {};

  /// 榜单视图的 key。「推荐」Tab 在支持榜单的源上不走 PagedGrid，
  /// 而是走 FeedView（多分区编排流），刷新要单独找它的 State。
  final Map<int, GlobalKey<FeedViewState>> _feedKeys = {};

  /// 当前源是否支持榜单流（kanju 有、橘汁没有）
  bool get _hasFeed => SourceRegistry.instance.now is SectionedFeed;

  /// 第 [i] 个 Tab 是否该走榜单视图。
  ///
  /// 只有「推荐」（分类 id 为空）走榜单——其余分类是真正的
  /// content_kind 筛选，服务端给的是扁平列表，用榜单区反而更绕。
  bool _isFeedTab(int i) {
    if (!_hasFeed) return false;
    final cats = _cats;
    if (i >= cats.length) return false;
    return cats[i].id.isEmpty;
  }

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
    SourceRegistry.instance.current.addListener(_onSourceChanged);
  }

  /// 切源后必须做三件事，少一件就会串源：
  ///   1. 重建 TabController（分类条数/名字都可能变）
  ///   2. 把所有网格的 key 换掉，强制丢弃上一源的列表与页码
  ///   3. 下标归零，避免停在超出新分类范围的 Tab 上
  void _onSourceChanged() {
    if (!mounted) return;
    _tab.removeListener(_onTabChanged);
    _tab.dispose();

    setState(() {
      _tabIndex = 0;
      _visited
        ..clear()
        ..add(0);
      _keys.clear();
      _feedKeys.clear();
      _tab = TabController(length: _cats.length, vsync: this);
    });
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
    SourceRegistry.instance.current.removeListener(_onSourceChanged);
    super.dispose();
  }

  void _open(Drama d) {
    // 按条目自己的来源打开详情：用户可能刚切了源，但列表里这张卡
    // 还是旧源的结果，用「当前源」去查必然 404。
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailPage(
        dramaId: d.id,
        title: d.name,
        sourceId: d.sourceId.isEmpty ? SourceRegistry.instance.now.id : d.sourceId,
      ),
    ));
  }

  Future<List<Drama>> _loader(int tabIndex, int page) {
    // 测试注入优先：布局测试不该联网，也不该在树上留定时器
    final injected = widget.debugLoader;
    if (injected != null) return injected(tabIndex, page);

    final cats = _cats;
    if (tabIndex >= cats.length) return Future.value(const <Drama>[]);
    final c = cats[tabIndex];
    final src = SourceRegistry.instance.now;
    if (c.id.isEmpty) {
      // 推荐 = 空关键词，两个源的语义一致（给我热门）
      return src.search('', page: page);
    }
    return src.category(c.id, page: page);
  }

  /// 刷新当前 Tab（TV 的刷新按钮用）
  ///
  /// 只刷当前 Tab —— 把 7 个分类全部重新请求一遍既慢又浪费流量。
  /// 榜单 Tab 与网格 Tab 是两种 State，要分别找。
  void _refreshCurrent() {
    if (_isFeedTab(_tabIndex)) {
      _feedKeys[_tabIndex]?.currentState?.refresh();
      return;
    }
    final key = _keys[_tabIndex];
    final state = key?.currentState;
    if (state == null) return;
    state.refresh();
  }

  /// 构建第 [i] 个 Tab 的内容：榜单或分页网格
  ///
  /// 两个视图都实现 refresh()，但类型不同，所以调用方各拿各的 key。
  /// [padding] 只对网格生效——榜单要贴边横向滚动，左右留白由
  /// FeedView 内部给每一行单独加，塞进外层 padding 会把滚动截断。
  Widget _tabBody(int i, {required EdgeInsets padding}) {
    if (_isFeedTab(i)) {
      final key = _feedKeys.putIfAbsent(i, () => GlobalKey<FeedViewState>());
      return FeedView(
        key: key,
        loader: feedLoaderOf(SourceRegistry.instance.now),
        onTap: _open,
        autoFocusFirst: i == _tabIndex,
      );
    }
    final key = _keys.putIfAbsent(i, () => GlobalKey<PagedGridState>());
    return PagedGrid(
      key: key,
      loader: (p) => _loader(i, p),
      onTap: _open,
      autoFocusFirst: i == _tabIndex,
      padding: padding,
    );
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
          tabs: _cats.map((e) => Tab(text: e.name)).toList(),
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
        children: List.generate(_cats.length, (i) {
          // 榜单 Tab 的左右留白交给 FeedView 自己控制（它要贴边滚动），
          // 网格 Tab 沿用原来的内边距。
          return _tabBody(
            i,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
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
                children: List.generate(_cats.length, (i) {
                  // 没访问过的分类不构建：IndexedStack 会实例化所有
                  // children，7 个分类等于开机并发 7 个请求。
                  if (!_visited.contains(i)) {
                    return const SizedBox.shrink();
                  }
                  return ExcludeFocus(
                    // 非当前分类必须摘掉焦点子树：IndexedStack 不绘制
                    // 非当前页，但焦点系统不认「看不见」，遥控器会走进
                    // 隐藏页的卡片，表现为「按方向键没反应」。
                    excluding: i != _tabIndex,
                    child: TickerMode(
                      enabled: i == _tabIndex,
                      child: _tabBody(
                        i,
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
            style: TextStyle(fontSize: Ts.subtitle, color: context.palette.textDim),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < _cats.length; i++) ...[
                    _tvChannelChip(context, i),
                    if (i != _cats.length - 1)
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
    final label = _cats[i].name;
    final body = GestureDetector(
      onTap: () => _selectCategory(i),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        // 跟随系统「减少动态效果」设置
        duration: motionOf(context, Motion.micro),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        decoration: BoxDecoration(
          color: active ? kAccent : context.palette.card,
          borderRadius: BorderRadius.circular(R.card),
          border: Border.all(
            color: active ? kAccent : context.palette.divider,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: Ts.subtitle,
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
      // 走当前数据源：两个源的搜索接口、签名、返回结构完全不同，
      // 页面不该知道这些差异，也不该在切源后还打老源的接口。
      final r = await SourceRegistry.instance.now.search(q);
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
            style: const TextStyle(fontSize: Ts.bodyLg),
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
      // 空屏必须给出路。搜不到时用户原来的唯一动作是「返回」，
      // 等于把「再试一次」的成本全丢给用户自己。这里直接把热词摆出来，
      // 点一下就是一个新的有效查询。
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: EmptyView(
          text: '没找到「${_input.text.trim()}」',
          hint: '换个说法试试，或从下面这些开始',
          action: Wrap(
            alignment: WrapAlignment.center,
            spacing: 9,
            runSpacing: 9,
            children: kHotWords
                .map((w) => ActionChip(
                      label: Text(w, style: const TextStyle(fontSize: Ts.bodySm)),
                      backgroundColor: context.palette.card,
                      side: BorderSide.none,
                      onPressed: () => _doSearch(w),
                    ))
                .toList(),
          ),
        ),
      );
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
              builder: (_) => DetailPage(
                dramaId: d.id,
                title: d.name,
                // 搜索结果有来源标记就按标记走，避免搜索中途切源后打错源
                sourceId: d.sourceId.isEmpty
                    ? SourceRegistry.instance.now.id
                    : d.sourceId,
              ),
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
      padding: EdgeInsets.all(tv ? Ts.display : Ts.subtitle),
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
                            fontSize: tv ? Ts.subtitle : Ts.body,
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
                            size: tv ? Ts.subtitle : Ts.bodyLg),
                        label: Text('清空',
                            style: TextStyle(fontSize: tv ? Ts.bodyLg : Ts.bodySm)),
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
                fontSize: tv ? Ts.subtitle : Ts.body, color: context.palette.textDim)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: kHotWords
              .map((w) => TvFocusRing(
                    radius: 18,
                    child: ActionChip(
                      label: Text(w,
                          style: TextStyle(fontSize: tv ? Ts.subtitle : Ts.bodySm)),
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
        padding: EdgeInsets.fromLTRB(tv ? Ts.bodyLg : Ts.caption, tv ? 9 : 6, 4,
            tv ? 9 : 6),
        child: Text(w, style: TextStyle(fontSize: tv ? Ts.subtitle : Ts.bodySm)),
      ),
    );
    final delArea = GestureDetector(
      onTap: () => SearchHistory.instance.remove(w),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: tv ? 8 : 5, vertical: tv ? 9 : 6),
        child: Icon(Icons.close_rounded,
            size: tv ? Ts.subtitle : Ts.body, color: context.palette.textDim),
      ),
    );

    final chip = Container(
      decoration: BoxDecoration(
        color: context.palette.card,
        borderRadius: BorderRadius.circular(R.pill),
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
        title: const Text('清空搜索历史？', style: TextStyle(fontSize: Ts.subtitle)),
        content: Text('将删除 $count 条搜索记录，此操作不可恢复。',
            style: TextStyle(fontSize: Ts.body, color: context.palette.textDim)),
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