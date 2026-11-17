/// 直播页：栏目 Tab + 频道网格 + 搜索
///
/// ## 数据从哪来
///
/// 全部来自打包资源 `assets/live_channels.json`（由 `tools/probe_live.py`
/// 在构建期探活生成）。**打开本页不发任何网络请求**，所以不存在
/// 「转圈等十几秒」——这是与其余 15 个源最本质的区别，理由见
/// `core/source/live_tv_source.dart` 的模块注释。
///
/// ## 为什么点开直接进播放器，没有中间页
///
/// 剧集有详情页是因为它有简介、演员、多线路、分集。频道什么都没有：
/// 一个名字、一个台标、一条流。中间加一页「确认要看这个台吗」纯属
/// 多一次点击，用户点频道就是要看。
///
/// ## 播放器怎么拿地址
///
/// 走 `PlayerPage` 的 `directUrl` 直连通道。不能伪装成 `DramaVideo.path`：
/// 那条路要过 `isDirectUrl` 校验，而 FLV 直播流（`…/douyu/9065082`）
/// 没有扩展名，会被判成「不可播」拦下——实测 2710 个频道里 FLV 占
/// 三分之一，拦掉就是大面积黑屏。
library;

import 'package:flutter/material.dart';

import '../core/layout.dart';
import '../core/models.dart';
import '../core/source/live_tv_source.dart';
import '../core/tokens.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/tv_focus.dart';
import 'player_page.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage>
    // 用复数版本而不是 Single：`_load()` 每次都会新建 TabController，
    // 而 Single 版本只允许 `vsync: this` 被用一次。现在只有一个调用点
    // （initState），但下拉刷新、切源重载这类改动很容易再加一个——
    // 那时崩的形态是 `multiple tickers were created`，与「直播」毫无关系，
    // 排查方向会完全跑偏。首页刚因为同一个写法在冷启动时崩过。
    with TickerProviderStateMixin {
  /// null = 还没读完资源（首帧）
  Map<String, List<LiveChannel>>? _sections;
  List<LiveChannel> _all = const [];

  TabController? _tab;

  /// 搜索关键词。非空时整个页面切成「搜索结果」单列表，
  /// 不再按栏目分 Tab —— 搜索结果跨栏目，留着 Tab 反而让人以为
  /// 只搜了当前栏目。
  String _query = '';
  List<LiveChannel> _hits = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tab?.removeListener(_onTab);
    _tab?.dispose();
    super.dispose();
  }

  /// Tab 切换只影响「当前栏目」的高亮，不需要 setState 重排整个列表：
  /// TabBarView 自己管内容切换。
  void _onTab() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final map = await LiveTvLibrary.bySection();
    final all = await LiveTvLibrary.all();
    if (!mounted) return;
    final ctrl = TabController(length: map.length, vsync: this);
    ctrl.addListener(_onTab);
    setState(() {
      _sections = map;
      _all = all;
      _tab = ctrl;
    });
  }

  Future<void> _search(String q) async {
    final hits = await LiveTvLibrary.search(q);
    if (!mounted) return;
    setState(() {
      _query = q.trim();
      _hits = hits;
    });
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    return Scaffold(
      backgroundColor: context.palette.bg,
      appBar: AppBar(
        title: _query.isEmpty
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text('直播'),
                  // 带上总数不是装饰：这个数字告诉用户「本地有 2000+
                  // 个频道可用」，量级感直接影响他愿不愿意往下翻。
                  // 只有几十个的话，用户会以为功能不完整而直接退出。
                  if (_all.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${_all.length} 个频道',
                      style: TextStyle(
                        fontSize: Ts.caption,
                        fontWeight: FontWeight.w400,
                        color: context.palette.textDim,
                      ),
                    ),
                  ],
                ],
              )
            : TextField(
                autofocus: true,
                style: TextStyle(
                    fontSize: Ts.bodyLg, color: context.palette.onSurface),
                decoration: InputDecoration(
                  hintText: '搜索频道 / 分组',
                  hintStyle: TextStyle(
                      fontSize: Ts.body, color: context.palette.textDim),
                  border: InputBorder.none,
                ),
                onChanged: _search,
              ),
        actions: [
          if (_query.isEmpty)
            IconButton(
              tooltip: '搜索频道',
              icon: const Icon(Icons.search_rounded),
              onPressed: () => setState(() => _query = ' '),
            )
          else
            IconButton(
              tooltip: '取消搜索',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => setState(() {
                _query = '';
                _hits = const [];
              }),
            ),
        ],
        bottom: _query.isEmpty && sections != null && _tab != null
            ? TabBar(
                controller: _tab,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                tabs: [
                  for (final e in sections.entries)
                    Tab(text: '${e.key} ${e.value.length}'),
                ],
              )
            : null,
      ),
      body: _body(sections),
    );
  }

  Widget _body(Map<String, List<LiveChannel>>? sections) {
    if (sections == null) return const Loading();

    // 搜索态：_query 是单个空格表示「刚点开搜索、还没输入」
    if (_query.isNotEmpty && _query.trim().isEmpty) {
      return const EmptyView(
        text: '输入频道名开始搜索',
        hint: '例如「CCTV」「湖南卫视」「斗鱼」',
        icon: Icons.search_rounded,
      );
    }
    if (_query.isNotEmpty) {
      if (_hits.isEmpty) {
        return EmptyView(
          text: '没有找到「$_query」',
          hint: '可以换个关键词，或清空搜索按栏目浏览',
          icon: Icons.search_off_rounded,
          action: FilledButton.tonal(
            onPressed: () => setState(() {
              _query = '';
              _hits = const [];
            }),
            child: const Text('清空搜索'),
          ),
        );
      }
      return _grid(_hits);
    }

    if (sections.isEmpty) {
      return const EmptyView(
        text: '直播源为空',
        hint: '打包资源 assets/live_channels.json 缺失或解析失败，'
            '重新运行 tools/probe_live.py 可重新生成',
        icon: Icons.live_tv_rounded,
      );
    }

    return TabBarView(
      controller: _tab,
      children: [
        for (final e in sections.entries) _grid(e.value),
      ],
    );
  }

  /// 频道网格。
  ///
  /// 用 `posterGridDelegate` 而不是写死列数：频道卡片是方形的，
  /// 但宽屏（桌面 1600+）下写死 3 列会把卡片拉到 500 宽、台标糊成一片。
  /// 复用海报网格的「目标宽度」思路，卡片视觉尺寸在所有屏幕上一致。
  Widget _grid(List<LiveChannel> list) {
    final tv = isTv(context);
    return ContentClamp(
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          // 频道卡片内容少（台标 + 一行字），比海报窄才不浪费横向空间。
          // TV 放大 2 倍，理由同海报：观看距离是沙发到电视。
          maxCrossAxisExtent: tv ? 300 : 150,
          crossAxisSpacing: tv ? 18 : 10,
          mainAxisSpacing: tv ? 20 : 12,
          childAspectRatio: 1.15,
        ),
        itemCount: list.length,
        itemBuilder: (ctx, i) => _ChannelCard(
          channel: list[i],
          onTap: () => _open(list[i], list),
        ),
      ),
    );
  }

  /// 打开频道。
  ///
  /// 为什么把整个 [list] 传下去当「上下台」的顺序来源：电视用户换台
  /// 是高频动作，看完 CCTV1 想接着看 CCTV2 是很自然的。当前没做遥控器
  /// 左右换台，先把列表传进去，后续加「上一个/下一个台」不用改调用点。
  void _open(LiveChannel ch, List<LiveChannel> list) {
    // PlayerPage 要求一个 video 对象，但频道不是剧集。
    // 这里构造一个只承载「标题」的壳：`resolve` 走 directUrl 分支时
    // 完全不会读它的 path/id，只有标题栏与日志会用到 epLabel。
    // 之所以不把 PlayerPage 的 video 改成可空：那要动 60+ 处
    // `_cur.xxx` 引用，风险远大于收益，而壳对象的成本只是一个对象。
    final shell = DramaVideo(
      id: ch.id,
      title: ch.name,
      path: ch.url,
      source: ch.section.isEmpty ? '直播' : ch.section,
      sourceCn: ch.section.isEmpty ? '直播' : ch.section,
    );
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerPage(
        video: shell,
        dramaName: ch.name,
        sourceId: 'live',
        directUrl: ch.url,
        userAgent: ch.ua,
        isLive: true,
        liveChannel: ch,
      ),
    ));
  }
}

/// 频道卡片：台标 + 名称 + 流类型角标
class _ChannelCard extends StatelessWidget {
  final LiveChannel channel;
  final VoidCallback onTap;

  const _ChannelCard({required this.channel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return TvFocus(
      onActivate: onTap,
      radius: R.card,
      child: Material(
        color: p.card,
        borderRadius: BorderRadius.circular(R.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _logo(p)),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Ts.bodySm,
                        fontWeight: FontWeight.w600,
                        color: p.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // 显示原始分组名而不是 section：section 是归并后的
                      // 大类（「一起看」有 800 个台），对用户没有区分度；
                      // group 里的「斗鱼」「虎牙」「咪咕」才是有效信息。
                      channel.group.isNotEmpty ? channel.group : channel.kind,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Ts.caption, color: p.textDim),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 台标。
  ///
  /// 不用 `CachedNetworkImage`：台标地址是几十个小站的图，缓存写磁盘
  /// 反而给「只是路过看一眼」的频道留下大量垃圾文件。用 Flutter 自带的
  /// `Image.network`（内存缓存）+ 失败兜底图标就够了。
  ///
  /// 兜底图标不是可选项：实测源里约四成频道没有 tvg-logo，另有相当一部分
  /// 地址已 404。没有占位的话卡片上半部分会是一片空白，看起来像加载失败。
  Widget _logo(AppPalette p) {
    final placeholder = Center(
      child: Icon(Icons.live_tv_rounded,
          size: 30, color: p.textDim.withValues(alpha: 0.55)),
    );
    if (channel.logo.isEmpty) return placeholder;
    return Image.network(
      channel.logo,
      fit: BoxFit.contain,
      // 台标通常带白底或透明底，直接铺在卡片底色上容易糊成一团，
      // 加一点内边距让它「浮」起来。
      errorBuilder: (_, __, ___) => placeholder,
      loadingBuilder: (ctx, child, prog) =>
          prog == null ? child : placeholder,
    );
  }
}