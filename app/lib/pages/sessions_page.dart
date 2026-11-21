import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'chat_page.dart';

class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(color: AidockColors.ok, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            const Text('会话'),
            const SizedBox(width: 8),
            Expanded(
              child: Text(state.hostLabel,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AidockColors.textDim)),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: state.busy ? null : state.refreshSessions,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
          IconButton(
            tooltip: '断开',
            onPressed: state.disconnect,
            icon: const Icon(Icons.link_off_rounded, size: 20),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.busy
            ? null
            : () async {
                await state.createSession();
                if (!context.mounted) return;
                if (state.openSessionId == null) return;
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => ChatPage(state: state, title: '新会话'),
                ));
              },
        backgroundColor: AidockColors.accent,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_comment_rounded, size: 19),
        label: const Text('新建会话', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
      body: RefreshIndicator(
        onRefresh: state.refreshSessions,
        color: AidockColors.accent,
        backgroundColor: AidockColors.surface,
        child: state.sessions.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 90),
                  Icon(Icons.forum_outlined, size: 44, color: AidockColors.textDim.withOpacity(0.55)),
                  const SizedBox(height: 14),
                  const Center(
                    child: Text('电脑上还没有会话',
                        style: TextStyle(color: AidockColors.textDim, fontSize: 13.5)),
                  ),
                  const SizedBox(height: 6),
                  const Center(
                    child: Text('在电脑上新建一个会话再下拉刷新',
                        style: TextStyle(color: AidockColors.textDim, fontSize: 12)),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                itemCount: state.sessions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final s = state.sessions[i];
                  return Material(
                    color: AidockColors.surface,
                    borderRadius: BorderRadius.circular(15),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(15),
                      onTap: () async {
                        await state.openSession(s);
                        if (context.mounted) {
                          Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => ChatPage(state: state, title: s.title),
                          ));
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(color: AidockColors.line),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _dot(s),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(s.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                                ),
                                if (s.pinned)
                                  const Icon(Icons.push_pin_rounded,
                                      size: 14, color: AidockColors.textDim),
                              ],
                            ),
                            if (s.subtitle.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(s.subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12.5, color: AidockColors.textDim, height: 1.45)),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _dot(SessionItem s) {
    Color color;
    if (s.running) {
      color = AidockColors.accent;
    } else if (s.pending) {
      color = AidockColors.warn;
    } else if (s.failed) {
      color = AidockColors.danger;
    } else {
      color = AidockColors.textDim.withOpacity(0.45);
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: s.running
            ? [BoxShadow(color: color.withOpacity(0.55), blurRadius: 6, spreadRadius: 1)]
            : null,
      ),
    );
  }
}
