import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一次 HTTP 往返的结果。只保留客户端真正要用的字段。
class DshHttpResponse {
  const DshHttpResponse(this.status, this.body);
  final int status;
  final String body;

  bool get ok => status >= 200 && status < 300;
}

/// 传输抽象：真机走 [IoDshTransport]，测试可以换成内存实现。
abstract class DshTransport {
  Future<DshHttpResponse> send({
    required String method,
    required String path,
    required String query,
    required Map<String, String> headers,
    required String body,
  });

  /// 打开一条 WebSocket；首帧之前要把 [headers] 带上去（签名头就在里面）。
  Future<DshSocket> openSocket({
    required String path,
    required String query,
    required Map<String, String> headers,
  });

  Future<void> close();
}

abstract class DshSocket {
  Stream<String> get frames;
  Future<void> close();
}

/// 基于 `dart:io` 的实现：Android / iOS / 桌面都能跑，不引第三方依赖。
class IoDshTransport implements DshTransport {
  IoDshTransport(this.baseUrl, {Duration? timeout})
      : _client = HttpClient(),
        _timeout = timeout ?? const Duration(seconds: 10);

  final Uri baseUrl;
  final HttpClient _client;
  final Duration _timeout;

  @override
  Future<DshHttpResponse> send({
    required String method,
    required String path,
    required String query,
    required Map<String, String> headers,
    required String body,
  }) async {
    final uri = _uri(path, query);
    final req = await _client.openUrl(method, uri).timeout(_timeout);
    headers.forEach(req.headers.set);
    final bytes = utf8.encode(body);
    if (bytes.isNotEmpty) {
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(_timeout);
    final text = await utf8.decoder.bind(res).join().timeout(_timeout);
    return DshHttpResponse(res.statusCode, text);
  }

  @override
  Future<DshSocket> openSocket({
    required String path,
    required String query,
    required Map<String, String> headers,
  }) async {
    final uri = _uri(path, query, scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws');
    final ws = await WebSocket.connect(uri.toString(), headers: headers)
        .timeout(_timeout);
    return _IoSocket(ws);
  }

  Uri _uri(String path, String query, {String? scheme}) => Uri.parse(
        '${scheme ?? baseUrl.scheme}://${baseUrl.authority}$path$query',
      );

  @override
  Future<void> close() async => _client.close(force: true);
}

class _IoSocket implements DshSocket {
  _IoSocket(this._ws);
  final WebSocket _ws;

  @override
  Stream<String> get frames => _ws.map((e) => e is String ? e : utf8.decode(e as List<int>));

  @override
  Future<void> close() => _ws.close();
}
