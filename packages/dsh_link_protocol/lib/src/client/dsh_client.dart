import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto.dart';
import '../envelope.dart';
import 'transport.dart';

class DshClientException implements Exception {
  DshClientException(this.message, {this.status, this.body});
  final String message;
  final int? status;
  final String? body;
  @override
  String toString() => 'DshClientException($message${status == null ? '' : ', HTTP $status'})';
}

/// 已不在信任的通道：传给 [DshTransport] 之外的调用方，用于记失败。
class DshPairResult {
  DshPairResult({required this.client, required this.instanceId});
  final DshClient client;
  final String instanceId;
}

class DshClient {
  DshClient({
    required this.baseUrl,
    required this.transport,
    required this.keys,
    required this.keyId,
    this.instanceId,
  });

  final Uri baseUrl;
  final DshTransport transport;
  final DshSessionKeys keys;
  final String keyId;
  final String? instanceId;

  static const _prefix = '/api/mobile/v1';

  /// 配对：用配对票 [ticket] 与 [instanceId] 派生 `pairKey`，把设备公钥材料送上去。
  ///
  /// 成功后返回可直接用来发请求的 [DshClient]。配对失败抛 [DshClientException]。
  static Future<DshPairResult> pair({
    required Uri baseUrl,
    required DshTransport transport,
    required List<int> ticket,
    required String instanceId,
    required Uint8List deviceKey,
    required String keyId,
    String deviceName = 'AIDock',
    String platform = 'android',
    String? pairingCode,
    String? pairPath,
  }) async {
    final pairKey = await DshCrypto.pairKey(ticket, instanceId);
    final aad = 'pair|v2|$instanceId';
    final clear = {
      'deviceKey': _b64u(deviceKey),
      'keyId': keyId,
      'device': {'name': deviceName, 'platform': platform},
    };
    final sealed = await DshCrypto.seal(
      key: pairKey,
      nonce: DshCrypto.randomNonce(),
      plaintext: utf8.encode(jsonEncode(clear)),
      aad: aad,
    );
    final body = jsonEncode(<String, dynamic>{
      'instanceId': instanceId,
      'sealed': _b64u(sealed),
      // AIDock：面板上的六位连接码既是「口令」也是派生素材，宿主用它替代二维码票据。
      if (pairingCode != null) 'code': pairingCode,
    });
    final res = await transport.send(
      method: 'POST',
      path: pairPath ?? '$_prefix/pair',
      query: '',
      headers: <String, String>{
        'Content-Type': 'application/json',
        'X-Dsh-Proto': '2',
        // AIDock：宿主用这个头把「六位连接码」换成等价于二维码票据的派生素材。
        if (pairingCode != null) 'X-Aidock-Code': pairingCode,
      },
      body: body,
    );
    if (!res.ok) {
      throw DshClientException('pair failed', status: res.status, body: res.body);
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (json['ok'] != true) {
      throw DshClientException('pair rejected: ${json['error'] ?? res.body}');
    }
    final keys = await DshCrypto.sessionKeys(deviceKey);
    return DshPairResult(
      client: DshClient(
        baseUrl: baseUrl,
        transport: transport,
        keys: keys,
        keyId: keyId,
        instanceId: instanceId,
      ),
      instanceId: instanceId,
    );
  }

  /// 通用调用：签名 → 发送 → 解密下行。
  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    String query = '',
    Map<String, dynamic>? payload,
  }) async {
    final env = await DshEnvelope.build(
      keys: keys,
      keyId: keyId,
      method: method,
      path: path,
      query: query,
      payload: payload ?? const {},
    );
    final res = await transport.send(
      method: method,
      path: path,
      query: query,
      headers: env.headers,
      body: env.body,
    );
    if (!res.ok) {
      throw DshClientException('request failed', status: res.status, body: res.body);
    }
    return _decode(res.body, method: method, path: path, env: env);
  }

  Future<Map<String, dynamic>> _decode(
    String body, {
    required String method,
    required String path,
    required DshEnvelope env,
    List<String> extraAads = const [],
  }) async {
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) {
      throw DshClientException('unexpected body shape');
    }
    final c = json['c'];
    if (c is! String) return json; // 明文响应（health/status 之类）
    final aads = <String>[
      ...extraAads,
      'v2|down|${method.toUpperCase()}|$path|${env.timestamp}|${env.nonce}',
    ];
    Object? last;
    for (final aad in aads) {
      try {
        final clear = await DshCrypto.open(
          key: keys.down,
          sealed: base64.decode(c),
          aad: aad,
        );
        return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      } catch (e) {
        last = e;
      }
    }
    throw DshClientException('cannot open response: $last');
  }

  /// 探活（明文）。
  Future<Map<String, dynamic>> health() async {
    final res = await transport.send(
      method: 'GET',
      path: '$_prefix/health',
      query: '',
      headers: const {},
      body: '',
    );
    if (!res.ok) throw DshClientException('health failed', status: res.status, body: res.body);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// 会话列表。
  Future<List<Map<String, dynamic>>> sessions({String query = ''}) async {
    final r = await call('GET', '$_prefix/sessions', query: query);
    final list = r['sessions'] ?? r['items'] ?? r['data'];
    if (list is List) {
      return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  /// 发一条消息。`fresh=1` 表示这是新一轮（不追加到上一条助手回复）。
  Future<Map<String, dynamic>> sendMessage(
    String sessionId,
    String text, {
    bool fresh = false,
  }) =>
      call(
        'POST',
        '$_prefix/session/send',
        query: fresh ? '?fresh=1' : '',
        payload: {'sessionId': sessionId, 'text': text},
      );

  /// 打断当前正在跑的回合。
  Future<Map<String, dynamic>> stop(String sessionId) =>
      call('POST', '$_prefix/session/stop', payload: {'sessionId': sessionId});

  /// 会话流：逐帧解密后交出。
  ///
  /// 帧可能是明文（传输层事件），也可能是 `{"v":2,"c":...}`；后者按
  /// [DshClient._streamAads] 里的候选 AAD 依次尝试。
  Stream<Map<String, dynamic>> stream(String sessionId) async* {
    final env = await DshEnvelope.build(
      keys: keys,
      keyId: keyId,
      method: 'GET',
      path: '$_prefix/session/stream',
      query: '?sessionId=$sessionId',
      payload: const {},
    );
    final socket = await transport.openSocket(
      path: '$_prefix/session/stream',
      query: '?sessionId=$sessionId',
      headers: env.headers,
    );
    try {
      await for (final frame in socket.frames) {
        final json = jsonDecode(frame);
        if (json is! Map<String, dynamic>) continue;
        final c = json['c'];
        if (c is! String) {
          yield json;
          continue;
        }
        yield await _decode(
          frame,
          method: 'GET',
          path: '$_prefix/session/stream',
          env: env,
          extraAads: [
            'v2|stream|$sessionId',
            'v2|down|GET|$_prefix/session/stream?sessionId=$sessionId|${env.timestamp}|${env.nonce}',
          ],
        );
      }
    } finally {
      await socket.close();
    }
  }

  static String _b64u(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

/// 生成一份新的设备密钥与 keyId（16 位小写 hex）。
Uint8List newDeviceKey() {
  final rnd = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
}

String newKeyId() {
  final rnd = Random.secure();
  return List<int>.generate(16, (_) => rnd.nextInt(16)).map((e) => e.toRadixString(16)).join();
}
