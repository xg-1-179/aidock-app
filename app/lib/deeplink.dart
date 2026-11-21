import 'package:flutter/services.dart';

/// `aidock://v1?h=…&c=…` 深链接：手机用系统相机/扫码器扫面板二维码后，
/// 直接从浏览器或扫一扫跳回 App，并把地址与六位码带进来。
///
/// 安卓侧由 `scripts/patch_android_notify.py` 注入 `MethodChannel('aidock/link')`：
/// `initial` 取冷启动那一条 intent，`link` 推送热启动（App 已在后台）的新 URL。
class DeepLink {
  /// 从任意 `aidock://` URL 里取会话 id（通知点击用 `aidock://open?session=<id>`）。
  static String? sessionOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'aidock') return null;
    final direct = uri.queryParameters['session'];
    if (direct != null && direct.isNotEmpty) return direct;
    // 兼容 `aidock://session/<id>` 这种路径形式。
    if (uri.host == 'session' && uri.pathSegments.isNotEmpty) return uri.pathSegments.first;
    return null;
  }

  static const MethodChannel _ch = MethodChannel('aidock/link');

  static Future<String?> initial() async {
    try {
      return await _ch.invokeMethod<String>('initial');
    } catch (_) {
      return null;
    }
  }

  static void listen(void Function(String url) onLink) {
    try {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'link') {
          final url = call.arguments;
          if (url is String && url.isNotEmpty) onLink(url);
        }
        return null;
      });
    } catch (_) {
      // 桌面/测试环境没有这条通道。
    }
  }
}
