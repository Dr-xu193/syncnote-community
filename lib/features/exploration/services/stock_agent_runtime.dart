import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/features/exploration/services/news_exploration_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_ai_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_coordinator.dart';
import 'package:syncnote/features/exploration/services/stock_agent_memory_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_paper_runner.dart';
import 'package:syncnote/features/exploration/services/stock_agent_read_tools.dart';
import 'package:syncnote/features/exploration/services/stock_agent_report_service.dart';
import 'package:syncnote/features/exploration/services/stock_data_quality.dart';
import 'package:syncnote/features/exploration/services/stock_market_gateway.dart';

abstract interface class StockAgentExperimentController {
  bool get canRunLocally;

  Future<StockAgentExperiment?> load();

  Future<StockAgentExperiment> start();

  Future<StockAgentRunResult> runToday();

  Future<StockAgentExperiment> setStatus(String status);

  Future<List<StockAgentDayIndex>> listDays();

  Future<Map<String, dynamic>> readDay(String day);

  Future<List<Map<String, dynamic>>> listReports();

  Future<Map<String, dynamic>> readReport(String periodId);

  Future<Map<String, dynamic>> generateReport(String periodId);
}

/// Windows stays active in the tray. Full application exit stops this local
/// timer; no cloud function, paid Firebase service or hidden background worker.
class StockAgentRuntime implements StockAgentExperimentController {
  StockAgentRuntime._();

  static final StockAgentRuntime instance = StockAgentRuntime._();

  final _memory = StockAgentMemoryService.instance;
  final _market = PublicChinaStockGateway();
  final _news = NewsExplorationService();
  late final _reports = StockAgentReportService(memory: _memory);
  late final StockAgentExistingReadTools _tools = StockAgentExistingReadTools(
    experimentId: StockAgentCoordinator.experimentId,
    market: _market,
    news: _news,
    memory: _memory,
  );
  late final StockAgentAiService _ai = StockAgentAiService(tools: _tools);
  late final StockAgentCoordinator _coordinator = StockAgentCoordinator(
    paper: const WindowsStockAgentPaperRunner(),
    memory: _memory,
    ai: _ai,
    bars: ExistingStockAgentDailyBars(_market),
  );
  Timer? _timer;
  bool _checking = false;

  @override
  bool get canRunLocally => !kIsWeb && Platform.isWindows;

  @override
  Future<StockAgentExperiment?> load() =>
      _memory.loadExperiment(StockAgentCoordinator.experimentId);

  @override
  Future<StockAgentExperiment> start() async {
    final experiment = await _coordinator.start();
    unawaited(_maybeRunToday());
    return experiment;
  }

  @override
  Future<StockAgentRunResult> runToday() => _coordinator.runToday();

  @override
  Future<StockAgentExperiment> setStatus(String status) =>
      _memory.setStatus(StockAgentCoordinator.experimentId, status);

  @override
  Future<List<StockAgentDayIndex>> listDays() =>
      _memory.loadDayIndexes(StockAgentCoordinator.experimentId);

  @override
  Future<Map<String, dynamic>> readDay(String day) =>
      _memory.readDay(StockAgentCoordinator.experimentId, day);

  @override
  Future<List<Map<String, dynamic>>> listReports() =>
      _reports.list(StockAgentCoordinator.experimentId);

  @override
  Future<Map<String, dynamic>> readReport(String periodId) =>
      _reports.read(StockAgentCoordinator.experimentId, periodId);

  @override
  Future<Map<String, dynamic>> generateReport(String periodId) async {
    if (!canRunLocally) throw UnsupportedError('请在 Windows 端生成正式报告');
    final now = DateTime.now().toUtc();
    final experiment = await load();
    if (experiment == null) throw StateError('股票实验不存在');
    if (periodId == 'month') {
      if (await _reports.exists(experiment.id, periodId)) {
        if (experiment.status != 'completed') {
          await _memory.completeExperiment(experiment.id, now);
        }
        return _reports.read(experiment.id, periodId);
      }
      final finalization = await _coordinator.finalize();
      final report = await _reports.generate(
        experiment: finalization.experiment,
        periodId: periodId,
        now: now,
        terminal: finalization.terminal,
      );
      await _memory.completeExperiment(experiment.id, now);
      return report;
    }
    return _reports.generate(
      experiment: experiment,
      periodId: periodId,
      now: now,
    );
  }

  void startScheduler() {
    if (!canRunLocally || _timer != null) return;
    _timer = Timer.periodic(const Duration(minutes: 15), (_) {
      unawaited(_maybeRunToday());
    });
    unawaited(_maybeRunToday());
  }

  Future<void> _maybeRunToday() async {
    if (!canRunLocally || _checking) return;
    _checking = true;
    try {
      if (FirebaseAuth.instance.currentUser == null) return;
      final now = DateTime.now().toUtc();
      final wall = ChinaMarketClock().toShanghaiWallTime(now);
      final experiment = await load();
      if (experiment == null) return;
      if (!now.isBefore(experiment.endsAt)) {
        if (await _reports.exists(experiment.id, 'month')) {
          if (experiment.status != 'completed') {
            await _memory.completeExperiment(experiment.id, now);
          }
          return;
        }
        final finished = await _coordinator.finalize();
        await _generateDueReports(finished.experiment, now, finished.terminal);
        await _memory.completeExperiment(experiment.id, now);
      } else {
        if (experiment.status == 'active' &&
            (wall.hour > 18 || (wall.hour == 18 && wall.minute >= 30))) {
          await _coordinator.runToday();
        }
        await _generateDueReports((await load()) ?? experiment, now, null);
      }
    } catch (error) {
      debugPrint('AI 虚拟操盘本次未执行：$error');
    } finally {
      _checking = false;
    }
  }

  Future<void> _generateDueReports(
    StockAgentExperiment experiment,
    DateTime now,
    Map<String, dynamic>? terminal,
  ) async {
    final startWall = ChinaMarketClock().toShanghaiWallTime(
      experiment.startedAt,
    );
    final startDay = DateTime.utc(
      startWall.year,
      startWall.month,
      startWall.day,
    );
    for (var week = 1; week <= 5; week++) {
      final endOffset = (week * 7).clamp(0, 30);
      final due = startDay
          .add(Duration(days: endOffset))
          .subtract(const Duration(hours: 8));
      final period = 'week-$week';
      if (now.isBefore(due) || await _reports.exists(experiment.id, period)) {
        continue;
      }
      try {
        await _reports.generate(
          experiment: experiment,
          periodId: period,
          now: now,
        );
      } catch (error) {
        debugPrint('$period 尚不能归档：$error');
      }
    }
    if (terminal != null && !await _reports.exists(experiment.id, 'month')) {
      await _reports.generate(
        experiment: experiment,
        periodId: 'month',
        now: now,
        terminal: terminal,
      );
    }
  }

  void dispose() {
    _timer?.cancel();
    _ai.dispose();
    _market.dispose();
    _news.dispose();
  }
}
