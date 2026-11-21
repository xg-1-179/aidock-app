import 'package:flutter/material.dart';

import 'app_state.dart';
import 'pages/pair_page.dart';
import 'pages/sessions_page.dart';
import 'theme.dart';

void main() => runApp(const AidockApp());

class AidockApp extends StatefulWidget {
  const AidockApp({super.key});

  @override
  State<AidockApp> createState() => _AidockAppState();
}

class _AidockAppState extends State<AidockApp> {
  final AppState state = AppState();

  @override
  void initState() {
    super.initState();
    // 上次连过的电脑：读出来让配对页可以先给一个「直接回去」的入口。
    state.loadSaved();
  }

  @override
  void dispose() {
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIDock',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: AnimatedBuilder(
        animation: state,
        builder: (context, _) =>
            state.paired ? SessionsPage(state: state) : PairPage(state: state),
      ),
    );
  }
}
