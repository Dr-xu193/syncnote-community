import 'package:flutter/material.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/features/exploration/services/exploration_repository.dart';
import 'package:syncnote/features/exploration/services/puzzle_judge_service.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';

class PuzzleExplorationScreen extends StatefulWidget {
  const PuzzleExplorationScreen({super.key});

  @override
  State<PuzzleExplorationScreen> createState() =>
      _PuzzleExplorationScreenState();
}

class _PuzzleExplorationScreenState extends State<PuzzleExplorationScreen> {
  final _answerController = TextEditingController();
  final _judge = PuzzleJudgeService();

  List<PuzzleCase> _puzzles = const [];
  Map<String, PuzzleProgress> _progress = {};
  int _puzzleIndex = 0;
  PuzzleJudgeDecision? _decision;
  String? _submitError;
  bool _loading = true;
  bool _submitting = false;

  PuzzleCase get _puzzle => _puzzles[_puzzleIndex];
  PuzzleProgress get _currentProgress =>
      _progress[_puzzle.id] ?? const PuzzleProgress();
  int get _stageIndex => _puzzle.stages.isEmpty
      ? 0
      : _currentProgress.currentStage.clamp(0, _puzzle.stages.length - 1);
  PuzzleStage get _stage => _puzzle.stages[_stageIndex];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _answerController.dispose();
    _judge.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final puzzles = await ExplorationRepository.instance.loadPuzzles();
    final progress = await ExplorationStateStore.instance.loadPuzzleProgress();
    var firstUncleared = 0;
    for (var index = 0; index < puzzles.length; index++) {
      if (!(progress[puzzles[index].id]?.cleared ?? false)) {
        firstUncleared = index;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _puzzles = puzzles;
      _progress = progress;
      _puzzleIndex = firstUncleared;
      _loading = false;
    });
  }

  void _selectPuzzle(int? index) {
    if (index == null) return;
    setState(() {
      _puzzleIndex = index;
      _answerController.clear();
      _decision = null;
      _submitError = null;
    });
  }

  Future<void> _submit() async {
    final answer = _answerController.text.trim();
    if (answer.isEmpty) {
      setState(() => _submitError = '请先写出你的结论和理由。');
      return;
    }
    setState(() {
      _submitting = true;
      _decision = null;
      _submitError = null;
    });
    try {
      final decision = await _judge.judge(
        puzzle: _puzzle,
        stage: _stage,
        answer: answer,
      );
      final updated = PuzzleProgress(
        currentStage: _currentProgress.currentStage,
        attempts: _currentProgress.attempts + 1,
        cleared: _currentProgress.cleared,
      );
      await ExplorationStateStore.instance.savePuzzleProgress(
        _puzzle.id,
        updated,
      );
      if (!mounted) return;
      setState(() {
        _progress[_puzzle.id] = updated;
        _decision = decision;
        _submitting = false;
      });
    } on PuzzleSubmissionRejected catch (error) {
      if (!mounted) return;
      setState(() {
        _submitError = error.message;
        _submitting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitError =
            '智能裁判本次未完成：$error\n'
            '你的答案已保留，本次不记尝试次数，也不会改变关卡进度。';
        _submitting = false;
      });
    }
  }

  Future<void> _advance() async {
    if (_decision?.passed != true) return;
    final nextStage = _stageIndex + 1;
    final cleared = nextStage >= _puzzle.stages.length;
    final updated = PuzzleProgress(
      currentStage: cleared ? _stageIndex : nextStage,
      attempts: _currentProgress.attempts,
      cleared: cleared,
    );
    await ExplorationStateStore.instance.savePuzzleProgress(
      _puzzle.id,
      updated,
    );
    if (!mounted) return;
    setState(() {
      _progress[_puzzle.id] = updated;
      _decision = null;
      _submitError = null;
      _answerController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('逻辑推演')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _puzzles.isEmpty
          ? const Center(child: Text('谜题数据加载失败'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildCaseSelector(context),
                    const SizedBox(height: 14),
                    _buildCaseCard(context),
                    const SizedBox(height: 14),
                    if (_currentProgress.cleared)
                      _buildClearedCard(context)
                    else ...[
                      _buildAnswerCard(context),
                      if (_submitting) ...[
                        const SizedBox(height: 14),
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        const Text('智能裁判正在逐项核对结论、因果链、线索和表达…'),
                      ],
                      if (_decision != null) ...[
                        const SizedBox(height: 14),
                        _buildDecisionCard(context, _decision!),
                      ],
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildCaseSelector(BuildContext context) {
    final clearedCount = _progress.values.where((item) => item.cleared).length;
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: _puzzleIndex,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '选择卷宗',
              border: OutlineInputBorder(),
            ),
            items: _puzzles.indexed
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry.$1,
                    child: Text(
                      '${entry.$1 + 1}. ${entry.$2.title}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: _selectPuzzle,
          ),
        ),
        const SizedBox(width: 12),
        Chip(
          avatar: const Icon(Icons.flag_rounded, size: 18),
          label: Text('已通关 $clearedCount / ${_puzzles.length}'),
        ),
      ],
    );
  }

  Widget _buildCaseCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _puzzle.title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Chip(
                  label: Text(
                    '第 ${_stageIndex + 1} / ${_puzzle.stages.length} 关',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              _puzzle.background,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            const Divider(height: 32),
            Text(
              _stage.task,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              '明确通过标准：总分 ≥ 85；结论 ≥ 30/35；因果链 ≥ 22/35；并且没有实质矛盾。',
              style: TextStyle(
                color: colors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '你的推演',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _answerController,
              minLines: 5,
              maxLines: 10,
              contextMenuBuilder:
                  AiContextMenuHelper.editableTextContextMenuBuilder,
              onChanged: (_) {
                if (_decision != null || _submitError != null) {
                  setState(() {
                    _decision = null;
                    _submitError = null;
                  });
                }
              },
              decoration: const InputDecoration(
                hintText: '先写结论，再说明“为什么”，并指出题面中支持你的线索。',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_submitError != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _submitError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: const Icon(Icons.psychology_alt_rounded),
                label: Text(_currentProgress.attempts == 0 ? '提交推演' : '重新提交推演'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDecisionCard(
    BuildContext context,
    PuzzleJudgeDecision decision,
  ) {
    final colors = Theme.of(context).colorScheme;
    final passed = decision.passed;
    return Card(
      margin: EdgeInsets.zero,
      color: passed
          ? colors.primaryContainer.withValues(alpha: 0.55)
          : colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  passed ? Icons.verified_rounded : Icons.rate_review_rounded,
                  color: passed ? Colors.green : colors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    passed ? '本关通过' : '本关尚未通过',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  '${decision.score} 分 · 置信度 ${(decision.confidence * 100).round()}%',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(decision.feedback),
            const SizedBox(height: 6),
            Text(
              '裁判方式：${decision.model} 单次语义裁决',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            ...decision.dimensions.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(item.label)),
                        Text('${item.score} / ${item.maximum}'),
                      ],
                    ),
                    const SizedBox(height: 5),
                    LinearProgressIndicator(
                      value: item.maximum == 0 ? 0 : item.score / item.maximum,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.explanation,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            if (decision.missingPoints.isNotEmpty) ...[
              Text(
                passed ? '可进一步完善（不影响本关通过）' : '还需要补充',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              ...decision.missingPoints.map((item) => Text('• $item')),
            ],
            const SizedBox(height: 12),
            Text(
              '下一步：${decision.nextAction}',
              style: TextStyle(
                color: colors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (passed) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _advance,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: Text(
                  _stageIndex + 1 >= _puzzle.stages.length ? '完成卷宗' : '进入下一关',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildClearedCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Icon(
              Icons.workspace_premium_rounded,
              size: 54,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              '这份卷宗已经全部通关',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text('共提交 ${_currentProgress.attempts} 次推演，进度会一直保留，不会按天重置。'),
          ],
        ),
      ),
    );
  }
}
