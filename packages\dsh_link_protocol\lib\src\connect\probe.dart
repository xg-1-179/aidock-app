import 'dart:async';

import 'candidate.dart';

/// 单次探测结果。
class ProbeResult {
  final Candidate candidate;
  final Duration latency;
  final int order;

  const ProbeResult(this.candidate, this.latency, this.order);

  @override
  String toString() => '$candidate ${latency.inMilliseconds}ms';
}

/// 一次失败的记录，用于诊断页展示。
class ProbeFailure {
  final Candidate candidate;
  final Object error;
  const ProbeFailure(this.candidate, this.error);
  @override
  String toString() => '$candidate 失败: $error';
}

class ProbeReport {
  final ProbeResult? winner;
  final List<ProbeResult> successes;
  final List<ProbeFailure> failures;
  final Duration elapsed;

  const ProbeReport({
    required this.winner,
    required this.successes,
    required this.failures,
    required this.elapsed,
  });
}

/// 把候选通道并行探测，先到先用。
typedef ProbeFn = Future<void> Function(Candidate candidate, Duration timeout);

class ConnectionProbe {
  final ProbeFn probe;
  final Duration timeout;

  ConnectionProbe({required this.probe, this.timeout = const Duration(seconds: 3)});

  /// 全部候选同时开跑，第一个成功者立即成为 winner，其余继续收集用于诊断，
  /// 但不再影响结果。[hardDeadline] 之后仍未成功的直接算失败。
  Future<ProbeReport> race(List<Candidate> candidates) async {
    final sw = Stopwatch()..start();
    final successes = <ProbeResult>[];
    final failures = <ProbeFailure>[];
    final done = Completer<ProbeReport>();
    var remaining = candidates.length;
    var winnerAssigned = false;

    void maybeFinish() {
      if (remaining != 0 || done.isCompleted) return;
      done.complete(ProbeReport(
        winner: successes.isEmpty ? null : successes.first,
        successes: successes,
        failures: failures,
        elapsed: sw.elapsed,
      ));
    }

    if (candidates.isEmpty) {
      return ProbeReport(
        winner: null, successes: const [], failures: const [], elapsed: sw.elapsed);
    }

    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      final order = i;
      Future<void>(() async {
        try {
          await probe(c, timeout).timeout(timeout);
          successes.add(ProbeResult(c, sw.elapsed, order));
          if (!winnerAssigned) winnerAssigned = true;
        } catch (e) {
          failures.add(ProbeFailure(c, e));
        } finally {
          remaining--;
          maybeFinish();
        }
      });
    }
    return done.future;
  }
}
