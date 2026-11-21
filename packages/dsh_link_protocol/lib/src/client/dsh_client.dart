import 'dart:convert';
import 'dart:io' show gzip;
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
    // 下行信封的形状是 `{n, c, z?}`：`n` 是 base64url 的 nonce，`c` 是 base64 的密文+tag。
    // 两者必须拼回 `nonce||ct||tag` 才能解 —— 只取 `c` 会一直 AEAD 认证失败（实测）。
    final sealedBytes = <int>[
      ...(json['n'] is String ? base64Url.decode(base64Url.normalize(json['n'] as String)) : const <int>[]),
      ...base64.decode(c),
    ];
    final aads = <String>[
      ...extraAads,
      'v2|down|${method.toUpperCase()}|$path|${env.timestamp}|${env.nonce}',
    ];
    Object? last;
    for (final aad in aads) {
      try {
        final clear = await DshCrypto.open(
          key: keys.down,
          sealed: sealedBytes,
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

  /// 会话流：服务端是 SSE（`text/event-stream`），不是 WebSocket。
  ///
  /// 每一帧要么是明文 JSON（服务端没开逐帧封装），要么是 `{"v":2,"n":…,"c":…}`
  /// 信封。信封的 AAD 钉死了「路径 + 本次请求的 ts/nonce + 帧序号」：
  /// `v2|down|sse|<path>|<ts>|<nonce>|<seq>`，序号从 1 起、宿主自己数。
  Stream<Map<String, dynamic>> stream(String sessionId) async* {
    const path = '$_prefix/session/stream';
    final query = '?sessionId=$sessionId';
    final env = await DshEnvelope.build(
      keys: keys,
      keyId: keyId,
      method: 'GET',
      path: path,
      query: query,
      payload: const {},
    );
    final es = await transport.openEventStream(
      method: 'GET',
      path: path,
      query: query,
      headers: env.headers,
    );
    if (!es.ok) {
      await es.close();
      throw DshClientException('stream failed', status: es.status);
    }
    final buffer = StringBuffer();
    var seq = 0;
    try {
      await for (final line in es.lines) {
        if (line.isEmpty) {
          final raw = buffer.toString();
          buffer.clear();
          if (raw.isEmpty) continue;
          final frame = await _openFrame(
            raw,
            path: path,
            timestamp: env.timestamp,
            nonce: env.nonce,
            seq: ++seq,
          );
          if (frame != null) yield frame;
          continue;
        }
        // SSE 记录：`id:` / `retry:` / 注释行都不进消息模型，只有 `data:` 是正文。
        if (line.startsWith('data:')) {
          buffer.write(line.substring(5).trimLeft());
        }
      }
    } finally {
      await es.close();
    }
  }

  /// 解一帧：`{v:2,n,c,z?}` → 明文 JSON；不是信封就只做 JSON 解析。
  Future<Map<String, dynamic>?> _openFrame(
    String raw, {
    required String path,
    required String timestamp,
    required String nonce,
    required int seq,
  }) async {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) return null;
    final c = json['c'];
    if (c is! String) return json;
    final sealed = <int>[
      ...(json['n'] is String
          ? base64Url.decode(base64Url.normalize(json['n'] as String))
          : const <int>[]),
      ...base64.decode(c),
    ];
    final clear = await DshCrypto.open(
      key: keys.down,
      sealed: sealed,
      aad: 'v2|down|sse|$path|$timestamp|$nonce|$seq',
    );
    // `z=g` 表示这段明文先压过（大帧才压）；不压的帧是原样 JSON。
    final bytes = json['z'] == 'g' ? gzip.decode(clear) : clear;
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : null;
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
