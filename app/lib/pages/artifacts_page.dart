import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../downloader.dart';
import '../theme.dart';

/// 会话产物：这一轮轮跑下来产出的文件，宿主确认还在的才列出来。
class ArtifactsPage extends StatefulWidget {
  const ArtifactsPage({super.key, required this.state});

  final AppState state;

  @override
  State<ArtifactsPage> createState() => _ArtifactsPageState();
}

class _ArtifactsPageState extends State<ArtifactsPage> {
  double? _progress;
  String? _downloading;

  Future<void> _download(String path) async {
    final client = widget.state.client;
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('还没连上电脑')));
      return;
    }
    setState(() {
      _downloading = path;
      _progress = 0;
    });
    try {
      final saved = await AIDockDownloader.download(
        client,
        path: path,
        sessionId: widget.state.openSessionId,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存到 $saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) {
        setState(() {
          _downloading = null;
          _progress = null;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.state.loadArtifacts();
  }

  String _size(Object? raw) {
    final n = (raw is num) ? raw.toInt() : int.tryParse('${raw ?? ''}') ?? 0;
    if (n <= 0) return '';
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _name(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('会话产物'),
            actions: [
              IconButton(
                tooltip: '刷新',
                onPressed: s.loadingArtifacts ? null : () => s.loadArtifacts(),
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          body: s.loadingArtifacts && s.artifacts.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : s.artifacts.isEmpty
                  ?  Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '这条会话还没有产出文件。\n有产出时，这里会列出路径与大小。',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: AidockColors.textDim, height: 1.6),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      itemCount: s.artifacts.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: AidockColors.line),
                      itemBuilder: (context, i) {
                        final a = s.artifacts[i];
                        final path = '${a['path'] ?? ''}';
                        final status = '${a['status'] ?? ''}';
                        final ok = status == 'ok';
                        final color = ok
                            ? AidockColors.ok
                            : (status == 'missing' ? AidockColors.warn : AidockColors.textDim);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            ok ? Icons.description_outlined : Icons.help_outline,
                            size: 20,
                            color: color,
                          ),
                          title: Text(_name(path),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14)),
                          subtitle: Text(
                            [path, _size(a['size']), ok ? '' : status]
                                .where((e) => e.isNotEmpty)
                                .join('\n'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style:  TextStyle(fontSize: 11, color: AidockColors.textDim, height: 1.5),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_downloading == path)
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    value: _progress,
                                    color: AidockColors.accent,
                                  ),
                                )
                              else
                                IconButton(
                                  tooltip: '下载到手机',
                                  icon: const Icon(Icons.download_outlined, size: 19),
                                  onPressed: ok ? () => _download(path) : null,
                                ),
                              IconButton(
                                tooltip: '复制路径',
                                icon: const Icon(Icons.copy_all_outlined, size: 18),
                                onPressed: () async {
                                  await Clipboard.setData(ClipboardData(text: path));
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('路径已复制')),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
        );
      },
    );
  }
}
