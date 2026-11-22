import 'package:flutter/material.dart';

import '../theme.dart';
import 'code_block.dart';

/// 消息正文渲染：普通段落（`**粗体**` / 行内代码）、``` 围栏代码块、`- ` 列表行，
/// 以及长消息折叠。
///
/// 只负责内容本身：气泡底色、圆角、内边距都由调用方（chat_page 的 `_bubble`）决定，
/// 组件内部只画代码块这类内部块。`mine` 只影响文字颜色；`streaming` 为 true 时不折叠，
/// 免得流式输出时高度反复跳。
class MessageBody extends StatelessWidget {
  const MessageBody({
    super.key,
    required this.text,
    this.mine = false,
    this.streaming = false,
  });

  final String text;
  final bool mine;
  final bool streaming;

  /// 正文行高 14 × 1.5；折叠高度按可视行数算。
  static const double _lineHeight = 21;
  static const int _foldLines = 12;
  static const int _foldChars = 900;

  @override
  Widget build(BuildContext context) {
    final shown = text.isEmpty && streaming ? '…' : text;
    if (shown.trim().isEmpty) return const SizedBox.shrink();

    final blocks = _parse(shown);
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (i > 0) {
        final gap = block.code || blocks[i - 1].code ? 8.0 : 6.0;
        children.add(SizedBox(height: gap));
      }
      children.add(
        block.code
            ? CodeBlock(code: block.text, language: block.info)
            : _TextBlock(text: block.text, mine: mine),
      );
    }
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
    if (streaming || !_tooLong(shown)) return content;
    return _FoldableMessage(text: shown, mine: mine, child: content);
  }

  /// 超过 12 行或 900 字就折；单段长文按每行 26 字折算可视行数。
  static bool _tooLong(String value) {
    if (value.length > _foldChars) return true;
    if ('\n'.allMatches(value).length + 1 > _foldLines) return true;
    return (value.length / 26).ceil() > _foldLines;
  }

  /// 按 ``` 围栏切成「正文 / 代码」交替的块。流式输出里围栏还没闭合时，
  /// 剩下的内容先当代码显示，避免把代码按正文排版。
  static List<_Block> _parse(String raw) {
    final blocks = <_Block>[];
    final buffer = StringBuffer();
    var inCode = false;
    var info = '';

    void pushText() {
      final body = buffer.toString().trim();
      buffer.clear();
      if (body.isEmpty) return;
      blocks.add(_Block(code: false, text: body));
    }

    for (final line in raw.split('\n')) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('```')) {
        if (inCode) {
          final body = buffer.toString().trimRight();
          buffer.clear();
          if (body.isNotEmpty) {
            blocks.add(_Block(code: true, text: body, info: info));
          }
          info = '';
          inCode = false;
        } else {
          pushText();
          info = trimmed.substring(3).trim();
          inCode = true;
        }
        continue;
      }
      buffer.write(line);
      buffer.write('\n');
    }

    if (inCode) {
      final body = buffer.toString().trimRight();
      buffer.clear();
      if (body.isNotEmpty) {
        blocks.add(_Block(code: true, text: body, info: info));
      }
    } else {
      pushText();
    }
    return blocks;
  }
}

class _Block {
  const _Block({required this.code, required this.text, this.info = ''});

  final bool code;
  final String text;
  final String info;
}

/// 一个正文块：空行分段，连续的 `- ` 行合成一个带圆点的列表。
class _TextBlock extends StatelessWidget {
  const _TextBlock({required this.text, required this.mine});

  final String text;
  final bool mine;

  static final RegExp _bullet = RegExp(r'^\s*[-*·]\s+');
  static final RegExp _inlinePattern = RegExp(r'\*\*([^*]+)\*\*|`([^`]+)`');

  @override
  Widget build(BuildContext context) {
    final color = mine ? Colors.white : AidockColors.text;
    final base = TextStyle(fontSize: 14, height: 1.5, color: color);
    final lines = text.split('\n');
    final children = <Widget>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.trim().isEmpty) {
        i++;
        continue;
      }
      if (children.isNotEmpty) children.add(const SizedBox(height: 6));
      if (_bullet.hasMatch(line)) {
        final items = <String>[];
        while (i < lines.length && _bullet.hasMatch(lines[i])) {
          items.add(lines[i].replaceFirst(_bullet, '').trimRight());
          i++;
        }
        children.add(_list(items, base, color));
      } else {
        final paragraph = <String>[];
        while (i < lines.length &&
            lines[i].trim().isNotEmpty &&
            !_bullet.hasMatch(lines[i])) {
          paragraph.add(lines[i].trimRight());
          i++;
        }
        children.add(Text.rich(
          TextSpan(children: _inline(paragraph.join('\n'), color, mine)),
          style: base,
        ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _list(List<String> items, TextStyle base, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0.0 : 3.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: mine ? Colors.white70 : AidockColors.textDim,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: _inline(items[i], color, mine)),
                    style: base,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 极简行内样式：`**粗体**` 与反引号行内代码，其余原样。
  static List<TextSpan> _inline(String text, Color color, bool mine) {
    final spans = <TextSpan>[];
    var at = 0;
    for (final match in _inlinePattern.allMatches(text)) {
      if (match.start > at) {
        spans.add(TextSpan(text: text.substring(at, match.start)));
      }
      final bold = match.group(1);
      if (bold != null) {
        spans.add(TextSpan(
          text: bold,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else {
        spans.add(TextSpan(
          text: match.group(2),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: color,
            backgroundColor:
                mine ? Colors.white.withOpacity(0.16) : AidockColors.surfaceAlt,
          ),
        ));
      }
      at = match.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return spans;
  }
}

/// 长消息折叠：默认裁到 12 行高，底部一颗「展开全部（共 N 字）」/「收起」。
///
/// 裁切用不可滚动的 [SingleChildScrollView] 而不是 maxLines：消息里可能混着代码块，
/// 按高度裁比按行裁更稳，也不会触发 RenderFlex 溢出。
class _FoldableMessage extends StatefulWidget {
  const _FoldableMessage({
    required this.text,
    required this.mine,
    required this.child,
  });

  final String text;
  final bool mine;
  final Widget child;

  @override
  State<_FoldableMessage> createState() => _FoldableMessageState();
}

class _FoldableMessageState extends State<_FoldableMessage> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final foreground = widget.mine ? Colors.white : AidockColors.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_expanded)
          widget.child
        else
          SizedBox(
            height: MessageBody._foldLines * MessageBody._lineHeight,
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: widget.child,
            ),
          ),
        TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 34),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          icon: Icon(
            _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            size: 17,
          ),
          label: Text(
            _expanded ? '收起' : '展开全部（共 ${widget.text.length} 字）',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}
