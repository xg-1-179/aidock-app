import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/material.dart' hide SearchController;

import '../search_controller.dart';
import '../theme.dart';

/// 全局搜索：搜电脑上的历史会话正文。
///
/// 与「列表里按标题过滤」是两件事 —— 这里走宿主的正文检索，命中片段直接摆出来。
/// 点一条结果由调用方决定怎么打开（[onOpenSession]），本页随后自行退出。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.client, this.onOpenSession});

  final DshClient client;

  /// 打开命中的会话：参数是 sessionId 与宿主侧的标题（补不到标题时是短 id）。
  final void Function(String sessionId, String title)? onOpenSession;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final SearchController _c;
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _c = SearchController(widget.client);
    // autofocus 在部分机型上会被键盘动画抢掉，补一次跑在首帧之后的抢焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _open(SearchHit hit) {
    final open = widget.onOpenSession;
    // 先退掉搜索页，再让调用方打开会话：反过来会把刚推上去的对话页一起弹掉。
    Navigator.of(context).maybePop().then((_) {
      if (open != null) open(hit.sessionId, hit.title);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索会话')),
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final trimmed = _c.query.trim();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: _c.onQueryChanged,
                  onSubmitted: (value) {
                    _c.search(value);
                  },
                  decoration: InputDecoration(
                    hintText: '搜关键词',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: trimmed.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _input.clear();
                              _focus.requestFocus();
                              _c.clear();
                            },
                          ),
                  ),
                ),
              ),
              if (_c.error != null) _errorBanner(_c.error!, trimmed),
              Expanded(child: _results(trimmed)),
            ],
          );
        },
      ),
    );
  }

  Widget _results(String trimmed) {
    if (_c.loading && _c.hits.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (trimmed.length < SearchController.minChars) {
      return _empty(
        icon: Icons.manage_search,
        title: '输入关键词，搜电脑上的历史会话',
        note: '至少 ${SearchController.minChars} 个字，只搜会话正文。',
      );
    }
    if (_c.hits.isEmpty) {
      return _empty(
        icon: Icons.search_off,
        title: '没有命中「$trimmed」',
        note: '换个词试试，或者回到会话列表按标题找。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: _c.hits.length + (_c.hasMore ? 2 : 1),
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '${_c.hits.length} 条命中',
              style: const TextStyle(fontSize: 12, color: AidockColors.textDim),
            ),
          );
        }
        final i = index - 1;
        if (i >= _c.hits.length) {
          return const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '宿主一次只回 20 条，命中更多时把关键词写细一点。',
              style: TextStyle(fontSize: 12, height: 1.5, color: AidockColors.textDim),
            ),
          );
        }
        return _hitTile(_c.hits[i], trimmed);
      },
    );
  }

  Widget _hitTile(SearchHit hit, String query) {
    final snippet = hit.snippet.trim();
    return InkWell(
      onTap: () => _open(hit),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: AidockColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AidockColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              hit.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (snippet.isNotEmpty) ...[
              const SizedBox(height: 6),
              RichText(
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: AidockColors.textDim,
                  ),
                  children: _highlight(snippet, query),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 把 query 的出现处切成强调色片段（大小写不敏感）。
  List<TextSpan> _highlight(String text, String query) {
    final needle = query.trim();
    if (needle.isEmpty) return <TextSpan>[TextSpan(text: text)];
    final hay = text.toLowerCase();
    final needleLower = needle.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    while (true) {
      final at = hay.indexOf(needleLower, from);
      if (at < 0) break;
      final end = at + needleLower.length;
      if (end > text.length) break;
      if (at > from) spans.add(TextSpan(text: text.substring(from, at)));
      spans.add(TextSpan(
        text: text.substring(at, end),
        style: const TextStyle(
          color: AidockColors.accent,
          fontWeight: FontWeight.w600,
        ),
      ));
      from = end;
    }
    if (from < text.length) spans.add(TextSpan(text: text.substring(from)));
    if (spans.isEmpty) spans.add(TextSpan(text: text));
    return spans;
  }

  Widget _empty({required IconData icon, required String title, required String note}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: AidockColors.textDim),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, height: 1.4, color: AidockColors.text),
            ),
            const SizedBox(height: 6),
            Text(
              note,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, height: 1.5, color: AidockColors.textDim),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner(String message, String trimmed) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AidockColors.danger.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AidockColors.danger.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.error_outline, size: 16, color: AidockColors.danger),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12.5, height: 1.5, color: AidockColors.text),
            ),
          ),
          if (trimmed.length >= SearchController.minChars)
            TextButton(
              onPressed: () => _c.search(trimmed),
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }
}
