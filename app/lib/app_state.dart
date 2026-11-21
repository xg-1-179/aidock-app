import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/foundation.dart';

class ChatMessage {
  ChatMessage({required this.role, required this.text, this.streaming = false});
  final String role;
  String text;
  bool streaming;
}

class SessionItem {
  SessionItem({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.updatedAt = 0,
    this.running = false,
    this.pending = false,
    this.failed = false,
    this.pinned = false,
  });
  final String id;
  String title;
  String subtitle;
  int updatedAt;
  bool running;
  bool pending;
  bool failed;
  bool pinned;
}

class ApprovalCard {
  ApprovalCard({
    required this.rpcId,
    required this.sessionId,
    required this.approvalId,
    this.toolName = '',
    this.reason = '',
    this.fact = '',
    this.classLabel = '',
    this.command = '',
    this.rememberable = false,
  });

  final String rpcId;
  final String sessionId;
  final String approvalId;
  final String toolName;
  final String reason;
  final String fact;
  final String classLabel;
  final String command;
  final bool rememberable;

  String get headline {
    if (reason.isNotEmpty) return reason;
    if (toolName.isNotEmpty) return '工具 $toolName 请求越权执行';
    return '有一项操作在等你的许可';
  }
}

class AppState extends ChangeNotifier {
  IoDshTransport? _transport;

  DshClient? _client;
  DshClient? get client => _client;

  String? instanceId;
  String hostLabel = '';
  String? error;
  bool busy = false;
  bool paired = false;

  String connectionKind = '';

  /// 上一次多路探测的结果（连接诊断用）：每条是 `地址 → 成功/失败原因`。
  final List<String> probeLog = [];

  final List<SessionItem> sessions = [];
  final List<ChatMessage> messages = [];
  final List<ApprovalCard> approvals = [];

  String? openSessionId;
  bool streamingNow = false;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _watchdog;
  Timer? _retryTimer;
  DateTime _lastFrameAt = DateTime.now();
  int _retryCount = 0;
  /// 断线自动重连中。界面据此画一条「正在重连」的提示，不打断正在看的消息。
  bool reconnecting = false;

  static Uri normalizeHost(String raw) {
    var s = raw.trim();
    if (s.isEmpty) throw const FormatException('请输入电脑地址');
    if (!s.contains('://')) s = 'http://$s';
    final uri = Uri.parse(s);
    if (uri.host.isEmpty) throw const FormatException('地址格式不正确');
    if (!uri.hasPort) {
      return Uri.parse('${uri.scheme}://${uri.host}:41873');
    }
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
  }

  /// 把用户填的一串地址拆成候选通道：逗号/空格/换行分隔，私网段算 lan、其余算 wan。
  ///
  /// 设计原则见 docs/CONNECTIVITY.md：没有任何一条通道是"必须存在"的，
  /// 全都摆在同一层并行探测，谁先答话就用谁。
  static List<Candidate> parseCandidates(String raw) {
    final parts = raw
        .split(RegExp(r'[,，\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    final out = <Candidate>[];
    final seen = <String>{};
    for (final part in parts) {
      final base = normalizeHost(part);
      final key = base.toString();
      if (!seen.add(key)) continue;
      out.add(Candidate(
        id: '${base.host}:${base.port}',
        baseUrl: base,
        kind: _kindOf(base.host),
      ));
    }
    return out;
  }

  static CandidateKind _kindOf(String host) {
    final ip = RegExp(r'^(\d{1,3})\.(\d{1,3})\.');
    final m = ip.firstMatch(host);
    if (m != null) {
      final a = int.parse(m.group(1)!);
      final b = int.parse(m.group(2)!);
      if (a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31)) {
        return CandidateKind.lan;
      }
    }
    if (host.endsWith('.local') || host == 'localhost') return CandidateKind.lan;
    return CandidateKind.wan;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static String _hex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  Future<void> connect(String rawHost, String code) async {
    busy = true;
    error = null;
    probeLog.clear();
    notifyListeners();
    try {
      final candidates = parseCandidates(rawHost);
      if (candidates.isEmpty) throw const FormatException('请输入电脑地址');
      // 多路并行探测：每条候选 3 秒超时，先答话的先用，其余继续收集供诊断。
      final probe = ConnectionProbe(
        timeout: const Duration(seconds: 3),
        probe: (candidate, timeout) async {
          final t = IoDshTransport(candidate.baseUrl, timeout: timeout);
          try {
            final r = await t.send(
              method: 'GET',
              path: '/api/mobile/v1/link/info',
              query: '',
              headers: const {},
              body: '',
            );
            if (!r.ok) throw StateError('HTTP ${r.status}');
          } finally {
            t.close();
          }
        },
      );
      final report = await probe.race(candidates);
      for (final ok in report.successes) {
        probeLog.add('${ok.candidate.id} 可用 ${ok.latency.inMilliseconds}ms');
      }
      for (final bad in report.failures) {
        probeLog.add('${bad.candidate.id} 失败：${bad.error}');
      }
      final winner = report.winner;
      if (winner == null) {
        throw DshClientException('这些地址都连不上（${candidates.length} 条，均超时）');
      }
      final base = winner.candidate.baseUrl;
      connectionKind = winner.candidate.kind.name;
      hostLabel = '${base.host}:${base.port}';
      _transport?.close();
      final transport = IoDshTransport(base);
      _transport = transport;
      final info = await transport.send(
        method: 'GET',
        path: '/api/mobile/v1/link/info',
        query: '',
        headers: const {},
        body: '',
      );
      if (!info.ok) {
        throw DshClientException('电脑没有响应', status: info.status, body: info.body);
      }
      final meta = jsonDecode(info.body) as Map<String, dynamic>;
      if (meta['ok'] != true) {
        throw DshClientException('${meta['error'] ?? '电脑没有就绪'}');
      }
      instanceId = '${meta['instanceId']}';
      final deviceKey = _randomBytes(32);
      final keyId = _hex(_randomBytes(8));
      final result = await DshClient.pair(
        baseUrl: base,
        transport: transport,
        ticket: utf8.encode(code.trim()),
        instanceId: instanceId!,
        deviceKey: deviceKey,
        keyId: keyId,
        pairingCode: code.trim(),
        pairPath: '/api/mobile/v1/link/pair',
      );
      _client = result.client;
      paired = true;
      connectionKind = '${meta['transport'] ?? 'direct'}';
      await refreshSessions();
    } on DshClientException catch (e) {
      error = e.status == 401 ? '连接码不对，或已经过期' : '${e.message}（HTTP ${e.status}）';
      paired = false;
    } on FormatException catch (e) {
      error = e.message;
      paired = false;
    } catch (e) {
      error = '连不上：$e';
      paired = false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }


  static int _intOf(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

  /// 列表行第二行：优先用宿主给的最后一条消息预览（`lastMessage.text`），
  /// 其次 lastTurn 的失败原因，最后退回 cwd。
  static String _previewOf(Map<String, dynamic> e) {
    final last = e['lastMessage'];
    if (last is Map) {
      final text = '${last['text'] ?? ''}'.trim();
      if (text.isNotEmpty) {
        return text.replaceAll('\n', ' ');
      }
    }
    final turn = e['lastTurn'];
    final err = e['lastTurnError'];
    if (err != null && err != false) {
      return '上一轮失败：$err';
    }
    if (turn is Map && turn['at'] != null) {
      return '最近一轮已结束';
    }
    final cwd = '${e['cwd'] ?? ''}'.trim();
    if (cwd.isNotEmpty) return cwd;
    return '';
  }

  Future<void> refreshSessions() async {
    final c = _client;
    if (c == null) return;
    try {
      final rows = await c.sessions();
      sessions
        ..clear()
        ..addAll(rows.map((e) => SessionItem(
              id: '${e['id'] ?? e['sessionId'] ?? e['session_id'] ?? ''}',
              title: '${e['title'] ?? e['name'] ?? '未命名会话'}',
              subtitle: _previewOf(e),
              updatedAt: _intOf(e['updatedAt'] ?? e['ts']),
              running: e['running'] == true,
              pending: e['pendingInteraction'] != null && e['pendingInteraction'] != false,
              failed: e['lastTurnError'] != null && e['lastTurnError'] != false,
              pinned: e['pinned'] == true,
            )).where((e) => e.id.isNotEmpty));
      error = null;
    } on DshClientException catch (e) {
      error = e.status == 500 && (e.body ?? '').contains('apiProxy')
          ? '电脑端插件还没加载完（缺少宿主接口），需要重启一次 DSH 再连'
          : '读取会话失败：${e.message}（HTTP ${e.status}）';
    } catch (e) {
      error = '读取会话失败：$e';
    }
    notifyListeners();
  }

  Future<void> openSession(SessionItem item) async {
    await _sub?.cancel();
    _sub = null;
    openSessionId = item.id;
    messages.clear();
    approvals.clear();
    notifyListeners();
    final c = _client;
    if (c == null) return;
    // 先补历史，再挂流：流只负责「打开之后」发生的事，历史由 /session/messages 给。
    try {
      final rows = await c.messages(item.id, limit: 40);
      for (final row in rows) {
        final role = '${row['role'] ?? row['author'] ?? ''}';
        final text = _textOfMessage(row);
        if (text.isEmpty) continue;
        final mine = role == 'user' || role == 'human';
        messages.add(ChatMessage(role: mine ? 'user' : 'assistant', text: text));
      }
      if (messages.isEmpty) {
        messages.add(ChatMessage(role: 'system', text: '这个会话还没有消息'));
      }
      error = null;
    } catch (e) {
      messages.add(ChatMessage(role: 'system', text: '历史读取失败：$e'));
    }
    notifyListeners();
    _attachStream(c, item.id);
  }

  /// 挂上会话流，并在断开时自己重连。
  ///
  /// 手机侧的断线原因太多（切网、锁屏、中转抖动、宿主换代），指望一条 SSE 从头活到尾不现实。
  /// 这里做三件事：① 掉线后按 1s/2s/4s/8s/15s 退避重连；② 40 秒没有任何帧（心跳 15 秒一发）
  /// 就当连接已死，主动断开重连；③ 重连成功后补一次历史，把断线期间漏掉的消息接回来。
  void _attachStream(DshClient c, String sessionId) {
    _lastFrameAt = DateTime.now();
    _sub = c.stream(sessionId).listen((frame) {
      _lastFrameAt = DateTime.now();
      if (reconnecting) {
        reconnecting = false;
        _retryCount = 0;
        error = null;
        notifyListeners();
      }
      _onFrame(frame);
    }, onError: (Object e) {
      streamingNow = false;
      _scheduleReconnect(c, sessionId, '$e');
    }, onDone: () {
      streamingNow = false;
      _scheduleReconnect(c, sessionId, '连接已结束');
    });
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (openSessionId != sessionId) return;
      if (DateTime.now().difference(_lastFrameAt).inSeconds < 40) return;
      _retryCount = max(_retryCount, 1).toInt();
      _sub?.cancel();
      _sub = null;
      _scheduleReconnect(c, sessionId, '心跳超时');
    });
  }

  void _scheduleReconnect(DshClient c, String sessionId, String reason) {
    if (openSessionId != sessionId) return;
    _retryTimer?.cancel();
    reconnecting = true;
    streamingNow = false;
    notifyListeners();
    final shift = min(_retryCount, 4).toInt();
    final seconds = min(15, 1 << shift).toInt();
    _retryCount++;
    _retryTimer = Timer(Duration(seconds: seconds), () async {
      if (openSessionId != sessionId) return;
      try {
        await _catchUp(c, sessionId);
        _attachStream(c, sessionId);
      } catch (e) {
        if (openSessionId != sessionId) return;
        _scheduleReconnect(c, sessionId, '$e');
      }
    });
  }

  /// 重连前补历史：只把断线期间新出现的消息接到尾巴上，不重刷整段。
  Future<void> _catchUp(DshClient c, String sessionId) async {
    final rows = await c.messages(sessionId, limit: 20);
    final incoming = <ChatMessage>[];
    for (final row in rows) {
      final role = '${row['role'] ?? row['author'] ?? ''}';
      final text = _textOfMessage(row);
      if (text.isEmpty) continue;
      incoming.add(ChatMessage(role: role == 'user' || role == 'human' ? 'user' : 'assistant', text: text));
    }
    if (incoming.isEmpty) return;
    // 尾巴对齐：把已显示的最后一两条与新历史的最前一条比，避免重复插入同一段。
    final tail = messages.isEmpty ? null : messages.last.text;
    for (final m in incoming) {
      final dup = tail != null && (m.text == tail ||
          (messages.length >= 1 && messages[messages.length - 1].text == m.text));
      if (dup) continue;
      if (messages.any((x) => x.role == m.role && x.text == m.text)) continue;
      messages.add(m);
    }
    notifyListeners();
  }

  void closeSession() {
    _sub?.cancel();
    _sub = null;
    _watchdog?.cancel();
    _watchdog = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    reconnecting = false;
    _retryCount = 0;
    openSessionId = null;
    messages.clear();
    approvals.clear();
    streamingNow = false;
    notifyListeners();
  }

  /// 会话流的一帧。
  ///
  /// 宿主下发的是 `{type:'session/event', event:{type, data}}` 这样的包裹层：真正的事件类型
  /// 在内层的 `event.type` 上（`user/message`、`assistant/chunk`、`assistant/message`、
  /// `turn/end`…），正文在 `event.data` 上。心跳与收尾帧（`session/heartbeat`、
  /// `session/resync-required`）不进消息模型。
  void _onFrame(Map<String, dynamic> frame) {
    final outer = '${frame['type'] ?? ''}';
    if (outer == 'session/heartbeat') return;
    if (outer == 'session/resync-required') {
      messages.add(ChatMessage(role: 'system', text: '这一段漏了消息，正在重新同步'));
      notifyListeners();
      return;
    }
    final event = frame['event'];
    final inner = event is Map<String, dynamic> ? event : frame;
    final type = '${inner['type'] ?? ''}';
    final data = inner['data'];
    final payload = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    switch (type) {
      case 'user/message':
        final text = _textOfMessage(payload);
        if (text.isNotEmpty) messages.add(ChatMessage(role: 'user', text: text));
        break;
      case 'assistant/chunk':
        final chunk = payload['chunk'];
        if (chunk is! Map) break;
        if ('${chunk['type']}' != 'text-delta') break;
        final delta = '${chunk['text'] ?? ''}';
        if (delta.isEmpty) break;
        streamingNow = true;
        if (messages.isNotEmpty && messages.last.role == 'assistant' && messages.last.streaming) {
          messages.last.text += delta;
        } else {
          messages.add(ChatMessage(role: 'assistant', text: delta, streaming: true));
        }
        break;
      case 'assistant/message':
        final msg = payload['message'];
        final text = _textOfMessage(msg is Map<String, dynamic> ? msg : payload);
        streamingNow = false;
        if (messages.isNotEmpty && messages.last.streaming) {
          messages.last.streaming = false;
          if (text.isNotEmpty) messages.last.text = text;
        } else if (text.isNotEmpty) {
          messages.add(ChatMessage(role: 'assistant', text: text));
        }
        break;
      case 'approval/requested':
        final card = ApprovalCard(
          rpcId: '${inner['rpcId'] ?? ''}',
          sessionId: '${inner['sessionId'] ?? openSessionId ?? ''}',
          approvalId: '${inner['approvalId'] ?? ''}',
          toolName: '${inner['toolName'] ?? ''}',
          reason: '${inner['reason'] ?? ''}',
          fact: '${inner['fact'] ?? ''}',
          classLabel: '${inner['classLabel'] ?? ''}',
          command: '${inner['command'] ?? ''}',
          rememberable: inner['rememberable'] == true,
        );
        if (card.rpcId.isNotEmpty && card.approvalId.isNotEmpty) {
          approvals.removeWhere((e) => e.approvalId == card.approvalId);
          approvals.add(card);
        }
        break;
      case 'approval/resolved':
        final id = '${inner['approvalId'] ?? payload['approvalId'] ?? ''}';
        if (id.isNotEmpty) approvals.removeWhere((e) => e.approvalId == id);
        break;
      case 'turn/end':
      case 'step/end':
        streamingNow = false;
        if (messages.isNotEmpty) messages.last.streaming = false;
        break;
      default:
        break;
    }
    notifyListeners();
  }

  /// 从一条消息对象里取纯文本：`content` 可能是字符串，也可能是 `[{type:'text',text}]`。
  static String _textOfMessage(Map<String, dynamic> msg) {
    final direct = msg['text'];
    if (direct is String && direct.isNotEmpty) return direct;
    final content = msg['content'];
    if (content is String) return content;
    if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map && '${part['type']}' == 'text') {
          buffer.write('${part['text'] ?? ''}');
        }
      }
      return buffer.toString();
    }
    return '';
  }

  /// 给审批卡作答。`outcome` 取 allowed-once / denied / allowed-class。
  Future<void> respond(ApprovalCard card, String outcome) async {
    final c = _client;
    if (c == null) return;
    try {
      await c.respondApproval(
        rpcId: card.rpcId,
        sessionId: card.sessionId,
        approvalId: card.approvalId,
        outcome: outcome,
      );
      approvals.removeWhere((e) => e.approvalId == card.approvalId);
      if (outcome == 'denied') {
        messages.add(ChatMessage(role: 'system', text: '已拒绝：${card.headline}'));
      }
    } catch (e) {
      messages.add(ChatMessage(role: 'system', text: '答复失败：$e'));
    }
    notifyListeners();
  }

  Future<void> send(String text) async {
    final c = _client;
    final sid = openSessionId;
    if (c == null || sid == null || text.trim().isEmpty) return;
    messages.add(ChatMessage(role: 'user', text: text.trim()));
    streamingNow = true;
    notifyListeners();
    try {
      await c.sendMessage(sid, text.trim());
    } catch (e) {
      streamingNow = false;
      messages.add(ChatMessage(role: 'system', text: '发送失败：$e'));
      notifyListeners();
    }
  }

  Future<void> stopTurn() async {
    final c = _client;
    final sid = openSessionId;
    if (c == null || sid == null) return;
    try {
      await c.stop(sid);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    _client = null;
    _transport?.close();
    _transport = null;
    paired = false;
    sessions.clear();
    messages.clear();
    openSessionId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _transport?.close();
    super.dispose();
  }
}
