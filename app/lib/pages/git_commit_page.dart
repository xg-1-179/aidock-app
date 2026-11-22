import 'dart:async';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/material.dart';

import '../git_write_controller.dart';
import '../theme.dart';

/// 暂存 + 提交。上面点文件就暂存，下面写一句提交信息再提交。
class GitCommitPage extends StatefulWidget {
  const GitCommitPage({super.key, required this.client, this.onDone});

  final DshClient client;

  /// 提交成功后叫一声，调用方自己去刷新 Git 页。
  final VoidCallback? onDone;

  @override
  State<GitCommitPage> createState() => _GitCommitPageState();
}

class _GitCommitPageState extends State<GitCommitPage> {
  late final GitWriteController _git;
  final TextEditingController _message = TextEditingController();
  late final Listenable _form;

  @override
  void initState() {
    super.initState();
    _git = GitWriteController(widget.client);
    _form = Listenable.merge(<Listenable>[_git, _message]);
    unawaited(_git.refreshStatus());
  }

  @override
  void dispose() {
    _message.dispose();
    _git.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _unstaged => _git.group('unstaged');

  List<Map<String, dynamic>> get _conflicted => _git.group('conflicted');

  List<Map<String, dynamic>> get _staged => _git.group('staged');

  Future<void> _submit() async {
    final message = _message.text.trim();
    if (message.isEmpty || _git.busy) return;
    final stagedCount = _staged.length;
    final ok = await _confirm(
      title: '提交这 ${stagedCount > 0 ? stagedCount : 0} 个文件？',
      message: message,
    );
    if (!mounted || ok != true) return;
    await _git.commit(message);
    if (!mounted || _git.error != null) return;
    final hash = _git.lastCommit;
    widget.onDone?.call();
    // 页面自己先关掉，成功提示交给上一页：这里 pop 之后再弹一句会跟着一起消失。
    Navigator.of(context).pop(hash);
  }

  Future<bool?> _confirm({required String title, required String message}) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AidockColors.surface,
        title: Text(title, style: const TextStyle(fontSize: 16, color: AidockColors.text)),
        content: Text(
          message,
          style: const TextStyle(fontSize: 13, color: AidockColors.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('再看看'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('暂存并提交'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _git.busy ? null : () => unawaited(_git.refreshStatus()),
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _form,
        builder: (context, _) {
          final conflicted = _conflicted;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_git.error != null) _banner(_git.error!, AidockColors.danger),
              if (conflicted.isNotEmpty)
                _banner('还有 ${conflicted.length} 个文件没解决冲突，回电脑上处理', AidockColors.warn),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  children: [
                    const _SectionLabel('未暂存'),
                    if (_unstaged.isEmpty)
                      const _Hint('没有未暂存的改动')
                    else ...[
                      for (final file in _unstaged) _unstagedRow(file),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton(
                          onPressed: _git.busy ? null : () => unawaited(_git.stageAll()),
                          child: const Text('全部暂存'),
                        ),
                      ),
                    ],
                    if (_staged.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const _SectionLabel('已暂存'),
                      for (final file in _staged) _stagedRow(file),
                    ],
                    const SizedBox(height: 18),
                    const _SectionLabel('提交信息'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _message,
                      enabled: !_git.busy && conflicted.isEmpty,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: 200,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: '这次改了什么',
                        counterText: '',
                      ),
                    ),
                  ],
                ),
              ),
              _footer(conflicted.isNotEmpty),
            ],
          );
        },
      ),
    );
  }

  Widget _unstagedRow(Map<String, dynamic> file) {
    final path = '${file['path'] ?? ''}';
    final status = '${file['status'] ?? ''}';
    final additions = file['additions'];
    final deletions = file['deletions'];
    final binary = file['binary'] == true;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: !_git.busy,
      onTap: () => unawaited(_git.stage(path)),
      title: Text(
        path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, color: AidockColors.text),
      ),
      subtitle: Row(
        children: [
          if (status.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AidockColors.surfaceAlt,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                status,
                style: const TextStyle(fontSize: 10.5, color: AidockColors.textDim),
              ),
            ),
          if (binary)
            const Text('二进制', style: TextStyle(fontSize: 11, color: AidockColors.textDim))
          else if (additions != null || deletions != null)
            Text(
              '+${additions ?? 0} -${deletions ?? 0}',
              style: const TextStyle(fontSize: 11, color: AidockColors.textDim),
            ),
        ],
      ),
      trailing: const Text(
        '点一下暂存',
        style: TextStyle(fontSize: 11, color: AidockColors.accent),
      ),
    );
  }

  Widget _stagedRow(Map<String, dynamic> file) {
    final path = '${file['path'] ?? ''}';
    final status = '${file['status'] ?? ''}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: !_git.busy,
      onTap: () => unawaited(_git.unstage(path)),
      title: Text(
        path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, color: AidockColors.textDim),
      ),
      subtitle: status.isEmpty
          ? null
          : Text(
              status,
              style: const TextStyle(fontSize: 11, color: AidockColors.textDim),
            ),
      trailing: const Text(
        '取消暂存',
        style: TextStyle(fontSize: 11, color: AidockColors.textDim),
      ),
    );
  }

  Widget _footer(bool hasConflict) {
    final message = _message.text.trim();
    final canSubmit =
        !_git.busy && !hasConflict && message.isNotEmpty && _staged.isNotEmpty;
    String hint = '';
    if (_git.busy) {
      hint = '正在提交';
    } else if (hasConflict) {
      hint = '先解决冲突';
    } else if (_staged.isEmpty) {
      hint = '先在上面暂存文件';
    } else if (message.isEmpty) {
      hint = '写一句提交信息';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                hint,
                style: const TextStyle(fontSize: 11.5, color: AidockColors.textDim),
              ),
            ),
          SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: canSubmit ? () => unawaited(_submit()) : null,
              child: Text(_git.busy ? '提交中…' : '提交'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _banner(String text, Color color) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: color),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AidockColors.textDim,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: AidockColors.textDim),
      ),
    );
  }
}
