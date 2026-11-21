import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:dsh_link_protocol/src/sha256.dart';
import 'package:test/test.dart';

List<int> _hex(String s) => List<int>.generate(
      s.length ~/ 2,
      (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16),
    );
String _toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
String _b64(List<int> b) => base64.encode(b);
String _b64u(List<int> b) => base64Url.encode(b).replaceAll('=', '');
Uint8List _u8(List<int> b) => Uint8List.fromList(b);

void main() {
  final vectors = jsonDecode(
    File('spec/e2ee-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final input = vectors['inputs'] as Map<String, dynamic>;
  final exp = vectors['expect'] as Map<String, dynamic>;

  test('pairKey 派生', () async {
    final key = await DshCrypto.pairKey(_hex(input['ticket']), input['instanceId']);
    expect(_toHex(key), exp['pairKey']);
  });

  test('会话密钥派生（up/down/sig）', () async {
    final keys = await DshCrypto.sessionKeys(_hex(input['deviceKey']));
    expect(_toHex(keys.up), exp['keyUp']);
    expect(_toHex(keys.down), exp['keyDown']);
    expect(_toHex(keys.sig), exp['keySig']);
  });

  test('配对请求封包', () async {
    final pairKey = await DshCrypto.pairKey(_hex(input['ticket']), input['instanceId']);
    final sealed = await DshCrypto.seal(
      key: pairKey,
      nonce: _hex(input['pairNonce']),
      aad: 'pair|v2|${input['instanceId']}',
      plaintext: utf8.encode(input['pairPlain'] as String),
    );
    expect(_toHex(sealed), exp['pairSealed']);

    final opened = await DshCrypto.open(
      key: pairKey,
      sealed: sealed,
      aad: 'pair|v2|${input['instanceId']}',
    );
    expect(utf8.decode(opened), input['pairPlain']);
  });

  test('上行封包 + 下行封包 + 私密参数封包', () async {
    final keys = await DshCrypto.sessionKeys(_hex(input['deviceKey']));
    final method = input['requestMethod'] as String;
    final path = input['requestPath'] as String;
    final ts = input['requestTs'] as int;
    final nonce = _hex(input['bodyNonce']);
    final nonceB64u = _b64u(nonce);

    final up = await DshCrypto.seal(
      key: keys.up,
      nonce: nonce,
      aad: 'v2|up|$method|$path',
      plaintext: utf8.encode(input['bodyPlain'] as String),
    );
    expect(_toHex(up), exp['upSealed']);

    final down = await DshCrypto.seal(
      key: keys.down,
      nonce: _hex(input['downNonce']),
      aad: 'v2|down|$method|$path|$ts|$nonceB64u',
      plaintext: utf8.encode(input['responsePlain'] as String),
    );
    expect(_toHex(down), exp['downSealed']);

    final params = await DshCrypto.seal(
      key: keys.up,
      nonce: _hex(input['paramsNonce']),
      aad: 'v2|params|$ts|$nonceB64u',
      plaintext: utf8.encode(input['paramsPlain'] as String),
    );
    expect(_toHex(params), exp['paramsSealed']);
  });

  test('签名原文与签名', () async {
    final keys = await DshCrypto.sessionKeys(_hex(input['deviceKey']));
    final envelopeJson = jsonEncode({'v': 2, 'c': exp['upSealed']}.map(
      (k, v) => MapEntry(k, v as String),
    ));
    // 官方向量里的 c 是 base64（不是 hex）——用真实封包重算一次更贴近实现。
    final up = _hex(exp['upSealed'] as String);
    final body = jsonEncode({'v': 2, 'c': _b64(up)});
    expect(envelopeJson, isNotEmpty);

    final bodyHash = _toHex(Sha256.hash(utf8.encode(body)));
    final canonical = [
      'v2',
      input['requestMethod'],
      input['requestPath'],
      input['requestQuery'],
      '${input['requestTs']}',
      _b64u(_hex(input['bodyNonce'])),
      bodyHash,
    ].join('\n');
    expect(canonical, exp['canonical']);
    expect(await DshCrypto.sign(keys.sig, canonical), exp['signature']);
  });

  test('信封 build 产出的头与体可被同一套规则验签', () async {
    final keys = await DshCrypto.sessionKeys(_hex(input['deviceKey']));
    final env = await DshEnvelope.build(
      keys: keys,
      keyId: '0011223344556677',
      method: 'POST',
      path: '/api/mobile/v1/session/send',
      query: '?fresh=1',
      payload: const {'sessionId': 'abc'},
      timestamp: input['requestTs'] as int,
      nonce: _u8(_hex(input['bodyNonce'])),
    );
    expect(env.headers['X-Dsh-Nonce'], _b64u(_hex(input['bodyNonce'])));
    expect(env.headers['X-Dsh-Sig'], exp['signature']);
    expect(env.nonce, _b64u(_hex(input['bodyNonce'])));
  });
}
