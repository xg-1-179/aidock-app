import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../theme.dart';
import 'scan_page.dart';

class PairPage extends StatefulWidget {
  const PairPage({super.key, required this.state});
  final AppState state;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _host = TextEditingController();
  final _code = TextEditingController();
  final _codeFocus = FocusNode();

  @override
  void dispose() {
    _host.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  /// 上次连过的电脑：省掉重新输地址和六位码（凭据过期会提示重新拿码）。
  Widget _savedCard(AppState s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AidockColors.accent.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.history_rounded, size: 18, color: AidockColors.accent),
              SizedBox(width: 8),
              Text('上次连接的电脑',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(s.savedHost ?? '',
              style: const TextStyle(
                  fontSize: 12, color: AidockColors.textDim, fontFamily: 'monospace')),
          if ((s.savedPermissions ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('权限：${s.savedPermissions}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AidockColors.textDim, height: 1.4)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: s.busy ? null : () => s.reconnectSaved(),
                  icon: const Icon(Icons.bolt_rounded, size: 18),
                  label: const Text('直接连接'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: s.busy ? null : () => s.forgetSaved(),
                child: const Text('忘掉'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 扫二维码：把地址与六位码一起填好并直接连，省掉手输。
  Future<void> _scan() async {
    final link = await Navigator.of(context).push<ScannedLink>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (link == null || !mounted) return;
    setState(() {
      _host.text = link.host;
      _code.text = link.code;
    });
    _submit();
  }

  void _submit() {
    if (_code.text.trim().length < 4) {
      _codeFocus.requestFocus();
      return;
    }
    widget.state.connect(_host.text, _code.text);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 34, 22, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: AidockColors.accentSoft,
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(color: AidockColors.accent.withOpacity(0.45)),
                    ),
                    child: const Icon(Icons.dock_rounded, color: AidockColors.accent, size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('AIDock',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                      Text('把电脑上的 DeepSeek Harness 装进口袋',
                          style: TextStyle(fontSize: 12.5, color: AidockColors.textDim)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 34),
              if (s.hasSaved) ...[
                _savedCard(s),
                const SizedBox(height: 20),
              ],
              const Text('连接这台电脑',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text('在电脑上打开插件面板，会显示一个 6 位连接码（10 分钟一换）。',
                  style: TextStyle(fontSize: 13, color: AidockColors.textDim, height: 1.5)),
              const SizedBox(height: 6),
              const SelectableText('电脑上打开：http://127.0.0.1:3080/api/mobile/v1/link/panel',
                  style: TextStyle(fontSize: 11.5, color: AidockColors.textDim, height: 1.5,
                      fontFamily: 'monospace')),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: s.busy ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('扫面板上的二维码（免手输）', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AidockColors.accent,
                    side: BorderSide(color: AidockColors.accent.withOpacity(0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _label('电脑地址'),
              const SizedBox(height: 8),
              TextField(
                controller: _host,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  hintText: '192.168.1.5:41873',
                  prefixIcon: Icon(Icons.dns_outlined, size: 20),
                ),
              ),
              const SizedBox(height: 18),
              _label('6 位连接码'),
              const SizedBox(height: 8),
              TextField(
                controller: _code,
                focusNode: _codeFocus,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(fontSize: 26, letterSpacing: 12, fontWeight: FontWeight.w600),
                decoration: const InputDecoration(
                  counterText: '',
                  hintText: '••••••',
                  hintStyle: TextStyle(letterSpacing: 10, fontSize: 22),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (s.error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AidockColors.danger.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AidockColors.danger.withOpacity(0.4)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline, size: 18, color: AidockColors.danger),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(s.error!,
                            style: const TextStyle(fontSize: 13, color: AidockColors.danger, height: 1.45)),
                      ),
                    ],
                  ),
                ),
              ],
              if (s.probeLog.isNotEmpty && !s.paired) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AidockColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AidockColors.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('连接诊断',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      for (final line in s.probeLog)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(line,
                              style: const TextStyle(
                                  fontSize: 11.5, color: AidockColors.textDim, height: 1.4)),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: s.busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AidockColors.accent,
                    foregroundColor: const Color(0xFF06121F),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
                  ),
                  child: s.busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.2, color: Color(0xFF06121F)),
                        )
                      : const Text('连接'),
                ),
              ),
              const SizedBox(height: 26),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AidockColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AidockColors.line),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('连不上时',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    SizedBox(height: 8),
                    Text('· 确认电脑上的 AIDock 正在运行，插件页显示「直连已就绪」\n'
                        '· 连接码 10 分钟内有效，过期就刷新电脑上的连接码页面\n'
                        '· 地址可以填多个（用空格或逗号分开），会并行探测取最快的那条\n'
                        '· 公网直连需要在云服务器安全组放行该端口',
                        style: TextStyle(fontSize: 12.5, color: AidockColors.textDim, height: 1.6)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(fontSize: 12.5, color: AidockColors.textDim, letterSpacing: 0.3));
}
