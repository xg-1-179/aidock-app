import 'package:flutter/material.dart';

import 'app_state.dart';
import 'deeplink.dart';
import 'notify.dart';
import 'pages/pair_page.dart';
import 'pages/sessions_page.dart';
import 'theme.dart';

void main() => runApp(const AidockApp());

class AidockApp extends StatefulWidget {
  const AidockApp({super.key});

  @override
  State<AidockApp> createState() => _AidockAppState();
}

class _AidockAppState extends State<AidockApp> with WidgetsBindingObserver {
  final AppState state = AppState();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 上次连过的电脑：读出来让配对页可以先给一个「直接回去」的入口。
    state.loadSaved();
    state.loadUiPrefs();
    // 通知权限：Android 13+ 会弹一次系统框；用户拒了也不影响其他功能。
    Notifier.ask();
    // 通知点进来的那条会话（热启动走监听，冷启动走 initial）。
    DeepLink.listen((url) {
      final sid = DeepLink.sessionOf(url);
      if (sid != null) state.pendingOpenSession = sid;
    });
    DeepLink.initial().then((url) {
      final sid = url == null ? null : DeepLink.sessionOf(url);
      if (sid != null) state.pendingOpenSession = sid;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState phase) {
    super.didChangeAppLifecycleState(phase);
    // 只有退到后台才发通知，前台看着屏幕时不打扰。
    state.appForeground = phase == AppLifecycleState.resumed;
    // 回到前台：手机在锁屏/切后台时系统会掐断长连接，而计时器也跟着停，靠心跳看门狗
    // 兜底要等几十秒。这里直接补一次「要不要立刻重连」，让界面几百毫秒内恢复。
    if (phase == AppLifecycleState.resumed) state.onResumed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIDock',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 2.0,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(state.textScale),
          ),
          child: child!,
        ),
      ),
      home: AnimatedBuilder(
        animation: state,
        builder: (context, _) =>
            state.paired ? SessionsPage(state: state) : PairPage(state: state),
      ),
    );
  }
}
