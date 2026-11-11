/// 「我的」页面
///
/// 原来底部第二个 Tab 是「下载」，直接进下载管理。问题是下载只是
/// 一个功能，用户还有「接着看上次的剧」「清理空间」这类需求，
/// 全塞进下载页会越堆越乱。改成「我的」做聚合入口：
///   顶部统计 → 快捷入口（下载管理 / 最近观看）→ 最近观看预览 → 设置
///
/// 不做账号体系：App 的数据全在本机，强行加登录只会增加使用门槛。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/cache_cleaner.dart';
import '../core/download.dart';
import '../core/favorites.dart';
import '../core/history.dart';
import '../core/layout.dart';
import '../core/playback_prefs.dart';
import '../core/source/data_source.dart';
import '../core/source/registry.dart';
import '../core/theme_settings.dart';
import '../core/tv.dart';
import '../core/version.dart';
import '../theme.dart';
import '../widgets/tv_focus.dart';
import 'detail_page.dart';
import 'download_page.dart';
import 'favorites_page.dart';
import 'history_page.dart';
import '../core/tokens.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    return Scaffold(
      backgroundColor: context.palette.bg,
      appBar: AppBar(title: const Text('我的')),
      body: wide ? _wideBody(context) : _narrowBody(context),
    );
  }

  /// 手机：单列纵向流
  Widget _narrowBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
      children: [
        _header(context),
        const SizedBox(height: 16),
        _quickEntries(context),
        const SizedBox(height: 18),
        _recentSection(context),
        const SizedBox(height: 18),
        _settings(context),
      ],
    );
  }

  /// 宽屏：左右两栏
  ///
  /// 左边是账号卡 + 快捷入口 + 设置，右边是「继续观看」列表。
  /// 单列拉满 1400 宽的话，每一行都只有一小截内容、剩下全是空白，
  /// 看起来像没做完。
  ///
  /// 但「没有观看记录」时右栏是空的（_recentSection 返回 shrink），
  /// 双栏就会留下半屏死白——新装用户第一眼看到的就是这个。
  /// 所以这里按记录数动态决定：没记录就单列铺开，有记录才分两栏。
  Widget _wideBody(BuildContext context) {
    return ContentClamp(
      child: ValueListenableBuilder<List<WatchRecord>>(
        valueListenable: HistoryStore.instance.records,
        builder: (c, list, _) {
          final hasRecent = list.isNotEmpty;
          final left = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(context),
              const SizedBox(height: 16),
              _quickEntries(context),
              const SizedBox(height: 18),
              _settings(context),
            ],
          );

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
            child: hasRecent
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: left),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [_recentSection(context, previewCount: 8)],
                        ),
                      ),
                    ],
                  )
                // 单列时限制到 720：账号卡和设置项本来就是横向宽条，
                // 拉满 1500 宽会变成一条细长的、读起来很累的行。
                : Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: left,
                    ),
                  ),
          );
        },
      ),
    );
  }

  // ---------------- 顶部统计 ----------------

  // context 必须显式传参：这两个是 StatelessWidget 的私有方法，
  // 不是 build，拿不到隐式的 context（写成 context.palette 会报
  // undefined_identifier）。
  Widget _header(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(R.panel),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kAccent.withValues(alpha: 0.22), context.palette.card],
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(R.panel),
            ),
            child: const Icon(Icons.person_rounded, color: kAccent, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '本地用户',
                  style: TextStyle(fontSize: Ts.subtitle, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '数据仅保存在本机',
                  style:
                      TextStyle(fontSize: Ts.bodySm, color: context.palette.textDim),
                ),
              ],
            ),
          ),
          // 下载数与观看数：用两个 ValueListenable 各自订阅，
          // 任何一边变化都只重建对应数字
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 下载器的数据源是 Stream（不是 ValueListenable），
              // 所以这里必须用 StreamBuilder；观看历史是 ValueNotifier。
              StreamBuilder<List<DownloadTask>>(
                stream: DownloadManager.instance.stream,
                initialData: DownloadManager.instance.tasks,
                builder: (c, snap) {
                  final list = snap.data ?? const <DownloadTask>[];
                  final done =
                      list.where((t) => t.state == DownloadState.done).length;
                  return _stat(context, '$done', '已下载');
                },
              ),
              const SizedBox(height: 6),
              ValueListenableBuilder<List<WatchRecord>>(
                valueListenable: HistoryStore.instance.records,
                builder: (c, list, _) => _stat(context, '${list.length}', '看过'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String v, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            v,
            style: const TextStyle(
                fontSize: Ts.subtitle, fontWeight: FontWeight.w700, color: kAccent),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(fontSize: Ts.caption, color: context.palette.textDim)),
        ],
      );

  // ---------------- 快捷入口 ----------------

  Widget _quickEntries(BuildContext context) {
    // 三个入口并排：下载 / 收藏 / 最近观看。
    // 之前只有两个（下载、最近观看），「想追的剧」没有任何存放位置，
    // 用户只能靠记忆重新搜索——这是和主流影视 App 差得最明显的一处。
    // 三个卡片在 360dp 宽的手机上刚好放得下（每个约 102dp），
    // 副标题也压到了 5 个字以内，不会换行。
    //
    // 必须套 IntrinsicHeight：调用方是 ListView / SingleChildScrollView，
    // 纵向约束是无限大，而 stretch 会把「无限高」原样传给子卡片，
    // 直接抛 "BoxConstraints forces an infinite height"。
    // 布局断言一炸，排在它后面的设置区（含「主题外观」）就整块不渲染了。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: StreamBuilder<List<DownloadTask>>(
              stream: DownloadManager.instance.stream,
              initialData: DownloadManager.instance.tasks,
              builder: (c, snap) {
                final list = snap.data ?? const <DownloadTask>[];
                final running = list
                    .where((t) =>
                        t.state == DownloadState.running ||
                        t.state == DownloadState.paused ||
                        t.state == DownloadState.pending)
                    .length;
                return _entryCard(
                  context,
                  icon: Icons.download_rounded,
                  title: '下载',
                  subtitle: running > 0 ? '$running 进行中' : '${list.length} 个任务',
                  badge: running,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DownloadPage()),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ValueListenableBuilder<List<FavoriteItem>>(
              valueListenable: FavoriteStore.instance.items,
              builder: (c, list, _) => _entryCard(
                context,
                icon: Icons.bookmark_rounded,
                title: '收藏',
                subtitle: list.isEmpty ? '还没有收藏' : '${list.length} 部在追',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FavoritesPage()),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ValueListenableBuilder<List<WatchRecord>>(
              valueListenable: HistoryStore.instance.records,
              builder: (c, list, _) => _entryCard(
                context,
                icon: Icons.history_rounded,
                title: '最近观看',
                subtitle: list.isEmpty ? '还没有记录' : '${list.length} 条记录',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const HistoryPage()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entryCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    int badge = 0,
  }) {
    final tv = isTv(context);
    final card = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(R.panel),
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: tv ? 18 : 14, vertical: tv ? 22 : 16),
        decoration: BoxDecoration(
          color: context.palette.card,
          borderRadius: BorderRadius.circular(R.panel),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: kAccent, size: tv ? 28 : 22),
                if (badge > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: kAccent,
                      borderRadius: BorderRadius.circular(R.card),
                    ),
                    child: Text(
                      '$badge',
                      style: TextStyle(
                          fontSize: tv ? Ts.bodySm : Ts.caption,
                          fontWeight: FontWeight.w700,
                          color: context.palette.bg),
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(height: tv ? Ts.body : Ts.caption),
            Text(
              title,
              style: TextStyle(
                  fontSize: tv ? 18 : 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: TextStyle(
                  fontSize: tv ? Ts.body : Ts.caption, color: context.palette.textDim),
            ),
          ],
        ),
      ),
    );
    // InkWell 已能聚焦并响应确定键，这里只补一圈描边：
    // 电视上没有鼠标指针，看不出选中谁就没法操作。
    if (!tv) return card;
    return TvFocusRing(radius: 14, child: card);
  }

  // ---------------- 最近观看预览 ----------------

  /// 横向缩略图卡片尺寸。
  ///
  /// **固定高度是关键**：原来一条记录就是一整行（竖版海报 84px +
  /// 文字 + 进度条），3 条要吃掉 300 多 px，下面的设置项全被挤出屏幕。
  /// 改成一行横向滚动后，1 条和 8 条占的高度完全一样。
  static const double _kRecentCardW = 112;
  static const double _kRecentThumbH = 70;
  static const double _kRecentStripH = 102;

  Widget _recentSection(BuildContext context, {int previewCount = 6}) {
    return ValueListenableBuilder<List<WatchRecord>>(
      valueListenable: HistoryStore.instance.records,
      builder: (c, list, _) {
        if (list.isEmpty) return const SizedBox.shrink();
        final show = list.take(previewCount).toList();
        return Material(
          key: const ValueKey('recentStrip'),
          color: context.palette.card,
          borderRadius: BorderRadius.circular(R.panel),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 0, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题整行可点：与参考样式一致，进完整历史页
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: InkWell(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const HistoryPage()),
                    ),
                    borderRadius: BorderRadius.circular(R.card),
                    child: Row(
                      children: [
                        Icon(Icons.history_rounded,
                            size: 16, color: context.palette.textDim),
                        const SizedBox(width: 6),
                        const Text(
                          '继续观看',
                          style: TextStyle(
                              fontSize: Ts.bodyLg, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '全部 ${list.length}',
                          style: TextStyle(
                              fontSize: Ts.bodySm,
                              color: context.palette.textDim),
                        ),
                        Icon(Icons.chevron_right_rounded,
                            size: 16, color: context.palette.textDim),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: _kRecentStripH,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 14),
                    itemCount: show.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _recentCard(context, show[i]),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 单条记录：横版缩略图 + 进度时间 + 剧名 + 细进度条。
  ///
  /// 删除入口保留在右上角小角标里 —— 原来的整行布局有个 X 按钮，
  /// 换成紧凑卡片后功能不能凭空消失。用 GestureDetector 而不是
  /// IconButton：后者最小 48x48，会把 112px 宽的卡片撑破。
  Widget _recentCard(BuildContext context, WatchRecord r) {
    return SizedBox(
      width: _kRecentCardW,
      child: InkWell(
        // 点一下就接着上次看，不再只是打开一个还得再点一次的详情页。
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DetailPage(
              dramaId: r.dramaId,
              title: r.dramaName,
              // 按记录自己的来源打开：切源后旧记录仍能正确解析
              sourceId: r.sourceId,
              resumeEpisode: r.episode,
              resumeSource: r.source,
              resumeSec: r.positionSec,
            ),
          ),
        ),
        borderRadius: BorderRadius.circular(R.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(R.card),
              child: SizedBox(
                width: double.infinity,
                height: _kRecentThumbH,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    r.cover.isEmpty
                        ? Container(color: context.palette.bg)
                        : CachedNetworkImage(
                            imageUrl: r.cover,
                            fit: BoxFit.cover,
                            // 112px 宽的小图，按原图解码纯属浪费内存
                            memCacheWidth: 240,
                            errorWidget: (_, __, ___) =>
                                Container(color: context.palette.bg),
                          ),
                    // 底部渐变压住白色小字，浅色封面上也读得清
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0x99000000)],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      right: 6,
                      bottom: 5,
                      child: Text(
                        r.epLabel.isEmpty
                            ? _dur(r.positionSec)
                            : '${r.epLabel} · ${_dur(r.positionSec)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10, color: Colors.white),
                      ),
                    ),
                    Positioned(
                      right: 3,
                      top: 3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => HistoryStore.instance
                            .remove(r.dramaId, r.dramaName),
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: const BoxDecoration(
                            color: Color(0x66000000),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close_rounded,
                              size: 13, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              r.dramaName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: Ts.bodySm, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(R.bar),
              child: LinearProgressIndicator(
                value: r.progress,
                minHeight: 2.5,
                backgroundColor: context.palette.bg,
                valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 设置 ----------------

  Widget _settings(BuildContext context) {
    // 用 Material 而不是带 BoxDecoration 的 Container 来上底色：
    // 里面是一列 ListTile，它的水波纹和背景是画在最近的 Material 上的。
    // 如果中间夹一层 DecoratedBox，水波纹会被盖住并且 debug 版直接抛断言。
    return Material(
      color: context.palette.card,
      borderRadius: BorderRadius.circular(R.panel),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // 下载目录是懒创建的：第一次真正下载时才建。之前这里直接读
          // rootPath，是个普通字段、赋值时没有通知，所以哪怕目录早就建好了，
          // 这一行也永远显示「未创建」。改成订阅 dirNotifier，建好后自动刷新。
          ValueListenableBuilder<String>(
            valueListenable: DownloadManager.instance.dirNotifier,
            builder: (c, path, _) => _settingRow(
              context,
              icon: Icons.folder_open_rounded,
              title: '下载保存位置',
              trailing: path.isEmpty ? '未创建' : '已设置',
              onTap: () {
                // 点击时读实时值，而不是闭包捕获的 path：
                // 用户可能正是在目录刚建好的一瞬间点的。
                final p = DownloadManager.instance.rootPath;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(p.isEmpty ? '尚未创建下载目录' : '保存到：$p',
                      style: const TextStyle(fontSize: Ts.bodySm)),
                  duration: const Duration(seconds: 5),
                ));
              },
            ),
          ),
          Divider(height: 1, color: context.palette.divider),
          // 主题：跟随系统 / 深色 / 浅色
          ValueListenableBuilder<AppThemeMode>(
            valueListenable: ThemeSettings.instance.mode,
            builder: (c, m, _) => _settingRow(
              context,
              icon: m == AppThemeMode.light
                  ? Icons.light_mode_rounded
                  : (m == AppThemeMode.dark
                      ? Icons.dark_mode_rounded
                      : Icons.brightness_auto_rounded),
              title: '主题外观',
              trailing: m.label,
              onTap: () => _pickTheme(context),
            ),
          ),
          Divider(height: 1, color: context.palette.divider),
          // 遥控器模式：自动识别 / 开启 / 关闭
          //
          // 为什么需要手动开关：盒子固件五花八门，有的把 UI_MODE 报成
          // NORMAL、有的不声明 leanback feature，纯靠探测会漏判；
          // 也有人在 HTPC / 投影上接电视用，需要手动强开。
          ValueListenableBuilder<TvOverride>(
            valueListenable: TvMode.instance.override,
            builder: (c, ov, _) => _settingRow(
              context,
              icon: Icons.tv_rounded,
              title: '遥控器模式',
              trailing: ov == TvOverride.auto
                  // 自动档把探测结果显示出来，用户才知道该不该手动开
                  ? (TvMode.instance.detected ? '已识别电视' : ov.label)
                  : ov.label,
              onTap: () => _pickTvMode(context),
            ),
          ),
          Divider(height: 1, color: context.palette.divider),
          // 数据源切换：两个源的片库、线路、画质完全不同，
          // 有的片只有 A 源有、有的只有 B 源能播，用户需要自己挑。
          ValueListenableBuilder<DataSource>(
            valueListenable: SourceRegistry.instance.current,
            builder: (c, src, _) => _settingRow(
              context,
              icon: Icons.dns_rounded,
              title: '数据源',
              trailing: src.displayName,
              onTap: () => _pickSource(context),
            ),
          ),
          Divider(height: 1, color: context.palette.divider),
          // 线路优先级：kanju 一部剧 14~28 条线路，分官方线与采集线两类，
          // 画质和稳定性完全相反。用户实测「普通源很卡」，
          // 所以默认官方优先，但要留一个能退回去的开关（弱网下多一跳反而慢）。
          ValueListenableBuilder<LinePreference>(
            valueListenable: PlaybackPrefs.instance.linePref,
            builder: (c, p, _) => _settingRow(
              context,
              icon: Icons.hd_rounded,
              title: '线路优先级',
              trailing: p.label,
              onTap: () => _pickLinePref(context),
            ),
          ),
          Divider(height: 1, color: context.palette.divider),
          _settingRow(
            context,
            icon: Icons.delete_sweep_rounded,
            title: '清空观看记录',
            onTap: () => _confirmClearHistory(context),
          ),
          Divider(height: 1, color: context.palette.divider),
          // 缓存清理：封面图 + HLS 临时分片的占用，可一键释放。
          // 单独抽成 StatefulWidget，因为要异步扫描目录才知道占了多少，
          // 塞进这个 StatelessWidget 里没法在扫完后刷新那一行文字。
          const CacheSettingRow(),
          Divider(height: 1, color: context.palette.divider),
          _settingRow(
            context,
            icon: Icons.info_outline_rounded,
            title: '关于',
            trailing: 'v$kAppVersion',
            onTap: () => showAboutDialog(
              context: context,
              applicationName: '4K追剧',
              applicationVersion: kAppVersionFull,
              children: [
                Text(
                  '第三方影视客户端，内容来自公开接口，仅用于学习交流。',
                  style:
                      TextStyle(fontSize: Ts.bodySm, color: context.palette.textDim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? trailing,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: context.palette.textDim),
      title: Text(title, style: const TextStyle(fontSize: Ts.bodyLg)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null) ...[
            Text(trailing,
                style:
                    TextStyle(fontSize: Ts.bodySm, color: context.palette.textDim)),
            const SizedBox(width: 4),
          ],
          Icon(Icons.chevron_right_rounded,
              size: 18, color: context.palette.textDim),
        ],
      ),
      onTap: onTap,
    );
  }

  /// 主题选择
  ///
  /// 用底部弹层而不是下拉菜单：三档选项各有说明文字，
  /// 弹层能放下副标题，用户不用猜「跟随系统」到底跟着什么。
  /// 点一下即生效并收起——主题是所见即所得的东西，再点一次「确定」多余。
  Future<void> _pickTheme(BuildContext context) async {
    final cur = ThemeSettings.instance.mode.value;
    await showModalBottomSheet<void>(
      context: context,
      // 用 surface 而不是默认色：默认在深色下是偏灰的容器色，
      // 和设置页卡片色对不上，看起来像另一层皮肤。
      backgroundColor: context.palette.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.pill)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text(
                  '主题外观',
                  style: TextStyle(
                    fontSize: Ts.subtitle,
                    fontWeight: FontWeight.w600,
                    color: sheetCtx.palette.onSurface,
                  ),
                ),
              ),
              for (final m in AppThemeMode.values)
                ListTile(
                  dense: true,
                  leading: Icon(
                    switch (m) {
                      AppThemeMode.system => Icons.brightness_auto_rounded,
                      AppThemeMode.dark => Icons.dark_mode_rounded,
                      AppThemeMode.light => Icons.light_mode_rounded,
                    },
                    size: 21,
                    color: m == cur ? kAccent : sheetCtx.palette.textDim,
                  ),
                  title: Text(
                    m.label,
                    style: TextStyle(
                      fontSize: Ts.bodyLg,
                      fontWeight: m == cur ? FontWeight.w600 : FontWeight.w400,
                      color: m == cur ? kAccent : sheetCtx.palette.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    m.hint,
                    style: TextStyle(
                        fontSize: Ts.bodySm, color: sheetCtx.palette.textDim),
                  ),
                  trailing: m == cur
                      ? const Icon(Icons.check_rounded,
                          size: 19, color: kAccent)
                      : null,
                  onTap: () {
                    ThemeSettings.instance.set(m);
                    Navigator.of(sheetCtx).pop();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 遥控器模式选择
  ///
  /// 和主题选择一样用底部弹层：三档各有说明，弹层能放下副标题。
  /// 另外把「系统探测结果」显式写进自动档的副标题——用户看到
  /// 「未识别到电视」时就知道该手动选「开启」，不用猜。
  Future<void> _pickTvMode(BuildContext context) async {
    final cur = TvMode.instance.override.value;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.palette.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.pill)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text(
                  '遥控器模式',
                  style: TextStyle(
                    fontSize: Ts.subtitle,
                    fontWeight: FontWeight.w600,
                    color: sheetCtx.palette.onSurface,
                  ),
                ),
              ),
              for (final m in TvOverride.values)
                ListTile(
                  dense: true,
                  leading: Icon(
                    switch (m) {
                      TvOverride.auto => Icons.tv_rounded,
                      TvOverride.on => Icons.settings_remote_rounded,
                      TvOverride.off => Icons.smartphone_rounded,
                    },
                    size: 21,
                    color: m == cur ? kAccent : sheetCtx.palette.textDim,
                  ),
                  title: Text(
                    m.label,
                    style: TextStyle(
                      fontSize: Ts.bodyLg,
                      fontWeight: m == cur ? FontWeight.w600 : FontWeight.w400,
                      color: m == cur ? kAccent : sheetCtx.palette.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    // 自动档补一句实际探测结果，避免用户以为开关坏了
                    m == TvOverride.auto
                        ? '${m.hint}（当前：'
                            '${TvMode.instance.detected ? '识别为电视' : '未识别到电视'}）'
                        : m.hint,
                    style: TextStyle(
                        fontSize: Ts.bodySm, color: sheetCtx.palette.textDim),
                  ),
                  trailing: m == cur
                      ? const Icon(Icons.check_rounded,
                          size: 19, color: kAccent)
                      : null,
                  onTap: () {
                    TvMode.instance.setOverride(m);
                    Navigator.of(sheetCtx).pop();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 数据源选择
  ///
  /// 为什么不放在首页顶部做成切换按钮：
  ///   1. 换源是**低频**动作。用户选定一个源后会一直用它，把入口摆在
  ///      首屏每天都在那儿占位，等于天天提示「你用的可能不是最好的」；
  ///   2. 换源会改变整个首页的分类结构（橘汁 7 个 typeId、
  ///      kanju 7 个 content_kind），放在首页顶部一旦误触，
  ///      整个列表内容和滚动位置全丢，用户会以为 App 出问题了。
  ///
  /// 副标题写清各自的特点，用户不必逐个试才知道区别。
  Future<void> _pickSource(BuildContext context) async {
    final cur = SourceRegistry.instance.now;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.palette.card,
      // 源会越加越多（现在是 6 个），弹窗必须能超过默认的 9/16 屏高，
      // 否则尾部源会被裁掉——且因为外层是 Column(min) 不带滚动，
      // 用户连滑都滑不到，看起来就像「某个源消失了」。
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.pill)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            // 留出上方空间，避免弹窗顶到状态栏；同时保证小屏也能滚。
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                  child: Text(
                    '数据源',
                    style: TextStyle(
                      fontSize: Ts.subtitle,
                      fontWeight: FontWeight.w600,
                      color: sheetCtx.palette.onSurface,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final s in SourceRegistry.all)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.dns_rounded,
                            size: 21,
                            color: identical(s, cur)
                                ? kAccent
                                : sheetCtx.palette.textDim,
                          ),
                          title: Text(
                            s.displayName,
                            style: TextStyle(
                              fontSize: Ts.bodyLg,
                              fontWeight: identical(s, cur)
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: identical(s, cur)
                                  ? kAccent
                                  : sheetCtx.palette.onSurface,
                            ),
                          ),
                          subtitle: Text(
                            _sourceHint(s),
                            style: TextStyle(
                                fontSize: Ts.bodySm,
                                color: sheetCtx.palette.textDim),
                          ),
                          trailing: identical(s, cur)
                              ? const Icon(Icons.check_rounded,
                                  size: 19, color: kAccent)
                              : null,
                          onTap: () async {
                            Navigator.of(sheetCtx).pop();
                            if (identical(s, cur)) return;
                            await SourceRegistry.instance.select(s);
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 源的差异由各源自己声明（[DataSource.description]），加源不改这里。
  ///
  /// 早期版本是 `if (s is SectionedFeed) … else …` 二选一，结果新接入的
  /// 片库 4K / 可可影视都不支持弹幕，却被统一标成「分类齐全、支持弹幕」。
  String _sourceHint(DataSource s) =>
      s.description.isEmpty ? '分类齐全' : s.description;

  /// 线路优先级选择
  ///
  /// 为什么需要这个开关：两类线路的优劣不是绝对的。
  ///   - 官方线画质最好（1080P/4K），实测 100% 可播，但要多发一次
  ///     resolve 请求并依赖游客会话；
  ///   - 普通采集线拿来就播、不依赖会话，但清晰度参差、常常卡顿。
  ///
  /// 默认给官方优先（用户实测反馈普通源很卡），但弱网环境下多那一跳
  /// 反而更慢，得让用户能自己退回去。副标题写清代价，用户不用试。
  Future<void> _pickLinePref(BuildContext context) async {
    final cur = PlaybackPrefs.instance.linePref.value;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.palette.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.pill)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text(
                  '线路优先级',
                  style: TextStyle(
                    fontSize: Ts.subtitle,
                    fontWeight: FontWeight.w600,
                    color: sheetCtx.palette.onSurface,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  '仅影响多线路数据源的默认选项，随时可改',
                  style: TextStyle(
                      fontSize: Ts.bodySm, color: sheetCtx.palette.textDim),
                ),
              ),
              for (final p in LinePreference.values)
                ListTile(
                  dense: true,
                  leading: Icon(
                    p == LinePreference.officialFirst
                        ? Icons.hd_rounded
                        : Icons.bolt_rounded,
                    size: 21,
                    color: p == cur ? kAccent : sheetCtx.palette.textDim,
                  ),
                  title: Text(
                    p.label,
                    style: TextStyle(
                      fontSize: Ts.bodyLg,
                      fontWeight:
                          p == cur ? FontWeight.w600 : FontWeight.w400,
                      color: p == cur ? kAccent : sheetCtx.palette.onSurface,
                    ),
                  ),
                  subtitle: Text(
                    p.hint,
                    style: TextStyle(
                        fontSize: Ts.bodySm, color: sheetCtx.palette.textDim),
                  ),
                  trailing: p == cur
                      ? const Icon(Icons.check_rounded,
                          size: 19, color: kAccent)
                      : null,
                  onTap: () async {
                    Navigator.of(sheetCtx).pop();
                    if (p == cur) return;
                    await PlaybackPrefs.instance.setLinePref(p);
                    // 偏好改了，详情页已缓存的线路顺序作废。
                    // 这里不主动刷新页面：用户从「我的」返回时，
                    // 详情页本就会重新取 sourcesByCn 并重排。
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空观看记录？'),
        content: const Text('只清除观看进度记录，已下载的文件不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) HistoryStore.instance.clear();
  }

  String _dur(int sec) {
    if (sec <= 0) return '00:00';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

/// 设置页里的「清理缓存」一行
///
/// 单独做成 StatefulWidget 的原因：占用体积要异步扫目录才知道，
/// 扫描完成得刷那一行文字。放进 `_settings()` 这个 StatelessWidget 里
/// 只能一直显示「计算中」。
///
/// 样式手写而没复用 `_settingRow`：那是 ProfilePage 的私有方法，
/// 跨类调不到。这里保持同样的字号/间距，视觉上看不出差别。
class CacheSettingRow extends StatefulWidget {
  const CacheSettingRow({super.key});

  @override
  State<CacheSettingRow> createState() => _CacheSettingRowState();
}

class _CacheSettingRowState extends State<CacheSettingRow> {
  /// null 表示还在扫
  CacheUsage? _usage;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final u = await CacheCleaner.measure();
    if (!mounted) return;
    setState(() => _usage = u);
  }

  Future<void> _onTap() async {
    if (_busy) return;
    final cur = _usage;
    // 缓存不值得弹确认框：里面全是可再生的封面图和临时分片，
    // 删了下次播放自动重下。多加一步确认反而显得可疑。
    if (cur == null || cur.files == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('没有可清理的缓存', style: TextStyle(fontSize: Ts.bodySm)),
        duration: Duration(seconds: 2),
      ));
      return;
    }

    setState(() => _busy = true);
    final freed = await CacheCleaner.clear();
    if (!mounted) return;
    setState(() => _busy = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        freed.files == 0
            ? '部分文件正在使用，未能清理'
            : '已清理 ${freed.files} 个文件，释放 ${freed.human}',
        style: const TextStyle(fontSize: Ts.bodySm),
      ),
      duration: const Duration(seconds: 3),
    ));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final u = _usage;
    final String trailing;
    if (_busy) {
      trailing = '清理中…';
    } else if (u == null) {
      trailing = '计算中…';
    } else if (u.files == 0) {
      trailing = '无缓存';
    } else {
      trailing = u.human;
    }

    return ListTile(
      dense: true,
      leading: Icon(Icons.cleaning_services_rounded,
          size: 20, color: context.palette.textDim),
      title: const Text('清理缓存', style: TextStyle(fontSize: Ts.bodyLg)),
      subtitle: Text(
        '封面图和临时分片，不影响已下载的视频',
        style: TextStyle(fontSize: Ts.caption, color: context.palette.textDim),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(trailing,
              style: TextStyle(fontSize: Ts.bodySm, color: context.palette.textDim)),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded,
              size: 18, color: context.palette.textDim),
        ],
      ),
      onTap: _onTap,
    );
  }
}
