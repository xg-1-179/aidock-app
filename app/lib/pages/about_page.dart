import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../updater.dart';

/// 关于页：App 名与版本、「检查更新」、插件仓库链接（纯文本可复制）与开源许可。
///
/// 这一页刻意不引 `url_launcher`：所有「打开」都降级成「下载到本地」或「复制链接」，
/// 需要点开的东西由用户自己在浏览器 / 文件管理器里完成，因此不新增任何依赖。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.currentVersion, this.onLogout});

  /// 当前版本号。`package_info_plus` 这一轮不加依赖，所以版本由调用方传进来。
  final String currentVersion;

  /// 传了就多一个「退出配对」按钮；不传则整块不出现。
  final VoidCallback? onLogout;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  bool _checking = false;

  /// 已经查过一轮且结论是「没有更新的版本」——用来区分「还没点」和「已是最新」。
  bool _checked = false;
  UpdateInfo? _info;
  String? _error;

  bool _downloading = false;
  double _progress = 0;
  String? _savedPath;
  String? _downloadError;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _header(),
          const SizedBox(height: 22),
          _section('版本'),
          _updateBlock(),
          const SizedBox(height: 22),
          _section('插件仓库'),
          _repoBlock(),
          const SizedBox(height: 22),
          _section('开源许可'),
          _licenseBlock(),
          if (widget.onLogout != null) ...[
            const SizedBox(height: 26),
            OutlinedButton(
              onPressed: widget.onLogout,
              style: OutlinedButton.styleFrom(
                foregroundColor: AidockColors.danger,
                side:  BorderSide(color: AidockColors.line),
                minimumSize: const Size.fromHeight(46),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('退出这台电脑的配对'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AidockColors.line),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AidockColors.accentSoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child:  Icon(
              Icons.smartphone,
              size: 26,
              color: AidockColors.accent,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                 Text(
                  'AIDock',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AidockColors.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '版本 ${widget.currentVersion}',
                  style:  TextStyle(
                    fontSize: 13,
                    color: AidockColors.textDim,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title,
        style:  TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AidockColors.text,
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AidockColors.line),
      ),
      child: child,
    );
  }

  Widget _updateBlock() {
    final info = _info;
    final children = <Widget>[
      Row(
        children: [
           Expanded(
            child: Text(
              '检查更新',
              style: TextStyle(fontSize: 14, color: AidockColors.text),
            ),
          ),
          if (_checking)
             SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(AidockColors.accent),
              ),
            )
          else
            TextButton(
              onPressed: _check,
              style: TextButton.styleFrom(
                foregroundColor: AidockColors.accent,
                minimumSize: const Size(64, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('检查'),
            ),
        ],
      ),
    ];
    if (_checking) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: LinearProgressIndicator(
            minHeight: 2,
            backgroundColor: AidockColors.surfaceAlt,
            valueColor:  AlwaysStoppedAnimation<Color>(AidockColors.accent),
          ),
        ),
      );
    } else if (_error != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _error!,
            style:  TextStyle(
              fontSize: 12,
              height: 1.5,
              color: AidockColors.danger,
            ),
          ),
        ),
      );
    } else if (info != null) {
      children.addAll(_updateDetails(info));
    } else {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _checked ? '已经是最新版本。' : '点「检查」看看 GitHub 上有没有新安装包。',
            style:  TextStyle(
              fontSize: 12,
              height: 1.5,
              color: AidockColors.textDim,
            ),
          ),
        ),
      );
    }
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  List<Widget> _updateDetails(UpdateInfo info) {
    final out = <Widget>[
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: Text(
              '发现新版本 ${info.tag}',
              style:  TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AidockColors.ok,
              ),
            ),
          ),
          Text(
            info.sizeLabel,
            style:  TextStyle(fontSize: 12, color: AidockColors.textDim),
          ),
        ],
      ),
    ];
    if (info.notes.isNotEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _notesPreview(info.notes),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style:  TextStyle(
              fontSize: 12,
              height: 1.6,
              color: AidockColors.textDim,
            ),
          ),
        ),
      );
    }
    if (_downloading) {
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(
            value: _progress <= 0 ? null : _progress,
            minHeight: 3,
            backgroundColor: AidockColors.surfaceAlt,
            valueColor:  AlwaysStoppedAnimation<Color>(AidockColors.accent),
          ),
        ),
      );
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '已下载 ${(_progress * 100).toStringAsFixed(0)}%',
            style:  TextStyle(fontSize: 12, color: AidockColors.textDim),
          ),
        ),
      );
    }
    if (_downloadError != null) {
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            _downloadError!,
            style:  TextStyle(
              fontSize: 12,
              height: 1.5,
              color: AidockColors.danger,
            ),
          ),
        ),
      );
    }
    if (_savedPath != null) {
      out.add(const SizedBox(height: 12));
      out.add(
         Text(
          '安装包已存到手机上（去「文件」里点开即可安装）：',
          style: TextStyle(fontSize: 12, height: 1.5, color: AidockColors.textDim),
        ),
      );
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: SelectableText(
            _savedPath!,
            style:  TextStyle(fontSize: 12, height: 1.5, color: AidockColors.text),
          ),
        ),
      );
      out.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => _copy(_savedPath!, '路径已复制'),
            style: TextButton.styleFrom(
              foregroundColor: AidockColors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(0, 34),
            ),
            child: const Text('复制路径'),
          ),
        ),
      );
    }
    out.add(const SizedBox(height: 8));
    out.add(
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            onPressed: _downloading ? null : _download,
            style: FilledButton.styleFrom(
              backgroundColor: AidockColors.accent,
              foregroundColor: AidockColors.bg,
              minimumSize: const Size(104, 40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(_downloading ? '下载中…' : '去下载'),
          ),
          TextButton(
            onPressed: () => _copy(info.apkUrl, '下载链接已复制'),
            style: TextButton.styleFrom(
              foregroundColor: AidockColors.accent,
              minimumSize: const Size(0, 40),
            ),
            child: const Text('复制下载链接'),
          ),
        ],
      ),
    );
    return out;
  }

  Widget _repoBlock() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _repoRow('插件端', AIDockUpdater.pluginRepoUrl),
          const SizedBox(height: 12),
          _repoRow('App 端', AIDockUpdater.repoUrl),
        ],
      ),
    );
  }

  Widget _repoRow(String label, String url) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style:  TextStyle(fontSize: 12, color: AidockColors.textDim),
            ),
            const Spacer(),
            InkWell(
              onTap: () => _copy(url, '$label链接已复制'),
              borderRadius: BorderRadius.circular(8),
              child:  Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  '复制',
                  style: TextStyle(fontSize: 12, color: AidockColors.accent),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        SelectableText(
          url,
          style:  TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: AidockColors.text,
          ),
        ),
      ],
    );
  }

  Widget _licenseBlock() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
           Text(
            '这个 App 用 Flutter 写，扫描用 mobile_scanner，选图用 image_picker，'
            '偏好设置用 shared_preferences，和手机端通信用同仓库打包进来的 dsh_link_protocol。'
            '上面这些组件各自遵循原本的开源许可。',
            style: TextStyle(
              fontSize: 12,
              height: 1.7,
              color: AidockColors.textDim,
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _showLicenses,
              style: TextButton.styleFrom(
                foregroundColor: AidockColors.accent,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 34),
              ),
              child: const Text('查看完整第三方许可'),
            ),
          ),
        ],
      ),
    );
  }

  /// release 说明是 Markdown 原文，这里只做纯文本预览：太长就截断，不渲染标记。
  static String _notesPreview(String notes) {
    final text = notes.replaceAll('\r\n', '\n').trim();
    return text.length <= 600 ? text : '${text.substring(0, 600)}…';
  }

  void _showLicenses() {
    showLicensePage(
      context: context,
      applicationName: 'AIDock',
      applicationVersion: widget.currentVersion,
      applicationIcon:  Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.smartphone, color: AidockColors.accent, size: 32),
      ),
    );
  }

  Future<void> _copy(String text, String toast) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(toast)));
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
      _downloadError = null;
      _savedPath = null;
    });
    try {
      final info = await AIDockUpdater.check();
      if (!mounted) return;
      setState(() {
        _checking = false;
        if (info == null) {
          _info = null;
          _checked = true;
        } else if (compareVersions(info.version, widget.currentVersion) > 0) {
          _info = info;
          _checked = false;
        } else {
          _info = null;
          _checked = true;
        }
      });
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _info = null;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _info = null;
        _error = '检查更新失败：$e';
      });
    }
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null || _downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _savedPath = null;
      _downloadError = null;
    });
    try {
      final path = await AIDockUpdater.openApk(
        info.apkUrl,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _progress = 1;
        _savedPath = path;
      });
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadError = '下载安装包失败：$e';
      });
    }
  }
}
