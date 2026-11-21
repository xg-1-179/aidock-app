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

/// 已可信的通道：配对成功后拿到的东西，调用方拿它换会话列表、发消息。
class DshPairResult {
  DshPairResult({required this.client, required this.instanceId, this.grant = const {}});
  final DshClient client;
  final String instanceId;

  /// 宿主在配对回包里封回来的授权信息（`token`、`deviceCredential`、`permissions`、
  /// `credentialExpiresAt`…）。App 要拿它做「免码重连」，所以原样留着。
  final Map<String, dynamic> grant;
}

class DshClient {
  DshClient({
    required this.baseUrl,
    required this.transport,
    required this.keys,
    required this.keyId,
    this.instanceId,
    this.authToken,
    this.deviceCredential,
  });

  final Uri baseUrl;
  final DshTransport transport;
  final DshSessionKeys keys;
  final String keyId;
  final String? instanceId;

  /// 配对回包里那枚访问令牌。**每条业务请求都要带 `Authorization: Bearer <token>`**：
  /// 只带签名不带令牌会被宿主当「没有移动 token」直接 401，症状是能配对、什么也打不开。
  final String? authToken;

  /// 宿主另外发的设备凭据（部分版本用 `X-Dsh-Device-Credential` 认设备）。
  final String? deviceCredential;

  static const _prefix = '/api/mobile/v1';

  /// 把配对拿到的令牌贴到请求头上；没有令牌时原样返回（配对前的请求）。
  Map<String, String> _withAuth(Map<String, String> headers) {
    final out = Map<String, String>.from(headers);
    final token = authToken;
    if (token != null && token.isNotEmpty) out['Authorization'] = 'Bearer $token';
    final credential = deviceCredential;
    if (credential != null && credential.isNotEmpty) {
      out['X-Dsh-Device-Credential'] = credential;
    }
    return out;
  }

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
    // 授权信息是**封在 sealed 里**回来的：token、deviceCredential、permissions 都在里面，
    // 不解包就只能带着签名去撞每条接口的 401。
    var grant = const <String, dynamic>{};
    final sealedB64 = json['sealed'];
    if (sealedB64 is String && sealedB64.isNotEmpty) {
      final clear = await DshCrypto.open(
        key: pairKey,
        sealed: base64Url.decode(base64Url.normalize(sealedB64)),
        aad: aad,
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is Map<String, dynamic>) grant = decoded;
    }
    final keys = await DshCrypto.sessionKeys(deviceKey);
    return DshPairResult(
      client: DshClient(
        baseUrl: baseUrl,
        transport: transport,
        keys: keys,
        keyId: keyId,
        instanceId: instanceId,
        authToken: grant['token'] is String ? grant['token'] as String : null,
        deviceCredential:
            grant['deviceCredential'] is String ? grant['deviceCredential'] as String : null,
      ),
      instanceId: instanceId,
      grant: grant,
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
      headers: _withAuth(env.headers),
      body: env.body,
    );
    if (!res.ok) {
      throw DshClientException(_errorMessageOf(res), status: res.status, body: res.body);
    }
    return _decode(res.body, method: method, path: path, env: env);
  }

  /// 失败响应里宿主会把话写在 `{"ok":false,"error":{"code","message"}}`；
  /// 原样把 `request failed` 抛给用户等于什么都没说（尤其是 401/403 这两类）。
  static String _errorMessageOf(DshHttpResponse res) {
    try {
      final j = jsonDecode(res.body);
      if (j is Map) {
        final err = j['error'];
        if (err is Map && err['message'] is String && '${err['message']}'.isNotEmpty) {
          return '${err['message']}';
        }
        if (err is String && err.isNotEmpty) return err;
        if (j['message'] is String && '${j['message']}'.isNotEmpty) return '${j['message']}';
      }
    } catch (_) {
      // 非 JSON（网关页之类）：退回通用文案。
    }
    return 'request failed';
  }

  Future<Map<String, dynamic>> _decode(
    String body, {
    required String method,
    required String path,
    required DshEnvelope env,
    List<String> extraAads = const [],
  }) async {
    final dynamic json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      // 空体或非 JSON（网关页、401 不带体）：按状态码抛，而不是让 FormatException 冒上去。
      throw DshClientException('响应不是 JSON', body: body);
    }
    if (json is! Map<String, dynamic>) {
      throw DshClientException('unexpected body shape');
    }
    // §8.5：列表类响应把元数据留在外层、正文塞进 `env` 信封
    // （`{ok, revision, generatedAt, env:{v,n,c}}`）。外层本身不是信封，
    // 所以这里要认出 `env` 并把里面那层按同样的下行 AAD 解开，再与元数据合并。
    final inner = json['env'];
    final Map<String, dynamic>? sealedWire = inner is Map<String, dynamic> ? inner : null;
    final wire = sealedWire ?? json;
    final c = wire['c'];
    if (c is! String) return json; // 明文响应（health/status 之类）
    // 下行信封的形状是 `{n, c, z?}`：`n` 是 base64url 的 nonce，`c` 是 base64 的密文+tag。
    // 两者必须拼回 `nonce||ct||tag` 才能解 —— 只取 `c` 会一直 AEAD 认证失败（实测）。
    final sealedBytes = <int>[
      ...(wire['n'] is String ? base64Url.decode(base64Url.normalize(wire['n'] as String)) : const <int>[]),
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
        final decoded = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
        if (sealedWire == null) return decoded;
        // 外层只留能给的元数据（ok / revision / generatedAt），正文在 env 里。
        final merged = <String, dynamic>{...json, ...decoded};
        merged.remove('env');
        return merged;
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
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw DshClientException('响应不是 JSON（HTTP ${res.status}）', status: res.status, body: res.body);
    }
  }

  /// 会话列表。
  Future<List<Map<String, dynamic>>> sessions({String query = ''}) async {
    // AIDock 宿主把会话清单与历史挂在自己的别名路径上（`link/` 前缀），
    // 这两条与旧的 `/sessions`、`/session/messages` 是同一份实现，只是后者在插件的
    // 热重载里换不掉（旧 handler 先注册先命中），别名路径没有这个问题。
    final r = await call('GET', '$_prefix/link/sessions', query: query);
    final list = r['sessions'] ?? r['items'] ?? r['data'];
    if (list is List) {
      return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  /// 会话历史：进入对话先拉最近 N 条（`thin=1` 让宿主按轮裁掉过程块）。
  /// 取一张历史图（`blocks` 里只带 `attachmentId`，字节要单独要）。
  ///
  /// 宿主回 `{ok, mediaType, data:<base64>, name?}`；附件被会话清理掉时回 404。
  Future<Map<String, dynamic>> attachment({
    required String sessionId,
    required String attachmentId,
  }) =>
      call('POST', '$_prefix/link/session/attachment',
          payload: {'sessionId': sessionId, 'attachmentId': attachmentId});

  Future<List<Map<String, dynamic>>> messages(
    String sessionId, {
    int limit = 50,
    int? beforeSeq,
    bool thin = true,
  }) async {
    final q = StringBuffer('?sessionId=${Uri.encodeQueryComponent(sessionId)}')
      ..write('&limit=$limit');
    if (beforeSeq != null) q.write('&beforeSeq=$beforeSeq');
    if (thin && beforeSeq == null) q.write('&thin=1');
    final r = await call('GET', '$_prefix/link/messages', query: q.toString());
    final list = r['messages'] ?? r['items'] ?? r['data'];
    if (list is List) {
      return list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  /// 审批卡作答：`outcome` 取 `allowed-once` / `denied` / `allowed-class`。
  Future<Map<String, dynamic>> respondApproval({
    required String rpcId,
    required String sessionId,
    required String approvalId,
    required String outcome,
    String reason = '',
  }) {
    return call(
      'POST',
      '$_prefix/link/approval/respond',
      payload: {
        'rpcId': rpcId,
        'sessionId': sessionId,
        'approvalId': approvalId,
        'outcome': outcome,
        if (reason.isNotEmpty) 'reason': reason,
      },
    );
  }

  /// 发一条消息。`fresh=1` 表示这是新一轮（不追加到上一条助手回复）。
  Future<Map<String, dynamic>> sendMessage(
    String sessionId,
    String text, {
    bool fresh = false,
  }) =>
      call(
        'POST',
        '$_prefix/link/session/send',
        query: fresh ? '?fresh=1' : '',
        payload: {'sessionId': sessionId, 'text': text},
      );

  /// 发送「内容块」消息（文本 + 图片等）。
  ///
  /// 宿主 `handleSend` 两种写法都认：`{sessionId, text}` 或 `{sessionId, content}`。
  /// 带图时必须走 `content`，图片块形状为
  /// `{type:'image', data:<base64>, mediaType:'image/jpeg', name?}`（宿主见 `data` 就内联，
  /// 不再去找 `uploadId`）。宿主明文上限 8MB、线上 10.7MB，调用方要先把图压到 1MB 级。
  Future<Map<String, dynamic>> sendContent(
    String sessionId,
    List<Map<String, dynamic>> content, {
    bool fresh = false,
  }) =>
      call(
        'POST',
        '$_prefix/link/session/send',
        query: fresh ? '?fresh=1' : '',
        payload: {'sessionId': sessionId, 'content': content},
      );

  /// 在电脑上新建一个会话。
  ///
  /// 宿主要求落点二者之一：`workspaceId`（已登记工作区）或 `cwd`（必须在某个已登记
  /// 工作区之内，否则 400 `bad-request`）。都不给就落到宿主的默认工作区，手机侧
  /// 只想要「点一下就开始聊」时走这条。
  Future<Map<String, dynamic>> newSession({
    String? workspaceId,
    String? cwd,
    bool isolate = false,
  }) =>
      call('POST', '$_prefix/link/session/new', payload: {
        if (workspaceId != null && workspaceId.isNotEmpty) 'workspaceId': workspaceId,
        if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
        if (isolate) 'isolate': true,
      });

  /// 打断当前正在跑的回合。
  Future<Map<String, dynamic>> stop(String sessionId) =>
      call('POST', '$_prefix/link/session/stop', payload: {'sessionId': sessionId});

  /// 回答宿主抛来的提问卡（`ask_user_question`）。
  ///
  /// `answers` 每题恰好一条：`{id, selected:[label...], custom?}`。宿主按题数严格校验，
  /// 少一条或多一条都回 400（见 `lib/mobile/questions.js` 的 `normalizeAnswers`）。
  Future<Map<String, dynamic>> respondQuestion({
    required String rpcId,
    required String sessionId,
    required List<Map<String, dynamic>> answers,
  }) =>
      call('POST', '$_prefix/link/question/respond', payload: {
        'rpcId': rpcId,
        'sessionId': sessionId,
        'answer': {'answers': answers},
      });

  /// 这条会话现在能用哪些模型（provider / model / 推理档位）。
  Future<Map<String, dynamic>> models(String sessionId) => call(
        'GET',
        '$_prefix/link/session/models',
        query: '?sessionId=${Uri.encodeQueryComponent(sessionId)}',
      );

  /// 只切「当前会话」的模型，电脑端默认不变。
  Future<Map<String, dynamic>> selectModel(
    String sessionId,
    String provider,
    String model, {
    String? reasoningEffort,
  }) =>
      call('POST', '$_prefix/link/session/select-model', payload: {
        'sessionId': sessionId,
        'provider': provider,
        'model': model,
        if (reasoningEffort != null && reasoningEffort.isNotEmpty) 'reasoningEffort': reasoningEffort,
      });

  /// 斜杠命令表。
  Future<List<Map<String, dynamic>>> commands(String sessionId) async {
    final r = await call(
      'GET',
      '$_prefix/link/commands',
      query: '?sessionId=${Uri.encodeQueryComponent(sessionId)}',
    );
    final raw = r['commands'] ?? r['items'] ?? r['data'];
    if (raw is List) return raw.whereType<Map<String, dynamic>>().toList();
    return const <Map<String, dynamic>>[];
  }

  /// 电脑上可用的智能体预设。
  Future<List<Map<String, dynamic>>> agentPresets() async {
    final r = await call('GET', '$_prefix/link/agent-presets');
    final raw = r['presets'] ?? r['items'] ?? r['data'];
    if (raw is List) return raw.whereType<Map<String, dynamic>>().toList();
    return const <Map<String, dynamic>>[];
  }

  /// 会话流：服务端是 SSE（`text/event-stream`），不是 WebSocket。
  ///
  /// 每一帧要么是明文 JSON（服务端没开逐帧封装），要么是 `{"v":2,"n":…,"c":…}`
  /// 信封。信封的 AAD 钉死了「路径 + 本次请求的 ts/nonce + 帧序号」：
  /// `v2|down|sse|<path>|<ts>|<nonce>|<seq>`，序号从 1 起、宿主自己数。
  Stream<Map<String, dynamic>> stream(String sessionId) async* {
    const path = '$_prefix/link/session/stream';
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
      headers: _withAuth(env.headers),
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
    required int timestamp,
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
