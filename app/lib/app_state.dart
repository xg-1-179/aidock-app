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
  SessionItem({required this.id, required this.title, this.subtitle = '', this.updatedAt = 0});
  final String id;
  String title;
  String subtitle;
  int updatedAt;
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

  final List<SessionItem> sessions = [];
  final List<ChatMessage> messages = [];

  String? openSessionId;
  bool streamingNow = false;
  StreamSubscription<Map<String, dynamic>>? _sub;

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

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static String _hex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  Future<void> connect(String rawHost, String code) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final base = normalizeHost(rawHost);
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
              subtitle: '${e['summary'] ?? e['lastMessage'] ?? e['workspace'] ?? ''}',
              updatedAt: (e['updatedAt'] ?? e['ts'] ?? 0) is int
                  ? (e['updatedAt'] ?? e['ts'] ?? 0) as int
                  : 0,
            )).where((e) => e.id.isNotEmpty));
      error = null;
    } catch (e) {
      error = '读取会话失败：$e';
    }
    notifyListeners();
  }

  Future<void> openSession(SessionItem item) async {
    await _sub?.cancel();
    _sub = null;
    openSessionId = item.id;
    messages
      ..clear()
      ..add(ChatMessage(role: 'system', text: '已打开「${item.title}」'));
    notifyListeners();
    final c = _client;
    if (c == null) return;
    _sub = c.stream(item.id).listen(_onFrame, onError: (Object e) {
      streamingNow = false;
      messages.add(ChatMessage(role: 'system', text: '流断开：$e'));
      notifyListeners();
    }, onDone: () {
      streamingNow = false;
      notifyListeners();
    });
  }

  void closeSession() {
    _sub?.cancel();
    _sub = null;
    openSessionId = null;
    messages.clear();
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
