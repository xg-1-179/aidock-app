import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:image_picker/image_picker.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/image_viewer.dart';
import '../widgets/message_body.dart';
import 'schedule_edit_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.state, required this.title});
  final AppState state;
  final String title;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  /// 输入框以 `/` 开头时的候选命令（前缀过滤后的结果）。
  List<Map<String, dynamic>> _slash = const [];
  final _scroll = ScrollController();
  int _seen = 0;

  @override
  void initState() {
    super.initState();
    // 上次没发完的草稿：切会话/退出都不该丢。
    final draft = widget.state.draft;
    if (draft.isNotEmpty) {
      _input.text = draft;
      _input.selection = TextSelection.collapsed(offset: draft.length);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    widget.state.closeSession();
    super.dispose();
  }

  /// 模型选择：宿主给的 groups 里按厂商分组列出来，点一条就只切这条会话。
  Future<void> _pickModel() async {
    final s = widget.state;
    await s.loadModels();
    if (!mounted) return;
    final info = s.modelInfo;
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('拿不到模型清单，稍后再试')),
      );
      return;
    }
    final groups = (info['groups'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        const <Map<String, dynamic>>[];
    final cur = info['current'];
    final curProvider = cur is Map ? '${cur['provider'] ?? ''}' : '';
    final curModel = cur is Map ? '${cur['model'] ?? ''}' : '';
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AidockColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.72),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Row(
                  children: [
                    const Text('选择模型',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (s.loadingModels)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final g in groups) ...<Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
                        child: Text(
                          '${g['name'] ?? g['id']}',
                          style: const TextStyle(
                              fontSize: 11, color: AidockColors.textDim, letterSpacing: .5),
                        ),
                      ),
                      for (final m in (g['models'] as List?)
                              ?.whereType<Map<String, dynamic>>()
                              .toList() ??
                          const <Map<String, dynamic>>[])
                        ListTile(
                          dense: true,
                          title: Text('${m['name'] ?? m['id']}',
                              style: const TextStyle(fontSize: 14)),
                          subtitle: m['description'] == null
                              ? null
                              : Text(
                                  '${m['description']}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11),
                                ),
                          trailing: ('${g['id']}' == curProvider &&
                                  '${m['id']}' == curModel)
                              ? const Icon(Icons.check, size: 18, color: AidockColors.accent)
                              : null,
                          onTap: () async {
                            Navigator.of(ctx).pop();
                            await s.chooseModel('${g['id']}', '${m['id']}');
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 选图：相册可多选，选完连输入框里的正文一起发。
  Future<void> _pickImage() async {
    final s = widget.state;
    if (s.openSessionId == null) return;
    try {
      final picked = await ImagePicker().pickMultiImage(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 78,
        limit: 9,
      );
      if (picked.isEmpty) return;
      final items = <OutgoingImage>[];
      for (final file in picked) {
        items.add(OutgoingImage(
          name: file.name.isEmpty ? 'image.jpg' : file.name,
          mediaType: _mediaTypeOf(file.name),
          bytes: await file.readAsBytes(),
        ));
      }
      final caption = _input.text.trim();
      if (caption.isNotEmpty) _input.clear();
      await s.sendImages(items, text: caption);
      if (mounted) Future<void>.delayed(const Duration(milliseconds: 120), _toBottom);
    } catch (e) {
      s.setError('选图失败：$e');
    }
  }

  static String _mediaTypeOf(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }

  void _send() {
    final text = _input.text;
    if (_slash.isNotEmpty) setState(() => _slash = const []);
    if (text.trim().isEmpty) return;
    _input.clear();
    widget.state.saveDraft('');
    widget.state.send(text);
    Future<void>.delayed(const Duration(milliseconds: 120), _toBottom);
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  /// 断线重连提示条：不弹窗、不遮消息，只在顶部说明「现在是什么状态」。
  Widget _reconnectBar() {
    return Container(
      width: double.infinity,
      color: AidockColors.warn.withOpacity(0.14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: AidockColors.warn),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '连接中断，正在自动重连…历史消息还在，回来的消息会自动补上',
              style: TextStyle(fontSize: 12.5, color: AidockColors.warn.withOpacity(0.95)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    // 消息变长（新消息或流式增量）就贴着底部走；用户往上翻历史时不动。
    final seen = s.messages.fold<int>(0, (a, m) => a + m.text.length) + s.messages.length;
    if (seen != _seen) {
      _seen = seen;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final near = _scroll.position.maxScrollExtent - _scroll.position.pixels;
        if (near < 260) _toBottom();
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '给这个会话建定时任务',
            icon: const Icon(Icons.schedule_rounded, size: 20),
            onPressed: s.client == null || s.openSessionId == null
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ScheduleEditPage(
                        client: s.client!,
                        sessionId: s.openSessionId,
                        onSaved: s.loadSchedules,
                      ),
                    )),
          ),
          TextButton.icon(
            onPressed: s.openSessionId == null ? null : _pickModel,
            icon: const Icon(Icons.memory, size: 17, color: AidockColors.textDim),
            label: Text(
              s.modelLabel,
              style: const TextStyle(fontSize: 12, color: AidockColors.textDim),
            ),
          ),
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
          if (s.reconnecting) _reconnectBar(),
          Expanded(
            child: AnimatedBuilder(
              animation: s,
              builder: (context, _) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
                final cards = s.approvals;
                if (s.messages.isEmpty && cards.isEmpty && s.questions.isEmpty) {
                  return const Center(
                    child: Text('说点什么…', style: TextStyle(color: AidockColors.textDim, fontSize: 13)),
                  );
                }
                return ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  children: [
                    for (final m in s.messages) _bubble(m),
                    for (final q in s.questions) _QuestionDock(state: s, card: q),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_slash.isNotEmpty) _slashBar(),
                  Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      onChanged: (v) {
                        _onInputChanged(v);
                        widget.state.saveDraft(v);
                      },
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: '发消息给电脑上的 Harness…',
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 42,
                    height: 46,
                    child: IconButton(
                      tooltip: '发图片（可多选）',
                      onPressed: _pickImage,
                      icon: const Icon(Icons.image_outlined, size: 22),
                      color: AidockColors.textDim,
                    ),
                  ),
                  const SizedBox(width: 6),
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 输入框以 `/` 开头时按前缀过滤命令表（最多 6 条）。
  void _onInputChanged(String raw) {
    final text = raw.trimLeft();
    if (!text.startsWith('/') || text.contains(' ') || text.contains('\n')) {
      if (_slash.isNotEmpty) setState(() => _slash = const []);
      return;
    }
    final q = text.substring(1).toLowerCase();
    final all = widget.state.slashCommands;
    final hits = all
        .where((c) => '${c['name'] ?? ''}'.toLowerCase().startsWith(q))
        .take(6)
        .toList();
    setState(() => _slash = hits);
  }

  Widget _slashBar() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AidockColors.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in _slash)
            InkWell(
              onTap: () {
                _input.text = '/${c['name']} ';
                _input.selection = TextSelection.collapsed(offset: _input.text.length);
                setState(() => _slash = const []);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(
                  children: [
                    Text('/${c['name']}',
                        style: const TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: AidockColors.accent)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${c['description'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, color: AidockColors.textDim),
                      ),
                    ),
                    if (c['input'] is Map && '${(c['input'] as Map)['hint'] ?? ''}'.isNotEmpty)
                      Text('${(c['input'] as Map)['hint']}',
                          style: const TextStyle(fontSize: 10.5, color: AidockColors.textDim)),
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
        border: Border.all(color: AidockColors.warn.withOpacity(0.45)),
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
    final bubble = GestureDetector(
      onLongPress: () => _messageMenu(m),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: mine ? AidockColors.accentDeep : AidockColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(15),
            topRight: const Radius.circular(15),
            bottomLeft: Radius.circular(mine ? 15 : 5),
            bottomRight: Radius.circular(mine ? 5 : 15),
          ),
          border: mine ? null : Border.all(color: AidockColors.line),
        ),
        child: _body(m, mine),
      ),
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          bubble,
          // 没发出去的那条：气泡下面挂一行「重发」，点一下摘掉坏气泡重走一遍。
          if (m.failed)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4, right: 4),
              child: TextButton.icon(
                onPressed: () => widget.state.retryMessage(m),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: AidockColors.warn,
                ),
                icon: const Icon(Icons.rotate_left_rounded, size: 15),
                label: const Text('没发出去，重发', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  /// 长按某条消息：复制原文，或者把它作为引用塞回输入框。
  Future<void> _messageMenu(ChatMessage m) async {
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
              leading: const Icon(Icons.copy_rounded, size: 20),
              title: const Text('复制这条消息', style: TextStyle(fontSize: 14)),
              onTap: () => Navigator.of(ctx).pop('copy'),
            ),
            if (m.role != 'system')
              ListTile(
                leading: const Icon(Icons.format_quote_rounded, size: 20),
                title: const Text('引用它再发一条', style: TextStyle(fontSize: 14)),
                onTap: () => Navigator.of(ctx).pop('quote'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.text));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制')));
      return;
    }
    if (action == 'quote') {
      final snippet = m.text.trim();
      final cut = snippet.length > 160 ? '${snippet.substring(0, 160)}…' : snippet;
      final quoted = cut
          .split('\n')
          .map((line) => line.isEmpty ? '>' : '> $line')
          .join('\n');
      final current = _input.text;
      _input.text = current.isEmpty ? '$quoted\n\n' : '$quoted\n\n$current';
      _input.selection = TextSelection.collapsed(offset: _input.text.length);
      _focus.requestFocus();
      setState(() {});
    }
  }

  /// 消息正文：用户气泡保持纯文本，助手消息按 ``` 切成「散文 / 代码」交替渲染。
  ///
  /// 不引第三方 Markdown 包：一是依赖越少构建越稳，二是手机窄屏上真正常用的只有
  /// 代码块、行内代码和粗体这三样，手写一遍比调包更好控行高与配色。
  /// 气泡里的图片：历史图按 `attachmentId` 现取（`AppState._hydrateImages`），
  /// 自己刚发的那张直接用本地字节，所以一发出就能看见。
  Widget _body(ChatMessage m, bool mine) {
    final text = m.text.isEmpty && m.streaming ? '…' : m.text;
    final body = MessageBody(text: text, mine: mine, streaming: m.streaming);
    if (m.images.isEmpty) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [_images(m), body],
    );
  }

  Widget _images(ChatMessage m) {
    if (m.images.isEmpty) return const SizedBox.shrink();
    final children = <Widget>[];
    for (var i = 0; i < m.images.length && i < 4; i++) {
      Uint8List bytes;
      try {
        bytes = base64Decode(m.images[i]);
      } catch (_) {
        continue;
      }
      children.add(GestureDetector(
        onTap: () => openImageViewer(context, m.images, i),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            width: 220,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

}

/// 提问卡（宿主 `ask_user_question`）：单选题点一下即选，多选题可反选；
/// 有选项时也可以补充自由输入，没选项时只填输入框。答复走 `/link/question/respond`。
class _QuestionDock extends StatefulWidget {
  const _QuestionDock({required this.state, required this.card});

  final AppState state;
  final QuestionCard card;

  @override
  State<_QuestionDock> createState() => _QuestionDockState();
}

class _QuestionDockState extends State<_QuestionDock> {
  final Map<String, Set<String>> _picks = <String, Set<String>>{};
  final Map<String, TextEditingController> _customs = <String, TextEditingController>{};
  bool _sending = false;

  @override
  void dispose() {
    for (final c in _customs.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _customOf(String id) =>
      _customs.putIfAbsent(id, () => TextEditingController());

  Set<String> _picksOf(String id) => _picks.putIfAbsent(id, () => <String>{});

  void _toggle(QuestionItem q, String label) {
    final set = _picksOf(q.id);
    setState(() {
      if (q.multiSelect) {
        if (!set.remove(label)) set.add(label);
      } else {
        set
          ..clear()
          ..add(label);
      }
    });
  }

  Future<void> _submit() async {
    if (_sending) return;
    setState(() => _sending = true);
    final customs = <String, String>{
      for (final q in widget.card.questions)
        if ((_customs[q.id]?.text ?? '').trim().isNotEmpty) q.id: _customs[q.id]!.text.trim(),
    };
    final picks = <String, List<String>>{for (final e in _picks.entries) e.key: e.value.toList()};
    await widget.state.answerQuestion(widget.card, picks, customs: customs);
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AidockColors.accent.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.help_outline, size: 16, color: AidockColors.accent),
              SizedBox(width: 7),
              Expanded(
                child: Text('电脑在等你回答',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AidockColors.text)),
              ),
            ],
          ),
          for (final q in card.questions) _question(q),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: _sending ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AidockColors.accent,
                    foregroundColor: const Color(0xFF06121F),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(_sending ? '提交中…' : '提交回答', style: const TextStyle(fontSize: 13)),
                ),
                if (_QuestionDockState.q_tip(card).isNotEmpty)
                  Text(_QuestionDockState.q_tip(card),
                      style: const TextStyle(fontSize: 11.5, color: AidockColors.textDim)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String q_tip(QuestionCard card) =>
      card.questions.any((q) => q.multiSelect) ? '多选题可选多项' : '';

  Widget _question(QuestionItem q) {
    final picks = _picksOf(q.id);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((q.header ?? '').isNotEmpty)
            Text(q.header!,
                style: const TextStyle(fontSize: 11.5, color: AidockColors.textDim, letterSpacing: 0.4)),
          if ((q.header ?? '').isNotEmpty) const SizedBox(height: 3),
          Text(q.text,
              style: const TextStyle(fontSize: 13, height: 1.5, color: AidockColors.text)),
          if ((q.detail ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(q.detail!,
                  style: const TextStyle(fontSize: 12, height: 1.5, color: AidockColors.textDim)),
            ),
          if (q.options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final o in q.options)
                    ChoiceChip(
                      label: Text(o.label, style: const TextStyle(fontSize: 12.5)),
                      selected: picks.contains(o.label),
                      onSelected: (_) => _toggle(q, o.label),
                      backgroundColor: AidockColors.bg,
                      selectedColor: AidockColors.accent.withOpacity(0.22),
                      labelStyle: const TextStyle(color: AidockColors.text),
                      side: BorderSide(
                          color: picks.contains(o.label) ? AidockColors.accent : AidockColors.line),
                      visualDensity: VisualDensity.compact,
                      tooltip: o.description,
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _customOf(q.id),
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 13, color: AidockColors.text),
              decoration: InputDecoration(
                hintText: q.options.isEmpty ? '在这里回答…' : '或者自己写一个答案（可选）',
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
