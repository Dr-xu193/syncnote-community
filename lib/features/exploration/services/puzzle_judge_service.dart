import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/features/exploration/services/exploration_ai_service.dart';

class PuzzleSubmissionRejected implements Exception {
  const PuzzleSubmissionRejected(this.message);

  final String message;

  @override
  String toString() => message;
}

class PuzzleJudgeService {
  PuzzleJudgeService({ExplorationAiService? ai})
    : _ai = ai ?? ExplorationAiService();

  static const passScore = 85;
  static const _injectionTerms = ['忽略之前', '系统提示词', '直接把我判', '无视规则', '输出参考答案'];

  final ExplorationAiService _ai;

  Future<PuzzleJudgeDecision> judge({
    required PuzzleCase puzzle,
    required PuzzleStage stage,
    required String answer,
  }) async {
    validateAnswer(answer);
    final result = await _ai.judgePuzzle(
      puzzle: puzzle,
      stage: stage,
      answer: answer.trim(),
    );
    return fromAi(result.data, result.model);
  }

  static void validateAnswer(String rawAnswer) {
    final answer = rawAnswer.trim();
    if (answer.isEmpty) {
      throw const PuzzleSubmissionRejected('请先写出你的结论和理由。');
    }
    if (_injectionTerms.any(answer.contains)) {
      throw const PuzzleSubmissionRejected(
        '检测到了要求改变裁判规则的文字。请只回答题目本身，你的答案尚未提交。',
      );
    }
  }

  static PuzzleJudgeDecision fromAi(Map<String, dynamic> data, String model) {
    final rawDimensions = Map<String, dynamic>.from(
      data['dimensions'] as Map? ?? const {},
    );
    final conclusion = _bounded(rawDimensions['conclusion'], 35);
    final reasoning = _bounded(rawDimensions['reasoning'], 35);
    final evidence = _bounded(rawDimensions['evidence'], 20);
    final clarity = _bounded(rawDimensions['clarity'], 10);
    final total = conclusion + reasoning + evidence + clarity;
    final contradictions = _strings(data['contradictions']);
    final requestedVerdict = _parseVerdict('${data['verdict'] ?? ''}');
    final passed =
        requestedVerdict == PuzzleVerdict.correct &&
        contradictions.isEmpty &&
        conclusion >= 30 &&
        reasoning >= 22 &&
        total >= passScore;
    final verdict = requestedVerdict == PuzzleVerdict.correct && !passed
        ? PuzzleVerdict.partial
        : requestedVerdict;
    final dimensionFeedback = Map<String, dynamic>.from(
      data['dimension_feedback'] as Map? ?? const {},
    );
    return PuzzleJudgeDecision(
      verdict: verdict,
      score: total,
      confidence: ((data['confidence'] as num?)?.toDouble() ?? 0).clamp(0, 1),
      feedback: _textOr(data['feedback'], '需要补充说明。'),
      matchedPoints: _strings(data['matched_points']),
      missingPoints: _strings(data['missing_points']),
      contradictions: contradictions,
      dimensions: [
        _dimension('结论', conclusion, 35, dimensionFeedback['conclusion']),
        _dimension('因果链', reasoning, 35, dimensionFeedback['reasoning']),
        _dimension('线索使用', evidence, 20, dimensionFeedback['evidence']),
        _dimension('表达完整', clarity, 10, dimensionFeedback['clarity']),
      ],
      passed: passed,
      nextAction: _textOr(
        data['next_action'],
        passed ? '本关已通过，可以进入下一关。' : '根据缺失项补充后再次提交。',
      ),
      model: model,
    );
  }

  static PuzzleDimensionScore _dimension(
    String label,
    int score,
    int maximum,
    Object? explanation,
  ) => PuzzleDimensionScore(
    label: label,
    score: score,
    maximum: maximum,
    explanation: _textOr(explanation, '未返回该项说明'),
  );

  static String _textOr(Object? value, String fallback) {
    final text = '${value ?? ''}'.trim();
    return text.isEmpty ? fallback : text;
  }

  static List<String> _strings(Object? value) =>
      List<String>.from(value as List? ?? const []);

  static PuzzleVerdict _parseVerdict(String value) {
    return switch (value) {
      'correct' => PuzzleVerdict.correct,
      'plausible_alternative' => PuzzleVerdict.plausibleAlternative,
      'partial' => PuzzleVerdict.partial,
      'incorrect' => PuzzleVerdict.incorrect,
      _ => PuzzleVerdict.needsClarification,
    };
  }

  static int _bounded(Object? value, int maximum) {
    return ((value as num?)?.toInt() ?? 0).clamp(0, maximum);
  }

  void dispose() => _ai.dispose();
}
