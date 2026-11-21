import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'chat_page.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, required this.state});
  final AppState state;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  /// 本地过滤：电脑上常有几百个会话，滚不动也找不到；
  /// 标题与第二行（最后一条消息 / 路径）都参与匹配。
  List<SessionItem> _filtered(List<SessionItem> all) {
    final q = _q.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((e) =>
            e.title.toLowerCase().contains(q) || e.subtitle.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final rows = _filtered(state.sessions);
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: TextField(
              controller: _q,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索会话标题或路径',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _q.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => setState(() {
                          _q.clear();
                        }),
                      ),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: state.refreshSessions,
              color: AidockColors.accent,
              backgroundColor: AidockColors.surface,
              child: rows.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 90),
                  Icon(Icons.forum_outlined, size: 44, color: AidockColors.textDim.withOpacity(0.55)),
                  const SizedBox(height: 14),
                  Center(
                    child: Text(
                        _q.text.trim().isEmpty
                            ? '电脑上还没有会话'
                            : '没有匹配「${_q.text.trim()}」的会话',
                        style: const TextStyle(color: AidockColors.textDim, fontSize: 13.5)),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text(
                        _q.text.trim().isEmpty
                            ? '在电脑上新建一个会话再下拉刷新'
                            : '换个关键词试试，或用右下角新建会话',
                        style: const TextStyle(color: AidockColors.textDim, fontSize: 12)),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final s = rows[i];
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
          ),
        ],
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
