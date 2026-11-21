import 'dart:async';

import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:test/test.dart';

Candidate c(String id, CandidateKind k) =>
    Candidate(id: id, baseUrl: Uri.parse('http://$id:41873'), kind: k);

/// 假通道：按 ms 延迟成功，或抛错。
ProbeFn fake(Map<String, int> delays, {Set<String> dead = const {}}) {
  return (candidate, timeout) async {
    if (dead.contains(candidate.id)) throw StateError('连接被拒绝');
    final ms = delays[candidate.id] ?? 500;
    if (ms > timeout.inMilliseconds) throw TimeoutException('超时');
    await Future<void>.delayed(Duration(milliseconds: ms));
  };
}

void main() {
  test('最快的通道胜出，不受候选顺序影响', () async {
    final probe = ConnectionProbe(
      probe: fake({'slow': 2400, 'fast': 120, 'mid': 900}),
      timeout: const Duration(seconds: 3),
    );
    final report = await probe.race([
      c('slow', CandidateKind.relay),
      c('mid', CandidateKind.lan),
      c('fast', CandidateKind.wan),
    ]);
    expect(report.winner?.candidate.id, 'fast');
    expect(report.failures, isEmpty);
  });

  test('死通道不影响其它通道，且被记入失败清单', () async {
    final probe = ConnectionProbe(
      probe: fake({'relay': 100, 'wan': 200}, dead: {'relay'}),
      timeout: const Duration(seconds: 3),
    );
    final report = await probe.race([
      c('relay', CandidateKind.relay),
      c('wan', CandidateKind.wan),
    ]);
    expect(report.winner?.candidate.id, 'wan');
    expect(report.failures.single.candidate.id, 'relay');
  });

  test('超过 timeout 的通道判负', () async {
    final probe = ConnectionProbe(
      probe: fake({'hang': 5000, 'ok': 100}),
      timeout: const Duration(seconds: 1),
    );
    final report = await probe.race([
      c('hang', CandidateKind.relay),
      c('ok', CandidateKind.wan),
    ]);
    expect(report.winner?.candidate.id, 'ok');
    expect(report.failures.map((f) => f.candidate.id), contains('hang'));
  });

  test('全部失败时 winner 为空，但每个失败都有原因', () async {
    final probe = ConnectionProbe(
      probe: fake({}, dead: {'a', 'b'}),
      timeout: const Duration(milliseconds: 500),
    );
    final report = await probe.race([
      c('a', CandidateKind.lan),
      c('b', CandidateKind.lan),
    ]);
    expect(report.winner, isNull);
    expect(report.failures, hasLength(2));
  });

  test('空候选列表立即返回，不挂起', () async {
    final probe = ConnectionProbe(probe: fake({}));
    final report = await probe.race(const []);
    expect(report.winner, isNull);
  });

  test('路径记忆把上次成功的通道排到最前', () {
    final mem = PathMemory();
    final list = [c('lan', CandidateKind.lan), c('wan', CandidateKind.wan)];
    expect(mem.trusted, isFalse);
    mem.recordSuccess(list[1]);
    expect(mem.trusted, isTrue);
    expect(mem.prefer(list).first.id, 'wan');
  });

  test('连续失败两次后记忆作废', () {
    final mem = PathMemory();
    mem.recordSuccess(c('wan', CandidateKind.wan));
    mem.recordFailure();
    expect(mem.trusted, isTrue, reason: '一次失败还不该作废');
    mem.recordFailure();
    expect(mem.trusted, isFalse);
    expect(mem.lastGoodId, isNull);
  });
}
