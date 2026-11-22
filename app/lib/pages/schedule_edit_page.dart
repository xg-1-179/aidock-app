import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 时间规则的两条路子（宿主 `kind` 是 `every` / `after`）。
enum _TimingMode { every, after }

/// 数值单位：宿主只认秒，界面上给人挑分钟还是小时。
enum _Unit { minute, hour }

/// 新建定时任务。
///
/// 端点按 `lib/mobile/schedule-edit.js` 核对：
/// `POST /api/mobile/v1/schedule/create`
/// body `{sessionId?, title, prompt, timing, target?}` ——
/// `title` 与 `prompt` **都是必填**（空标题回 400 `invalid_title`），
/// `timing` 收 `{kind:'every', every_seconds}` / `{kind:'after', after_seconds}`；
/// 只传 `sessionId` 不带 `target` 时，宿主默认把任务落在这条会话上。
class ScheduleEditPage extends StatefulWidget {
  const ScheduleEditPage({
    super.key,
    required this.client,
    this.sessionId,
    this.onSaved,
  });

  final DshClient client;

  /// 任务落在哪条会话；null 表示不绑会话（宿主会为它新开一条）。
  final String? sessionId;

  /// 创建成功后的回调（调用方用来刷新列表），在退出本页之前执行。
  final Future<void> Function()? onSaved;

  @override
  State<ScheduleEditPage> createState() => _ScheduleEditPageState();
}

class _ScheduleEditPageState extends State<ScheduleEditPage> {
  static const int _minCount = 1;
  static const int _maxCount = 1440;

  /// 宿主的硬上限：标题 120 字、指令 4000 字（超了它不报错，只是把指令截断）。
  static const int _maxTitle = 120;
  static const int _maxPrompt = 4000;

  final TextEditingController _prompt = TextEditingController();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _count = TextEditingController(text: '30');

  _TimingMode _mode = _TimingMode.every;
  _Unit _unit = _Unit.minute;
  bool _saving = false;
  String? _promptError;
  String? _titleError;
  String? _countError;
  String? _error;

  @override
  void dispose() {
    _prompt.dispose();
    _title.dispose();
    _count.dispose();
    super.dispose();
  }

  String get _unitText => _unit == _Unit.hour ? '小时' : '分钟';

  /// 界面上那句人话：规则本身由它一眼看懂，不用再解释一遍。
  String get _preview {
    final n = int.tryParse(_count.text.trim());
    final value = n == null || n < _minCount || n > _maxCount ? '—' : '$n';
    if (_mode == _TimingMode.every) return '每 $value $_unitText触发一次';
    return '$value $_unitText后触发一次';
  }

  String _deriveTitle(String prompt) {
    final line = prompt
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '')
        .trim();
    final base = line.isEmpty ? '定时任务' : line;
    return base.length <= 60 ? base : '${base.substring(0, 60)}…';
  }

  String _errorText(Object e) {
    if (e is DshClientException) {
      final message = e.message;
      if (message.isNotEmpty) return message;
      return '创建失败（HTTP ${e.status ?? '?'}）';
    }
    return '$e';
  }

  Future<void> _submit() async {
    if (_saving) return;
    final prompt = _prompt.text.trim();
    final typed = _title.text.trim();
    final n = int.tryParse(_count.text.trim());
    final promptError = prompt.isEmpty
        ? '提示词不能为空'
        : (prompt.length > _maxPrompt ? '提示词最多 $_maxPrompt 字' : null);
    final titleError = typed.length > _maxTitle ? '标题最多 $_maxTitle 字' : null;
    final countError = (n == null || n < _minCount || n > _maxCount)
        ? '填 $_minCount–$_maxCount 之间的整数'
        : null;
    setState(() {
      _promptError = promptError;
      _titleError = titleError;
      _countError = countError;
      _error = null;
    });
    if (promptError != null || titleError != null || countError != null || n == null) {
      return;
    }

    final seconds = n * (_unit == _Unit.hour ? 3600 : 60);
    final timing = _mode == _TimingMode.every
        ? <String, dynamic>{'kind': 'every', 'every_seconds': seconds}
        : <String, dynamic>{'kind': 'after', 'after_seconds': seconds};
    final title = typed.isNotEmpty ? typed : _deriveTitle(prompt);
    final sessionId = widget.sessionId?.trim() ?? '';
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _saving = true);
    try {
      await widget.client.api('POST', '/schedule/create', payload: {
        'title': title,
        'prompt': prompt,
        'timing': timing,
        if (sessionId.isNotEmpty) 'sessionId': sessionId,
      });
      final saved = widget.onSaved;
      if (saved != null) await saved();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('已创建定时任务：$title')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bound = (widget.sessionId ?? '').trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('新建定时任务')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _label('提示词'),
          TextField(
            controller: _prompt,
            minLines: 4,
            maxLines: 8,
            textInputAction: TextInputAction.newline,
            enabled: !_saving,
            onChanged: (_) {
              if (_promptError != null) setState(() => _promptError = null);
            },
            decoration: InputDecoration(
              hintText: '到点要它做什么，例如「跑一遍 flutter analyze，把报错贴出来」',
              errorText: _promptError,
            ),
          ),
          const SizedBox(height: 18),
          _label('标题'),
          TextField(
            controller: _title,
            enabled: !_saving,
            onChanged: (_) {
              if (_titleError != null) setState(() => _titleError = null);
            },
            decoration: InputDecoration(
              hintText: '选填，留空取提示词第一行',
              errorText: _titleError,
            ),
          ),
          const SizedBox(height: 18),
          _label('触发方式'),
          SegmentedButton<_TimingMode>(
            segments: const [
              ButtonSegment<_TimingMode>(
                value: _TimingMode.every,
                label: Text('每隔'),
                icon: Icon(Icons.repeat, size: 16),
              ),
              ButtonSegment<_TimingMode>(
                value: _TimingMode.after,
                label: Text('一次性'),
                icon: Icon(Icons.schedule, size: 16),
              ),
            ],
            selected: <_TimingMode>{_mode},
            showSelectedIcon: false,
            onSelectionChanged: _saving
                ? null
                : (selection) => setState(() => _mode = selection.first),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _count,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  onChanged: (_) {
                    setState(() {
                      if (_countError != null) _countError = null;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: '$_minCount–$_maxCount',
                    errorText: _countError,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('分钟'),
                      selected: _unit == _Unit.minute,
                      onSelected: _saving ? null : (_) => setState(() => _unit = _Unit.minute),
                    ),
                    ChoiceChip(
                      label: const Text('小时'),
                      selected: _unit == _Unit.hour,
                      onSelected: _saving ? null : (_) => setState(() => _unit = _Unit.hour),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _preview,
            style:  TextStyle(fontSize: 12.5, height: 1.5, color: AidockColors.textDim),
          ),
          const SizedBox(height: 6),
          Text(
            bound
                ? '结果会回到这条会话里。'
                : '没绑定会话：宿主会为它新开一条会话来跑。',
            style:  TextStyle(fontSize: 12.5, height: 1.5, color: AidockColors.textDim),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: AidockColors.danger.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AidockColors.danger.withOpacity(0.35)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.error_outline, size: 16, color: AidockColors.danger),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style:  TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: AidockColors.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(
          height: 48,
          child: FilledButton(
            onPressed: _saving ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: AidockColors.accent,
              foregroundColor: AidockColors.bg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _saving
                ?  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AidockColors.bg),
                  )
                : const Text('创建', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style:  TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AidockColors.textDim,
        ),
      ),
    );
  }
}
