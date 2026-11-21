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

/// 一条正在读的 SSE 响应。
///
/// 手机端拿到的会话流是 `text/event-stream`（不是 WebSocket）：先有响应头，然后一帧一帧
/// 的 `data:` 行。这里只把它拆成「行」，SSE 记录与信封解码交给 [DshClient]。
class DshEventStream {
  DshEventStream(this.status, this.headers, this.lines, Future<void> Function() close)
      : _close = close;

  final int status;
  final Map<String, String> headers;

  /// 原始行（已按 `\n` 拆开，不含换行符）。
  final Stream<String> lines;

  final Future<void> Function() _close;

  bool get ok => status >= 200 && status < 300;

  /// 服务端协商出来的协议版本（`x-dsh-proto: 2` 表示帧是信封）。
  String get proto => headers['x-dsh-proto'] ?? '';

  Future<void> close() => _close();
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

  /// 打开一条 SSE 流：返回响应头 + 行流。请求头（签名 / 协议版本）必须原样带上。
  Future<DshEventStream> openEventStream({
    required String method,
    required String path,
    required String query,
    required Map<String, String> headers,
  });

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
  Future<DshEventStream> openEventStream({
    required String method,
    required String path,
    required String query,
    required Map<String, String> headers,
  }) async {
    final uri = _uri(path, query);
    final req = await _client.openUrl(method, uri).timeout(_timeout);
    headers.forEach(req.headers.set);
    req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    // 心跳是 15 秒一帧，桌面那条路上还会有更长的静默；这里只限制「拿到响应头」的时间，
    // 之后的读由流本身控制（否则一段安静的长回复会被判成超时）。
    final res = await req.close().timeout(_timeout);
    final head = <String, String>{};
    res.headers.forEach((name, values) {
      if (values.isNotEmpty) head[name.toLowerCase()] = values.first;
    });
    final lines = utf8.decoder.bind(res).transform(const LineSplitter());
    return DshEventStream(res.statusCode, head, lines, () async {
      try {
        await res.detachSocket().then((s) => s.destroy());
      } catch (_) {/* 已经断了 */}
    });
  }

  Uri _uri(String path, String query) =>
      Uri.parse('${baseUrl.scheme}://${baseUrl.authority}$path$query');

  @override
  Future<void> close() async => _client.close(force: true);
}
