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

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    widget.state.closeSession();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
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
          Expanded(
            child: AnimatedBuilder(
              animation: s,
              builder: (context, _) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
                final cards = s.approvals;
                if (s.messages.isEmpty && cards.isEmpty) {
                  return const Center(
                    child: Text('说点什么…', style: TextStyle(color: AidockColors.textDim, fontSize: 13)),
                  );
                }
                return ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  children: [
                    for (final m in s.messages) _bubble(m),
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
        border: Border.all(color: AidockColors.warn.withValues(alpha: 0.45)),
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
        child: Text(
          m.text.isEmpty && m.streaming ? '…' : m.text,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: mine ? const Color(0xFF06121F) : AidockColors.text,
          ),
        ),
      ),
    );
  }
}
