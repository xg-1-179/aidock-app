import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notify.dart';

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.text,
    this.streaming = false,
    List<String>? images,
  }) : images = images ?? <String>[];
  final String role;
  String text;
  bool streaming;

  /// 这一条里带的图片（base64 原字节）；历史里按 `attachmentId` 现取，
  /// 取不到就是空列表，气泡里仍显示「（图片）」占位。
  List<String> images;
}

/// 选项：宿主给 `{label, description?}`，老形态可能只给字符串。
class QuestionOption {
  const QuestionOption({required this.label, this.description});
  final String label;
  final String? description;
}

/// 一道题。`options` 为空表示自由作答（只填 `custom`）。
class QuestionItem {
  const QuestionItem({
    required this.id,
    required this.text,
    this.header,
    this.detail,
    this.options = const <QuestionOption>[],
    this.multiSelect = false,
  });
  final String id;
  final String text;
  final String? header;
  final String? detail;
  final List<QuestionOption> options;
  final bool multiSelect;
}

/// 一张待回答的提问卡（`question/requested`）。
class QuestionCard {
  const QuestionCard({required this.rpcId, required this.sessionId, required this.questions});
  final String rpcId;
  final String sessionId;
  final List<QuestionItem> questions;
}

/// 一台连过的电脑。手机里存的是「再回去一次」所需的最小凭据集合：
/// 主机地址、设备私钥、keyId、实例号、授权 token 与设备凭据。
class SavedMachine {
  SavedMachine({
    required this.host,
    required this.deviceKeyB64,
    required this.keyId,
    required this.instanceId,
    required this.token,
    required this.credential,
    this.permissions = '',
    this.lastAt = 0,
  });

  final String host;
  final String deviceKeyB64;
  final String keyId;
  final String instanceId;
  final String token;
  final String credential;
  final String permissions;
  int lastAt;

  Map<String, dynamic> toJson() => {
        'host': host,
        'key': deviceKeyB64,
        'keyId': keyId,
        'instanceId': instanceId,
        'token': token,
        'credential': credential,
        'permissions': permissions,
        'lastAt': lastAt,
      };

  static SavedMachine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final host = '${raw['host'] ?? ''}';
    if (host.isEmpty) return null;
    return SavedMachine(
      host: host,
      deviceKeyB64: '${raw['key'] ?? ''}',
      keyId: '${raw['keyId'] ?? ''}',
      instanceId: '${raw['instanceId'] ?? ''}',
      token: '${raw['token'] ?? ''}',
      credential: '${raw['credential'] ?? ''}',
      permissions: '${raw['permissions'] ?? ''}',
      lastAt: raw['lastAt'] is int ? raw['lastAt'] as int : 0,
    );
  }
}

class SessionItem {
  SessionItem({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.updatedAt = 0,
    this.running = false,
    this.pending = false,
    this.failed = false,
    this.pinned = false,
  });
  final String id;
  String title;
  String subtitle;
  int updatedAt;
  bool running;
  bool pending;
  bool failed;
  bool pinned;
}

class ApprovalCard {
  ApprovalCard({
    required this.rpcId,
    required this.sessionId,
    required this.approvalId,
    this.toolName = '',
    this.reason = '',
    this.fact = '',
    this.classLabel = '',
    this.command = '',
    this.rememberable = false,
  });

  final String rpcId;
  final String sessionId;
  final String approvalId;
  final String toolName;
  final String reason;
  final String fact;
  final String classLabel;
  final String command;
  final bool rememberable;

  String get headline {
    if (reason.isNotEmpty) return reason;
    if (toolName.isNotEmpty) return '工具 $toolName 请求越权执行';
    return '有一项操作在等你的许可';
  }
}

class AppState extends ChangeNotifier {
  IoDshTransport? _transport;

  DshClient? _client;
  DshClient? get client => _client;

  String? instanceId;
  String hostLabel = '';
  String? error;
  bool busy = false;
  bool paired = false;

  String connectionKind = '';

  // ---- 免码重连：上次配对的东西存在手机本地 ----
  static const String _kHost = 'aidock.host';
  static const String _kDeviceKey = 'aidock.deviceKey';
  static const String _kKeyId = 'aidock.keyId';
  static const String _kInstance = 'aidock.instanceId';
  static const String _kToken = 'aidock.token';
  static const String _kCredential = 'aidock.deviceCredential';
  static const String _kPerms = 'aidock.permissions';
  static const String _kMachines = 'aidock.machines';

  String? savedHost;
  String? savedPermissions;
  bool get hasSaved => machines.isNotEmpty;

  /// App 是否在前台；后台时收到审批/提问才发系统通知。
  bool appForeground = true;

  /// 连过的电脑（最近连的排最前）。
  final List<SavedMachine> machines = [];

  /// 上一次多路探测的结果（连接诊断用）：每条是 `地址 → 成功/失败原因`。
  final List<String> probeLog = [];

  final List<SessionItem> sessions = [];
  final List<ChatMessage> messages = [];
  final List<ApprovalCard> approvals = [];
  /// 待回答的提问卡（同一条 rpcId 只留一张）。
  final List<QuestionCard> questions = [];

  String? openSessionId;
  bool streamingNow = false;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _watchdog;
  Timer? _retryTimer;
  DateTime _lastFrameAt = DateTime.now();
  int _retryCount = 0;
  /// 断线自动重连中。界面据此画一条「正在重连」的提示，不打断正在看的消息。
  bool reconnecting = false;

  static Uri normalizeHost(String raw) {
    var s = raw.trim();
    if (s.isEmpty) throw const FormatException('请输入电脑地址');
    if (!s.contains('://')) s = 'http://$s';
    final uri = Uri.parse(s);
    if (uri.host.isEmpty) throw const FormatException('地址格式不正确');
    if (!uri.hasPort) {
      return Uri.parse('${uri.scheme}://${uri.host}:41873');
    }
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
  }

  /// 把用户填的一串地址拆成候选通道：逗号/空格/换行分隔，私网段算 lan、其余算 wan。
  ///
  /// 设计原则见 docs/CONNECTIVITY.md：没有任何一条通道是"必须存在"的，
  /// 全都摆在同一层并行探测，谁先答话就用谁。
  static List<Candidate> parseCandidates(String raw) {
    final parts = raw
        .split(RegExp(r'[,，\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    final out = <Candidate>[];
    final seen = <String>{};
    for (final part in parts) {
      final base = normalizeHost(part);
      final key = base.toString();
      if (!seen.add(key)) continue;
      out.add(Candidate(
        id: '${base.host}:${base.port}',
        baseUrl: base,
        kind: _kindOf(base.host),
      ));
    }
    return out;
  }

  static CandidateKind _kindOf(String host) {
    final ip = RegExp(r'^(\d{1,3})\.(\d{1,3})\.');
    final m = ip.firstMatch(host);
    if (m != null) {
      final a = int.parse(m.group(1)!);
      final b = int.parse(m.group(2)!);
      if (a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31)) {
        return CandidateKind.lan;
      }
    }
    if (host.endsWith('.local') || host == 'localhost') return CandidateKind.lan;
    return CandidateKind.wan;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  static String _hex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  /// 启动时读一次：有记录就在配对页顶上一张「上次连接的电脑」。
  Future<void> loadSaved() async {
    try {
      final p = await SharedPreferences.getInstance();
      machines.clear();
      final raw = p.getString(_kMachines);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            final m = SavedMachine.fromJson(item);
            if (m != null) machines.add(m);
          }
        }
      }
      // 老版本只存了一台（散键），迁进来后删掉旧的键。
      final legacyHost = p.getString(_kHost);
      if (machines.isEmpty && legacyHost != null && legacyHost.isNotEmpty) {
        final migrated = SavedMachine(
          host: legacyHost,
          deviceKeyB64: p.getString(_kDeviceKey) ?? '',
          keyId: p.getString(_kKeyId) ?? '',
          instanceId: p.getString(_kInstance) ?? '',
          token: p.getString(_kToken) ?? '',
          credential: p.getString(_kCredential) ?? '',
          permissions: p.getString(_kPerms) ?? '',
        );
        machines.add(migrated);
        await _persistMachines();
      }
      machines.sort((a, b) => b.lastAt.compareTo(a.lastAt));
      savedHost = machines.isEmpty ? null : machines.first.host;
      savedPermissions = machines.isEmpty ? null : machines.first.permissions;
      notifyListeners();
    } catch (_) {
      // 存储不可用不该挡住输入六位码这条路。
    }
  }

  Future<void> _persistMachines() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kMachines,
        jsonEncode(machines.map((m) => m.toJson()).toList()),
      );
      for (final k in [_kHost, _kDeviceKey, _kKeyId, _kInstance, _kToken, _kCredential, _kPerms]) {
        await p.remove(k);
      }
    } catch (_) {}
  }

  Future<void> _rememberDevice({
    required String host,
    required List<int> deviceKey,
    required String keyId,
    required String instanceId,
    required Map<String, dynamic> grant,
  }) async {
    final token = grant['token'] is String ? grant['token'] as String : '';
    final credential =
        grant['deviceCredential'] is String ? grant['deviceCredential'] as String : '';
    final perms = grant['permissions'] is List ? (grant['permissions'] as List).join(',') : '';
    savedHost = host;
    savedPermissions = perms;
    final machine = SavedMachine(
      host: host,
      deviceKeyB64: base64Url.encode(deviceKey).replaceAll('=', ''),
      keyId: keyId,
      instanceId: instanceId,
      token: token,
      credential: credential,
      permissions: perms,
      lastAt: DateTime.now().millisecondsSinceEpoch,
    );
    machines.removeWhere((m) => m.host == host);
    machines.insert(0, machine);
    await _persistMachines();
  }

  /// 忘掉一台电脑（不传就忘掉最近那台）。只删本地记录，不动电脑上的设备授权。
  Future<void> forgetSaved([SavedMachine? machine]) async {
    final target = machine ?? (machines.isEmpty ? null : machines.first);
    if (target != null) machines.removeWhere((m) => m.host == target.host);
    savedHost = machines.isEmpty ? null : machines.first.host;
    savedPermissions = machines.isEmpty ? null : machines.first.permissions;
    await _persistMachines();
    notifyListeners();
  }

  /// 用手机里存的凭据直接回去，不扫码不输六位码。
  /// 失败点很明确：凭据过期（401）→ 让用户重新拿码；连不上 → 报连接错误。
  Future<void> reconnectSaved([SavedMachine? machine]) async {
    final target = machine ?? (machines.isEmpty ? null : machines.first);
    if (target == null) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final keyB64 = target.deviceKeyB64;
      final keyId = target.keyId;
      final instance = target.instanceId;
      final token = target.token;
      final credential = target.credential;
      if (keyB64.isEmpty || keyId.isEmpty) {
        throw const FormatException('本地凭据不完整，请用六位码重连一次');
      }
      final base = Uri.parse(target.host);
      final transport = IoDshTransport(base);
      _transport?.close();
      _transport = transport;
      final keys = await DshCrypto.sessionKeys(
        Uint8List.fromList(base64Url.decode(base64Url.normalize(keyB64))),
      );
      _client = DshClient(
        baseUrl: base,
        transport: transport,
        keys: keys,
        keyId: keyId,
        instanceId: instance,
        authToken: token,
        deviceCredential: credential,
      );
      instanceId = instance;
      hostLabel = '${base.host}:${base.port}';
      paired = true;
      await refreshSessions();
      if (error != null) {
        throw StateError(error!);
      }
    } on DshClientException catch (e) {
      paired = false;
      error = e.status == 401
          ? '上次的登录凭据过期了，重新用六位码连一次'
          : '${e.message}（HTTP ${e.status}）';
    } catch (e) {
      paired = false;
      error = '连不上上次那台电脑：$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> connect(String rawHost, String code) async {
    busy = true;
    error = null;
    probeLog.clear();
    notifyListeners();
    try {
      final candidates = parseCandidates(rawHost);
      if (candidates.isEmpty) throw const FormatException('请输入电脑地址');
      // 多路并行探测：每条候选 3 秒超时，先答话的先用，其余继续收集供诊断。
      final probe = ConnectionProbe(
        timeout: const Duration(seconds: 3),
        probe: (candidate, timeout) async {
          final t = IoDshTransport(candidate.baseUrl, timeout: timeout);
          try {
            final r = await t.send(
              method: 'GET',
              // 探活打 `/health`：它是唯一在公网监听口上无条件放行的端点
              // （配对前的 `/link/info` 要等宿主重启后才免鉴权，探活不能依赖它）。
              path: '/api/mobile/v1/health',
              query: '',
              headers: const {},
              body: '',
            );
            if (!r.ok) throw StateError('HTTP ${r.status}');
          } finally {
            t.close();
          }
        },
      );
      final report = await probe.race(candidates);
      for (final ok in report.successes) {
        probeLog.add('${ok.candidate.id} 可用 ${ok.latency.inMilliseconds}ms');
      }
      for (final bad in report.failures) {
        probeLog.add('${bad.candidate.id} 失败：${bad.error}');
      }
      final winner = report.winner;
      if (winner == null) {
        throw DshClientException('这些地址都连不上（${candidates.length} 条，均超时）');
      }
      final base = winner.candidate.baseUrl;
      connectionKind = winner.candidate.kind.name;
      hostLabel = '${base.host}:${base.port}';
      _transport?.close();
      final transport = IoDshTransport(base);
      _transport = transport;
      var info = await transport.send(
        method: 'GET',
        path: '/api/mobile/v1/link/info',
        query: '',
        headers: const {},
        body: '',
      );
      Map<String, dynamic> meta = const {};
      if (info.ok) {
        final decoded = jsonDecode(info.body);
        if (decoded is Map<String, dynamic>) meta = decoded;
      }
      if (meta['ok'] != true) {
        // 回落：`/health` 也带 instanceId，公网口上它一定放行。
        info = await transport.send(
          method: 'GET',
          path: '/api/mobile/v1/health',
          query: '',
          headers: const {},
          body: '',
        );
        if (!info.ok) {
          throw DshClientException('电脑没有响应', status: info.status, body: info.body);
        }
        final decoded = jsonDecode(info.body);
        meta = decoded is Map<String, dynamic> ? decoded : const {};
      }
      if (meta['ok'] != true) {
        throw DshClientException('${meta['error'] ?? '电脑没有就绪'}');
      }
      instanceId = '${meta['instanceId']}';
      final deviceKey = _randomBytes(32);
      final keyId = _hex(_randomBytes(8));
      final result = await DshClient.pair(
        baseUrl: base,
        transport: transport,
        ticket: utf8.encode(code.trim()),
        instanceId: instanceId!,
        deviceKey: deviceKey,
        keyId: keyId,
        pairingCode: code.trim(),
        pairPath: '/api/mobile/v1/link/pair',
      );
      _client = result.client;
      paired = true;
      connectionKind = '${meta['transport'] ?? 'direct'}';
      // 存下来：下次开 App 不用再问一遍地址和六位码。
      await _rememberDevice(
        host: base.toString(),
        deviceKey: deviceKey,
        keyId: keyId,
        instanceId: instanceId!,
        grant: result.grant,
      );
      await refreshSessions();
    } on DshClientException catch (e) {
      error = e.status == 401
          ? '连接码不对，或已经过期'
          : (e.status == null ? e.message : '${e.message}（HTTP ${e.status}）');
      paired = false;
    } on FormatException catch (e) {
      error = e.message;
      paired = false;
    } catch (e) {
      error = '连不上：$e';
      paired = false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }


  static int _intOf(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

  /// 列表行第二行：优先用宿主给的最后一条消息预览（`lastMessage.text`），
  /// 其次 lastTurn 的失败原因，最后退回 cwd。
  static String _previewOf(Map<String, dynamic> e) {
    final last = e['lastMessage'];
    if (last is Map) {
      final text = '${last['text'] ?? ''}'.trim();
      if (text.isNotEmpty) {
        return text.replaceAll('\n', ' ');
      }
    }
    final turn = e['lastTurn'];
    final err = e['lastTurnError'];
    if (err != null && err != false) {
      return '上一轮失败：$err';
    }
    if (turn is Map && turn['at'] != null) {
      return '最近一轮已结束';
    }
    final cwd = '${e['cwd'] ?? ''}'.trim();
    if (cwd.isNotEmpty) return cwd;
    return '';
  }

  /// 当前会话的模型快照（宿主原样给的）。
  Map<String, dynamic>? modelInfo;
  bool loadingModels = false;

  /// 顶栏显示用：当前模型名，拿不到就退回「模型」。
  String get modelLabel {
    final cur = modelInfo?['current'];
    if (cur is Map && cur['model'] is String) return '${cur['model']}';
    return '模型';
  }

  Future<void> loadModels() async {
    final c = _client;
    final sid = openSessionId;
    if (c == null || sid == null) return;
    loadingModels = true;
    notifyListeners();
    try {
      modelInfo = await c.models(sid);
    } on DshClientException catch (e) {
      if (_isAuthError(e)) _stopForAuth();
      modelInfo = null;
    } catch (_) {
      modelInfo = null;
    }
    loadingModels = false;
    notifyListeners();
  }

  Future<void> chooseModel(String provider, String model, {String? effort}) async {
    final c = _client;
    final sid = openSessionId;
    if (c == null || sid == null) return;
    final prev = modelInfo;
    // 乐观更新：宿主拒绝时回滚，别让顶栏一直挂着旧名字。
    modelInfo = <String, dynamic>{
      ...?prev,
      'current': <String, dynamic>{
        'provider': provider,
        'model': model,
        if (effort != null && effort.isNotEmpty) 'reasoningEffort': effort,
      },
    };
    notifyListeners();
    try {
      await c.selectModel(sid, provider, model, reasoningEffort: effort);
      await loadModels();
      error = null;
    } on DshClientException catch (e) {
      modelInfo = prev;
      if (_isAuthError(e)) {
        _stopForAuth();
      } else {
        error = '切换模型失败：${e.message}';
      }
    } catch (e) {
      modelInfo = prev;
      error = '切换模型失败：$e';
    }
    notifyListeners();
  }

  Future<void> refreshSessions() async {
    final c = _client;
    if (c == null) return;
    try {
      final rows = await c.sessions();
      sessions
        ..clear()
        ..addAll(rows.map((e) => SessionItem(
              id: '${e['id'] ?? e['sessionId'] ?? e['session_id'] ?? ''}',
              title: '${e['title'] ?? e['name'] ?? '未命名会话'}',
              subtitle: _previewOf(e),
              updatedAt: _intOf(e['updatedAt'] ?? e['ts']),
              running: e['running'] == true,
              pending: e['pendingInteraction'] != null && e['pendingInteraction'] != false,
              failed: e['lastTurnError'] != null && e['lastTurnError'] != false,
              pinned: e['pinned'] == true,
            )).where((e) => e.id.isNotEmpty));
      error = null;
    } on DshClientException catch (e) {
      error = e.status == 500 && (e.body ?? '').contains('apiProxy')
          ? '电脑端插件还没加载完（缺少宿主接口），需要重启一次 DSH 再连'
          : '读取会话失败：${e.message}（HTTP ${e.status}）';
    } catch (e) {
      error = '读取会话失败：$e';
    }
    notifyListeners();
  }

  /// 在电脑上新开一个会话，再刷新列表并直接打开它。
  ///
  /// 不传落点＝落到宿主的默认工作区：手机上没有「选目录」的必要，先把「点一下就能聊」
  /// 打通；要指定项目时再从会话页传 `workspaceId`/`cwd`。
  /// 电脑上这条会话可用的斜杠命令（聊天框里打 `/` 时提示）。
  final List<Map<String, dynamic>> slashCommands = [];
  bool loadingCommands = false;

  Future<void> loadCommands() async {
    final c = _client;
    final sid = openSessionId;
    if (c == null || sid == null || loadingCommands) return;
    loadingCommands = true;
    slashCommands.clear();
    try {
      final list = await c.commands(sid);
      slashCommands.addAll(list);
    } catch (_) {
      // 命令表取不到不影响正常发消息，静默即可。
    } finally {
      loadingCommands = false;
      notifyListeners();
    }
  }

  /// 电脑上登记过的工作区（新建会话时可以选）。
  List<Map<String, dynamic>> workspaces = [];
  bool loadingWorkspaces = false;

  Future<void> loadWorkspaces() async {
    final c = _client;
    if (c == null || loadingWorkspaces) return;
    loadingWorkspaces = true;
    try {
      workspaces = await c.workspaces();
      error = null;
    } catch (e) {
      error = '读取工作区失败：$e';
    } finally {
      loadingWorkspaces = false;
      notifyListeners();
    }
  }

  /// 改会话标题（会话页长按菜单）。成功后就地更新列表条目。
  Future<bool> renameSession(String sessionId, String title) async {
    final c = _client;
    final name = title.trim();
    if (c == null || name.isEmpty) return false;
    try {
      final real = await c.renameSession(sessionId, name);
      for (final it in sessions) {
        if (it.id == sessionId) {
          it.title = real;
          break;
        }
      }
      notifyListeners();
      return true;
    } catch (e) {
      error = '重命名失败：$e';
      notifyListeners();
      return false;
    }
  }

  Future<void> createSession({String? workspaceId}) async {
    final c = _client;
    if (c == null) return;
    busy = true;
    notifyListeners();
    try {
      final created = await c.newSession(workspaceId: workspaceId);
      final id = '${created['sessionId'] ?? created['id'] ?? ''}';
      final cwd = '${created['cwd'] ?? ''}';
      await refreshSessions();
      if (id.isNotEmpty) {
        await openSession(SessionItem(
          id: id,
          title: '新会话',
          subtitle: cwd,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          running: false,
          pending: false,
          failed: false,
          pinned: false,
        ));
      }
      error = null;
    } on DshClientException catch (e) {
      error = e.status == null
          ? '新建会话失败：${e.message}'
          : '新建会话失败：${e.message}（HTTP ${e.status}）';
    } catch (e) {
      error = '新建会话失败：$e';
    }
    busy = false;
    notifyListeners();
  }

  Future<void> openSession(SessionItem item) async {
    await _sub?.cancel();
    _sub = null;
    // 上一段会话若还挂着重连计时器，换会话时必须停掉，否则它会把新会话顶掉。
    _retryTimer?.cancel();
    _retryTimer = null;
    reconnecting = false;
    _retryCount = 0;
    openSessionId = item.id;
    messages.clear();
    approvals.clear();
    questions.clear();
    _seenIds.clear();
    notifyListeners();
    final c = _client;
    if (c == null) return;
    // 先补历史，再挂流：流只负责「打开之后」发生的事，历史由 /session/messages 给。
    try {
      final rows = await c.messages(item.id, limit: 40);
      final pending = <int, List<String>>{};
      for (final row in rows) {
        final role = '${row['role'] ?? row['author'] ?? ''}';
        final text = _textOfMessage(row);
        if (text.isEmpty) continue;
        final id = '${row['id'] ?? ''}';
        if (id.isNotEmpty) _seenIds.add(id);
        final mine = role == 'user' || role == 'human';
        messages.add(ChatMessage(role: mine ? 'user' : 'assistant', text: text));
        final ids = _attachmentIdsOf(row);
        if (ids.isNotEmpty) pending[messages.length - 1] = ids;
      }
      if (pending.isNotEmpty) unawaited(_hydrateImages(c, item.id, pending));
      if (messages.isEmpty) {
        messages.add(ChatMessage(role: 'system', text: '这个会话还没有消息'));
      }
      error = null;
    } catch (e) {
      messages.add(ChatMessage(role: 'system', text: '历史读取失败：$e'));
    }
    notifyListeners();
    _attachStream(c, item.id);
    // 顶栏要显示当前模型，进会话就顺手拉一次（失败不阻塞打开）。
    unawaited(loadModels());
    unawaited(loadCommands());
  }

  /// 挂上会话流，并在断开时自己重连。
  ///
  /// 手机侧的断线原因太多（切网、锁屏、中转抖动、宿主换代），指望一条 SSE 从头活到尾不现实。
  /// 这里做三件事：① 掉线后按 1s/2s/4s/8s/15s 退避重连；② 40 秒没有任何帧（心跳 15 秒一发）
  /// 就当连接已死，主动断开重连；③ 重连成功后补一次历史，把断线期间漏掉的消息接回来。
  /// 当前挂着流的客户端与会话，供 `session/resync-required` 触发补历史。
  DshClient? _streamClient;
  String? _streamSessionId;
  /// 已经显示过的主机消息 id：补历史时按 id 去重，避免同一段被插两遍，
  /// 也不至于把「用户连发两条一样的文本」当成重复吞掉。
  final Set<String> _seenIds = <String>{};

  /// 把宿主此刻挂着的卡补进界面（审批 / 提问帧不带 seq，重连不会回放）。
  Future<void> _syncPending(DshClient c, String sessionId) async {
    try {
      final payload = await c.pendingCards(sessionId);
      final approval = payload['approval'];
      if (approval is Map<String, dynamic> && approval['type'] != null) {
        _onFrame(approval);
      }
      final question = payload['question'];
      if (question is Map<String, dynamic> && question['type'] != null) {
        _onFrame(question);
      }
    } catch (_) {
      // 补卡失败不致命：流本身还在，真卡再推送一次也能补上。
    }
  }

  /// 回到前台时补一次连接检查。
  ///
  /// 手机锁屏或切后台后，系统会掐掉长连接，而 Dart 的定时器也跟着停——只靠心跳看门狗，
  /// 用户解锁回来可能先盯着「正在自动重连…」等几十秒。这里不等计时器，直接判一次：
  /// 流已经没了就立刻重挂，流还挂着但很久没帧也重挂。
  void onResumed() {
    final c = _client;
    final sid = _streamSessionId ?? openSessionId;
    if (c != null && sid != null) {
      final idle = DateTime.now().difference(_lastFrameAt).inSeconds;
      if (_sub == null || reconnecting || idle >= 30) {
        _retryTimer?.cancel();
        _retryTimer = null;
        _retryCount = 0;
        _sub?.cancel();
        _sub = null;
        _attachStream(c, sid);
      } else {
        unawaited(_syncPending(c, sid));
      }
    }
    if (_client != null) unawaited(refreshSessions());
  }

  void _attachStream(DshClient c, String sessionId) {
    _streamClient = c;
    _streamSessionId = sessionId;
    _lastFrameAt = DateTime.now();
    // 挂上就先把条收掉：真断了 onError/onDone 会再把它立起来。等心跳帧再收
    // 会让「正在自动重连…」在安静会话里多挂 15 秒。
    if (reconnecting) reconnecting = false;
    _sub = c.stream(sessionId).listen((frame) {
      _lastFrameAt = DateTime.now();
      if (reconnecting) {
        reconnecting = false;
        _retryCount = 0;
        error = null;
        notifyListeners();
      }
      _onFrame(frame);
    }, onError: (Object e) {
      streamingNow = false;
      if (_isAuthError(e)) {
        _stopForAuth();
        return;
      }
      _scheduleReconnect(c, sessionId, '$e');
    }, onDone: () {
      streamingNow = false;
      _scheduleReconnect(c, sessionId, '连接已结束');
    });
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (openSessionId != sessionId) return;
      if (DateTime.now().difference(_lastFrameAt).inSeconds < 40) return;
      _retryCount = max(_retryCount, 1).toInt();
      _sub?.cancel();
      _sub = null;
      _scheduleReconnect(c, sessionId, '心跳超时');
    });
    unawaited(_syncPending(c, sessionId));
  }

  /// 401/403 不是「网断了」，重试一万次也不会好：直接把话说明白，让用户去重连。
  static bool _isAuthError(Object e) {
    if (e is DshClientException) {
      return e.status == 401 || e.status == 403;
    }
    final text = '$e';
    return text.contains('401') || text.contains('403');
  }

  void _stopForAuth() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    _sub?.cancel();
    _sub = null;
    reconnecting = false;
    streamingNow = false;
    error = '登录凭据过期了：断开后用六位码重新连一次';
    notifyListeners();
  }

  void _scheduleReconnect(DshClient c, String sessionId, String reason) {
    if (openSessionId != sessionId) return;
    if (_isAuthError(reason)) {
      _stopForAuth();
      return;
    }
    _retryTimer?.cancel();
    reconnecting = true;
    streamingNow = false;
    notifyListeners();
    final shift = min(_retryCount, 4).toInt();
    final seconds = min(15, 1 << shift).toInt();
    _retryCount++;
    _retryTimer = Timer(Duration(seconds: seconds), () async {
      if (openSessionId != sessionId) return;
      try {
        await _catchUp(c, sessionId);
        _attachStream(c, sessionId);
      } catch (e) {
        if (openSessionId != sessionId) return;
        if (_isAuthError(e)) {
          _stopForAuth();
          return;
        }
        _scheduleReconnect(c, sessionId, '$e');
      }
    });
  }

  /// 重连前补历史：只把断线期间新出现的消息接到尾巴上，不重刷整段。
  ///
  /// 去重按主机给的 `id`：老宿主不带 id 时只拿「最后两条」对齐，绝不在全表里找——
  /// 否则用户连发两条一样的文本，第二条会被当成重复吞掉。
  Future<void> _catchUp(DshClient c, String sessionId) async {
    final rows = await c.messages(sessionId, limit: 20);
    var added = 0;
    for (final row in rows) {
      final text = _textOfMessage(row);
      if (text.isEmpty) continue;
      final role = '${row['role'] ?? row['author'] ?? ''}';
      final mine = role == 'user' || role == 'human';
      final id = '${row['id'] ?? ''}';
      if (id.isNotEmpty) {
        if (!_seenIds.add(id)) continue;
      } else {
        final tail = messages.length >= 2 ? messages.sublist(messages.length - 2) : messages;
        final dup = tail.any((x) => x.text == text && x.role == (mine ? 'user' : 'assistant'));
        if (dup) continue;
      }
      messages.add(ChatMessage(role: mine ? 'user' : 'assistant', text: text));
      added++;
    }
    if (added > 0) notifyListeners();
  }

  void closeSession() {
    _sub?.cancel();
    _sub = null;
    _watchdog?.cancel();
    _watchdog = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    reconnecting = false;
    _retryCount = 0;
    openSessionId = null;
    messages.clear();
    approvals.clear();
    questions.clear();
    _seenIds.clear();
    streamingNow = false;
    notifyListeners();
  }

  /// 会话流的一帧。
  ///
  /// 宿主下发的是 `{type:'session/event', event:{type, data}}` 这样的包裹层：真正的事件类型
  /// 在内层的 `event.type` 上（`user/message`、`assistant/chunk`、`assistant/message`、
  /// `turn/end`…），正文在 `event.data` 上。心跳与收尾帧（`session/heartbeat`、
  /// `session/resync-required`）不进消息模型。
  void _onFrame(Map<String, dynamic> frame) {
    final outer = '${frame['type'] ?? ''}';
    if (outer == 'session/heartbeat') return;
    if (outer == 'session/resync-required') {
      // 宿主说「这一段漏了帧」：不猜丢了哪几条，直接按 JSONL 尾巴补一次历史。
      // 补历史本身会去重（`_catchUp` 里对齐末条文本），用户看到的是列表被填齐，
      // 而不是冒出一条「正在重新同步」的系统消息。
      final c = _streamClient;
      final sid = _streamSessionId;
      if (c != null && sid != null) unawaited(_catchUp(c, sid));
      return;
    }
    final event = frame['event'];
    final inner = event is Map<String, dynamic> ? event : frame;
    final type = '${inner['type'] ?? ''}';
    final data = inner['data'];
    final payload = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    switch (type) {
      case 'user/message':
        final text = _textOfMessage(payload);
        if (text.isNotEmpty) {
          // 自己刚发出的那条已经在本地乐观显示了，宿主随后必然回推同一条：
          // 再插一次屏幕上就会出现两条「一模一样」的用户消息。
          final last = messages.isEmpty ? null : messages.last;
          final dup = last != null && last.role == 'user' && last.text == text;
          if (!dup) messages.add(ChatMessage(role: 'user', text: text));
        }
        break;
      case 'assistant/chunk':
        final chunk = payload['chunk'];
        if (chunk is! Map) break;
        if ('${chunk['type']}' != 'text-delta') break;
        final delta = '${chunk['text'] ?? ''}';
        if (delta.isEmpty) break;
        streamingNow = true;
        if (messages.isNotEmpty && messages.last.role == 'assistant' && messages.last.streaming) {
          messages.last.text += delta;
        } else {
          messages.add(ChatMessage(role: 'assistant', text: delta, streaming: true));
        }
        break;
      case 'assistant/message':
        final msg = payload['message'];
        final text = _textOfMessage(msg is Map<String, dynamic> ? msg : payload);
        streamingNow = false;
        if (messages.isNotEmpty && messages.last.role == 'assistant') {
          final tail = messages.last;
          // 三种收尾都归到同一个气泡上：还在流式中、已经流完但文本相同、
          // 或者流式只拿到前半截（这一帧才是全量正文）。
          if (tail.streaming || tail.text == text || (tail.text.isNotEmpty && text.startsWith(tail.text))) {
            tail.streaming = false;
            if (text.isNotEmpty) tail.text = text;
            break;
          }
        }
        if (text.isNotEmpty) messages.add(ChatMessage(role: 'assistant', text: text));
        break;
      case 'question/requested':
        final raw = inner['questions'] ?? payload['questions'];
        final items = <QuestionItem>[];
        if (raw is List) {
          for (final q in raw) {
            if (q is! Map) continue;
            final id = '${q['id'] ?? ''}';
            final text = '${q['question'] ?? ''}';
            if (id.isEmpty || text.isEmpty) continue;
            final opts = <QuestionOption>[];
            final ro = q['options'];
            if (ro is List) {
              for (final o in ro) {
                if (o is String && o.trim().isNotEmpty) {
                  opts.add(QuestionOption(label: o.trim()));
                } else if (o is Map) {
                  final label = '${o['label'] ?? o['value'] ?? o['text'] ?? ''}'.trim();
                  if (label.isEmpty) continue;
                  final desc = '${o['description'] ?? ''}'.trim();
                  opts.add(QuestionOption(label: label, description: desc.isEmpty ? null : desc));
                }
              }
            }
            items.add(QuestionItem(
              id: id,
              text: text,
              header: q['header'] == null ? null : '${q['header']}',
              detail: q['detail'] == null ? null : '${q['detail']}',
              options: opts,
              multiSelect: q['multiSelect'] == true,
            ));
          }
        }
        final qRpc = '${inner['rpcId'] ?? payload['rpcId'] ?? ''}';
        if (qRpc.isNotEmpty && items.isNotEmpty) {
          final isNew = !questions.any((e) => e.rpcId == qRpc);
          questions.removeWhere((e) => e.rpcId == qRpc);
          questions.add(QuestionCard(
            rpcId: qRpc,
            sessionId: '${inner['sessionId'] ?? openSessionId ?? ''}',
            questions: items,
          ));
          if (isNew && !appForeground) {
            unawaited(Notifier.show('电脑在等你回答', items.first.text));
          }
        }
        break;
      case 'question/resolved':
        final qid = '${inner['questionRpcId'] ?? payload['questionRpcId'] ?? inner['rpcId'] ?? ''}';
        if (qid.isNotEmpty) questions.removeWhere((e) => e.rpcId == qid);
        break;
      case 'approval/requested':
        final card = ApprovalCard(
          rpcId: '${inner['rpcId'] ?? payload['rpcId'] ?? ''}',
          sessionId: '${inner['sessionId'] ?? openSessionId ?? ''}',
          approvalId: '${inner['approvalId'] ?? ''}',
          toolName: '${inner['toolName'] ?? ''}',
          reason: '${inner['reason'] ?? ''}',
          fact: '${inner['fact'] ?? ''}',
          classLabel: '${inner['classLabel'] ?? ''}',
          command: '${inner['command'] ?? ''}',
          rememberable: inner['rememberable'] == true,
        );
        if (card.rpcId.isNotEmpty && card.approvalId.isNotEmpty) {
          final isNew = !approvals.any((e) => e.approvalId == card.approvalId);
          approvals.removeWhere((e) => e.approvalId == card.approvalId);
          approvals.add(card);
          if (isNew && !appForeground) {
            unawaited(Notifier.show(
              '需要你批准：${card.toolName.isEmpty ? '工具调用' : card.toolName}',
              card.fact.isNotEmpty ? card.fact : card.reason,
            ));
          }
        }
        break;
      case 'approval/resolved':
        final id = '${inner['approvalId'] ?? payload['approvalId'] ?? ''}';
        if (id.isNotEmpty) approvals.removeWhere((e) => e.approvalId == id);
        break;
      case 'turn/end':
        if (!appForeground && streamingNow) {
          unawaited(Notifier.show('这一轮跑完了', _lastAssistantText()));
        }
        break;
      case 'step/end':
        streamingNow = false;
        if (messages.isNotEmpty) messages.last.streaming = false;
        break;
      default:
        break;
    }
    notifyListeners();
  }

  /// 从一条消息对象里取纯文本：`content` 可能是字符串，也可能是 `[{type:'text',text}]`。
  /// 这一条消息里带了哪些图片附件（历史里图块只有 id，没有字节）。
  static List<String> _attachmentIdsOf(Map<String, dynamic> row) {
    final blocks = row['blocks'];
    if (blocks is! List) return const [];
    final ids = <String>[];
    for (final b in blocks) {
      if (b is! Map) continue;
      if ('${b['type']}' != 'image') continue;
      final id = '${b['attachmentId'] ?? ''}'.trim();
      if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  /// 按 id 把图片字节抓回来填进气泡。
  ///
  /// 一屏最多补 8 张（一张 200KB 就够呛），失败静默——气泡里本来就有「（图片）」占位。
  Future<void> _hydrateImages(
    DshClient c,
    String sessionId,
    Map<int, List<String>> pending,
  ) async {
    var budget = 8;
    for (final entry in pending.entries) {
      if (budget <= 0) return;
      if (entry.key >= messages.length) continue;
      final got = <String>[];
      for (final id in entry.value) {
        if (budget <= 0) break;
        budget -= 1;
        try {
          final res = await c.attachment(sessionId: sessionId, attachmentId: id);
          final data = '${res['data'] ?? ''}';
          if (data.isNotEmpty) got.add(data);
        } catch (_) {
          // 附件被会话清理掉（404）是常态，不打扰用户。
        }
      }
      if (got.isEmpty) continue;
      messages[entry.key].images = got;
      notifyListeners();
    }
  }

  /// 最近一条助手消息的前 80 字（通知里当正文用）。
  String _lastAssistantText() {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == 'assistant' && m.text.trim().isNotEmpty) {
        final t = m.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        return t.length <= 80 ? t : '${t.substring(0, 80)}…';
      }
    }
    return '回到 AIDock 看看结果';
  }

  static String _textOfMessage(Map<String, dynamic> msg) {
    final blocks0 = msg['blocks'];
    final imageCount = blocks0 is List
        ? blocks0.where((b) => b is Map && '${b['type']}' == 'image').length
        : 0;
    final direct = msg['text'];
    if (direct is String && direct.isNotEmpty) {
      if (imageCount == 0) return direct;
      return '$direct${imageCount == 1 ? '\n（图片）' : '\n（$imageCount 张图片）'}';
    }
    final content = msg['content'];
    if (content is String) return content;
    if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map && '${part['type']}' == 'text') {
          buffer.write('${part['text'] ?? ''}');
        }
      }
      return buffer.toString();
    }
    // 纯工具调用的轮次没有正文（`text:""`、`content:null`），只剩 blocks 里的
    // tool-call。不补一句的话历史里会出现一串空气泡，用户看不到那轮干了什么。
    final blocks = msg['blocks'];
    if (blocks is List && blocks.isNotEmpty) {
      // 只有图没有正文的轮次（手机发图、或模型只回一张图）也要有可见占位，
      // 否则历史里是空气泡。多张就报张数。
      final images = blocks.where((b) => b is Map && '${b['type']}' == 'image').length;
      final names = <String>[];
      for (final b in blocks) {
        if (b is Map && '${b['type']}' == 'tool-call') {
          final name = '${b['name'] ?? ''}'.trim();
          if (name.isNotEmpty && !names.contains(name)) names.add(name);
        }
      }
      if (names.isNotEmpty) return '调用工具 ${names.join('、')}';
      if (images > 0) return images == 1 ? '（图片）' : '（$images 张图片）';
    }
    return '';
  }

  /// 给审批卡作答。`outcome` 取 allowed-once / denied / allowed-class。
  Future<void> respond(ApprovalCard card, String outcome) async {
    final c = _client;
    if (c == null) return;
    try {
      await c.respondApproval(
        rpcId: card.rpcId,
        sessionId: card.sessionId,
        approvalId: card.approvalId,
        outcome: outcome,
      );
      approvals.removeWhere((e) => e.approvalId == card.approvalId);
      if (outcome == 'denied') {
        messages.add(ChatMessage(role: 'system', text: '已拒绝：${card.headline}'));
      }
    } catch (e) {
      messages.add(ChatMessage(role: 'system', text: '答复失败：$e'));
    }
    notifyListeners();
  }

  /// 提交提问卡的回答。`picks` 是「题 id → 选中的 label 列表」，`customs` 是自由输入。
  Future<void> answerQuestion(
    QuestionCard card,
    Map<String, List<String>> picks, {
    Map<String, String> customs = const <String, String>{},
  }) async {
    final c = _client;
    if (c == null) return;
    final answers = <Map<String, dynamic>>[
      for (final q in card.questions)
        <String, dynamic>{
          'id': q.id,
          'selected': (picks[q.id] ?? const <String>[]).toList(),
          if ((customs[q.id] ?? '').trim().isNotEmpty) 'custom': customs[q.id]!.trim(),
        },
    ];
    try {
      await c.respondQuestion(rpcId: card.rpcId, sessionId: card.sessionId, answers: answers);
      questions.removeWhere((e) => e.rpcId == card.rpcId);
      error = null;
    } on DshClientException catch (e) {
      error = '提交回答失败：${e.message}';
    } catch (e) {
      error = '提交回答失败：$e';
    }
    notifyListeners();
  }

  Future<void> send(String text) async {
    final c = _client;
    final sid = openSessionId;
    if (c == null || sid == null || text.trim().isEmpty) return;
    // 空会话那句占位提示在第一条真消息到达时就该让位。
    if (messages.length == 1 &&
        messages.first.role == 'system' &&
        messages.first.text == '这个会话还没有消息') {
      messages.clear();
    }
    messages.add(ChatMessage(role: 'user', text: text.trim()));
    streamingNow = true;
    notifyListeners();
    try {
      await c.sendMessage(sid, text.trim());
    } catch (e) {
      streamingNow = false;
      messages.add(ChatMessage(role: 'system', text: '发送失败：$e'));
      notifyListeners();
    }
  }

  /// 发一张图（可带一句正文）。
  ///
  /// 宿主只认 `content` 块数组；图片块 `data` 是 base64，`mediaType` 要可读（
  /// `history-derive.js` 靠它决定下发形状），否则桌面端渲染不出图。
  Future<void> sendImage({
    required String name,
    required String mediaType,
    required List<int> bytes,
    String text = '',
  }) async {
    final c = _client;
    final sid = openSessionId;
    if (c == null || sid == null) return;
    if (messages.length == 1 &&
        messages.first.role == 'system' &&
        messages.first.text == '这个会话还没有消息') {
      messages.clear();
    }
    final body = text.trim();
    // 宿主单条消息 ≤ 8MB 明文（SEND_MAX_BODY = ceil(8MB*4/3)），超了会被整条拒掉，
    // 与其让用户等一轮失败，不如当场说清楚该压到多大。
    if (bytes.length > 7 * 1024 * 1024) {
      error = '这张图 ${(bytes.length / 1048576).toStringAsFixed(1)}MB，太大了：'
          '单张请压到 7MB 以内再发';
      notifyListeners();
      return;
    }
    final encoded = base64Encode(bytes);
    final content = <Map<String, dynamic>>[
      if (body.isNotEmpty) {'type': 'text', 'text': body},
      {
        'type': 'image',
        'data': encoded,
        'mediaType': mediaType,
        'name': name,
      },
    ];
    messages.add(ChatMessage(
      role: 'user',
      text: body.isEmpty ? '（图片）$name' : '$body\n（图片）$name',
      images: [encoded],
    ));
    streamingNow = true;
    notifyListeners();
    try {
      await c.sendContent(sid, content);
    } catch (e) {
      streamingNow = false;
      messages.add(ChatMessage(role: 'system', text: '发送失败：$e'));
      notifyListeners();
    }
  }

  /// UI 侧（选图失败等）把问题挂到同一条错误带上，避免各页自己维护一份。
  void setError(String message) {
    error = message;
    notifyListeners();
  }

  Future<void> stopTurn() async {
    final c = _client;
    final sid = openSessionId;
    if (c == null || sid == null) return;
    try {
      await c.stop(sid);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    // 断开＝彻底收摊：流、看门狗、重连计时器、审批卡、重连标记全清，否则
    // 10 秒一次的心跳看门狗会在断开之后把旧客户端又拉起来。
    await _sub?.cancel();
    _sub = null;
    _watchdog?.cancel();
    _watchdog = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    reconnecting = false;
    _retryCount = 0;
    _streamClient = null;
    _streamSessionId = null;
    _client = null;
    _transport?.close();
    _transport = null;
    paired = false;
    sessions.clear();
    messages.clear();
    approvals.clear();
    questions.clear();
    streamingNow = false;
    openSessionId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _transport?.close();
    super.dispose();
  }
}
