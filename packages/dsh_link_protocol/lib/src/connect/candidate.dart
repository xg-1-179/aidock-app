/// 一条可尝试的连接通道。
///
/// 设计原则（见 docs/CONNECTIVITY.md）：没有"必须存在"的通道，
/// 中转只是候选之一，探测阶段所有候选地位平等。
enum CandidateKind { lan, wan, relay, tailcat, p2p }

class Candidate {
  final String id;
  final Uri baseUrl;
  final CandidateKind kind;

  const Candidate({required this.id, required this.baseUrl, required this.kind});

  @override
  String toString() => '$id(${kind.name})';
}
