import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/note_images.dart';
import '../common/app_widgets.dart';

/// 当前文件的图片列表：缩略图 + 一行说明，点一下跳到那一行。
///
/// 和大纲、表格共用右侧那一栏（三者互斥，见 `SettingsController`），所以骨架
/// 刻意和大纲保持一致：同样的列宽、同样的 32px 表头、同样的悬停底色。
class ImagePanel extends StatelessWidget {
  const ImagePanel({
    super.key,
    required this.images,
    required this.onSelect,
    required this.providerFor,
    this.width = AppLayout.rightPanelWidth,
  });

  final List<NoteImage> images;

  /// 点了某一张：参数是那一行的行首偏移，直接交给 `goToOffset`。
  final ValueChanged<int> onSelect;

  /// 把一条引用解析成能画的图片；解析不出（文件不在、路径越界）时返回 `null`，
  /// 面板上给一个占位图标，而不是让整行消失。
  final ImageProvider? Function(NoteImage image) providerFor;

  final double width;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    return Container(
      width: width,
      // 与大纲同一步：编辑区是唯一的亮面，两侧栏都读作它周围的框架色。
      // 左边的拖拽条自己画那条细线，这里不再画，否则两条线差 3px。
      color: p.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: AppLayout.panelHeaderHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.sm, 0),
              child: Row(
                children: <Widget>[
                  Text(
                    '图片',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: p.textTertiary,
                    ),
                  ),
                  const SizedBox(width: AppSpace.xs + 2),
                  Text(
                    '${images.length}',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: images.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                    child: Text(
                      '这份笔记里还没有图片。\n粘贴或拖一张进来，\n这里会列出全部图片。',
                      style: TextStyle(
                        fontSize: AppText.caption,
                        height: 1.6,
                        color: p.textTertiary,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: AppSpace.xl),
                    itemCount: images.length,
                    itemBuilder: (BuildContext context, int i) => _ImageRow(
                      image: images[i],
                      provider: providerFor(images[i]),
                      onTap: () => onSelect(images[i].offset),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ImageRow extends StatelessWidget {
  const _ImageRow({
    required this.image,
    required this.provider,
    required this.onTap,
  });

  final NoteImage image;
  final ImageProvider? provider;
  final VoidCallback onTap;

  /// 缩略图边长。44 是「一眼认得出是哪张图」和「一行放得下两行字」的折中。
  static const double _thumb = 44;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.sm, 3, AppSpace.xs, 3),
          child: AnimatedContainer(
            duration: AppMotion.fast,
            padding: const EdgeInsets.all(AppSpace.sm - 2),
            decoration: BoxDecoration(
              color: hovered ? p.surfaceRaised : Colors.transparent,
              borderRadius: AppRadius.smAll,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _Thumbnail(provider: provider, palette: p, size: _thumb),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        image.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppText.label,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                          color: hovered ? p.textPrimary : p.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _captionFor(image),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppText.caption - 1,
                          height: 1.3,
                          color: p.textTertiary,
                          fontFeatures: const <ui.FontFeature>[
                            ui.FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「第 12 行 · 宽 320」。宽度没写就说「原尺寸」——那正是它现在的表现。
  static String _captionFor(NoteImage image) {
    final StringBuffer out = StringBuffer('第 ${image.line + 1} 行');
    final double? width = image.width;
    out.write(width == null ? ' · 原尺寸' : ' · 宽 ${width.round()}');
    if (image.isExternal) out.write(' · 网络');
    return out.toString();
  }
}

/// 缩略图。加载中、加载失败都给一块安静的占位，不留空洞。
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.provider,
    required this.palette,
    required this.size,
  });

  final ImageProvider? provider;
  final AppPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) {
    final Widget placeholder = Center(
      child: Icon(
        LucideIcons.image,
        size: size * 0.4,
        color: palette.textTertiary,
      ),
    );
    final ImageProvider? source = provider;

    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.surfaceSunken,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: palette.outlineSoft),
      ),
      child: source == null
          ? placeholder
          : Image(
              image: source,
              fit: BoxFit.cover,
              // 解码完成前留占位，完成后淡入；失败退回图标。三态都不让这一格
              // 忽大忽小——列表跟着跳是最难受的。
              frameBuilder:
                  (
                    BuildContext context,
                    Widget child,
                    int? frame,
                    bool wasSynchronouslyLoaded,
                  ) => frame == null ? placeholder : child,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stack) =>
                      placeholder,
            ),
    );
  }
}
