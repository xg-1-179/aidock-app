import 'candidate.dart';

/// 路径记忆：记住上次成功的通道，冷启动先试它；连续失败 [failThreshold] 次后作废。
class PathMemory {
  final int failThreshold;
  String? lastGoodId;
  int consecutiveFailures = 0;

  PathMemory({this.failThreshold = 2});

  bool get trusted => lastGoodId != null && consecutiveFailures < failThreshold;

  void recordSuccess(Candidate c) {
    lastGoodId = c.id;
    consecutiveFailures = 0;
  }

  void recordFailure() {
    consecutiveFailures++;
    if (consecutiveFailures >= failThreshold) lastGoodId = null;
  }

  /// 把记住的通道排到最前，其余保持原顺序。
  List<Candidate> prefer(List<Candidate> candidates) {
    if (!trusted) return candidates;
    final id = lastGoodId;
    final hit = candidates.where((c) => c.id == id).toList();
    if (hit.isEmpty) return candidates;
    return [...hit, ...candidates.where((c) => c.id != id)];
  }
}
