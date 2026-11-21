import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'sha256.dart' as dshsha;

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

  /// 生成 12 字节随机 nonce；[seal] 会把它拼在密文最前面。
  static Uint8List randomNonce() {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(12, (_) => rnd.nextInt(256)));
  }

  /// 与 [open] 同义，语义上用于"配对阶段的公钥解密"，避免调用方误用会话密钥。
  static Future<Uint8List> openPublic({
    required List<int> key,
    required List<int> sealed,
    required String aad,
  }) =>
      open(key: key, sealed: sealed, aad: aad);

  /// 信封 JSON 文本的 SHA-256（小写 hex）。签名规范哈希的是信封文本本身，
  /// 不是密文字节——单独开一个入口，避免各处重复踩这个坑。
  static Future<String> sha256HexOfEnvelope(String body) async {
    final digest = dshsha.Sha256.hash(utf8.encode(body));
    return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
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
