import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/foundation.dart';

/// 已装清单里的一条：`GET /plugins` 的 `items[i]`。
///
/// 宿主把桌面上「设置 → 插件」的只读快照搬过来了：`moduleName` 是 npm 包名，
/// `enabled` 是**有效启停**（停用的条目仍在清单里，只是没有运行时），
/// `fiberPhase` 是运行时的当前状态，宿主没报就是 null。
class InstalledPlugin {
  InstalledPlugin({
    required this.entryId,
    required this.moduleName,
    required this.enabled,
    this.fiberPhase,
  });

  /// 宿主内部条目标识；列表 key 用它，业务动作仍按 [moduleName] 走。
  final String entryId;

  /// npm 包名，也是 `/plugin/market/enabled` 与 `/plugin/market/remove` 认的名字。
  final String moduleName;

  /// 有效启停；页面上的 Switch 直接读它。
  bool enabled;

  /// `failed / pending / active / loading / unloading`。
  final String? fiberPhase;

  bool get active => fiberPhase == 'active';
}

/// 市场里的一条：`GET /plugin/market` 的 `bundles[i]`。
class MarketBundle {
  MarketBundle({
    required this.name,
    required this.title,
    required this.description,
    this.version,
    this.source,
    this.iconData,
    this.enabled = false,
    this.installed = false,
    this.official = false,
    this.removable = false,
    this.protectedSelf = false,
    this.update,
    this.availability,
    this.installVersion,
    this.installSpec,
    this.errorCode,
    this.errorMessage,
  }) : iconBytes = _decodeIcon(iconData);

  final String name;

  /// `meta.title` 可能是字符串，也可能是多语言表；这里已经挑成一句。
  final String title;
  final String description;
  final String? version;
  final String? source;

  /// 宿主给的 `data:image/...` 原文，留着排查用。
  final String? iconData;

  /// 解码后的图标字节；没有图标、不是位图或解不开时为 null，页面画占位图标。
  final Uint8List? iconBytes;

  final bool enabled;
  final bool installed;
  final bool official;
  final bool removable;

  /// 承载这台手机连接的那个包：不可停用、不可卸载。
  final bool protectedSelf;
  final String? update;
  final String? availability;
  final String? installVersion;
  final String? installSpec;
  final String? errorCode;
  final String? errorMessage;

  factory MarketBundle.fromJson(Map<String, dynamic> row) {
    final installTarget = row['installTarget'];
    final spec = installTarget is Map ? _nonEmpty(installTarget['spec']) : null;
    final targetVersion = installTarget is Map ? _nonEmpty(installTarget['version']) : null;
    final error = row['error'];
    final name = _nonEmpty(row['name']) ?? '';
    return MarketBundle(
      name: name,
      title: _localized(row['title']) ?? name,
      description: _localized(row['description']) ?? '',
      version: _nonEmpty(row['version']),
      source: _nonEmpty(row['source']),
      iconData: _nonEmpty(row['icon']),
      enabled: row['enabled'] == true,
      installed: row['installed'] == true,
      official: row['official'] == true,
      removable: row['removable'] == true,
      protectedSelf: row['protectedSelf'] == true,
      update: _nonEmpty(row['update']),
      availability: _nonEmpty(row['availability']),
      installSpec: spec,
      installVersion: targetVersion,
      errorCode: error is Map ? _nonEmpty(error['code']) : null,
      errorMessage: error is Map ? _nonEmpty(error['message']) : null,
    );
  }

  static Uint8List? _decodeIcon(String? dataUrl) {
    if (dataUrl == null || !dataUrl.startsWith('data:image/')) return null;
    // Image.memory 只吃位图；SVG 图标交给占位框，别让它每次 build 都抛一次解析错误。
    if (dataUrl.contains('svg')) return null;
    final marker = dataUrl.indexOf('base64,');
    if (marker < 0) return null;
    final payload = dataUrl.substring(marker + 7);
    if (payload.isEmpty) return null;
    try {
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }
}

/// 一个插件的说明文档：`GET /plugin/market/detail` 的投影。
class PluginDetail {
  PluginDetail({required this.name, required this.status, this.markdown = '', this.error});

  final String name;

  /// `found` / `none`，读取失败时是 `error`。
  final String status;
  final String markdown;
  final String? error;

  bool get hasText => status == 'found' && markdown.trim().isNotEmpty;
}

class PluginVersion {
  const PluginVersion({
    required this.version,
    this.tags = const [],
    this.prerelease = false,
    this.deprecated,
  });

  final String version;
  final List<String> tags;
  final bool prerelease;
  final String? deprecated;
}

/// 一次版本查询：`listed` 有列表，`refused` 是宿主拒了（附原因），`error` 是没问到。
class PluginVersions {
  const PluginVersions({
    required this.name,
    required this.status,
    this.versions = const [],
    this.installed,
    this.registry,
    this.problem,
    this.reason,
    this.error,
  });

  final String name;
  final String status;
  final List<PluginVersion> versions;
  final String? installed;
  final String? registry;
  final String? problem;
  final String? reason;
  final String? error;

  bool get listed => status == 'listed';

  String get problemText {
    if (problem == null && reason == null) return '';
    final head = problem ?? 'refused';
    final tail = (reason ?? '').trim();
    return tail.isEmpty ? head : '$head：$tail';
  }
}

/// 插件页的控制器：已装清单 + 市场 + 安装/卸载/启停 + 1 秒一次的安装进度轮询。
///
/// 字段对页面只读，写操作一律走方法；页面用 `AnimatedBuilder` 订阅。
/// 事件（安装结束一类的结果）通过 [eventSeq] / [eventText] 递给页面，由页面弹 SnackBar，
/// 控制器自己不碰任何 UI。
class PluginsController extends ChangeNotifier {
  PluginsController(this.client);

  final DshClient client;

  // ---- 已安装（GET /plugins）----
  final List<InstalledPlugin> installed = [];
  bool installedLoading = false;
  String? installedError;
  String revision = '';

  // ---- 市场（GET /plugin/market）----
  final List<MarketBundle> bundles = [];
  bool marketLoading = false;
  String? marketError;
  String selfName = '';

  // ---- npm 源（GET /plugin/market/registries）----
  final List<String> registries = [];
  String? configuredRegistry;
  String? resolvedRegistry;
  bool registriesLoading = false;

  // ---- 安装 / 卸载进度 ----
  bool operationRunning = false;

  /// `install` 或 `remove`。
  String operationKind = '';
  String operationTarget = '';
  String? operationPhase;
  int operationElapsed = 0;

  /// 结束事件序号；页面只处理比上次大的那一个。
  int eventSeq = 0;
  String? eventText;
  bool eventOk = true;

  final Map<String, PluginDetail> _details = {};
  final Map<String, PluginVersions> _versionsCache = {};
  final Map<String, Future<PluginVersions>> _versionRequests = {};
  final Set<String> _busy = <String>{};

  bool _disposed = false;
  bool _polling = false;
  int _pollErrors = 0;
  Timer? _pollTimer;
  String? _requestId;
  DateTime? _operationStartedAt;

  bool isBusy(String name) => _busy.contains(name);

  MarketBundle? bundleFor(String name) {
    for (final bundle in bundles) {
      if (bundle.name == name) return bundle;
    }
    return null;
  }

  PluginDetail? cachedDetail(String name) => _details[name];

  /// 首次进页面用：清单、市场、源列表一起读。
  Future<void> refreshAll({bool force = true}) async {
    await Future.wait<void>([
      refreshInstalled(force: force),
      loadMarket(),
      loadRegistries(),
    ]);
  }

  /// 已装清单。带 `?rev=` 走条件请求：宿主回 `unchanged` 时列表原样留着。
  Future<void> refreshInstalled({bool force = false}) async {
    if (installedLoading) return;
    installedLoading = true;
    installedError = null;
    _notify();
    try {
      final query =
          (!force && revision.isNotEmpty) ? '?rev=${Uri.encodeQueryComponent(revision)}' : '';
      final r = await client.api('GET', '/plugins', query: query);
      if (r['unchanged'] != true) {
        final raw = r['items'];
        final next = <InstalledPlugin>[];
        if (raw is List) {
          for (final row in raw.whereType<Map>()) {
            final item = Map<String, dynamic>.from(row);
            final entryId = _nonEmpty(item['entryId']);
            final moduleName = _nonEmpty(item['moduleName']);
            if (entryId == null || moduleName == null) continue;
            next.add(InstalledPlugin(
              entryId: entryId,
              moduleName: moduleName,
              enabled: item['enabled'] == true,
              fiberPhase: _nonEmpty(item['fiberPhase']),
            ));
          }
        }
        installed
          ..clear()
          ..addAll(next);
        final rev = _nonEmpty(r['revision']);
        if (rev != null) revision = rev;
        installedError = null;
      }
    } catch (error) {
      if (!_disposed) installedError = describeError(error);
    } finally {
      if (!_disposed) {
        installedLoading = false;
        _notify();
      }
    }
  }

  /// 市场清单。`silent` 时不在开始阶段清掉错误提示（用于操作完的静默刷新）。
  Future<void> loadMarket({bool silent = false}) async {
    if (marketLoading) return;
    marketLoading = true;
    if (!silent) marketError = null;
    _notify();
    try {
      final r = await client.api('GET', '/plugin/market');
      final raw = r['bundles'];
      final next = <MarketBundle>[];
      if (raw is List) {
        for (final row in raw.whereType<Map>()) {
          final bundle = MarketBundle.fromJson(Map<String, dynamic>.from(row));
          if (bundle.name.isNotEmpty) next.add(bundle);
        }
      }
      bundles
        ..clear()
        ..addAll(next);
      final self = _nonEmpty(r['self']);
      if (self != null) selfName = self;
      marketError = null;
    } catch (error) {
      if (!_disposed) marketError = describeError(error);
    } finally {
      if (!_disposed) {
        marketLoading = false;
        _notify();
      }
    }
  }

  /// 安装时能选的 npm 源。拿不到只影响「选源」，不该让整页报错。
  Future<void> loadRegistries() async {
    if (registriesLoading) return;
    registriesLoading = true;
    _notify();
    try {
      final r = await client.api('GET', '/plugin/market/registries');
      final options = <String>[];
      final fallback = r['fallbackRegistries'];
      final fallbacks = fallback is List
          ? fallback.whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty)
          : const Iterable<String>.empty();
      configuredRegistry = _nonEmpty(r['registry']);
      resolvedRegistry = _nonEmpty(r['resolved']);
      for (final item in <String?>[resolvedRegistry, configuredRegistry, ...fallbacks]) {
        if (item != null && item.isNotEmpty && !options.contains(item)) options.add(item);
      }
      registries
        ..clear()
        ..addAll(options);
    } catch (_) {
      // 源列表只是安装对话框里的可选项；读不到就只留「跟随宿主配置」。
    } finally {
      if (!_disposed) {
        registriesLoading = false;
        _notify();
      }
    }
  }

  /// 启用 / 停用。返回 null 表示请求已受理，否则是给用户看的一句话。
  Future<String?> setEnabled(String name, bool enabled) async {
    final key = name.trim();
    if (key.isEmpty || _busy.contains(key)) return null;
    _busy.add(key);
    _notify();
    try {
      final r = await client.api(
        'POST',
        '/plugin/market/enabled',
        payload: {'name': key, 'enabled': enabled},
      );
      final operation = r['operation'];
      final reported =
          operation is Map && operation['enabled'] is bool ? operation['enabled'] as bool : enabled;
      _applyEnabled(key, reported);
      _notify();
      unawaited(_refreshSoon());
      return null;
    } catch (error) {
      return describeError(error);
    } finally {
      _busy.remove(key);
      _notify();
    }
  }

  /// 卸载。宿主立即回 202 + requestId，结果靠轮询；返回 null 表示已开始。
  Future<String?> removeBundle(String name) async {
    if (operationRunning) return '上一次操作还没结束';
    final key = name.trim();
    if (key.isEmpty) return '需要插件包名';
    try {
      final r = await client.api(
        'POST',
        '/plugin/market/remove',
        payload: {'name': key, 'requestId': _newRequestId('remove')},
      );
      final requestId = _nonEmpty(r['requestId']);
      if (requestId == null) return '宿主没有返回这次卸载的编号';
      _beginOperation(kind: 'remove', target: key, requestId: requestId);
      return null;
    } catch (error) {
      return describeError(error);
    }
  }

  /// 安装。`version` 为空表示 latest；`registry` 为空表示跟随宿主配置。
  Future<String?> install({required String name, String? version, String? registry}) async {
    if (operationRunning) return '上一次操作还没结束';
    final key = name.trim();
    if (key.isEmpty) return '需要插件包名';
    final wanted = version?.trim() ?? '';
    final spec = wanted.isEmpty ? key : '$key@$wanted';
    final payload = <String, dynamic>{
      'spec': spec,
      'requestId': _newRequestId('install'),
    };
    final registryText = registry?.trim() ?? '';
    if (registryText.isNotEmpty) payload['registry'] = registryText;
    try {
      final r = await client.api('POST', '/plugin/market/install', payload: payload);
      final requestId = _nonEmpty(r['requestId']);
      if (requestId == null) return '宿主没有返回这次安装的编号';
      _beginOperation(kind: 'install', target: key, requestId: requestId);
      return null;
    } catch (error) {
      return describeError(error);
    }
  }

  /// 让宿主停掉正在跑的那一次安装 / 卸载；结果仍由轮询回报。
  Future<String?> cancelOperation() async {
    final requestId = _requestId;
    if (requestId == null) return null;
    try {
      await client.api('POST', '/plugin/market/cancel', payload: {'requestId': requestId});
      return null;
    } catch (error) {
      return describeError(error);
    }
  }

  /// 插件说明：`GET /plugin/market/detail?name=&language=zh`。
  Future<PluginDetail> loadDetail(String name, {bool refresh = false}) async {
    final cached = _details[name];
    if (!refresh && cached != null && cached.error == null) return cached;
    try {
      final r = await client.api(
        'GET',
        '/plugin/market/detail',
        query: '?name=${Uri.encodeQueryComponent(name)}&language=zh',
      );
      final status = _nonEmpty(r['status']) ?? 'none';
      final detail = PluginDetail(
        name: name,
        status: status,
        markdown: status == 'found' ? '${r['markdown'] ?? ''}' : '',
      );
      _details[name] = detail;
      _notify();
      return detail;
    } catch (error) {
      final failed = PluginDetail(name: name, status: 'error', error: describeError(error));
      _details[name] = failed;
      _notify();
      return failed;
    }
  }

  /// 可选版本：`GET /plugin/market/versions?name=&registry=`。同参数在飞时复用同一个请求。
  Future<PluginVersions> loadVersions(String name, {String? registry, bool refresh = false}) {
    final key = '$name@@${registry ?? ''}';
    final inFlight = _versionRequests[key];
    if (inFlight != null) return inFlight;
    final cached = _versionsCache[key];
    if (!refresh && cached != null && cached.error == null) {
      return Future<PluginVersions>.value(cached);
    }
    final future = _fetchVersions(name, registry);
    _versionRequests[key] = future;
    future.whenComplete(() => _versionRequests.remove(key));
    return future;
  }

  Future<PluginVersions> _fetchVersions(String name, String? registry) async {
    final query = StringBuffer('?name=${Uri.encodeQueryComponent(name)}');
    if (registry != null && registry.isNotEmpty) {
      query.write('&registry=${Uri.encodeQueryComponent(registry)}');
    }
    try {
      final r = await client.api('GET', '/plugin/market/versions', query: query.toString());
      final status = _nonEmpty(r['status']) ?? 'refused';
      final versions = <PluginVersion>[];
      final raw = r['versions'];
      if (raw is List) {
        for (final row in raw.whereType<Map>()) {
          final item = Map<String, dynamic>.from(row);
          final version = _nonEmpty(item['version']);
          if (version == null) continue;
          final tags = item['tags'];
          versions.add(PluginVersion(
            version: version,
            tags: tags is List ? tags.whereType<String>().toList(growable: false) : const <String>[],
            prerelease: item['prerelease'] == true,
            deprecated: _nonEmpty(item['deprecated']),
          ));
        }
      }
      final result = PluginVersions(
        name: name,
        status: status,
        versions: versions,
        installed: _nonEmpty(r['installed']),
        registry: _nonEmpty(r['registry']),
        problem: _nonEmpty(r['problem']),
        reason: _nonEmpty(r['reason']),
      );
      _versionsCache['$name@@${registry ?? ''}'] = result;
      return result;
    } catch (error) {
      return PluginVersions(name: name, status: 'error', error: describeError(error));
    }
  }

  /// 把宿主 / 传输层的错误翻成一句人话；401、503 用固定文案。
  String describeError(Object error) {
    if (error is DshClientException) {
      final status = error.status ?? 0;
      if (status == 401) return '登录凭据过期，重新用六位码连一次';
      if (status == 503) return '宿主没装插件能力';
      final text = error.message.trim();
      if (status == 403) {
        return text.isEmpty || text == 'request failed' ? '权限不够：这台设备没有配置权限' : text;
      }
      if (text.isNotEmpty && text != 'request failed') return text;
      if (status >= 500) return '宿主出错了（HTTP $status）';
      return '请求失败（HTTP $status）';
    }
    return '$error';
  }

  void _applyEnabled(String name, bool enabled) {
    for (final plugin in installed) {
      if (plugin.moduleName == name) plugin.enabled = enabled;
    }
    for (var i = 0; i < bundles.length; i++) {
      final bundle = bundles[i];
      if (bundle.name != name) continue;
      bundles[i] = MarketBundle(
        name: bundle.name,
        title: bundle.title,
        description: bundle.description,
        version: bundle.version,
        source: bundle.source,
        iconData: bundle.iconData,
        enabled: enabled,
        installed: bundle.installed,
        official: bundle.official,
        removable: bundle.removable,
        protectedSelf: bundle.protectedSelf,
        update: bundle.update,
        availability: bundle.availability,
        installVersion: bundle.installVersion,
        installSpec: bundle.installSpec,
        errorCode: bundle.errorCode,
        errorMessage: bundle.errorMessage,
      );
      break;
    }
  }

  Future<void> _refreshSoon() async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (_disposed) return;
    await refreshInstalled(force: true);
    if (_disposed) return;
    await loadMarket(silent: true);
  }

  void _beginOperation({required String kind, required String target, required String requestId}) {
    _pollTimer?.cancel();
    _requestId = requestId;
    operationRunning = true;
    operationKind = kind;
    operationTarget = target;
    operationPhase = null;
    operationElapsed = 0;
    _operationStartedAt = DateTime.now();
    _pollErrors = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_pollOnce()));
    _notify();
  }

  Future<void> _pollOnce() async {
    final requestId = _requestId;
    if (requestId == null || _polling || _disposed) return;
    _polling = true;
    try {
      final r = await client.api(
        'GET',
        '/plugin/market/progress',
        query: '?requestId=${Uri.encodeQueryComponent(requestId)}',
      );
      if (_disposed) return;
      _pollErrors = 0;
      final state = _nonEmpty(r['state']) ?? '';
      if (state == 'running') {
        operationPhase = _nonEmpty(r['phase']);
        _updateElapsed();
        _notify();
        return;
      }
      _completeOperation(state: state, payload: r);
    } catch (error) {
      if (_disposed) return;
      _pollErrors += 1;
      if (_pollErrors >= 3) {
        final kind = operationKind;
        final target = operationTarget;
        _stopPolling();
        operationRunning = false;
        _emit(false, '${kindLabel(kind)} $target 的进度查不到了：${describeError(error)}；下拉刷新看一下结果');
      }
    } finally {
      _polling = false;
    }
  }

  void _completeOperation({required String state, required Map<String, dynamic> payload}) {
    final kind = operationKind;
    final target = operationTarget;
    _stopPolling();
    operationRunning = false;
    operationPhase = null;
    _updateElapsed();

    if (state == 'unknown') {
      _emit(false, '${kindLabel(kind)} $target 的结果查不到了（宿主可能重启过），已重新读一次清单');
      unawaited(_reloadAfterOperation());
      return;
    }

    final rawResult = payload['result'];
    final result = rawResult is Map ? Map<String, dynamic>.from(rawResult) : const <String, dynamic>{};

    if (result['ok'] != true) {
      final rawError = result['error'];
      final error = rawError is Map ? Map<String, dynamic>.from(rawError) : const <String, dynamic>{};
      final message = _nonEmpty(error['message']);
      final code = _nonEmpty(error['code']);
      final stage = _nonEmpty(result['stage']);
      final reason = message ?? code ?? '宿主没有说明原因';
      final stageText = stage == null ? '' : '（阶段 $stage）';
      _emit(false, '${kindLabel(kind)} $target 失败：$reason$stageText');
      unawaited(_reloadAfterOperation());
      return;
    }

    final rawOperation = result['operation'];
    final operation =
        rawOperation is Map ? Map<String, dynamic>.from(rawOperation) : const <String, dynamic>{};
    final application = _nonEmpty(operation['application']) ?? 'unknown';
    final version = _nonEmpty(operation['version']);
    final suffix = version == null ? '' : '（$version）';
    final warnings = operation['warnings'];
    final warningText = warnings is List && warnings.isNotEmpty
        ? '；${warnings.whereType<String>().take(2).join('；')}'
        : '';

    if (application == 'applied') {
      _emit(true, '${kindLabel(kind)} $target$suffix 完成$warningText');
    } else if (application == 'restart-required') {
      _emit(true, '${kindLabel(kind)} $target$suffix 完成，重启电脑上的 DSH 后生效$warningText');
    } else if (application == 'cancelled') {
      _emit(false, '${kindLabel(kind)} $target 已取消');
    } else if (application == 'failed') {
      final rawError = operation['error'];
      final error = rawError is Map ? Map<String, dynamic>.from(rawError) : const <String, dynamic>{};
      final reason = _nonEmpty(error['message']) ?? _nonEmpty(error['code']) ?? '宿主没有说明原因';
      _emit(false, '${kindLabel(kind)} $target 失败：$reason');
    } else {
      _emit(false, '${kindLabel(kind)} $target 结束了，但宿主没说是否生效；刷新清单看一下');
    }
    unawaited(_reloadAfterOperation());
  }

  Future<void> _reloadAfterOperation() async {
    await refreshInstalled(force: true);
    if (_disposed) return;
    await loadMarket(silent: true);
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _requestId = null;
  }

  void _updateElapsed() {
    final started = _operationStartedAt;
    if (started == null) return;
    operationElapsed = DateTime.now().difference(started).inSeconds;
  }

  void _emit(bool ok, String text) {
    eventSeq += 1;
    eventOk = ok;
    eventText = text;
    _notify();
  }

  String kindLabel(String kind) {
    if (kind == 'remove') return '卸载';
    if (kind == 'update') return '更新';
    return '安装';
  }

  String _newRequestId(String prefix) =>
      'mobile-app-$prefix-${DateTime.now().microsecondsSinceEpoch}';

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }
}

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

String? _localized(Object? raw) {
  if (raw is String) return _nonEmpty(raw);
  if (raw is Map) {
    for (final key in const <String>['zh-CN', 'zh_CN', 'zh', 'zh-Hans', 'en', 'en-US']) {
      final value = _nonEmpty(raw[key]);
      if (value != null) return value;
    }
    for (final value in raw.values) {
      final text = _nonEmpty(value);
      if (text != null) return text;
    }
  }
  return null;
}
