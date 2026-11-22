import 'package:flutter/services.dart';

/// 前台服务保活：连上电脑后起一条常驻通知，锁屏/切后台时别让系统把进程收掉。
///
/// 桌面端和测试环境没有这条通道，所有调用都吞异常 —— 保活失败不该影响聊天。
class KeepAlive {
  static const MethodChannel _ch = MethodChannel('aidock/keepalive');

  static Future<void> start([String text = '已连接到电脑']) async {
    try {
      await _ch.invokeMethod<void>('start', {'text': text});
    } catch (_) {}
  }

  /// 打开系统的电池优化设置，让用户把 AIDock 加进白名单（国产 ROM 必做一步）。
  static Future<void> requestBatteryExemption() async {
    try {
      await _ch.invokeMethod<void>('exempt');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
