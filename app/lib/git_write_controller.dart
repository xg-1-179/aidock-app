import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/foundation.dart';

/// Git 的写操作：暂存、取消暂存、提交。
///
/// 打的是宿主**原路径** `/api/mobile/v1/git/*`（没有 `/link/*` 别名），契约见
/// `dsh-mobile-plugin/lib/mobile/git.js`：
///
/// - `POST /git/stage`   body `{paths?: string[] | path?: string, all?: bool}`
/// - `POST /git/unstage` body 同上
/// - `POST /git/commit`  body `{message}` —— 只提交**已暂存**那批，没有 `paths`，也没有 `amend`
/// - `GET  /git/status`  → `{ok, staged, unstaged, untracked, conflicted}`
///
/// 写回包都带一份新的 `status`，本地就直接用它刷新，省一次往返。
class GitWriteController extends ChangeNotifier {
  GitWriteController(this.client, {this.workspaceId});

  final DshClient client;

  /// git 那一组接口要 `workspaceId`（宿主按工作区定位仓库根）。为空时按「宿主默认」，
  /// 但那多半会被 400 拒掉，所以页面构造时一定把当前工作区传进来。
  final String? workspaceId;

  String get _qs => workspaceId == null
      ? ''
      : '?workspaceId=${Uri.encodeQueryComponent(workspaceId!)}';

  Map<String, dynamic> _status = const <String, dynamic>{};
  bool _busy = false;
  String? _error;
  String? _lastCommit;
  bool _disposed = false;

  /// 最近一次拿到的 `/git/status`（写操作回包里的那份也算）。
  Map<String, dynamic> get status => _status;

  /// 有请求在飞。
  bool get busy => _busy;

  /// 上一次操作的失败原因，已经翻成人话；成功后清空。
  String? get error => _error;

  /// 上一次提交的短 hash。
  String? get lastCommit => _lastCommit;

  /// 从 `status` 里取一组文件（`staged` / `unstaged` / `untracked` / `conflicted`）。
  List<Map<String, dynamic>> group(String key) {
    final raw = _status[key];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// 重读 `GET /git/status`。
  Future<void> refreshStatus() => _run(() async {
        _status = await client.api('GET', '/git/status', query: _qs);
      });

  /// 全部暂存（`git add -A`）。
  Future<void> stageAll() => _run(() async {
        final r = await client.api(
          'POST',
          '/git/stage',
          payload: <String, dynamic>{'all': true, if (workspaceId != null) 'workspaceId': workspaceId!},
        );
        _applyStatus(r);
      });

  /// 暂存一个文件。
  Future<void> stage(String path) {
    final target = path.trim();
    if (target.isEmpty) return Future<void>.value();
    return _run(() async {
      final r = await client.api(
        'POST',
        '/git/stage',
        payload: <String, dynamic>{
          'paths': <String>[target],
          if (workspaceId != null) 'workspaceId': workspaceId!,
        },
      );
      _applyStatus(r);
    });
  }

  /// 取消暂存一个文件。
  Future<void> unstage(String path) {
    final target = path.trim();
    if (target.isEmpty) return Future<void>.value();
    return _run(() async {
      final r = await client.api(
        'POST',
        '/git/unstage',
        payload: <String, dynamic>{
          'paths': <String>[target],
          if (workspaceId != null) 'workspaceId': workspaceId!,
        },
      );
      _applyStatus(r);
    });
  }

  /// 提交已暂存的文件。
  ///
  /// [amend] 只是签名上的占位：宿主这版 `git/commit` 不收 `amend`，真要改写上一次提交
  /// 得回电脑上做。所以这里不假装支持，直接给一句人话说明。
  Future<void> commit(String message, {bool amend = false}) {
    final text = message.trim();
    if (text.isEmpty) {
      _reject('先写一句提交信息');
      return Future<void>.value();
    }
    if (amend) {
      _reject('宿主这版不支持改写上一次提交，只能新建一次提交');
      return Future<void>.value();
    }
    return _run(() async {
      final r = await client.api(
        'POST',
        '/git/commit',
        payload: <String, dynamic>{'message': text, if (workspaceId != null) 'workspaceId': workspaceId!},
      );
      final short = '${r['shortHash'] ?? r['hash'] ?? ''}'.trim();
      _lastCommit = short.isEmpty ? null : short;
      // 提交已经成功了：接下来这次刷新失败不该把成功翻成失败。
      try {
        _status = await client.api('GET', '/git/status', query: _qs);
      } on DshClientException catch (_) {
        // 留着提交前那份 status，页面滚回列表时还会再刷一次。
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      await action();
    } on DshClientException catch (e) {
      _error = _humanize(e);
    } catch (_) {
      _error = '刚才那步没成功，稍后再试';
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _reject(String message) {
    _error = message;
    _notify();
  }

  void _applyStatus(Map<String, dynamic> response) {
    final next = response['status'];
    if (next is Map) _status = Map<String, dynamic>.from(next);
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 宿主错误 → 一句人话。401/403 是凭据过期，400/409 直接用宿主写好的中文。
  static String _humanize(DshClientException e) {
    final code = e.status;
    if (code == 401 || code == 403) {
      return '这台设备没有权限了：重启一次 DSH 或重新配对';
    }
    final message = e.message.trim();
    if (code == 400 || code == 409) {
      return message.isEmpty || message == 'request failed' ? '宿主拒绝了这次操作' : message;
    }
    if (message.isNotEmpty && message != 'request failed') return message;
    return '连不上电脑，检查一下网络';
  }
}
