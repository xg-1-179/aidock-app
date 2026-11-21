import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 协议 v2 的全部密码学原语。字节级规则见 docs/PROTOCOL-NOTES.md。
class DshCrypto {
  DshCrypto._();

  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final AesGcm _gcm = AesGcm.with256bits();
  static final Hmac _hmac = Hmac.sha256();

  /// 从二维码票据派生配对密钥：salt = instanceId 的 UTF-8 字节。
  static Future<Uint8List> pairKey(List<int> ticket, String instanceId) async {
    final key = await _hkdf.deriveKey(
      secretKey: SecretKey(ticket),
      nonce: utf8.encode(instanceId),
      info: utf8.encode('dsh-pair-v2'),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// 从 deviceKey 派生会话上下行与签名密钥。
  static Future<DshSessionKeys> sessionKeys(List<int> deviceKey) async {
    Future<Uint8List> derive(String info) async {
      final key = await _hkdf.deriveKey(
        secretKey: SecretKey(deviceKey),
        nonce: const <int>[],
        info: utf8.encode(info),
      );
      return Uint8List.fromList(await key.extractBytes());
    }

    return DshSessionKeys(
      up: await derive('dsh-v2|up'),
      down: await derive('dsh-v2|down'),
      sig: await derive('dsh-v2|sig'),
    );
  }

  /// 封装：nonce(12) || ciphertext || tag(16)。
  static Future<Uint8List> seal({
    required List<int> key,
    required List<int> nonce,
    required String aad,
    required List<int> plaintext,
  }) async {
    final box = await _gcm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode(aad),
    );
    final out = BytesBuilder();
    out.add(box.nonce);
    out.add(box.cipherText);
    out.add(box.mac.bytes);
    return out.toBytes();
  }

  /// 解封。认证失败必须整条失败，绝不返回半截明文。
  static Future<Uint8List> open({
    required List<int> key,
    required List<int> sealed,
    required String aad,
  }) async {
    if (sealed.length < 28) {
      throw const DshCryptoException('密文长度不足 28 字节');
    }
    final nonce = sealed.sublist(0, 12);
    final cipherText = sealed.sublist(12, sealed.length - 16);
    final tag = sealed.sublist(sealed.length - 16);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(tag));
    final clear = await _gcm.decrypt(
      box,
      secretKey: SecretKey(key),
      aad: utf8.encode(aad),
    );
    return Uint8List.fromList(clear);
  }

  static Future<String> sign(List<int> sigKey, String canonical) async {
    final mac = await _hmac.calculateMac(
      utf8.encode(canonical),
      secretKey: SecretKey(sigKey),
    );
    return _b64u(mac.bytes);
  }

  static String _b64u(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

class DshSessionKeys {
  const DshSessionKeys({required this.up, required this.down, required this.sig});

  final Uint8List up;
  final Uint8List down;
  final Uint8List sig;
}

class DshCryptoException implements Exception {
  const DshCryptoException(this.message);

  final String message;

  @override
  String toString() => 'DshCryptoException: $message';
}
