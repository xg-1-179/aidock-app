import 'package:flutter/services.dart';

/// 手机通知：审批待处理、提问待回答、回合结束时提醒（App 在后台才发）。
///
/// 走 `MethodChannel('aidock/notify')`，安卓侧由 `scripts/patch_android_notify.py`
/// 注入到 `MainActivity`（不引第三方插件，构建风险最小）。iOS 没做，调用直接吞掉。
class Notifier {
  static const MethodChannel _ch = MethodChannel('aidock/notify');

  /// 请求通知权限（Android 13+ 会弹系统授权框）。
  static Future<void> ask() async {
    try {
      await _ch.invokeMethod<void>('ask');
    } catch (_) {
      // 桌面/测试环境没有这个通道，忽略。
    }
  }

  /// [sessionId] 非空时，点通知会带着它回到 App 并直接打开那条会话。
  static Future<void> show(String title, String body, {String? sessionId}) async {
    if (body.trim().isEmpty) return;
    try {
      await _ch.invokeMethod<void>('show', {
        'title': title,
        'body': body,
        if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      });
    } catch (_) {}
  }
}
