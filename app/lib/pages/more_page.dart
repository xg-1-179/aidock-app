import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../keepalive.dart' as keepalive;
import '../theme.dart';
import 'artifacts_page.dart';
import 'about_page.dart';
import 'jobs_page.dart';
import 'plugins_page.dart';
import 'schedule_edit_page.dart';
import 'git_page.dart';

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
              _section('定时任务', trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                _refresh(s.loadingSchedules, s.loadSchedules),
                IconButton(
                  tooltip: '新建定时任务',
                  icon: const Icon(Icons.add_rounded, size: 20),
                  onPressed: s.client == null
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => ScheduleEditPage(
                              client: s.client!,
                              sessionId: s.openSessionId,
                              onSaved: s.loadSchedules,
                            ),
                          )),
                ),
              ])),
              if (s.schedules.isEmpty)
                _hint(s.loadingSchedules
                    ? '读取中…'
                    : (s.scheduleHint.isNotEmpty ? s.scheduleHint : '还没有定时任务')),
              for (final r in s.schedules) _scheduleRow(s, r),
              const SizedBox(height: 24),
              _section('会话与代码'),
              _linkTile(
                icon: Icons.commit,
                title: 'Git 改动',
                subtitle: '暂存 / 未暂存 / 冲突，以及最近提交',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => GitPage(state: s)),
                ),
              ),
              _linkTile(
                icon: Icons.folder_open,
                title: '这条会话的产物',
                subtitle: s.openSessionId == null ? '先打开一条会话再看' : '生成过、改动过的文件',
                enabled: s.openSessionId != null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ArtifactsPage(state: s)),
                ),
              ),
              _linkTile(
                icon: Icons.memory,
                title: '后台任务',
                subtitle: '电脑上正在跑的命令，可以在这里掐掉',
                enabled: s.client != null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => JobsPage(client: s.client!)),
                ),
              ),
              _linkTile(
                icon: Icons.extension_outlined,
                title: '插件',
                subtitle: '装 / 卸 / 启停电脑上的插件',
                enabled: s.client != null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => PluginsPage(client: s.client!)),
                ),
              ),
              const SizedBox(height: 24),
              _section('界面'),
              _quietTile(s),
              _themeTile(s),
              _textScaleTile(s),
              _linkTile(
                icon: Icons.battery_saver_outlined,
                title: '让系统别杀后台',
                subtitle: '加入电池优化白名单，锁屏时也能收消息',
                onTap: () async {
                  await keepalive.KeepAlive.requestBatteryExemption();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已打开系统设置，找到 AIDock 选「不限制」')),
                    );
                  }
                },
              ),
              _linkTile(
                icon: Icons.info_outline,
                title: '关于 AIDock',
                subtitle: '版本 · 检查更新 · 开源许可',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AboutPage(
                      currentVersion: '0.18.1',
                      onLogout: () => s.forgetSaved(),
                    ),
                  ),
                ),
              ),
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
                  style:  TextStyle(
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

  Widget _linkTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: enabled ? AidockColors.accent : AidockColors.textDim),
      title: Text(title, style: TextStyle(color: enabled ? null : AidockColors.textDim)),
      subtitle: Text(subtitle, style:  TextStyle(fontSize: 12, color: AidockColors.textDim)),
      trailing: const Icon(Icons.chevron_right, size: 20),
      enabled: enabled,
      onTap: enabled ? onTap : null,
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
      child: Text(text, style:  TextStyle(fontSize: 13, color: AidockColors.textDim)),
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
        subtitle: Text(sub, style:  TextStyle(fontSize: 12, color: AidockColors.textDim)),
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
        : (status == 'paused' ? AidockColors.warn : AidockColors.textDim);
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

  Widget _quietTile(AppState s) {
    final on = s.quietEnabled;
    final range = '${s.quietStart.toString().padLeft(2, '0')}:00 – '
        '${s.quietEnd.toString().padLeft(2, '0')}:00';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AidockColors.line),
      ),
      child: Row(
        children: [
           Icon(Icons.nightlight_round, size: 18, color: AidockColors.textDim),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('免打扰时段', style: TextStyle(fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                  on ? '这段时间只推送审批和提问 · $range' : '关着：任何提醒都会响',
                  style:  TextStyle(fontSize: 11.5, color: AidockColors.textDim),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _editQuiet(s),
            child: const Text('时段'),
          ),
          Switch(
            value: on,
            activeColor: AidockColors.accent,
            onChanged: (v) => s.setQuiet(enabled: v, start: s.quietStart, end: s.quietEnd),
          ),
        ],
      ),
    );
  }

  Future<void> _editQuiet(AppState s) async {
    final startCtl = TextEditingController(text: '${s.quietStart}');
    final endCtl = TextEditingController(text: '${s.quietEnd}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('免打扰时段'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
             Text('填 0–23 的整点，跨夜也行（23 到 8 表示晚上 11 点到早上 8 点）。',
                style: TextStyle(fontSize: 12.5, height: 1.5, color: AidockColors.textDim)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: TextField(controller: startCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '开始'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: endCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '结束'))),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      final a = int.tryParse(startCtl.text.trim()) ?? s.quietStart;
      final b = int.tryParse(endCtl.text.trim()) ?? s.quietEnd;
      await s.setQuiet(
        enabled: true,
        start: a.clamp(0, 23).toInt(),
        end: b.clamp(0, 23).toInt(),
      );
    }
    startCtl.dispose();
    endCtl.dispose();
  }

  Widget _themeTile(AppState s) {
    return Card(
      color: AidockColors.surface,
      child: SwitchListTile(
        value: s.lightMode,
        onChanged: (v) => s.setLightMode(v),
        title: Text('浅色模式', style: TextStyle(fontSize: 14, color: AidockColors.text)),
        subtitle: Text(
          s.lightMode ? '白底深字，白天在户外看得清' : '深色底，夜里不刺眼',
          style: TextStyle(fontSize: 11, color: AidockColors.textDim),
        ),
        secondary: Icon(
          s.lightMode ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          size: 20,
          color: AidockColors.textDim,
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
                    style:  TextStyle(fontSize: 12, color: AidockColors.textDim)),
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
