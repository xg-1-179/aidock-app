import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 全屏看图：深色底、双指缩放、双击放大、左右滑动切换，底部有计数与翻页按钮。
///
/// 为什么不提供「复制图片 / 保存到相册」：图片在协议里是 base64 原字节，要落到相册
/// 得走 MethodChannel，当前工程没有注册保存通道，硬发会抛 MissingPluginException；
/// 把 base64 原文塞进剪贴板对用户也没有意义。所以这里只保留查看、缩放与关闭。
Future<void> openImageViewer(
  BuildContext context,
  List<String> base64Images,
  int index,
) {
  if (base64Images.isEmpty) return Future<void>.value();
  final start = index < 0
      ? 0
      : (index >= base64Images.length ? base64Images.length - 1 : index);
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ImageViewerPage(images: base64Images, initialIndex: start),
    ),
  );
}

class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.images,
    this.initialIndex = 0,
  });

  final List<String> images;
  final int initialIndex;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pager;
  late int _index;
  bool _zoomed = false;
  final Map<int, Uint8List?> _decoded = <int, Uint8List?>{};

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex < 0
        ? 0
        : (widget.initialIndex >= widget.images.length
            ? widget.images.length - 1
            : widget.initialIndex);
    _pager = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  /// base64 → 字节；兼容 `data:image/png;base64,` 前缀，坏图返回 null 不抛。
  Uint8List? _bytesAt(int at) {
    return _decoded.putIfAbsent(at, () {
      var raw = widget.images[at].trim();
      final comma = raw.indexOf(',');
      if (raw.startsWith('data:') && comma > 0) raw = raw.substring(comma + 1);
      try {
        return base64Decode(raw);
      } catch (_) {
        return null;
      }
    });
  }

  /// 放大状态下先把横滑让给图片拖动，免得拖图顺手把页翻过去。
  void _onZoomChanged(bool zoomed) {
    if (!mounted || zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  void _step(int delta) {
    final last = widget.images.length - 1;
    final next = _index + delta;
    if (!_pager.hasClients || next < 0 || next > last) return;
    _pager.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.images.length;
    return Scaffold(
      backgroundColor: AidockColors.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _pager,
              itemCount: total,
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              onPageChanged: (at) => setState(() {
                _index = at;
                _zoomed = false;
              }),
              itemBuilder: (context, at) {
                final bytes = _bytesAt(at);
                if (bytes == null) return const _BrokenImage();
                return _ZoomableImage(
                  bytes: bytes,
                  label: '第 ${at + 1} 张，共 $total 张',
                  onZoomChanged: _onZoomChanged,
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _RoundButton(
                    icon: Icons.close_rounded,
                    tooltip: '关闭',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AidockColors.bg.withOpacity(0),
                    AidockColors.bg.withOpacity(0.92),
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 10, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '双击放大 · 双指缩放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.3,
                            color: AidockColors.textDim,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AidockColors.surface.withOpacity(0.9),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: AidockColors.line),
                        ),
                        child: Text(
                          '${_index + 1} / $total',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AidockColors.text,
                          ),
                        ),
                      ),
                      if (total > 1) ...[
                        _ArrowButton(
                          icon: Icons.chevron_left_rounded,
                          tooltip: '上一张',
                          onTap: _index > 0 ? () => _step(-1) : null,
                        ),
                        _ArrowButton(
                          icon: Icons.chevron_right_rounded,
                          tooltip: '下一张',
                          onTap: _index < total - 1 ? () => _step(1) : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单张图：包一层 [InteractiveViewer] 给双指缩放，外面接双击放大 / 还原。
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({
    required this.bytes,
    required this.label,
    required this.onZoomChanged,
  });

  final Uint8List bytes;
  final String label;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoom;
  Offset _tapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _animation.addListener(_tick);
  }

  void _tick() {
    final zoom = _zoom;
    if (zoom != null) _transform.value = zoom.value;
  }

  void _reportZoom() {
    widget.onZoomChanged(_transform.value.getMaxScaleOnAxis() > 1.01);
  }

  @override
  void dispose() {
    _animation
      ..removeListener(_tick)
      ..dispose();
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final zoomedIn = _transform.value.getMaxScaleOnAxis() > 1.2;
    final Matrix4 target;
    if (zoomedIn) {
      target = Matrix4.identity();
    } else {
      target = Matrix4.identity()
        ..translate(_tapAt.dx, _tapAt.dy)
        ..scale(2.5)
        ..translate(-_tapAt.dx, -_tapAt.dy);
    }
    _zoom = Matrix4Tween(begin: _transform.value, end: target).animate(
      CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic),
    );
    _animation.forward(from: 0);
    widget.onZoomChanged(!zoomedIn);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTapDown: (details) => _tapAt = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 5,
        clipBehavior: Clip.hardEdge,
        onInteractionEnd: (_) => _reportZoom(),
        child: Center(
          child: Semantics(
            image: true,
            label: widget.label,
            child: Image.memory(
              widget.bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const _BrokenImage(),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部左右翻页键：图片被放大后拖动会吃掉横滑手势，这里留一条确定可用的通道。
class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              icon,
              size: 26,
              color: enabled
                  ? AidockColors.text
                  : AidockColors.textDim.withOpacity(0.35),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AidockColors.surface.withOpacity(0.9),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Icon(icon, size: 22, color: AidockColors.text),
          ),
        ),
      ),
    );
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 28,
            color: AidockColors.textDim,
          ),
          SizedBox(height: 8),
          Text(
            '这张图打不开',
            style: TextStyle(fontSize: 12, color: AidockColors.textDim),
          ),
        ],
      ),
    );
  }
}
