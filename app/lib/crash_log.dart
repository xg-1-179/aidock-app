import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 崩溃与错误采集：写到应用私有目录，脱敏后可在「更多 → 运行日志」旁导出。
///
/// 只记栈与消息，**不记**凭据、token、消息正文 —— 排查闪退够用了，
/// 不该为了排查把用户聊天内容搬走。
class CrashLog {
  CrashLog._();

  static final List<String> _lines = [];
  static File? _file;

  static String get text => _lines.join('\n');

  static int get count => _lines.length;

  static Future<void> init() async {
    try {
      final dir = Directory('${Directory.systemTemp.path}/aidock');
      await dir.create(recursive: true);
      _file = File('${dir.path}/crash.log');
      if (await _file!.exists()) {
        final old = await _file!.readAsString();
        _lines.addAll(old.split('\n').where((e) => e.trim().isNotEmpty).take(200));
      }
    } catch (_) {}

    FlutterError.onError = (details) {
      record('FlutterError', details.exceptionAsString(), details.stack);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record('PlatformError', '$error', stack);
      return false;
    };
  }

  static void record(String kind, String message, [StackTrace? stack]) {
    final at = DateTime.now().toIso8601String();
    final head = '[$at] $kind: ${_scrub(message)}';
    _lines.add(head);
    if (stack != null) {
      final trace = stack.toString().split('\n').take(8).map(_scrub).join('\n');
      _lines.add(trace);
    }
    while (_lines.length > 300) {
      _lines.removeAt(0);
    }
    unawaited(_flush());
  }

  static Future<void> _flush() async {
    try {
      await _file?.writeAsString(_lines.join('\n'));
    } catch (_) {}
  }

  static Future<void> clear() async {
    _lines.clear();
    try {
      await _file?.writeAsString('');
    } catch (_) {}
  }

  /// 把像凭据的片段抹掉：长度 ≥ 24 的 base64url/hex 串一律替换。
  static String _scrub(String raw) {
    var out = raw;
    out = out.replaceAll(RegExp(r'[A-Za-z0-9\-_]{24,}'), '<redacted>');
    out = out.replaceAll(RegExp(r'[0-9a-f]{32,}'), '<redacted>');
    return out;
  }
}
