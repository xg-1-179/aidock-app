import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'crypto.dart';
import 'sha256.dart';

/// 一次 v2 请求的加密信封：请求体 `{"v":2,"c":"<b64>"}` + 五个签名头。
class DshEnvelope {
  const DshEnvelope({
    required this.headers,
    required this.body,
    required this.nonce,
    required this.timestamp,
  });

  final Map<String, String> headers;
  final String body;

  /// 本次请求的 nonce（base64url），下行 AAD 要用它。
  final String nonce;

  /// 本次请求的时间戳（毫秒），下行 AAD 要用它。
  final int timestamp;

  /// 组装一次请求。
  ///
  /// [path] 从 `/api/mobile/v1/` 起算；[query] 含前导 `?`，没有则传空串。
  static Future<DshEnvelope> build({
    required DshSessionKeys keys,
    required String keyId,
    required String method,
    required String path,
    required String query,
    required Map<String, dynamic> payload,
    int? timestamp,
    Uint8List? nonce,
  }) async {
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final n = nonce ?? _randomNonce();
    final nB64u = _b64u(n);

    final clear = utf8.encode(jsonEncode(payload));
    final sealed = await DshCrypto.seal(
      key: keys.up,
      nonce: n,
      aad: 'v2|up|${method.toUpperCase()}|$path',
      plaintext: clear,
    );
    final c = base64.encode(sealed);
    final body = jsonEncode({'v': 2, 'c': c});

    // 注意：哈希的是信封 JSON 文本，不是密文字节。
    final bodyHash = _hex(_sha256(utf8.encode(body)));
    final canonical = [
      'v2',
      method.toUpperCase(),
      path,
      // 服务端按线上原样签（QUERY 含前导 `?`，见 lib/shared/e2ee-request.js 的 signedQuery），
      // 这里必须一字不差地跟着签，去掉问号会直接 e2ee-bad-signature。
      query,
      '$ts',
      nB64u,
      bodyHash,
    ].join('\n');
    final sig = await DshCrypto.sign(keys.sig, canonical);

    return DshEnvelope(
      headers: {
        'X-Dsh-Proto': '2',
        'X-Dsh-Key-Id': keyId,
        'X-Dsh-Ts': '$ts',
        'X-Dsh-Nonce': nB64u,
        'X-Dsh-Sig': sig,
        'Content-Type': 'application/json',
      },
      body: body,
      nonce: nB64u,
      timestamp: ts,
    );
  }

  /// 解下行响应：密文即 `{"v":2,"c":"..."}` 里的 `c`。
  static Future<Map<String, dynamic>> openResponse({
    required DshSessionKeys keys,
    required String method,
    required String path,
    required int requestTimestamp,
    required String requestNonce,
    required String sealedBase64,
  }) async {
    final aad =
        'v2|down|${method.toUpperCase()}|$path|$requestTimestamp|$requestNonce';
    final clear = await DshCrypto.open(
      key: keys.down,
      sealed: base64.decode(sealedBase64),
      aad: aad,
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  static Uint8List _randomNonce() {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(12, (_) => rnd.nextInt(256)));
  }

  static List<int> _sha256(List<int> data) => Sha256.hash(data);

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _b64u(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
