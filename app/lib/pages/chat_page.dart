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
                if (s.messages.isEmpty) {
                  return const Center(
                    child: Text('说点什么…', style: TextStyle(color: AidockColors.textDim, fontSize: 13)),
                  );
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  itemCount: s.messages.length,
                  itemBuilder: (context, i) => _bubble(s.messages[i]),
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
