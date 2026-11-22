import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'downloader.dart' show downloadDirectory;

/// 检查 / 下载更新时出的问题。页面拿 `message` 直接展示。
class UpdateException implements Exception {
  UpdateException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// 一条 GitHub release 里应用真正关心的那几样。
///
/// 一个 `const` 值对象：`Version` 侧比较交给 [AIDockUpdater.compareVersions]，
/// 大小与文案的格式化留在 [sizeLabel] 里，页面不用自己拼字符串。
class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.apkUrl,
    required this.notes,
    required this.size,
  });

  /// release 的标签原文，例如 `v0.16.0`。
  final String tag;

  /// 第一个 `.apk` 资产的直链。
  final String apkUrl;

  /// release 说明正文（Markdown 原文，这里不渲染）。
  final String notes;

  /// 安装包字节数，取不到时为 0。
  final int size;

  /// 去掉前导 `v` 的版本号，给 [AIDockUpdater.compareVersions] 用。
  String get version => tag.replaceFirst(RegExp('^[vV]'), '');

  /// 人类可读的大小；[size] 未知时回「大小未知」而不是 0 B。
  String get sizeLabel {
    if (size <= 0) return '大小未知';
    if (size < 1024) return '$size B';
    final kb = size / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}

/// 宽松地比版本号：返回 <0 表示 [a] 比 [b] 旧，0 表示一样，>0 表示 [a] 更新。
///
/// 「宽松」的取舍（版本号是人写的，写错格式不该让更新检查整个失败）：
/// * 认 `1.2.3`、`v1.2.3`、`1.2`、`1`、`1.2.3+23`、`1.2.3-beta.1` 这些写法；
/// * 只按数字段比，段数少的补 0（`1.2` == `1.2.0`）；
/// * 数字段一样时，带预发布后缀的那个算**旧**（`1.2.0-beta` < `1.2.0`），
///   两个都带后缀就按字典序比是否相等；
/// * 认不出数字的段按 0 处理，所以「看不出谁新」的极端输入会退化成「相等」，
///   由页面显示成「已是最新」，而不是报错。
int compareVersions(String a, String b) {
  final pa = _versionParts(a);
  final pb = _versionParts(b);
  final count = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < count; i++) {
    final left = i < pa.length ? pa[i] : 0;
    final right = i < pb.length ? pb[i] : 0;
    if (left != right) return left < right ? -1 : 1;
  }
  final suffixA = _versionSuffix(a);
  final suffixB = _versionSuffix(b);
  if (suffixA == suffixB) return 0;
  if (suffixA.isEmpty) return 1; // 正式版比预发布版新
  if (suffixB.isEmpty) return -1;
  return suffixA.compareTo(suffixB);
}

/// 取版本号里的数字段。`+` 之后是构建号，不参与比较。
List<int> _versionParts(String raw) {
  final core = raw.split('+').first.split('-').first;
  final out = <int>[];
  for (final piece in core.split('.')) {
    final match = RegExp(r'\d+').firstMatch(piece);
    out.add(match == null ? 0 : int.tryParse(match.group(0)!) ?? 0);
  }
  return out;
}

/// 取 `-` 之后的预发布后缀（`1.2.3-beta.1` → `beta.1`），没有则为空串。
String _versionSuffix(String raw) {
  final core = raw.split('+').first;
  final dash = core.indexOf('-');
  return dash < 0 ? '' : core.substring(dash + 1);
}

/// 应用内更新：查 GitHub 的 latest release，并把安装包抓到手机上。
///
/// 仓库是公开的，查询**不带 token**（GitHub 对匿名请求限 60 次/小时，够用；
/// 也免得把 token 打进 APK 里被人捞）。匿名请求会被 GitHub 拒掉的情况只有一种：
/// 没有 `User-Agent` 头，所以下面每次都显式设了 UA。
class AIDockUpdater {
  AIDockUpdater._();

  /// App 自己的仓库（安装包的来源）。
  static const String repoUrl = 'https://github.com/xg-1-179/aidock-app';

  /// 插件端仓库（关于页里给的那条链接）。
  static const String pluginRepoUrl = 'https://github.com/xg-1-179/aidock';

  /// latest release 的 API 地址。
  static const String releasesUrl =
      'https://api.github.com/repos/xg-1-179/aidock-app/releases/latest';

  /// GitHub 要求匿名请求必须带 UA，否则直接 403。
  static const String _userAgent = 'AIDock-Android';

  /// 查最新 release。仓库还没发过 release（404）时返回 `null`，交给页面说「已是最新」。
  ///
  /// 拿不到 `.apk` 资产时抛 [UpdateException]：那说明发版流程漏了打包，属真异常，
  /// 不该被显示成「已是最新」糊过去。
  static Future<UpdateInfo?> check({Duration timeout = const Duration(seconds: 15)}) async {
    final http = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await http.getUrl(Uri.parse(releasesUrl)).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final res = await req.close().timeout(timeout);
      final raw = await res.transform(utf8.decoder).join().timeout(timeout);

      if (res.statusCode == 404) return null;
      if (res.statusCode == 403 || res.statusCode == 429) {
        throw UpdateException('GitHub 一直在限流，过几分钟再试', status: res.statusCode);
      }
      if (res.statusCode != 200) {
        throw UpdateException('查更新失败（HTTP ${res.statusCode}）', status: res.statusCode);
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        throw UpdateException('GitHub 回的格式看不懂，可能被网络中间人换掉了');
      }
      if (decoded is! Map<String, dynamic>) {
        throw UpdateException('GitHub 回的格式看不懂');
      }

      final tag = '${decoded['tag_name'] ?? decoded['name'] ?? ''}'.trim();
      final notes = '${decoded['body'] ?? ''}'.trim();
      final assets = decoded['assets'];
      if (assets is List) {
        for (final asset in assets) {
          if (asset is! Map) continue;
          final name = '${asset['name'] ?? ''}'.toLowerCase();
          if (!name.endsWith('.apk')) continue;
          final url = '${asset['browser_download_url'] ?? ''}'.trim();
          if (url.isEmpty) continue;
          final size = asset['size'];
          return UpdateInfo(
            tag: tag.isEmpty ? '未命名版本' : tag,
            apkUrl: url,
            notes: notes,
            size: size is num ? size.toInt() : 0,
          );
        }
      }
      throw UpdateException(
        tag.isEmpty ? '最新 release 里没有 .apk 安装包' : '最新 release（$tag）里没有 .apk 安装包',
      );
    } on UpdateException {
      rethrow;
    } on SocketException catch (e) {
      throw UpdateException('连不上 GitHub：${e.message}');
    } on HandshakeException catch (e) {
      throw UpdateException('和 GitHub 的 TLS 握手失败：${e.message}');
    } on TimeoutException {
      throw UpdateException('GitHub 太久没回应（超时）');
    } on HttpException catch (e) {
      throw UpdateException('下载安装包失败：${e.message}');
    } finally {
      http.close(force: true);
    }
  }

  /// 把安装包下载到本地，返回它的**绝对路径** —— 这里刻意**不**拉起安装器。
  ///
  /// 试过的两条路都不成立，所以这一版是降级方案，页面按下面的约定接线：
  /// * `Process.run('am', ['start', ...])`：`am` 是 shell 脚本、要先过 `app_process`，
  ///   普通应用进程 exec 它只会拿到 `Cannot run program "am"`，在真机上不可靠；
  /// * 正规做法是 `Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)` 授权后，用
  ///   `ACTION_VIEW` + `application/vnd.android.package-archive` 拉起安装界面，这需要写平台
  ///   通道，或者引 `url_launcher` / `open_filex` 这类插件 —— 依赖由主控统一加，这一轮不加。
  ///
  /// 降级后的交互：本方法返回路径，页面把它显示出来（用户去「文件」里点开就能装），
  /// 或者页面提供「复制下载链接」让用户丢进浏览器，由系统下载器自己弹安装提示。
  static Future<String> openApk(
    String url, {
    void Function(double)? onProgress,
  }) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw UpdateException('安装包地址不对：$url');
    }
    final dir = await downloadDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${_apkNameOf(uri)}');
    final http = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = _userAgent;
    IOSink? sink;
    var finished = false;
    try {
      final req = await http.getUrl(uri).timeout(const Duration(seconds: 20));
      // GitHub 的资产直链会 302 到 objects.githubusercontent.com，默认就跟。
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        throw UpdateException('下载安装包失败（HTTP ${res.statusCode}）', status: res.statusCode);
      }
      final total = res.contentLength;
      var received = 0;
      onProgress?.call(0);
      sink = file.openWrite();
      await for (final part in res.timeout(const Duration(seconds: 90))) {
        sink.add(part);
        received += part.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0.0, 1.0).toDouble());
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total > 0 && received != total) {
        throw UpdateException('安装包没下全（$received / $total 字节）');
      }
      onProgress?.call(1);
      finished = true;
      return file.absolute.path;
    } on UpdateException {
      rethrow;
    } on SocketException catch (e) {
      throw UpdateException('连不上 GitHub：${e.message}');
    } on TimeoutException {
      throw UpdateException('下载安装包超时');
    } on FileSystemException catch (e) {
      throw UpdateException('写安装包失败：${e.message}');
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // 连接已断，close 失败不影响结论。
        }
      }
      http.close(force: true);
      if (!finished) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // 半成品删不掉只能留着，异常已经说明了失败。
        }
      }
    }
  }

  /// 比较两个版本号，<0 表示 [a] 更旧。见顶层 [compareVersions]。
  static int compare(String a, String b) => compareVersions(a, b);

  /// 资产直链最后一段通常就是 `aidock-0.16.0.apk`；不是 `.apk` 就自己编一个。
  static String _apkNameOf(Uri uri) {
    final segments = uri.pathSegments;
    var last = segments.isEmpty ? '' : segments.last;
    if (!last.toLowerCase().endsWith('.apk')) {
      last = 'aidock-${DateTime.now().millisecondsSinceEpoch}.apk';
    }
    return last.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  }
}
