import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 命令的「收藏」与「最近用过」。
///
/// 只存命令名（宿主 `/link/commands` 的 `name`），不存描述：命令表由宿主提供，
/// 名字才是稳定标识；描述随时会变，存下来只会过期。
///
/// 两串都用 `shared_preferences` 落盘，键名固定为 [favoritesKey] / [recentKey]，
/// 换设备靠重新收藏，不做云同步。
class CommandsStore extends ChangeNotifier {
  CommandsStore();

  /// 收藏集合的存储键。
  static const String favoritesKey = 'aidock.cmdFavorites';

  /// 最近使用的存储键。
  static const String recentKey = 'aidock.cmdRecent';

  /// 「最近用过」最多留几条。
  static const int recentLimit = 8;

  final List<String> _favorites = <String>[];
  final List<String> _recent = <String>[];
  bool _loaded = false;
  bool _disposed = false;

  /// 是否已经从磁盘读过一次（页面据此区分「空」和「还没读」）。
  bool get loaded => _loaded;

  /// 收藏的命令名，按收藏先后排列。
  List<String> get favorites => List<String>.unmodifiable(_favorites);

  /// 最近用过的命令名，最近一条在最前。
  List<String> get recent => List<String>.unmodifiable(_recent);

  /// 读盘。重复调用是安全的：列表会被磁盘内容覆盖，不会翻倍。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final favorites = _dedupe(prefs.getStringList(favoritesKey));
    final recent = _dedupe(prefs.getStringList(recentKey));
    _favorites
      ..clear()
      ..addAll(favorites);
    _recent
      ..clear()
      ..addAll(recent.take(recentLimit));
    _loaded = true;
    _notify();
  }

  /// 这个名字在不在收藏里。
  bool isFavorite(String name) => _favorites.contains(name.trim());

  /// 收藏 / 取消收藏，立即生效并落盘。
  Future<void> toggleFavorite(String name) async {
    final key = name.trim();
    if (key.isEmpty) return;
    if (!_favorites.remove(key)) _favorites.add(key);
    _notify();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(favoritesKey, List<String>.from(_favorites));
  }

  /// 记一次使用：提到最前，超出 [recentLimit] 的挤掉。
  Future<void> touch(String name) async {
    final key = name.trim();
    if (key.isEmpty) return;
    _recent.remove(key);
    _recent.insert(0, key);
    if (_recent.length > recentLimit) {
      _recent.removeRange(recentLimit, _recent.length);
    }
    _notify();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(recentKey, List<String>.from(_recent));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 去空、去重，保持原顺序；磁盘里的脏数据不该冒到界面上。
  static List<String> _dedupe(List<String>? raw) {
    final out = <String>[];
    if (raw == null) return out;
    for (final item in raw) {
      final name = item.trim();
      if (name.isEmpty || out.contains(name)) continue;
      out.add(name);
    }
    return out;
  }
}
