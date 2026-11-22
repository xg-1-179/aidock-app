import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';

/// 一次下载失败。页面直接拿 `message` 展示就行：四类情况（文件没了 / 凭据过期 /
/// 不在放行范围 / 网络断了）在这里已经分好话术；`status` 与 `code` 留给调用方做分支
/// —— 401 该引导重新配对，404 该把入口置灰，403 该提示去宿主上放行。
class DownloadException implements Exception {
  DownloadException(this.message, {this.status, this.code});

  final String message;
  final int? status;
  final String? code;

  @override
  String toString() => message;
}

/// 把电脑上的一个文件按块取回手机。
///
/// 宿主 `/file/read` 对带信封（`X-Dsh-Proto: 2`）的请求回的不是裸字节，而是一段**加密
/// 分块信封**（`content-type: application/x-dsh-e2ee-chunks`）：
///
/// * 每帧 = `[4 字节大端长度 L][12 字节 nonce][密文 + 16 字节 tag]`，`L` 只数「密文 + tag」
///   （不含 nonce 与长度字段本身）；整帧 = `16 + L`。
/// * 密钥是会话下行的 `keys.down`（AES-256-GCM），AAD 绑这条请求与块序号：
///   `v2|down|file|<请求路径>|<请求 nonce>|<块序号>`。`<请求路径>` 是
///   `signedPath(req)` 的结果，即 `/api/mobile/v1/file/read`；`<请求 nonce>` 是本次请求
///   `X-Dsh-Nonce` 头的原文（base64url 字符串，不是字节）；块序号从 1 数起，按 64KiB
///   明文块计，从文件中间起读时首块序号是 `offset / 65536 + 1`。
/// * 一次响应的块序连续，末尾**永远多一块**（长度对齐的段也有一块明文为空的；空文件就
///   只有这一块）。所以解出来是 0 字节的块不是错误，跳过即可。
/// * 状态码是 200（不是 206），段长由 `x-dsh-range-start` / `x-dsh-range-length` /
///   `x-dsh-file-size` 三个头给。
///
/// 正因为正文不是 JSON，这里不能复用 `DshClient.call()`（它只解 JSON）；签名头仍然用协议包
/// 的 `DshEnvelope.build` 生成，避免自己重写一遍 canonical 串日后与宿主漂开。
class AIDockDownloader {
  AIDockDownloader._();

  /// 一次请求取回的明文字节数。宿主只接受 64KiB 对齐的 `offset`，512KiB 正好 8 块，
  /// 也在宿主 `length` 上限（2MiB）之内。
  static const int chunkBytes = 512 * 1024;

  /// 宿主分块信封的明文块大小（`FILE_CHUNK_BYTES`），块序号口径按它算。
  static const int frameBytes = 64 * 1024;

  /// 取字节的端点。放行面由宿主判：已登记工作区 ∪ 本会话的项目目录。
  static const String readPath = '/api/mobile/v1/file/read';

  static const String _chunksType = 'application/x-dsh-e2ee-chunks';
  static const int _framePrefixBytes = 4 + 12;
  static const int _tagBytes = 16;

  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _headerTimeout = Duration(seconds: 25);
  static const Duration _bodyTimeout = Duration(seconds: 90);

  /// 把一个宿主上的绝对路径 [path] 下载到本地，返回落盘文件的**绝对路径**。
  ///
  /// [sessionId] 只影响宿主的放行判定（本会话项目目录里的文件才认），传不传都行。
  /// [onProgress] 在 0..1 之间回调；宿主没报总长时只在开头和结尾各调一次。
  ///
  /// 同名文件直接覆盖。中途失败会把半成品删掉，不留一个「看起来下好了」的残文件。
  static Future<String> download(
    DshClient client, {
    required String path,
    String? sessionId,
    void Function(double)? onProgress,
  }) async {
    final remotePath = path.trim();
    if (remotePath.isEmpty) {
      throw DownloadException('要下载的文件路径是空的');
    }
    final dir = await downloadDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${_fileNameOf(remotePath)}');
    final http = HttpClient()..connectionTimeout = _connectTimeout;
    IOSink? sink;
    var finished = false;
    try {
      sink = file.openWrite();
      var offset = 0;
      // -1 表示宿主还没告诉我们总长（第一次响应之后一定知道）。
      var total = -1;
      onProgress?.call(0);

      while (true) {
        final window = total > 0
            ? (total - offset).clamp(0, chunkBytes).toInt()
            : chunkBytes;
        final res = await _readRange(
          http,
          client,
          filePath: remotePath,
          sessionId: sessionId,
          offset: offset,
          length: window,
        );
        if (res.status != 200) {
          throw await _errorOf(client, res);
        }

        final start = _intHeader(res.headers, 'x-dsh-range-start') ?? offset;
        final rangeLength =
            _intHeader(res.headers, 'x-dsh-range-length') ?? res.bytes.length;
        final fileSize = _intHeader(res.headers, 'x-dsh-file-size');
        if (fileSize != null && fileSize >= 0) total = fileSize;

        final encrypted = (res.headers['content-type'] ?? '')
            .toLowerCase()
            .startsWith(_chunksType);
        // 明文兜底：宿主没认出信封时（例如这条请求没带签名头）回的是裸字节，
        // 那种情况下按原样落盘，不硬解。
        final plain = encrypted
            ? await _openChunks(
                client,
                requestNonce: res.env.nonce,
                frames: res.bytes,
                startOffset: start,
              )
            : res.bytes;

        if (encrypted && plain.length != rangeLength) {
          throw DownloadException(
            '有一段解出来的字节数和宿主报的段长对不上（${plain.length} / $rangeLength）',
            status: res.status,
          );
        }
        if (plain.isNotEmpty) {
          sink.add(plain);
          await sink.flush();
        }

        offset = start + rangeLength;
        if (total > 0) {
          onProgress?.call((offset / total).clamp(0.0, 1.0).toDouble());
        }
        // 到尾巴时宿主回一个 0 长的段（空文件也一样），这就是「读完了」的凭据。
        if (rangeLength <= 0) break;
        if (total >= 0 && offset >= total) break;
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (total >= 0) {
        final written = await file.length();
        if (written != total) {
          throw DownloadException('下载完了但落盘大小不对（$written / $total）');
        }
      }
      onProgress?.call(1);
      finished = true;
      return file.absolute.path;
    } on DownloadException {
      rethrow;
    } on SocketException catch (e) {
      throw DownloadException('连不上电脑：${e.message}');
    } on HandshakeException catch (e) {
      throw DownloadException('和电脑之间的连接握手失败：${e.message}');
    } on TimeoutException {
      throw DownloadException('电脑一直没有把这一段发完（超时了，重试一次通常就好）');
    } on FileSystemException catch (e) {
      throw DownloadException('写文件失败：${e.message}');
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // 已经断了，close 失败不影响结论。
        }
      }
      http.close(force: true);
      if (!finished) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // 删不掉半成品也只能留着，异常已经说明失败了。
        }
      }
    }
  }

  /// 把一次响应的分块信封解开。
  static Future<Uint8List> _openChunks(
    DshClient client, {
    required String requestNonce,
    required Uint8List frames,
    required int startOffset,
  }) async {
    final out = BytesBuilder(copy: false);
    final firstSeq = startOffset ~/ frameBytes + 1;
    var at = 0;
    var index = 0;
    while (at < frames.length) {
      if (at + _framePrefixBytes > frames.length) {
        throw DownloadException(
          '加密块的头不完整（第 ${index + 1} 块，只剩 ${frames.length - at} 字节）',
        );
      }
      final bodyLength = (frames[at] << 24) |
          (frames[at + 1] << 16) |
          (frames[at + 2] << 8) |
          frames[at + 3];
      final end = at + _framePrefixBytes + bodyLength;
      if (bodyLength < _tagBytes || end > frames.length) {
        throw DownloadException(
          '加密块的长度字段不对（第 ${index + 1} 块：$bodyLength 字节，剩 ${frames.length - at} 字节）',
        );
      }
      // sealed = nonce(12) || 密文 || tag(16)，正是 DshCrypto.open 要的形状。
      final sealed = Uint8List.sublistView(frames, at + 4, end);
      try {
        final clear = await DshCrypto.open(
          key: client.keys.down,
          sealed: sealed,
          aad: 'v2|down|file|$readPath|$requestNonce|${firstSeq + index}',
        );
        out.add(clear);
      } on DshCryptoException catch (e) {
        throw DownloadException('文件块解不开（第 ${firstSeq + index} 块）：${e.message}');
      }
      at = end;
      index += 1;
    }
    return out.toBytes();
  }

  /// 发一次带信封的 `/file/read`，把响应**按字节**收下来（`DshClient` 那条路只给 String）。
  static Future<_RangeResponse> _readRange(
    HttpClient http,
    DshClient client, {
    required String filePath,
    String? sessionId,
    required int offset,
    required int length,
  }) async {
    final payload = <String, dynamic>{
      'path': filePath,
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      'offset': offset,
      'length': length,
    };
    final env = await DshEnvelope.build(
      keys: client.keys,
      keyId: client.keyId,
      method: 'POST',
      path: readPath,
      query: '',
      payload: payload,
    );

    final base = client.baseUrl;
    // 与 IoDshTransport 同一口径：只取 scheme + authority，baseUrl 自带 path 不参与。
    final uri = Uri.parse('${base.scheme}://${base.authority}$readPath');
    final req = await http.postUrl(uri).timeout(_connectTimeout);
    env.headers.forEach(req.headers.set);
    // 二进制不能吃压缩：一句 identity 让宿主别压，也按住 HttpClient 自己加 Accept-Encoding。
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final token = client.authToken;
    if (token != null && token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final credential = client.deviceCredential;
    if (credential != null && credential.isNotEmpty) {
      req.headers.set('X-Dsh-Device-Credential', credential);
    }
    final body = utf8.encode(env.body);
    req.contentLength = body.length;
    req.add(body);

    final res = await req.close().timeout(_headerTimeout);
    final builder = BytesBuilder(copy: false);
    await for (final part in res.timeout(_bodyTimeout)) {
      builder.add(part);
    }
    final headers = <String, String>{};
    res.headers.forEach((name, values) {
      if (values.isNotEmpty) headers[name.toLowerCase()] = values.first;
    });
    return _RangeResponse(
      status: res.statusCode,
      headers: headers,
      bytes: builder.toBytes(),
      env: env,
    );
  }

  /// 失败响应分两种形状：401 / 403 / 503 永远是明文 JSON（宿主刻意不封，好让客户端先读懂
  /// 「凭据没了」），其余状态码会被守卫再封一层 `{v:2,n?,c}`。两种都认。
  static Future<Map<String, dynamic>?> _decodeErrorBody(
    DshClient client,
    _RangeResponse res,
  ) async {
    if (res.bytes.isEmpty) return null;
    final decoded = _tryJson(utf8.decode(res.bytes, allowMalformed: true));
    if (decoded is! Map<String, dynamic>) return null;
    final c = decoded['c'];
    if (c is! String || c.isEmpty) return decoded;
    try {
      final nonce = decoded['n'];
      final sealed = <int>[
        if (nonce is String && nonce.isNotEmpty)
          ...base64Url.decode(base64Url.normalize(nonce)),
        ...base64.decode(c),
      ];
      final clear = await DshCrypto.open(
        key: client.keys.down,
        sealed: sealed,
        aad: 'v2|down|POST|$readPath|${res.env.timestamp}|${res.env.nonce}',
      );
      final inner = _tryJson(utf8.decode(clear));
      return inner is Map<String, dynamic> ? inner : null;
    } catch (_) {
      // 解不开就把外层原样交回去，至少还有状态码能说人话。
      return decoded;
    }
  }

  static Future<DownloadException> _errorOf(
    DshClient client,
    _RangeResponse res,
  ) async {
    final body = await _decodeErrorBody(client, res);
    var code = '';
    var message = '';
    if (body != null) {
      final err = body['error'];
      if (err is Map) {
        code = '${err['code'] ?? ''}';
        message = '${err['message'] ?? ''}'.trim();
      } else if (err is String) {
        message = err.trim();
      }
      if (message.isEmpty) {
        final fallback = body['message'];
        if (fallback is String) message = fallback.trim();
      }
      if (code.isEmpty) {
        final fallbackCode = body['code'];
        if (fallbackCode is String) code = fallbackCode;
      }
    }
    final status = res.status;
    if (status == 401) {
      return DownloadException(
        message.isEmpty ? '凭据过期了，回「更多」里重新连一次电脑' : '凭据过期了：$message',
        status: status,
        code: code,
      );
    }
    if (status == 403) {
      return DownloadException(
        message.isEmpty ? '这个文件不在能看的范围里（只放行工作区目录和本会话的项目目录）' : message,
        status: status,
        code: code,
      );
    }
    if (status == 404) {
      return DownloadException(
        message.isEmpty ? '附件/文件已不可读：电脑上已经没有这个文件了' : '附件/文件已不可读：$message',
        status: status,
        code: code,
      );
    }
    if (status == 413) {
      return DownloadException(
        message.isEmpty ? '这个文件太大，这条通道不支持整份取回（上限 512MB）' : message,
        status: status,
        code: code,
      );
    }
    return DownloadException(
      message.isEmpty ? '下载失败（HTTP $status）' : '$message（HTTP $status）',
      status: status,
      code: code,
    );
  }

  static int? _intHeader(Map<String, String> headers, String name) {
    final raw = headers[name];
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw.trim());
  }

  static Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// 落盘文件名：宿主路径的最后一段，去掉 Windows/Android 都不认的字符。
  static String _fileNameOf(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    var name = parts.isEmpty ? '' : parts.last;
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (name.isEmpty || name == '.' || name == '..') {
      name = 'aidock-${DateTime.now().millisecondsSinceEpoch}';
    }
    return name;
  }
}

/// 一次 `/file/read` 的原始响应（字节 + 头 + 生成它的信封，后者解块要用）。
class _RangeResponse {
  _RangeResponse({
    required this.status,
    required this.headers,
    required this.bytes,
    required this.env,
  });

  final int status;
  final Map<String, String> headers;
  final Uint8List bytes;
  final DshEnvelope env;
}

/// 下载落盘目录：`Download/AIDock`。
///
/// 这一轮不加 `path_provider`（依赖要主控统一加），所以按平台自己能找到的绝对路径挨个试，
/// 第一个「能建目录、并且真的写得进去」的胜出：
///
/// 1. 安卓的共享下载目录 `/storage/emulated/0/Download/AIDock` —— 用户能在「文件」里直接
///    看到、点开。但 Android 10 起的分区存储会让这里写失败（`Operation not permitted`），
///    所以下面必须有兜底，只写这一条等于在真机上必然失败。
/// 2. `Directory.systemTemp/AIDock` —— 应用私有目录，一定能写；缺点是系统清缓存时会一起清掉。
///
/// 想稳定落到「应用外部目录」或让系统下载器接管，主控加 `path_provider`
/// （`getExternalStorageDirectory`）之后把第 1 条换成它即可，这个函数是唯一需要改的地方。
Future<Directory> downloadDirectory() async {
  final separator = Platform.pathSeparator;
  final candidates = <String>[
    '/storage/emulated/0/Download/AIDock',
    '${Directory.systemTemp.path}${separator}AIDock',
  ];
  Object? lastError;
  for (final raw in candidates) {
    try {
      final dir = Directory(raw);
      if (!await dir.exists()) await dir.create(recursive: true);
      // 目录建得出来不代表写得进去（分区存储就是这么骗人的），所以落一次探针。
      final probe = File('${dir.path}${separator}.aidock-probe');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return dir;
    } catch (error) {
      lastError = error;
    }
  }
  throw DownloadException('手机上没有可写的下载目录（试过 ${candidates.join('、')}）：$lastError');
}
