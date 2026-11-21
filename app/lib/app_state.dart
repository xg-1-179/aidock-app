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
  final IoDshTransport _transport = IoDshTransport();

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
      final info = await _transport.send(
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
        transport: _transport,
        ticket: utf8.encode(code.trim()),
        instanceId: instanceId!,
        deviceKey: deviceKey,
        keyId: keyId,
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

  void _onFrame(Map<String, dynamic> frame) {
    final type = '${frame['type'] ?? frame['t'] ?? ''}';
    final text = '${frame['text'] ?? frame['delta'] ?? frame['content'] ?? ''}';
    switch (type) {
      case 'message':
      case 'user':
        messages.add(ChatMessage(role: 'user', text: text));
        break;
      case 'delta':
      case 'assistant_delta':
        streamingNow = true;
        if (messages.isNotEmpty && messages.last.role == 'assistant' && messages.last.streaming) {
          messages.last.text += text;
        } else {
          messages.add(ChatMessage(role: 'assistant', text: text, streaming: true));
        }
        break;
      case 'done':
      case 'turn_end':
        streamingNow = false;
        if (messages.isNotEmpty && messages.last.streaming) {
          messages.last.streaming = false;
        }
        break;
      default:
        if (text.isNotEmpty) {
          messages.add(ChatMessage(role: 'assistant', text: text));
        }
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
    paired = false;
    sessions.clear();
    messages.clear();
    openSessionId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _transport.close();
    super.dispose();
  }
}
