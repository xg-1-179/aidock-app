import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme.dart';
import 'git_commit_page.dart';

/// Git 面板（只读那一半）：改动清单 + 最近提交 + 单份 diff。
///
/// 宿主 `/git/status` 回 `staged / unstaged / untracked / conflicted` 四组，
/// `/git/log` 回 `commits`；这里不假设字段名更多，缺什么就少显示什么。
class GitPage extends StatefulWidget {
  const GitPage({super.key, required this.state});

  final AppState state;

  @override
  State<GitPage> createState() => _GitPageState();
}

class _GitPageState extends State<GitPage> {
  @override
  void initState() {
    super.initState();
    widget.state.loadGit();
  }

  List<Map<String, dynamic>> _group(String key) {
    final raw = widget.state.gitStatus[key];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  String _repoLine(Map<String, dynamic> s) {
    final branch = '${s['branch'] ?? '?'}';
    final ahead = s['ahead'];
    final behind = s['behind'];
    final bits = <String>['分支 $branch'];
    if (ahead is num && ahead > 0) bits.add('领先 $ahead');
    if (behind is num && behind > 0) bits.add('落后 $behind');
    return bits.join(' · ');
  }

  Future<void> _showDiff(String title, {String? path, String? commit}) async {
    final text = await widget.state.gitDiff(path: path, commit: commit);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AidockColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          return FractionallySizedBox(
            heightFactor: 0.8,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14)),
                      ),
                      IconButton(
                        tooltip: '复制',
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                        onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    child: Text(
                      text.isEmpty ? '（空）' : text,
                      style:  TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        fontFamily: 'monospace',
                        color: AidockColors.textDim,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Git'),
            actions: [
              IconButton(
                tooltip: '暂存并提交',
                icon: const Icon(Icons.upload_file_rounded, size: 20),
                onPressed: () {
                  final c = s.client;
                  if (c == null) return;
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => GitCommitPage(client: c, onDone: s.loadGit, workspaceId: s.gitWorkspaceId),
                  ));
                },
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: s.loadingGit ? null : s.loadGit,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          body: s.loadingGit && s.gitStatus.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    if (s.gitError != null)
                      _banner('读不到 Git 状态：${s.gitError}')
                    else
                      _banner(_repoLine(s.gitStatus)),
                    ..._section('已暂存', _group('staged'), staged: true),
                    ..._section('未暂存', _group('unstaged')),
                    ..._section('未跟踪', _group('untracked')),
                    if (_group('conflicted').isNotEmpty)
                      ..._section('冲突', _group('conflicted')),
                    const SizedBox(height: 18),
                    const Text('最近提交',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    if (s.gitCommits.isEmpty)
                       Text('（没有提交，或者仓库是空的）',
                          style: TextStyle(fontSize: 13, color: AidockColors.textDim)),
                    for (final c in s.gitCommits) _commitRow(c),
                  ],
                ),
        );
      },
    );
  }

  Widget _banner(String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style:  TextStyle(fontSize: 12, color: AidockColors.textDim)),
    );
  }

  List<Widget> _section(String title, List<Map<String, dynamic>> rows, {bool staged = false}) {
    if (rows.isEmpty) return const [];
    return [
      const SizedBox(height: 14),
      Text('$title（${rows.length}）',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      for (final r in rows)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('${r['path'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            '${r['status'] ?? ''}'
            '${(r['additions'] is num && (r['additions'] as num) > 0) ? '  +${r['additions']}' : ''}'
            '${(r['deletions'] is num && (r['deletions'] as num) > 0) ? '  -${r['deletions']}' : ''}',
            style:  TextStyle(fontSize: 11, color: AidockColors.textDim),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => _showDiff('${r['path'] ?? ''}', path: '${r['path'] ?? ''}'),
        ),
    ];
  }

  Widget _commitRow(Map<String, dynamic> c) {
    final short = '${c['short'] ?? c['shortHash'] ?? c['hash'] ?? ''}';
    final subject = '${c['subject'] ?? c['message'] ?? c['title'] ?? ''}';
    final author = '${c['author'] ?? c['authorName'] ?? ''}';
    final date = '${c['date'] ?? c['authorDate'] ?? c['when'] ?? ''}';
    final meta = [short, author, date].where((e) => e.isNotEmpty).join(' · ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(subject.isEmpty ? '(无标题)' : subject,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13)),
      subtitle: Text(meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:  TextStyle(fontSize: 11, color: AidockColors.textDim)),
      onTap: short.isEmpty ? null : () => _showDiff(short, commit: short),
    );
  }
}
