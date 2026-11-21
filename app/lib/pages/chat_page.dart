import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.state, required this.title});
  final AppState state;
  final String title;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _seen = 0;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    widget.state.closeSession();
    super.dispose();
  }

  /// 模型选择：宿主给的 groups 里按厂商分组列出来，点一条就只切这条会话。
  Future<void> _pickModel() async {
    final s = widget.state;
    await s.loadModels();
    if (!mounted) return;
    final info = s.modelInfo;
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('拿不到模型清单，稍后再试')),
      );
      return;
    }
    final groups = (info['groups'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        const <Map<String, dynamic>>[];
    final cur = info['current'];
    final curProvider = cur is Map ? '${cur['provider'] ?? ''}' : '';
    final curModel = cur is Map ? '${cur['model'] ?? ''}' : '';
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AidockColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.72),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Row(
                  children: [
                    const Text('选择模型',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (s.loadingModels)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final g in groups) ...<Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
                        child: Text(
                          '${g['name'] ?? g['id']}',
                          style: const TextStyle(
                              fontSize: 11, color: AidockColors.textDim, letterSpacing: .5),
                        ),
                      ),
                      for (final m in (g['models'] as List?)
                              ?.whereType<Map<String, dynamic>>()
                              .toList() ??
                          const <Map<String, dynamic>>[])
                        ListTile(
                          dense: true,
                          title: Text('${m['name'] ?? m['id']}',
                              style: const TextStyle(fontSize: 14)),
                          subtitle: m['description'] == null
                              ? null
                              : Text(
                                  '${m['description']}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11),
                                ),
                          trailing: ('${g['id']}' == curProvider &&
                                  '${m['id']}' == curModel)
                              ? const Icon(Icons.check, size: 18, color: AidockColors.accent)
                              : null,
                          onTap: () async {
                            Navigator.of(ctx).pop();
                            await s.chooseModel('${g['id']}', '${m['id']}');
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    widget.state.send(text);
    Future<void>.delayed(const Duration(milliseconds: 120), _toBottom);
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  /// 断线重连提示条：不弹窗、不遮消息，只在顶部说明「现在是什么状态」。
  Widget _reconnectBar() {
    return Container(
      width: double.infinity,
      color: AidockColors.warn.withOpacity(0.14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: AidockColors.warn),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '连接中断，正在自动重连…历史消息还在，回来的消息会自动补上',
              style: TextStyle(fontSize: 12.5, color: AidockColors.warn.withOpacity(0.95)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    // 消息变长（新消息或流式增量）就贴着底部走；用户往上翻历史时不动。
    final seen = s.messages.fold<int>(0, (a, m) => a + m.text.length) + s.messages.length;
    if (seen != _seen) {
      _seen = seen;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final near = _scroll.position.maxScrollExtent - _scroll.position.pixels;
        if (near < 260) _toBottom();
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton.icon(
            onPressed: s.openSessionId == null ? null : _pickModel,
            icon: const Icon(Icons.memory, size: 17, color: AidockColors.textDim),
            label: Text(
              s.modelLabel,
              style: const TextStyle(fontSize: 12, color: AidockColors.textDim),
            ),
          ),
          if (s.streamingNow)
            TextButton.icon(
              onPressed: s.stopTurn,
              icon: const Icon(Icons.stop_circle_outlined, size: 18, color: AidockColors.warn),
              label: const Text('停止', style: TextStyle(color: AidockColors.warn, fontSize: 13)),
            ),
        ],
      ),
      body: Column(
        children: [
          if (s.reconnecting) _reconnectBar(),
          Expanded(
            child: AnimatedBuilder(
              animation: s,
              builder: (context, _) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
                final cards = s.approvals;
                if (s.messages.isEmpty && cards.isEmpty && s.questions.isEmpty) {
                  return const Center(
                    child: Text('说点什么…', style: TextStyle(color: AidockColors.textDim, fontSize: 13)),
                  );
                }
                return ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  children: [
                    for (final m in s.messages) _bubble(m),
                    for (final q in s.questions) _QuestionDock(state: s, card: q),
                    for (final card in cards) _approval(card),
                  ],
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: const BoxDecoration(
                color: AidockColors.bg,
                border: Border(top: BorderSide(color: AidockColors.line)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: '发消息给电脑上的 Harness…',
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 46,
                    height: 46,
                    child: FilledButton(
                      onPressed: _send,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: AidockColors.accent,
                        foregroundColor: const Color(0xFF06121F),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                      ),
                      child: const Icon(Icons.arrow_upward_rounded, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 审批卡：宿主在会话流里推 `approval/requested`，答复走 `/approval/respond`。
  Widget _approval(ApprovalCard card) {
    final s = widget.state;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AidockColors.warn.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, size: 16, color: AidockColors.warn),
              const SizedBox(width: 7),
              Expanded(
                child: Text(card.headline,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AidockColors.text)),
              ),
            ],
          ),
          if (card.fact.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(card.fact,
                  style: const TextStyle(fontSize: 12.5, height: 1.5, color: AidockColors.textDim)),
            ),
          if (card.command.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AidockColors.bg,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: AidockColors.line),
                ),
                child: Text(card.command,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.45, color: AidockColors.text)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: () => s.respond(card, 'allowed-once'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AidockColors.accent,
                    foregroundColor: const Color(0xFF06121F),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('允许一次', style: TextStyle(fontSize: 13)),
                ),
                OutlinedButton(
                  onPressed: () => s.respond(card, 'denied'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AidockColors.warn,
                    side: const BorderSide(color: AidockColors.line),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('拒绝', style: TextStyle(fontSize: 13)),
                ),
                if (card.rememberable)
                  TextButton(
                    onPressed: () => s.respond(card, 'allowed-class'),
                    child: Text(card.classLabel.isEmpty ? '这一类以后都同意' : '以后都同意：${card.classLabel}',
                        style: const TextStyle(fontSize: 12.5, color: AidockColors.textDim)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(ChatMessage m) {
    if (m.role == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(m.text,
              style: const TextStyle(fontSize: 11.5, color: AidockColors.textDim)),
        ),
      );
    }
    final mine = m.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: mine ? AidockColors.accent : AidockColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(15),
            topRight: const Radius.circular(15),
            bottomLeft: Radius.circular(mine ? 15 : 5),
            bottomRight: Radius.circular(mine ? 5 : 15),
          ),
          border: mine ? null : Border.all(color: AidockColors.line),
        ),
        child: _body(m, mine),
      ),
    );
  }

  /// 消息正文：用户气泡保持纯文本，助手消息按 ``` 切成「散文 / 代码」交替渲染。
  ///
  /// 不引第三方 Markdown 包：一是依赖越少构建越稳，二是手机窄屏上真正常用的只有
  /// 代码块、行内代码和粗体这三样，手写一遍比调包更好控行高与配色。
  Widget _body(ChatMessage m, bool mine) {
    final text = m.text.isEmpty && m.streaming ? '…' : m.text;
    final color = mine ? const Color(0xFF06121F) : AidockColors.text;
    final base = TextStyle(fontSize: 14, height: 1.5, color: color);
    if (mine || !text.contains('```')) {
      return Text.rich(TextSpan(children: _inline(text, color)), style: base);
    }
    final parts = text.split('```');
    final children = <Widget>[];
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.trim().isEmpty) continue;
      if (i.isOdd) {
        // 首行可能是语言名（```dart），单独去掉，避免当成正文显示。
        final body = part.replaceFirst(RegExp(r'^[A-Za-z0-9_+#.-]*\r?\n'), '');
        children.add(Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF070B10),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: AidockColors.line),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              body.trimRight(),
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 12.5, height: 1.45, color: Color(0xFFCFE3FF)),
            ),
          ),
        ));
      } else {
        children.add(Text.rich(TextSpan(children: _inline(part, color)), style: base));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  /// 极简行内样式：`**粗体**` 与反引号包住的行内代码，其余原样。
  List<TextSpan> _inline(String text, Color color) {
    final spans = <TextSpan>[];
    final pattern = RegExp(r'\*\*([^*]+)\*\*|`([^`]+)`');
    var at = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      final bold = m.group(1);
      if (bold != null) {
        spans.add(TextSpan(text: bold, style: const TextStyle(fontWeight: FontWeight.w700)));
      } else {
        spans.add(TextSpan(
          text: m.group(2),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            color: color,
            backgroundColor: const Color(0x1AFFFFFF),
          ),
        ));
      }
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return spans;
  }
}

/// 提问卡（宿主 `ask_user_question`）：单选题点一下即选，多选题可反选；
/// 有选项时也可以补充自由输入，没选项时只填输入框。答复走 `/link/question/respond`。
class _QuestionDock extends StatefulWidget {
  const _QuestionDock({required this.state, required this.card});

  final AppState state;
  final QuestionCard card;

  @override
  State<_QuestionDock> createState() => _QuestionDockState();
}

class _QuestionDockState extends State<_QuestionDock> {
  final Map<String, Set<String>> _picks = <String, Set<String>>{};
  final Map<String, TextEditingController> _customs = <String, TextEditingController>{};
  bool _sending = false;

  @override
  void dispose() {
    for (final c in _customs.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _customOf(String id) =>
      _customs.putIfAbsent(id, () => TextEditingController());

  Set<String> _picksOf(String id) => _picks.putIfAbsent(id, () => <String>{});

  void _toggle(QuestionItem q, String label) {
    final set = _picksOf(q.id);
    setState(() {
      if (q.multiSelect) {
        if (!set.remove(label)) set.add(label);
      } else {
        set
          ..clear()
          ..add(label);
      }
    });
  }

  Future<void> _submit() async {
    if (_sending) return;
    setState(() => _sending = true);
    final customs = <String, String>{
      for (final q in widget.card.questions)
        if ((_customs[q.id]?.text ?? '').trim().isNotEmpty) q.id: _customs[q.id]!.text.trim(),
    };
    final picks = <String, List<String>>{for (final e in _picks.entries) e.key: e.value.toList()};
    await widget.state.answerQuestion(widget.card, picks, customs: customs);
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AidockColors.accent.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.help_outline, size: 16, color: AidockColors.accent),
              SizedBox(width: 7),
              Expanded(
                child: Text('电脑在等你回答',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AidockColors.text)),
              ),
            ],
          ),
          for (final q in card.questions) _question(q),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: _sending ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AidockColors.accent,
                    foregroundColor: const Color(0xFF06121F),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(_sending ? '提交中…' : '提交回答', style: const TextStyle(fontSize: 13)),
                ),
                if (_QuestionDockState.q_tip(card).isNotEmpty)
                  Text(_QuestionDockState.q_tip(card),
                      style: const TextStyle(fontSize: 11.5, color: AidockColors.textDim)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String q_tip(QuestionCard card) =>
      card.questions.any((q) => q.multiSelect) ? '多选题可选多项' : '';

  Widget _question(QuestionItem q) {
    final picks = _picksOf(q.id);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((q.header ?? '').isNotEmpty)
            Text(q.header!,
                style: const TextStyle(fontSize: 11.5, color: AidockColors.textDim, letterSpacing: 0.4)),
          if ((q.header ?? '').isNotEmpty) const SizedBox(height: 3),
          Text(q.text,
              style: const TextStyle(fontSize: 13, height: 1.5, color: AidockColors.text)),
          if ((q.detail ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(q.detail!,
                  style: const TextStyle(fontSize: 12, height: 1.5, color: AidockColors.textDim)),
            ),
          if (q.options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final o in q.options)
                    ChoiceChip(
                      label: Text(o.label, style: const TextStyle(fontSize: 12.5)),
                      selected: picks.contains(o.label),
                      onSelected: (_) => _toggle(q, o.label),
                      backgroundColor: AidockColors.bg,
                      selectedColor: AidockColors.accent.withOpacity(0.22),
                      labelStyle: const TextStyle(color: AidockColors.text),
                      side: BorderSide(
                          color: picks.contains(o.label) ? AidockColors.accent : AidockColors.line),
                      visualDensity: VisualDensity.compact,
                      tooltip: o.description,
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _customOf(q.id),
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 13, color: AidockColors.text),
              decoration: InputDecoration(
                hintText: q.options.isEmpty ? '在这里回答…' : '或者自己写一个答案（可选）',
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
