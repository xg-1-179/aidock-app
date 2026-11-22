import 'dart:async';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/foundation.dart';

/// 宿主 `session/jobs` 帧里的一条后台任务（`status` 是闭集）。
enum JobStatus {
  running('运行'),
  stopping('停止中'),
  completed('完成'),
  killed('已杀'),
  failed('失败');

  const JobStatus(this.label);
  final String label;

  static JobStatus parse(Object? raw) {
    final value = (raw ?? '').toString().trim();
    for (final status in JobStatus.values) {
      if (status.name == value) return status;
    }
    return JobStatus.completed;
  }
}

/// 一行后台任务。
///
/// 字段来源：SSE `/link/session/stream` 的 `session/jobs` 帧
/// `{id, kind, label, status, startedAt, detail?, finishedAt?}`。
class JobRow {
  const JobRow({
    required this.sessionId,
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    this.detail,
    this.startedAt,
    this.finishedAt,
  });

  final String sessionId;
  final String id;
  final String kind;
  final String label;
  final JobStatus status;
  final String? detail;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isActive => status == JobStatus.running || status == JobStatus.stopping;

  /// 跑了多久：运行中算到现在，结束的算到 `finishedAt`。
  Duration? get elapsed {
    final start = startedAt;
    if (start == null) return null;
    final end = finishedAt ?? DateTime.now();
    final span = end.difference(start);
    return span.isNegative ? Duration.zero : span;
  }

  JobRow copyWith({JobStatus? status, DateTime? finishedAt}) => JobRow(
        sessionId: sessionId,
        id: id,
        kind: kind,
        label: label,
        status: status ?? this.status,
        detail: detail,
        startedAt: startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
      );

  static DateTime? _time(Object? raw) {
    if (raw is num) {
      final ms = raw.toInt();
      if (ms <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (raw is String && raw.isNotEmpty) {
      final asNumber = int.tryParse(raw);
      if (asNumber != null && asNumber > 0) {
        return DateTime.fromMillisecondsSinceEpoch(asNumber);
      }
      return DateTime.tryParse(raw);
    }
    return null;
  }

  static JobRow? fromFrame(Object? raw, {required String sessionId}) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    final title = (raw['label'] ?? '').toString().trim();
    final detail = (raw['detail'] ?? '').toString().trim();
    return JobRow(
      sessionId: sessionId,
      id: id,
      kind: (raw['kind'] ?? '').toString().trim(),
      label: title.isNotEmpty ? title : (detail.isNotEmpty ? detail : kindLabel(raw['kind'])),
      status: JobStatus.parse(raw['status']),
      detail: detail.isEmpty ? null : detail,
      startedAt: _time(raw['startedAt']),
      finishedAt: _time(raw['finishedAt']),
    );
  }

  static String kindLabel(Object? raw) {
    switch ((raw ?? '').toString().trim()) {
      case 'shell':
        return '后台命令';
      case 'task':
        return '子任务';
      case 'agent':
        return '子代理';
      case 'tool':
        return '工具调用';
      default:
        return '后台任务';
    }
  }
}

/// 后台任务页的数据源。
///
/// 宿主没有「列出全部后台任务」的 REST：清单只从会话流的 `session/jobs` 帧来
/// （`GET /api/mobile/v1/link/session/stream?sessionId=`），而这条帧不带历史、
/// 只在变化时推送。所以这里的做法是：
/// 1. 每 [pollInterval] 打一次 `GET /api/mobile/v1/monitor`，拿到「哪些会话在跑」；
/// 2. 给每个在跑的会话开一条流，收它推来的 job 帧；
/// 3. 会话跑完后关流，把最后一帧里已经结束的行留进「最近结束」。
///
/// 取消走 `POST /api/mobile/v1/jobs/cancel`（body `{sessionId, jobId}`）。
class JobsController extends ChangeNotifier {
  JobsController(this.client);

  final DshClient client;

  /// 轮询间隔：monitor 很轻，3 秒够「跑没跑完」的观感。
  static const Duration pollInterval = Duration(seconds: 3);

  /// 「最近结束」最多留几行，避免会话越跑越多把列表撑爆。
  static const int recentLimit = 20;

  List<JobRow> _jobs = const <JobRow>[];
  List<JobRow> get jobs => _jobs;

  List<JobRow> get activeJobs =>
      _jobs.where((row) => row.isActive).toList(growable: false);

  List<JobRow> get finishedJobs =>
      _jobs.where((row) => !row.isActive).toList(growable: false);

  bool loading = false;
  String? error;
  DateTime? updatedAt;

  final Map<String, List<JobRow>> _frames = <String, List<JobRow>>{};
  final Map<String, String> _titles = <String, String>{};
  final Map<String, StreamSubscription<Map<String, dynamic>>> _subs =
      <String, StreamSubscription<Map<String, dynamic>>>{};
  final Set<String> _watching = <String>{};
  final List<JobRow> _recent = <JobRow>[];

  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  /// 会话标题（monitor 里带的 title）；取不到就显示短 id。
  String titleOf(String sessionId) {
    final title = _titles[sessionId];
    if (title != null && title.isNotEmpty) return title;
    return sessionId.length <= 8 ? sessionId : sessionId.substring(0, 8);
  }

  /// 开始轮询。页面 initState 调它，dispose 时 [dispose] 会收掉。
  void start() {
    if (_disposed || _timer != null) return;
    unawaited(load());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(load()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final sub in _subs.values) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _watching.clear();
  }

  Future<void> load() async {
    if (_disposed || _busy) return;
    _busy = true;
    if (_jobs.isEmpty) {
      loading = true;
      _safeNotify();
    }
    try {
      final data = await client.api('GET', '/monitor');
      // 条件刷新命中时宿主回 `{ok:true, unchanged:true, revision}`，**没有 items**：
      // 那种情况什么都不用动，尤其不能当成「一个会话都没跑」。
      final raw = data['items'];
      if (raw is List) {
        final running = <String>{};
        for (final entry in raw) {
          if (entry is! Map) continue;
          final sessionId = (entry['sessionId'] ?? '').toString().trim();
          if (sessionId.isEmpty) continue;
          final title = (entry['title'] ?? '').toString().trim();
          if (title.isNotEmpty) _titles[sessionId] = title;
          final isRunning = entry['running'] == true && entry['completed'] != true;
          if (isRunning) running.add(sessionId);
        }
        _syncStreams(running);
      }
      final stamp = data['generatedAt'];
      final generated = stamp is num
          ? DateTime.fromMillisecondsSinceEpoch(stamp.toInt())
          : (stamp is String ? DateTime.tryParse(stamp) : null);
      updatedAt = generated ?? DateTime.now();
      error = null;
    } catch (e) {
      error = errorText(e);
    } finally {
      _busy = false;
      loading = false;
      _recompute();
      _safeNotify();
    }
  }

  /// 取消一条任务。返回一句给用户看的结果；失败直接抛（页面拿 `errorText` 显示）。
  Future<String> cancel(String id) async {
    JobRow? target;
    for (final row in _jobs) {
      if (row.id == id) {
        target = row;
        break;
      }
    }
    if (target == null) throw StateError('这条任务已经不在列表里了');
    final data = await client.api('POST', '/jobs/cancel', payload: {
      'sessionId': target.sessionId,
      'jobId': id,
    });
    final outcome = (data['outcome'] ?? '').toString();
    _markStopping(target.sessionId, id);
    unawaited(Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (!_disposed) unawaited(load());
    }));
    return outcome == 'already-finished' ? '这条任务已经结束了' : '已请求取消';
  }

  void _markStopping(String sessionId, String id) {
    final rows = _frames[sessionId];
    if (rows == null) return;
    var changed = false;
    final next = <JobRow>[];
    for (final row in rows) {
      if (row.id == id && row.status == JobStatus.running) {
        next.add(row.copyWith(status: JobStatus.stopping));
        changed = true;
      } else {
        next.add(row);
      }
    }
    if (!changed) return;
    _frames[sessionId] = next;
    _recompute();
    _safeNotify();
  }

  void _syncStreams(Set<String> running) {
    for (final sessionId in running) {
      if (!_subs.containsKey(sessionId)) _subscribe(sessionId);
    }
    for (final sessionId in _subs.keys.toList(growable: false)) {
      if (running.contains(sessionId)) continue;
      final sub = _subs.remove(sessionId);
      if (sub != null) unawaited(sub.cancel());
      _pushRecent(_frames.remove(sessionId) ?? const <JobRow>[]);
    }
    _watching
      ..clear()
      ..addAll(running);
  }

  void _subscribe(String sessionId) {
    try {
      final sub = client.stream(sessionId).listen(
        (frame) {
          if (frame['type'] != 'session/jobs') return;
          final raw = frame['jobs'];
          if (raw is! List) return;
          final rows = <JobRow>[];
          for (final entry in raw) {
            final row = JobRow.fromFrame(entry, sessionId: sessionId);
            if (row != null) rows.add(row);
          }
          if (rows.isEmpty) {
            // 空数组＝这条会话的任务都结束了。
            _pushRecent(_frames.remove(sessionId) ?? const <JobRow>[]);
          } else {
            _frames[sessionId] = rows;
          }
          _recompute();
          _safeNotify();
        },
        onError: (Object _) => _dropSub(sessionId),
        onDone: () => _dropSub(sessionId),
        cancelOnError: true,
      );
      _subs[sessionId] = sub;
    } catch (_) {
      // 这个会话的流开不起来：等下一轮 monitor 再试，不把整页拖垮。
      return;
    }
  }

  void _dropSub(String sessionId) {
    _subs.remove(sessionId);
  }

  void _pushRecent(List<JobRow> rows) {
    final finished = rows.where((row) => !row.isActive).toList(growable: false);
    if (finished.isEmpty) return;
    for (final row in finished) {
      _recent.removeWhere(
        (old) => old.sessionId == row.sessionId && old.id == row.id,
      );
      _recent.insert(0, row);
    }
    while (_recent.length > recentLimit) {
      _recent.removeLast();
    }
  }

  void _recompute() {
    final out = <JobRow>[];
    final seen = <String>{};
    final sessionIds = <String>[
      ..._watching.where(_frames.containsKey),
      ..._frames.keys.where((id) => !_watching.contains(id)),
    ];
    for (final sessionId in sessionIds) {
      for (final row in _frames[sessionId] ?? const <JobRow>[]) {
        if (seen.add('${row.sessionId}/${row.id}')) out.add(row);
      }
    }
    for (final row in _recent) {
      if (seen.add('${row.sessionId}/${row.id}')) out.add(row);
    }
    out.sort((a, b) {
      final aRank = a.isActive ? 0 : 1;
      final bRank = b.isActive ? 0 : 1;
      if (aRank != bRank) return aRank - bRank;
      final aStart = a.startedAt?.millisecondsSinceEpoch ?? 0;
      final bStart = b.startedAt?.millisecondsSinceEpoch ?? 0;
      return bStart.compareTo(aStart);
    });
    _jobs = List<JobRow>.unmodifiable(out);
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

/// 把异常压成一句人话：宿主给的 `error.message` 已经是原话，别再包一层。
String errorText(Object error) {
  if (error is DshClientException) {
    final message = error.message;
    if (message.isNotEmpty) return message;
    return '请求失败（HTTP ${error.status ?? '?'}）';
  }
  if (error is StateError) return error.message;
  return '$error';
}
