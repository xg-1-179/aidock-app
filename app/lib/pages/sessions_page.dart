import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme.dart';
import 'chat_page.dart';
import 'more_page.dart';
import 'search_page.dart';
import 'session_actions_sheet.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, required this.state});
  final AppState state;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_maybeOpenPending);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOpenPending());
  }

  /// 从通知/深链进来的会话：把 `pendingOpenSession` 消费掉，直接进聊天页。
  void _maybeOpenPending() {
    final state = widget.state;
    final id = state.pendingOpenSession;
    if (id == null || !mounted) return;
    state.pendingOpenSession = null;
    final hit = state.sessions.where((e) => e.id == id);
    final title = hit.isEmpty ? '会话' : hit.first.title;
    state.openSessionById(id).then((_) {
      if (!mounted || state.openSessionId == null) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (context) => ChatPage(state: state, title: title)),
      );
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_maybeOpenPending);
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

  /// 换一台电脑：把已配对过的机器列出来，点哪台就切过去。
  ///
  /// 切过去不动本地保存的凭据，所以来回切不需要重新扫码。
  Future<void> _switchMachine(AppState state) async {
    final picked = await showModalBottomSheet<SavedMachine>(
      context: context,
      backgroundColor: AidockColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('换一台电脑', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            for (final m in state.machines)
              ListTile(
                dense: true,
                leading: Icon(
                  (state.hostLabel.isNotEmpty && m.host.contains(state.hostLabel)) ? Icons.check_circle : Icons.computer_outlined,
                  size: 20,
                  color: (state.hostLabel.isNotEmpty && m.host.contains(state.hostLabel)) ? AidockColors.ok : AidockColors.textDim,
                ),
                title: Text(m.host, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  m.permissions.isEmpty ? '这台还没记权限' : '权限：${m.permissions}',
                  style:  TextStyle(fontSize: 11, color: AidockColors.textDim),
                ),
                onTap: () => Navigator.pop(ctx, m),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await state.reconnectSaved(picked);
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
              decoration:  BoxDecoration(color: AidockColors.ok, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            const Text('会话'),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: state.machines.length < 2 ? null : () => _switchMachine(state),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(state.hostLabel,
                          overflow: TextOverflow.ellipsis,
                          style:  TextStyle(fontSize: 12, color: AidockColors.textDim)),
                    ),
                    if (state.machines.length > 1) ...[
                      const SizedBox(width: 4),
                       Icon(Icons.swap_horiz_rounded, size: 14, color: AidockColors.textDim),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '搜索会话',
            icon: const Icon(Icons.search_rounded, size: 20),
            onPressed: state.client == null
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => SearchPage(
                        client: state.client!,
                        onOpenSession: (id, title) => state.openSessionById(id),
                      ),
                    )),
          ),
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
          IconButton(
            tooltip: '更多',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (context) => MorePage(state: state)),
            ),
            icon: const Icon(Icons.more_horiz_rounded, size: 20),
          ),
        ],
      ),
      floatingActionButton: GestureDetector(
        onLongPress: state.busy ? null : () => _newInWorkspace(state),
        child: FloatingActionButton.extended(
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
          foregroundColor: AidockColors.onAccent,
          icon: const Icon(Icons.add_comment_rounded, size: 19),
          label: const Text('新建会话', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
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
                        style:  TextStyle(color: AidockColors.textDim, fontSize: 13.5)),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text(
                        _q.text.trim().isEmpty
                            ? '在电脑上新建一个会话再下拉刷新'
                            : '换个关键词试试，或用右下角新建会话',
                        style:  TextStyle(color: AidockColors.textDim, fontSize: 12)),
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
                      onLongPress: () => _sessionMenu(state, s),
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
                                   Icon(Icons.push_pin_rounded,
                                      size: 14, color: AidockColors.textDim),
                              ],
                            ),
                            if (s.subtitle.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(s.subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style:  TextStyle(
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

  /// 长按会话：改名、复制 ID。重命名和 fork 宿主都支持，这里只做最常用的两个。
  Future<void> _sessionMenu(AppState state, SessionItem s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AidockColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded, size: 20),
              title: const Text('重命名会话', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.call_split_rounded, size: 20),
              title: const Text('从这里分叉', style: TextStyle(fontSize: 14)),
              subtitle: const Text('复制当前历史，开一条新会话', style: TextStyle(fontSize: 11)),
              onTap: () => Navigator.of(ctx).pop('fork'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded, size: 20),
              title: const Text('复制会话 ID', style: TextStyle(fontSize: 14)),
              subtitle: Text(s.id, style: const TextStyle(fontSize: 11)),
              onTap: () => Navigator.of(ctx).pop('copy'),
            ),
            ListTile(
              leading: const Icon(Icons.more_horiz_rounded, size: 20),
              title: const Text('更多操作…', style: TextStyle(fontSize: 14)),
              subtitle: const Text('置顶、归档、导出、删除', style: TextStyle(fontSize: 11)),
              onTap: () => Navigator.of(ctx).pop('more'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'more') {
      final client = state.client;
      if (client == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('还没连上电脑')));
        return;
      }
      await showSessionActions(
        context,
        client: client,
        sessionId: s.id,
        title: s.title,
        pinned: s.pinned,
        onChanged: () => state.refreshSessions(),
      );
      return;
    }
    if (action == 'fork') {
      final id = await state.forkSession(s.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(id == null ? '分叉没成功，看看列表里有没有新会话' : '已分叉出新会话')),
      );
      return;
    }
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: s.id));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('会话 ID 已复制')));
      return;
    }
    final controller = TextEditingController(text: s.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AidockColors.surface,
        title: const Text('重命名会话', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(hintText: '会话标题'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final ok = await state.renameSession(s.id, name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已重命名' : (state.error ?? '重命名失败'))),
    );
  }

  /// 长按「新建会话」：挑一个工作区再建。电脑上只登记了一个工作区时不打扰，直接建。
  Future<void> _newInWorkspace(AppState state) async {
    if (state.busy) return;
    await state.loadWorkspaces();
    if (!mounted) return;
    final list = state.workspaces;
    if (list.length <= 1) {
      await state.createSession();
      if (!mounted) return;
      if (state.openSessionId != null) {
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ChatPage(state: state, title: '新会话'),
        ));
      }
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: AidockColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
             Padding(
              padding: EdgeInsets.fromLTRB(18, 16, 18, 6),
              child: Text('在哪个工作区新建会话？',
                  style: TextStyle(fontSize: 13, color: AidockColors.textDim)),
            ),
            for (final w in list)
              ListTile(
                leading: const Icon(Icons.folder_outlined, size: 20),
                title: Text('${w['name'] ?? w['title'] ?? w['id'] ?? '工作区'}',
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text('${w['cwd'] ?? w['path'] ?? ''}',
                    style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.of(ctx).pop(w),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await state.createSession(workspaceId: '${picked['id'] ?? picked['workspaceId'] ?? ''}');
    if (!mounted) return;
    if (state.openSessionId != null) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatPage(state: state, title: '新会话'),
      ));
    }
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
