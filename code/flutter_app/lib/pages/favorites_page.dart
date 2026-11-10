/// 我的收藏（追剧列表）
///
/// 和「最近观看」并列但语义不同：
///   - 最近观看 = 看过什么（自动产生，会被裁剪）
///   - 我的收藏 = 打算追什么（用户主动，不自动清理）
///
/// 主流影视 App 都同时提供这两个入口，缺了收藏，用户想「先把想看的存
/// 起来、过几天再挑一部」就完全做不到，只能靠记忆重新搜。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/favorites.dart';
import '../core/layout.dart';
import '../theme.dart';
import '../widgets/tv_focus.dart';
import 'detail_page.dart';
import '../core/tokens.dart';

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.bg,
      appBar: AppBar(
        title: const Text('我的收藏'),
        actions: [
          ValueListenableBuilder<List<FavoriteItem>>(
            valueListenable: FavoriteStore.instance.items,
            builder: (c, list, _) => list.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: '清空收藏',
                    icon: const Icon(Icons.delete_sweep_rounded),
                    onPressed: () => _confirmClear(context),
                  ),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<FavoriteItem>>(
        valueListenable: FavoriteStore.instance.items,
        builder: (c, list, _) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bookmark_border_rounded,
                        color: context.palette.textDim, size: 44),
                    const SizedBox(height: 12),
                    Text('还没有收藏',
                        style: TextStyle(
                            fontSize: Ts.body, color: context.palette.textDim)),
                    const SizedBox(height: 6),
                    Text('在剧集详情页点右上角书签即可收藏',
                        style: TextStyle(
                            fontSize: Ts.caption, color: context.palette.textDim)),
                  ],
                ),
              ),
            );
          }
          final tv = isTv(context);
          return ContentClamp(
            child: GridView.builder(
              padding: EdgeInsets.fromLTRB(
                  tv ? 20 : 12, 10, tv ? 20 : 12, 20),
              gridDelegate:
                  posterGridDelegate(aspect: 0.52, tv: tv),
              itemCount: list.length,
              itemBuilder: (c, i) => _card(context, list[i], tv, i == 0),
            ),
          );
        },
      ),
    );
  }

  Widget _card(
      BuildContext context, FavoriteItem f, bool tv, bool first) {
    final body = GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DetailPage(dramaId: f.dramaId, title: f.name),
      )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(R.card),
                  child: f.cover.isEmpty
                      ? Container(
                          color: context.palette.card,
                          child: Center(
                            child: Icon(Icons.movie_outlined,
                                color: context.palette.textDim, size: 26),
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: f.cover,
                          fit: BoxFit.cover,
                          memCacheWidth: tv ? 640 : 420,
                          placeholder: (_, __) =>
                              Container(color: context.palette.card),
                          errorWidget: (_, __, ___) => Container(
                            color: context.palette.card,
                            child: Center(
                              child: Icon(Icons.movie_outlined,
                                  color: context.palette.textDim, size: 26),
                            ),
                          ),
                        ),
                ),
                // 取消收藏：右上角常驻小按钮
                //
                // 不做成长按菜单：电视上没有长按，手机上也多一步。
                // 放在角上用小尺寸，避免误触（点封面本身是进详情）。
                Positioned(
                  top: 4,
                  right: 4,
                  child: _unfavBtn(context, f, tv),
                ),
                if (f.remark.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(6, 12, 6, 5),
                      decoration: const BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                            bottom: Radius.circular(R.card)),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87],
                        ),
                      ),
                      child: Text(
                        f.remark,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: Ts.caption,
                            color: Colors.white,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            f.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: tv ? Ts.subtitle : Ts.body,
              fontWeight: FontWeight.w500,
              color: context.palette.onSurface,
            ),
          ),
          if (f.subtitle.isNotEmpty)
            Text(
              f.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: tv ? Ts.body : Ts.caption,
                  color: context.palette.textDim),
            ),
        ],
      ),
    );

    if (!tv) return body;
    return TvFocus(
      autofocus: first,
      radius: 10,
      onActivate: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DetailPage(dramaId: f.dramaId, title: f.name),
      )),
      child: body,
    );
  }

  Widget _unfavBtn(BuildContext context, FavoriteItem f, bool tv) {
    final btn = GestureDetector(
      onTap: () => FavoriteStore.instance.remove(f.dramaId),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.all(tv ? 6 : 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.bookmark_rounded,
          size: tv ? 20 : 15,
          color: kAccent,
        ),
      ),
    );
    if (!tv) return btn;
    return TvFocus(
      radius: 30,
      onActivate: () => FavoriteStore.instance.remove(f.dramaId),
      child: btn,
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: context.palette.card,
        title: const Text('清空收藏？', style: TextStyle(fontSize: Ts.subtitle)),
        content: Text('收藏列表会被清空，不影响观看记录和已下载文件。',
            style:
                TextStyle(fontSize: Ts.body, color: context.palette.textDim)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child:
                const Text('清空', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) FavoriteStore.instance.clear();
  }
}