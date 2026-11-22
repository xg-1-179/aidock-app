import 'dart:async';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/foundation.dart';

/// 一条会话正文命中。
///
/// 宿主 `/session/search` 只回 `{sessionId, snippet}`（见 `lib/mobile/session-search.js`：
/// 标题这类本地元数据它不拼），标题由本控制器从 `/link/sessions` 的清单里按 sessionId 补；
/// 清单里没有的（已归档 / 子会话）与桌面端同口径整条丢掉，可见性与侧栏一致。
class SearchHit {
  const SearchHit({
    required this.sessionId,
    required this.title,
    required this.snippet,
  });

  final String sessionId;
  final String title;

  /// 宿主给的命中片段，最多 240 码点；老宿主可能回空串。
  final String snippet;
}

/// 全局搜索（宿主的会话正文检索）。
///
/// 端点与字段全部按 `lib/mobile/session-search.js` 核对：
/// `GET /api/mobile/v1/session/search?query=…` → `{ok, items:[{sessionId, snippet}], hasMore}`；
/// query 为空回 400（`缺少 query`），宿主没开正文检索时也是 400 并且带 `error.message` ——
/// 所以这里把宿主原话抬到 [error]，不把「没开检索」显示成「没有命中」。
class SearchController extends ChangeNotifier {
  SearchController(this.client);

  final DshClient client;

  /// 最少两个字才发请求：宿主那边是整台电脑的正文扫描，一个字的开销不划算。
  static const int minChars = 2;

  /// 输入防抖窗口（`onChanged` 逐个字符触发）。
  static const Duration debounceWindow = Duration(milliseconds: 300);

  /// 会话标题缓存的新鲜度：一页搜索里不值得每条都去拉一遍清单。
  static const Duration titleTtl = Duration(minutes: 1);

  List<SearchHit> hits = const <SearchHit>[];
  bool loading = false;
  String query = '';
  String? error;

  /// 宿主说「还有更多」。它单次最多回 20 条，这里只做提示，不做翻页（宿主没给游标）。
  bool hasMore = false;

  Timer? _debounce;

  /// 请求代号：慢回包不能盖掉后一次搜索的结果。
  int _ticket = 0;

  Map<String, String>? _titles;
  DateTime? _titlesAt;

  bool get canSearch => query.trim().length >= minChars;

  /// 输入框 `onChanged` 直接调它：300 ms 防抖后才真正发请求。
  void onQueryChanged(String value) {
    query = value;
    _debounce?.cancel();
    final text = value.trim();
    if (text.length < minChars) {
      // 字太少不发请求，同时把上一次的结果收掉，免得列表和输入框对不上。
      _ticket += 1;
      loading = false;
      error = null;
      hasMore = false;
      hits = const <SearchHit>[];
      notifyListeners();
      return;
    }
    _debounce = Timer(debounceWindow, () {
      unawaited(search(text));
    });
    // 输入本身也要重画（清空按钮、字数提示）。
    if (!loading) notifyListeners();
  }

  /// 立即检索（回车键 / 重试按钮走这条，不等防抖）。
  Future<void> search(String q) async {
    final text = q.trim();
    final ticket = ++_ticket;
    if (text.length < minChars) {
      query = text;
      hits = const <SearchHit>[];
      hasMore = false;
      error = null;
      loading = false;
      notifyListeners();
      return;
    }

    query = text;
    loading = true;
    error = null;
    notifyListeners();

    try {
      final titles = await _sessionTitles();
      final body = await client.api(
        'GET',
        '/session/search',
        query: '?query=${Uri.encodeQueryComponent(text)}',
      );
      if (ticket != _ticket) return;

      final raw = body['items'];
      final out = <SearchHit>[];
      if (raw is List) {
        for (final entry in raw) {
          if (entry is! Map) continue;
          final id = '${entry['sessionId'] ?? ''}'.trim();
          if (id.isEmpty) continue;
          final known = titles[id];
          if (known == null && titles.isNotEmpty) {
            // 清单里没有这条会话：已归档或子会话，与桌面端一致地丢掉。
            continue;
          }
          final snippet = entry['snippet'];
          out.add(SearchHit(
            sessionId: id,
            title: known ?? _shortId(id),
            snippet: snippet is String ? snippet : '',
          ));
        }
      }
      hits = out;
      hasMore = body['hasMore'] == true;
      loading = false;
      notifyListeners();
    } catch (e) {
      if (ticket != _ticket) return;
      hits = const <SearchHit>[];
      hasMore = false;
      loading = false;
      error = describeError(e);
      notifyListeners();
    }
  }

  /// 清空输入与结果（返回搜索页时不会看到上一次的残留）。
  void clear() {
    _debounce?.cancel();
    _debounce = null;
    _ticket += 1;
    query = '';
    hits = const <SearchHit>[];
    hasMore = false;
    error = null;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _debounce = null;
    super.dispose();
  }

  /// sessionId → 标题。读不到清单不阻塞检索：那时退化成短 id，不至于整页空白。
  Future<Map<String, String>> _sessionTitles() async {
    final cached = _titles;
    final at = _titlesAt;
    if (cached != null && at != null && DateTime.now().difference(at) < titleTtl) {
      return cached;
    }
    final out = <String, String>{};
    try {
      final list = await client.sessions();
      for (final row in list) {
        final id = '${row['sessionId'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        final title = '${row['title'] ?? ''}'.trim();
        out[id] = title.isEmpty ? _shortId(id) : title;
      }
    } catch (_) {
      // 清单失败只是少个标题，不该把搜索本身判死。
      return cached ?? out;
    }
    _titles = out;
    _titlesAt = DateTime.now();
    return out;
  }

  static String _shortId(String id) =>
      id.length <= 8 ? id : '会话 ${id.substring(0, 8)}';
}

/// 把异常抬成人话：`DshClientException.message` 已经是宿主 `error.message` 的原文
/// （见 `_errorMessageOf`），比 `request failed` 有用得多。
String describeError(Object error) {
  if (error is DshClientException) {
    final message = error.message;
    if (message.isNotEmpty) return message;
    return '请求失败（HTTP ${error.status ?? '?'}）';
  }
  return '$error';
}
