import 'package:flutter/material.dart';
import 'package:dsh_link_protocol/dsh_link_protocol.dart';

import '../sessions_admin_controller.dart';
import '../theme.dart';

/// 会话一行的「更多操作」：置顶 / 归档 / 导出 / 删除。
///
/// 失败的话术不弹 SnackBar，而是留在表内的错误行里 —— 底部表一关就没了的提示，
/// 等于没提示。动作成功、并且 [onChanged] 也跑完之后才关表，另回一条确认。
Future<void> showSessionActions(
  BuildContext context, {
  required DshClient client,
  required String sessionId,
  required String title,
  bool pinned = false,
  Future<void> Function()? onChanged,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AidockColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _SessionActionsSheet(
      client: client,
      sessionId: sessionId,
      title: title,
      pinned: pinned,
      onChanged: onChanged,
    ),
  );
}

class _SessionActionsSheet extends StatefulWidget {
  const _SessionActionsSheet({
    required this.client,
    required this.sessionId,
    required this.title,
    required this.pinned,
    this.onChanged,
  });

  final DshClient client;
  final String sessionId;
  final String title;
  final bool pinned;
  final Future<void> Function()? onChanged;

  @override
  State<_SessionActionsSheet> createState() => _SessionActionsSheetState();
}

class _SessionActionsSheetState extends State<_SessionActionsSheet> {
  late final SessionsAdminController _controller = SessionsAdminController(widget.client);

  /// 控制器之外的意外（比如本地写盘失败），也照样落在同一行里。
  String? _localError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {required String done}) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _localError = null);
    try {
      await action();
      final onChanged = widget.onChanged;
      if (onChanged != null) await onChanged();
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on SessionsAdminException {
      // 话已经在 controller.error 里，ListenableBuilder 会把错误行刷出来。
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _localError = '$e');
    }
  }

  Future<void> _togglePin() {
    final next = !widget.pinned;
    return _run(
      () => _controller.pin(widget.sessionId, next),
      done: next ? '已置顶' : '已取消置顶',
    );
  }

  Future<void> _archive() =>
      _run(() => _controller.archive(widget.sessionId), done: '已归档，列表里收起来了');

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _localError = null);
    try {
      final saved = await _controller.exportZip(widget.sessionId);
      final onChanged = widget.onChanged;
      if (onChanged != null) await onChanged();
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('已存到 $saved')));
    } on SessionsAdminException {
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _localError = '$e');
    }
  }

  Future<void> _confirmDelete() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AidockColors.surface,
        title: const Text('删除这个会话？', style: TextStyle(fontSize: 16)),
        content: const Text(
          '手机上没法真删：这一下会把会话归档、从列表里移走，它还在跑的话会先停掉当前这一轮。\n'
          '会话记录仍然留在电脑上，桌面端还可以把它捞回来。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:  Text('删除', style: TextStyle(color: AidockColors.danger)),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _run(
      () => _controller.remove(widget.sessionId),
      done: '已从列表移走（记录还在电脑上）',
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final busy = _controller.busy;
          final error = _localError ?? _controller.error;
          final heading = widget.title.isEmpty ? '当前会话' : widget.title;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(
                  heading,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:  TextStyle(fontSize: 13, color: AidockColors.textDim),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AidockColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AidockColors.danger),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                         Icon(
                          Icons.error_outline_rounded,
                          size: 18,
                          color: AidockColors.danger,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            error,
                            style:  TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: AidockColors.danger,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (busy)
                 Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: AidockColors.line,
                    color: AidockColors.accent,
                  ),
                ),
              _tile(
                icon: widget.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                title: widget.pinned ? '取消置顶' : '置顶会话',
                subtitle: widget.pinned ? '不再固定在列表最上面' : '固定在列表最上面',
                enabled: !busy,
                onTap: _togglePin,
              ),
              _tile(
                icon: Icons.archive_outlined,
                title: '归档会话',
                subtitle: '从列表里收起来，记录还留在电脑上',
                enabled: !busy,
                onTap: _archive,
              ),
              _tile(
                icon: Icons.file_download_outlined,
                title: '导出打包',
                subtitle: '把这一整段会话存成 zip',
                enabled: !busy,
                onTap: _export,
              ),
               Divider(height: 1, thickness: 1, color: AidockColors.line),
              _tile(
                icon: Icons.delete_outline_rounded,
                title: '删除会话',
                subtitle: '归档并停止运行，桌面端可恢复',
                color: AidockColors.danger,
                enabled: !busy,
                onTap: _confirmDelete,
              ),
              const SizedBox(height: 6),
            ],
          );
        },
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    String? subtitle,
    Color? color,
    bool enabled = true,
    required VoidCallback onTap,
  }) {
    final ink = color ?? AidockColors.text;
    return ListTile(
      enabled: enabled,
      leading: Icon(icon, size: 20, color: enabled ? ink : AidockColors.textDim),
      title: Text(
        title,
        style: TextStyle(fontSize: 14, color: enabled ? ink : AidockColors.textDim),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style:  TextStyle(fontSize: 11, color: AidockColors.textDim)),
      onTap: enabled ? onTap : null,
    );
  }
}
