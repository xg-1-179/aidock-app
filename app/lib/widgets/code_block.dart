import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 代码正文的统一样式：等宽、12.5、行高 1.45，和气泡正文（14 / 1.5）同一视觉节奏。
const TextStyle _codeStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 12.5,
  height: 1.45,
  color: AidockColors.text,
);

/// 复制代码，并在当前页给一句反馈。
Future<void> copyCode(BuildContext context, String code) async {
  await Clipboard.setData(ClipboardData(text: code));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('代码已复制'), duration: Duration(seconds: 2)),
  );
}

/// 气泡里的围栏代码块：深色底、圆角 10、等宽、横向滚动，
/// 右上角「复制」「全屏」两颗小按钮。
///
/// 只画自己的内部块（底色 + 边框），不碰气泡底色，所以放在强调色气泡（用户消息）里
/// 也照样可读。
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, this.language = ''});

  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    final lang = language.trim();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AidockColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AidockColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
            child: Row(
              children: [
                if (lang.isNotEmpty)
                  Expanded(
                    child: Text(
                      lang,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                        color: AidockColors.textDim,
                        letterSpacing: 0.3,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                _CodeAction(
                  icon: Icons.copy_rounded,
                  label: '复制',
                  onTap: () => copyCode(context, code),
                ),
                _CodeAction(
                  icon: Icons.fullscreen_rounded,
                  label: '全屏',
                  onTap: () =>
                      openCodeFullscreen(context, code: code, language: lang),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
            child: Text(code, style: _codeStyle),
          ),
        ],
      ),
    );
  }
}

/// 右上角的小按钮：图标 + 11 号字，点击区 26 高，属于气泡内的次级操作。
class _CodeAction extends StatelessWidget {
  const _CodeAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: AidockColors.textDim),
              const SizedBox(width: 3),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  color: AidockColors.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 打开全屏代码页；行号默认打开，标题栏里可切。
Future<void> openCodeFullscreen(
  BuildContext context, {
  required String code,
  String language = '',
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => CodeFullscreenPage(code: code, language: language),
    ),
  );
}

/// 全屏代码页：标题栏带行号开关与「复制」，正文等宽、可横向滚动。
class CodeFullscreenPage extends StatefulWidget {
  const CodeFullscreenPage({super.key, required this.code, this.language = ''});

  final String code;
  final String language;

  @override
  State<CodeFullscreenPage> createState() => _CodeFullscreenPageState();
}

class _CodeFullscreenPageState extends State<CodeFullscreenPage> {
  bool _lineNumbers = true;

  @override
  Widget build(BuildContext context) {
    final lines = widget.code.split('\n');
    final title = widget.language.trim();
    return Scaffold(
      backgroundColor: AidockColors.bg,
      appBar: AppBar(
        title: Text(title.isEmpty ? '代码' : title),
        actions: [
          IconButton(
            tooltip: _lineNumbers ? '隐藏行号' : '显示行号',
            onPressed: () => setState(() => _lineNumbers = !_lineNumbers),
            icon: Icon(
              Icons.format_list_numbered_rounded,
              size: 20,
              color: _lineNumbers ? AidockColors.accent : AidockColors.textDim,
            ),
          ),
          TextButton.icon(
            onPressed: () => copyCode(context, widget.code),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8, bottom: 28),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_lineNumbers) ...[
                  Text(
                    _gutter(lines.length),
                    textAlign: TextAlign.right,
                    style: _codeStyle.copyWith(color: AidockColors.textDim),
                  ),
                  const SizedBox(width: 12),
                ],
                Text(widget.code, style: _codeStyle),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 行号文本：右对齐补到同一宽度，和代码行一一对得上。
  String _gutter(int count) {
    final width = '$count'.length;
    return [
      for (var i = 1; i <= count; i++) '$i'.padLeft(width),
    ].join('\n');
  }
}
