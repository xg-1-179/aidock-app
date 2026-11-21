import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';

/// 扫电脑面板上的那张连接二维码，把「地址 + 六位码」一起带回来。
///
/// 只认 `aidock://v1?h=<地址>&c=<六位码>` 这种文本；别的码就当没看见，
/// 免得对着随便一张二维码也能配对。
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _handled = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final link = ScannedLink.parse(raw);
      if (link == null) {
        setState(() => _hint = '这不是 AIDock 的连接码，对着电脑面板上的二维码再试一次');
        continue;
      }
      _handled = true;
      Navigator.of(context).pop(link);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫连接二维码'),
        backgroundColor: AidockColors.bg,
        foregroundColor: AidockColors.text,
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Align(
            alignment: Alignment.center,
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: AidockColors.accent, width: 2.5),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 34),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _hint ?? '把电脑上的二维码放进框里',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: _hint == null ? AidockColors.textDim : AidockColors.warn,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '扫不到也可以返回手输地址和六位码',
                    style: TextStyle(fontSize: 11.5, color: AidockColors.textDim),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 二维码里那串 `aidock://v1?h=…&c=…` 的解析结果。
class ScannedLink {
  const ScannedLink({required this.host, required this.code, this.instanceId});

  final String host;
  final String code;
  final String? instanceId;

  static ScannedLink? parse(String raw) {
    final text = raw.trim();
    if (!text.toLowerCase().startsWith('aidock://')) return null;
    Uri uri;
    try {
      uri = Uri.parse(text);
    } catch (_) {
      return null;
    }
    final host = uri.queryParameters['h'] ?? '';
    final code = uri.queryParameters['c'] ?? '';
    if (host.isEmpty || code.isEmpty) return null;
    return ScannedLink(host: host, code: code, instanceId: uri.queryParameters['i']);
  }
}
