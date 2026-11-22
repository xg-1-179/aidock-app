import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/foundation.dart';

/// 会话管理员动作里能出错的唯一出口：`message` 已经是给人看的中文，
/// 页面直接展示即可；`status` 留给调用方做分支（401 该重连、404 该把入口收起来）。
class SessionsAdminException implements Exception {
  SessionsAdminException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// 「会话」一行的四个管理员动作：置顶 / 归档 / 删除 / 导出。
///
/// 所有请求都走 `client.api(...)`：它负责补 `/api/mobile/v1` 前缀、按模板签名、
/// 带授权头，所以这里只写相对路径。宿主的接口形状以
/// `dsh-mobile-plugin/lib/mobile/workspaces.js` 为准：
///
/// * 置顶 / 取消置顶：`POST /workspace/pin-session`、`POST /workspace/unpin-session`，
///   body 只有 `{sessionId}`，回 `{ok:true, pinnedSessionIds:[...]}`；
/// * 归档：`POST /workspace/archive-session`，body `{sessionId, stopActivity?}`，
///   回 `{ok:true, archivedSessionIds:[...]}`；
/// * 删除：移动端**没有**按会话硬删除的路由（宿主注释写明归档就是移动端的「删除」语义），
///   所以 [remove] 走归档并顺带 `stopActivity:true`，把还在跑的那一轮停掉；
/// * 导出：[exportZip] 目前无法落盘，原因见该方法的注释。
///
/// 失败一律先归一成 [SessionsAdminException] 再抛，同时把话术留在 [error] 里 ——
/// 底部操作表靠 [error] 在表内显示错误行，而不是弹一个转瞬即逝的 SnackBar。
class SessionsAdminController extends ChangeNotifier {
  SessionsAdminController(this.client);

  final DshClient client;

  bool _busy = false;
  bool _disposed = false;
  String? _error;
  String? _lastSavedPath;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 表被滑走之后请求可能还在飞：给已释放的 ChangeNotifier 发通知会在 debug 里炸，
  /// 所以收尾通知统一从这里过一道。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 有请求在飞。页面据此禁用按钮、显示进度行。
  bool get busy => _busy;

  /// 最近一次失败的人话；开始下一次操作时清空。
  String? get error => _error;

  /// 导出成功时落盘的绝对路径（[exportZip] 通了之后才有值）。
  String? get lastSavedPath => _lastSavedPath;

  /// 置顶 / 取消置顶。`pinned` 是「做完之后想要的状态」。
  Future<void> pin(String sessionId, bool pinned) {
    final path = pinned ? '/workspace/pin-session' : '/workspace/unpin-session';
    return _guard<void>(() async {
      final body = await client.api(
        'POST',
        path,
        payload: <String, dynamic>{'sessionId': sessionId},
      );
      _ensureOk(body, pinned ? '置顶' : '取消置顶');
    });
  }

  /// 归档：从列表里收起，日志仍留在电脑上（宿主侧可取消归档）。
  Future<void> archive(String sessionId) =>
      _guard<void>(() => _archiveSession(sessionId, stopActivity: false));

  /// 「删除」：移动端能做到的最接近的一步 —— 归档，并把还在跑的那一轮停掉。
  ///
  /// 宿主没有删单条会话的接口，唯一的重活是 `workspace/clear-archived`
  /// （清空全部已归档会话，且要 `confirm:true`），它不是「删这一条」，所以不在这里调。
  Future<void> remove(String sessionId) =>
      _guard<void>(() => _archiveSession(sessionId, stopActivity: true));

  /// 导出整段会话为 zip。
  ///
  /// 现阶段只能如实报错，不能伪造一个路径。卡点在传输层，不在业务层：
  ///
  /// * 宿主只有两条导出路由 —— `GET /session-log`（sessionId + includeDescendants）
  ///   与 `POST /session/archive`（现场把勾选的文件打包）—— 两条都直接把
  ///   `application/zip` 字节流写进响应体；
  /// * App 这边的 [DshClient] 走 `IoDshTransport`，响应体是用
  ///   `utf8.decoder.bind(res).join()` 收成 `String` 的
  ///   （`packages/dsh_link_protocol/lib/src/client/transport.dart:86`），二进制一过就坏；
  /// * `AIDockDownloader` 只吃「电脑上的文件路径」（内部固定打
  ///   `/api/mobile/v1/file/read` 再按块解信封），没有「给我一条 URL 拿字节」的入口。
  ///
  /// 真接上需要一条按字节下载的通道，做法见下面的 TODO。
  Future<String> exportZip(String sessionId) {
    // TODO(session-export): 传输层能按字节收响应后，换成
    //   GET /api/mobile/v1/session-log?sessionId=<id>&includeDescendants=true 取原始的
    //   application/zip 响应（分块信封的 AAD 是 v2|down|file|<path>|<请求 nonce>|<块序号>，
    //   密钥用 client.keys.down），再照宿主自己的命名存进
    //   AIDockDownloader.downloadDirectory()，把落盘路径记进 _lastSavedPath 并 return 它。
    final name = _suggestedZipName(sessionId);
    return _guard<String>(() async {
      throw SessionsAdminException(
        '导出还没接上：电脑上的导出接口只回 zip 字节流，而这个 App 的下载通道只认电脑上的'
        '文件路径，中间没有「按字节下载」这一环。补上之后，这里会直接存成 $name。',
      );
    });
  }

  /// 宿主自己的导出文件名就是 `dsh-session-<会话 id>.zip`（mobile/session-log.js），
  /// 这里照抄，等字节通道补上就能直接用。
  static String _suggestedZipName(String sessionId) {
    final safe = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return 'dsh-session-${safe.isEmpty ? 'session' : safe}.zip';
  }

  Future<void> _archiveSession(String sessionId, {required bool stopActivity}) async {
    final body = await client.api(
      'POST',
      '/workspace/archive-session',
      payload: <String, dynamic>{
        'sessionId': sessionId,
        if (stopActivity) 'stopActivity': true,
      },
    );
    _ensureOk(body, stopActivity ? '删除' : '归档');
  }

  /// 宿主对这几条写操作的「业务失败」有时是 200 + `{ok:false,error:{message}}`，
  /// HTTP 层看不出来，只能自己认。
  void _ensureOk(Map<String, dynamic> body, String what) {
    if (body['ok'] != false) return;
    final err = body['error'];
    final message = err is Map && err['message'] is String ? '${err['message']}'.trim() : '';
    throw SessionsAdminException(message.isEmpty ? '$what没成功，电脑没给原因' : message);
  }

  /// 统一包一层：置 busy、清旧错、把各类异常翻成人话、收尾通知。
  Future<T> _guard<T>(Future<T> Function() body) async {
    if (_busy) {
      const message = '上一个操作还没结束，等它一下';
      _error = message;
      _notify();
      throw SessionsAdminException(message);
    }
    _busy = true;
    _error = null;
    _notify();
    try {
      return await body();
    } on SessionsAdminException catch (e) {
      _error = e.message;
      rethrow;
    } on DshClientException catch (e) {
      final message = _humanize(e);
      _error = message;
      throw SessionsAdminException(message, status: e.status);
    } on FormatException catch (e) {
      final message = '电脑回来的响应读不懂（${e.message}）';
      _error = message;
      throw SessionsAdminException(message);
    } catch (e) {
      final message = '这次没走通：$e';
      _error = message;
      throw SessionsAdminException(message);
    } finally {
      _busy = false;
      _notify();
    }
  }

  String _humanize(DshClientException e) {
    final status = e.status;
    if (status == 401) {
      return '这台电脑还没加载新接口（重启一次 DSH），或者登录凭据过期了';
    }
    if (status == 403) {
      final message = e.message.trim();
      if (message.isEmpty || message == 'request failed') {
        return '电脑不让改这个会话（403）：可能已经归档了，也可能它不在可操作的范围里';
      }
      return message;
    }
    if (status == 404) {
      return '这个会话已经不在了';
    }
    if (status != null) {
      return '${e.message}（HTTP $status）';
    }
    return e.message.isEmpty ? '没连上电脑，看看它还在不在同一个网里' : e.message;
  }
}
