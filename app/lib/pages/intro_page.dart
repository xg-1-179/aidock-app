import 'package:flutter/material.dart';

import '../theme.dart';

/// 第一次打开时的三步说明。看完写一个本地标记，不再出现。
class IntroPage extends StatelessWidget {
  const IntroPage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('AIDock',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
              const SizedBox(height: 6),
               Text('手机连着你的电脑，随时接着聊。',
                  style: TextStyle(fontSize: 13, color: AidockColors.textDim)),
              const SizedBox(height: 28),
              _step(1, '电脑上打开连接页',
                  '在电脑上打开 http://127.0.0.1:3080/api/mobile/v1/link/panel，页面上有六位连接码和二维码。'),
              _step(2, '扫码或输入六位码',
                  '地址填这台电脑的公网地址（例如 http://你的IP:41873），再填六位码。扫面板上的二维码可以一次填完。'),
              _step(3, '开始用',
                  '会话列表、流式回复、审批与提问都能在手机上处理；断线会自动重连，凭据存在手机本地，下次一点就回。'),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onDone,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('开始'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(int n, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AidockColors.accent.withOpacity(0.16),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$n',
                style:  TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: AidockColors.accent)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(body,
                    style:  TextStyle(
                        fontSize: 12.5, height: 1.65, color: AidockColors.textDim)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
