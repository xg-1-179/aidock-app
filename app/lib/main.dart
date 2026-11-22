import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'crash_log.dart';
import 'deeplink.dart';
import 'notify.dart';
import 'pages/intro_page.dart';
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

  /// 第一次打开时先给一页三步说明，看完写标记就不再出现。
  static const String _kIntroSeen = 'aidock.introSeen';
  bool? _showIntro;
  StreamSubscription<List<ConnectivityResult>>? _conn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CrashLog.init();
    // 上次连过的电脑：读出来让配对页可以先给一个「直接回去」的入口。
    state.loadSaved();
    state.loadUiPrefs();
    state.loadLocalExtras();
    // 切网（WiFi ↔ 4G、飞行模式回来）是断流最常见的原因：一有变化就立刻补一次重连，
    // 不要干等 10 秒心跳看门狗。
    _conn = Connectivity().onConnectivityChanged.listen((_) {
      if (!mounted) return;
      state.onResumed();
    });
    // 通知权限：Android 13+ 会弹一次系统框；用户拒了也不影响其他功能。
    Notifier.ask();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() => _showIntro = p.getBool(_kIntroSeen) != true);
    });
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
    _conn?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 整棵树套在 AnimatedBuilder 里：切深色/浅色时换的是全局配色表 + ThemeData，
    // 必须从 MaterialApp 这一层重建，否则弹出的底部面板、SnackBar 还拿旧主题。
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        AidockColors.apply(state.lightMode);
        return MaterialApp(
          title: 'AIDock',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(light: state.lightMode),
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            maxScaleFactor: 2.0,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(state.textScale),
              ),
              child: child!,
            ),
          ),
          home: _showIntro == null
              ? Scaffold(body: Center(child: CircularProgressIndicator()))
              : _showIntro!
                  ? IntroPage(onDone: () async {
                      final p = await SharedPreferences.getInstance();
                      await p.setBool(_kIntroSeen, true);
                      if (mounted) setState(() => _showIntro = false);
                    })
                  : state.paired
                      ? SessionsPage(state: state)
                      : PairPage(state: state),
        );
      },
    );
  }
}
