import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/material.dart';

import '../jobs_controller.dart';
import '../theme.dart';

/// 后台任务页：看宿主那边正在跑 / 刚跑完的后台任务，运行中的能取消。
///
/// 数据来自 [JobsController]（monitor 轮询定会话 + 会话流收 `session/jobs` 帧），
/// 取消打 `POST /api/mobile/v1/jobs/cancel`。
class JobsPage extends StatefulWidget {
  const JobsPage({super.key, required this.client});

  final DshClient client;

  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> {
  late final JobsController _controller = JobsController(widget.client);

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    // 轮询与各会话的流都在控制器里，dispose 一并收掉。
    _controller.dispose();
    super.dispose();
  }

  Future<void> _cancel(JobRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AidockColors.surface,
        title: const Text('取消这条任务？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              row.label,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style:  TextStyle(fontSize: 14, height: 1.5, color: AidockColors.text),
            ),
            const SizedBox(height: 10),
            Text(
              '已跑 ${_duration(row.elapsed)}，取消会把它停掉。',
              style:  TextStyle(fontSize: 12.5, height: 1.5, color: AidockColors.textDim),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AidockColors.danger),
            child: const Text('取消任务'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final message = await _controller.cancel(row.id);
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('后台任务'),
        actions: [
          IconButton(
            onPressed: () => _controller.load(),
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          if (_controller.loading && _controller.jobs.isEmpty) {
            return const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          final active = _controller.activeJobs;
          final finished = _controller.finishedJobs;
          final error = _controller.error;
          return RefreshIndicator(
            onRefresh: _controller.load,
            color: AidockColors.accent,
            backgroundColor: AidockColors.surface,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (error != null) _errorBar(error),
                if (_controller.jobs.isEmpty) ..._emptyBody(),
                if (active.isNotEmpty) _section('运行中', active.length),
                for (final row in active) _row(row),
                if (finished.isNotEmpty) _section('最近结束', finished.length),
                for (final row in finished) _row(row),
                if (_controller.jobs.isNotEmpty && _controller.updatedAt != null)
                  _footer(_controller.updatedAt!),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _emptyBody() {
    return  [
      SizedBox(height: 72),
      Icon(Icons.memory, size: 32, color: AidockColors.textDim),
      SizedBox(height: 14),
      Text(
        '没有正在跑的后台任务',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AidockColors.text),
      ),
      SizedBox(height: 8),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          '会话里启动的后台命令会出现在这里，跑完也会留一会儿。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, height: 1.6, color: AidockColors.textDim),
        ),
      ),
    ];
  }

  Widget _section(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
      child: Row(
        children: [
          Text(
            title,
            style:  TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: AidockColors.textDim,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(fontSize: 12, color: AidockColors.textDim.withOpacity(0.8)),
          ),
        ],
      ),
    );
  }

  Widget _row(JobRow row) {
    final color = _statusColor(row.status);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AidockColors.line.withOpacity(0.6))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    fontWeight: row.isActive ? FontWeight.w500 : FontWeight.w400,
                    color: row.isActive ? AidockColors.text : AidockColors.textDim,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _pill(row.status, color),
                    const SizedBox(width: 8),
                    Text(
                      _duration(row.elapsed),
                      style:  TextStyle(fontSize: 12, color: AidockColors.textDim),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '· ${_controller.titleOf(row.sessionId)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:  TextStyle(fontSize: 12, color: AidockColors.textDim),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (row.isActive)
            TextButton(
              onPressed: row.status == JobStatus.stopping ? null : () => _cancel(row),
              style: TextButton.styleFrom(
                foregroundColor: AidockColors.danger,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(48, 36),
              ),
              child: Text(
                row.status == JobStatus.stopping ? '取消中' : '取消',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pill(JobStatus status, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 11,
          height: 1.25,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _errorBar(String message) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
              message,
              style:  TextStyle(fontSize: 12.5, height: 1.5, color: AidockColors.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(DateTime updatedAt) {
    final clock = '${_two(updatedAt.hour)}:${_two(updatedAt.minute)}:${_two(updatedAt.second)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Text(
        '每 3 秒自动刷新 · 更新于 $clock',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11.5, color: AidockColors.textDim.withOpacity(0.75)),
      ),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static Color _statusColor(JobStatus status) {
    switch (status) {
      case JobStatus.running:
        return AidockColors.accent;
      case JobStatus.stopping:
        return AidockColors.warn;
      case JobStatus.completed:
        return AidockColors.ok;
      case JobStatus.killed:
        return AidockColors.textDim;
      case JobStatus.failed:
        return AidockColors.danger;
    }
  }

  static String _duration(Duration? span) {
    if (span == null) return '—';
    final seconds = span.inSeconds;
    if (seconds < 60) return '$seconds 秒';
    final minutes = span.inMinutes;
    if (minutes < 60) {
      final rest = seconds - minutes * 60;
      return rest == 0 ? '$minutes 分' : '$minutes 分 $rest 秒';
    }
    final hours = span.inHours;
    final restMinutes = minutes - hours * 60;
    return restMinutes == 0 ? '$hours 小时' : '$hours 小时 $restMinutes 分';
  }
}
