import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme.dart';

/// 「更多」页：设备管理、定时任务、界面字号、运行日志。
///
/// 这里的东西都直接打宿主原路径（`/api/mobile/v1/...`），所以它们是「reset 一次宿主」
/// 之后才好用的那一批；打不通时页面会把宿主原话贴出来，而不是装作空列表。
class MorePage extends StatefulWidget {
  const MorePage({super.key, required this.state});

  final AppState state;

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  @override
  void initState() {
    super.initState();
    widget.state.loadDevices();
    widget.state.loadSchedules();
  }

  String _when(int ms) {
    if (ms <= 0) return '—';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    if (t.year == now.year && t.month == now.month && t.day == now.day) return '今天 $hm';
    return '${t.month}/${t.day} $hm';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('更多')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _section('已配对的手机', trailing: _refresh(s.loadingDevices, s.loadDevices)),
              if (s.devices.isEmpty)
                _hint(s.loadingDevices ? '读取中…' : '这台电脑上还没有其它已配对设备'),
              for (final d in s.devices) _deviceRow(s, d),
              const SizedBox(height: 24),
              _section('定时任务', trailing: _refresh(s.loadingSchedules, s.loadSchedules)),
              if (s.schedules.isEmpty)
                _hint(s.loadingSchedules ? '读取中…' : '还没有定时任务'),
              for (final r in s.schedules) _scheduleRow(s, r),
              const SizedBox(height: 24),
              _section('界面'),
              _textScaleTile(s),
              const SizedBox(height: 24),
              _section('运行日志', trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(
                  onPressed: s.logLines.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: s.logText));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('日志已复制')),
                            );
                          }
                        },
                  child: const Text('复制'),
                ),
                TextButton(onPressed: s.logLines.isEmpty ? null : s.clearLog, child: const Text('清空')),
              ])),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AidockColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  s.logLines.isEmpty ? '（暂时没有日志）' : s.logText,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    fontFamily: 'monospace',
                    color: AidockColors.textDim,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _refresh(bool loading, VoidCallback onTap) {
    if (loading) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: onTap);
  }

  Widget _section(String title, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text, style: const TextStyle(fontSize: 13, color: AidockColors.textDim)),
    );
  }

  Widget _deviceRow(AppState s, Map<String, dynamic> d) {
    final name = '${d['name'] ?? ''}'.trim();
    final model = '${d['model'] ?? ''}'.trim();
    final title = [name, model].where((e) => e.isNotEmpty).join(' · ');
    final last = (d['lastSeenAt'] is num) ? (d['lastSeenAt'] as num).toInt() : 0;
    final sub = '最后出现 ${_when(last)}';
    final id = '${d['deviceId'] ?? ''}';
    return Card(
      color: AidockColors.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.smartphone, size: 20),
        title: Text(title.isEmpty ? id : title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(sub, style: const TextStyle(fontSize: 12, color: AidockColors.textDim)),
        trailing: TextButton(
          onPressed: id.isEmpty
              ? null
              : () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('吊销这台设备？'),
                      content: const Text('它需要重新扫码或输码才能再连。'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('吊销')),
                      ],
                    ),
                  );
                  if (ok == true) await s.revokeDevice(id);
                },
          child: const Text('吊销'),
        ),
      ),
    );
  }

  Widget _scheduleRow(AppState s, Map<String, dynamic> r) {
    final id = '${r['id'] ?? ''}';
    final title = '${r['title'] ?? '(无标题)'}';
    final status = '${r['status'] ?? r['state'] ?? ''}';
    final kind = '${r['kind'] ?? ''}';
    final color = status == 'active'
        ? AidockColors.accent
        : (status == 'paused' ? const Color(0xFFE0B34D) : AidockColors.textDim);
    final paused = status == 'paused';
    return Card(
      color: AidockColors.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: const TextStyle(fontSize: 14)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    kind.isEmpty ? status : '$kind · $status',
                    style: TextStyle(fontSize: 11, color: color),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                TextButton(
                  onPressed: id.isEmpty ? null : () => s.scheduleAction(id, paused ? 'resume' : 'pause'),
                  child: Text(paused ? '恢复' : '暂停'),
                ),
                TextButton(
                  onPressed: id.isEmpty ? null : () => s.scheduleAction(id, 'run'),
                  child: const Text('立即运行'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _textScaleTile(AppState s) {
    return Card(
      color: AidockColors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('字号', style: TextStyle(fontSize: 14)),
                const Spacer(),
                Text('${(s.textScale * 100).round()}%',
                    style: const TextStyle(fontSize: 12, color: AidockColors.textDim)),
              ],
            ),
            Slider(
              value: s.textScale,
              min: 0.85,
              max: 1.6,
              divisions: 15,
              onChanged: (v) => s.setTextScale(v),
            ),
          ],
        ),
      ),
    );
  }
}
