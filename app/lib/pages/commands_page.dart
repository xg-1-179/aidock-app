import 'dart:async';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/material.dart';

import '../commands_store.dart';
import '../theme.dart';

/// 命令表里的一条。
///
/// 字段来自宿主 `GET /api/mobile/v1/link/commands?sessionId=…` 的 `items`：
/// `{name, description, input?:{hint}}`；别的字段宿主不会发，这里也不猜。
class _Command {
  const _Command({required this.name, required this.description, this.hint});

  final String name;
  final String description;
  final String? hint;

  static _Command? fromJson(Map<String, dynamic> json) {
    final name = '${json['name'] ?? ''}'.trim();
    if (name.isEmpty) return null;
    var hint = '';
    final input = json['input'];
    if (input is Map) hint = '${input['hint'] ?? ''}'.trim();
    return _Command(
      name: name,
      description: '${json['description'] ?? ''}'.trim(),
      hint: hint.isEmpty ? null : hint,
    );
  }

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return name.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q) ||
        (hint ?? '').toLowerCase().contains(q);
  }
}

/// 全部命令：收藏 / 最近 / 全部，带搜索与星标。
///
/// 点一行把命令名交回调用方（通常填进输入框），本页随后退出。
class CommandsPage extends StatefulWidget {
  const CommandsPage({
    super.key,
    required this.client,
    required this.sessionId,
    this.onPick,
  });

  final DshClient client;
  final String sessionId;

  /// 选中一条命令：参数是命令名（不带前导 `/`）。
  final void Function(String name)? onPick;

  @override
  State<CommandsPage> createState() => _CommandsPageState();
}

class _CommandsPageState extends State<CommandsPage> {
  late final CommandsStore _store;
  final TextEditingController _query = TextEditingController();
  List<_Command> _all = const <_Command>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _store = CommandsStore();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _query.dispose();
    _store.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _store.load();
    if (!mounted) return;
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.client.api(
        'GET',
        '/link/commands',
        query: '?sessionId=${Uri.encodeQueryComponent(widget.sessionId)}',
      );
      final raw = r['items'] ?? r['commands'] ?? r['data'];
      final parsed = <_Command>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final command = _Command.fromJson(Map<String, dynamic>.from(item));
          if (command != null) parsed.add(command);
        }
      }
      if (!mounted) return;
      setState(() {
        _all = parsed;
        _loading = false;
      });
    } on DshClientException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _humanize(e);
        _loading = false;
      });
    }
  }

  void _pick(String name) {
    unawaited(_store.touch(name));
    widget.onPick?.call(name);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('命令'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _store,
        builder: (context, _) {
          final query = _query.text.trim();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '搜命令或说明',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _query.clear();
                              setState(() {});
                            },
                          ),
                  ),
                ),
              ),
              Expanded(child: _body(query)),
            ],
          );
        },
      ),
    );
  }

  Widget _body(String query) {
    if (_error != null) return _errorView(_error!);
    if (_loading && _all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_all.isEmpty) return _empty('这条会话还没有可用的命令');

    final byName = <String, _Command>{for (final c in _all) c.name: c};
    final favorites = <_Command>[];
    for (final name in _store.favorites) {
      final command = byName[name];
      if (command != null) favorites.add(command);
    }
    final recent = <_Command>[];
    for (final name in _store.recent) {
      final command = byName[name];
      if (command != null) recent.add(command);
    }
    final filtered = _all.where((c) => c.matches(query)).toList();

    if (!_store.loaded) {
      // 收藏还没读出来时先别画两份空组，否则首帧会闪一下「还没有收藏」。
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: _rows(_all),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: <Widget>[
        ..._section('收藏', favorites, emptyHint: '点命令右侧的星标收藏'),
        ..._section('最近', recent, emptyHint: '用过的命令会排在这里'),
        ..._section(query.isEmpty ? '全部' : '搜索结果', filtered, emptyHint: '没有匹配的命令'),
      ],
    );
  }

  List<Widget> _section(String title, List<_Command> items, {required String emptyHint}) {
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AidockColors.textDim,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${items.length}',
              style: const TextStyle(fontSize: 11.5, color: AidockColors.textDim),
            ),
          ],
        ),
      ),
      if (items.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            emptyHint,
            style: const TextStyle(fontSize: 12, color: AidockColors.textDim),
          ),
        )
      else
        ..._rows(items),
      const Divider(height: 18, thickness: 1, color: AidockColors.line),
    ];
  }

  List<Widget> _rows(List<_Command> items) {
    return <Widget>[for (final command in items) _row(command)];
  }

  Widget _row(_Command command) {
    final favorite = _store.isFavorite(command.name);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: () => _pick(command.name),
      title: Text(
        '/${command.name}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 13.5,
          fontFamily: 'monospace',
          color: AidockColors.accent,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (command.description.isNotEmpty)
            Text(
              command.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AidockColors.textDim),
            ),
          if (command.hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AidockColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  command.hint!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: AidockColors.textDim),
                ),
              ),
            ),
        ],
      ),
      trailing: IconButton(
        tooltip: favorite ? '取消收藏' : '收藏',
        iconSize: 20,
        onPressed: () => unawaited(_store.toggleFavorite(command.name)),
        icon: Icon(
          favorite ? Icons.star_rounded : Icons.star_outline_rounded,
          color: favorite ? AidockColors.warn : AidockColors.textDim,
        ),
      ),
    );
  }

  Widget _empty(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AidockColors.textDim),
        ),
      ),
    );
  }

  Widget _errorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AidockColors.textDim),
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: () => unawaited(_load()),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  static String _humanize(DshClientException e) {
    if (e.status == 401 || e.status == 403) {
      return '这台设备没有权限了：重启一次 DSH 或重新配对';
    }
    final message = e.message.trim();
    if (message.isNotEmpty && message != 'request failed') return message;
    return '拿不到命令表，检查一下电脑那边';
  }
}
