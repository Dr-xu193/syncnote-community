import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/features/exploration/services/stock_agent_ai_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_coordinator.dart';
import 'package:syncnote/features/exploration/services/stock_agent_memory_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_paper_runner.dart';
import 'package:syncnote/features/exploration/services/stock_agent_report_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'AI one-account cycle persists a 1000-yuan decision and next-day fill',
    () async {
      var clock = DateTime.parse('2026-08-24T14:00:00+08:00');
      final backend = _CoordinatorBackend();
      final memory = StockAgentMemoryService.forTesting(backend);
      final ai = _FakeDecisionService();
      final coordinator = StockAgentCoordinator(
        paper: const WindowsStockAgentPaperRunner(),
        memory: memory,
        ai: ai,
        bars: _FakeDailyBars(),
        clock: () => clock,
      );
      final started = await coordinator.start();
      expect(started.account['initialCash'], 1000);

      clock = DateTime.parse('2026-08-24T16:00:00+08:00');
      final first = await coordinator.runToday();
      expect(first.journalSaved, isTrue);
      expect(first.decision?.targets.single.targetWeight, 1);
      expect((first.experiment.account['pending'] as List), hasLength(1));
      expect(
        (await memory.readDay(
          StockAgentCoordinator.experimentId,
          '2026-08-24',
        ))['events'],
        hasLength(1),
      );

      clock = DateTime.parse('2026-08-25T16:00:00+08:00');
      final second = await coordinator.runToday();
      final positions = second.experiment.account['positions'] as List;
      expect((positions.single as Map)['shares'], 100);
      expect(
        (second.experiment.account['cash'] as num).toDouble(),
        lessThan(5),
      );
      expect(second.decision?.mode, 'hold');
      expect(second.experiment.version, 2);

      final replay = await coordinator.runToday();
      expect(replay.alreadyRan, isTrue);
      expect(ai.calls, 2);
      expect(backend.events, hasLength(2));
      final dayTwo = await memory.readDay(
        StockAgentCoordinator.experimentId,
        '2026-08-25',
      );
      final cycle = (dayTwo['events'] as List).single as Map;
      expect((cycle['detail'] as Map)['paperEvents'], isNotEmpty);
      ai.dispose();
    },
    skip: !Platform.isWindows,
  );

  test(
    'failed daily archive retries without a second model decision',
    () async {
      var clock = DateTime.parse('2026-08-24T14:00:00+08:00');
      final backend = _CoordinatorBackend()..failNextUpload = true;
      final memory = StockAgentMemoryService.forTesting(backend);
      final ai = _FakeDecisionService();
      final coordinator = StockAgentCoordinator(
        paper: const WindowsStockAgentPaperRunner(),
        memory: memory,
        ai: ai,
        bars: _FakeDailyBars(),
        clock: () => clock,
      );
      await coordinator.start();
      clock = DateTime.parse('2026-08-24T16:00:00+08:00');
      await expectLater(coordinator.runToday(), throwsStateError);
      expect((await coordinator.load())!.version, 1);
      expect(ai.calls, 1);
      final recovered = await coordinator.runToday();
      expect(recovered.alreadyRan, isTrue);
      expect(recovered.journalSaved, isTrue);
      expect(ai.calls, 1);
      ai.dispose();
    },
    skip: !Platform.isWindows,
  );

  test(
    'a second Windows instance cannot duplicate the same AI run',
    () async {
      var clock = DateTime.parse('2026-08-24T14:00:00+08:00');
      final backend = _CoordinatorBackend();
      final memory = StockAgentMemoryService.forTesting(backend);
      final ai = _FakeDecisionService();
      final coordinator = StockAgentCoordinator(
        paper: const WindowsStockAgentPaperRunner(),
        memory: memory,
        ai: ai,
        bars: _FakeDailyBars(),
        clock: () => clock,
      );
      await coordinator.start();
      backend.leaseOwner = 'other-process';
      backend.leaseUntil = DateTime.now().toUtc().add(
        const Duration(minutes: 5),
      );
      clock = DateTime.parse('2026-08-24T16:00:00+08:00');
      await expectLater(coordinator.runToday(), throwsStateError);
      expect(ai.calls, 0);
      expect((await coordinator.load())!.version, 0);
      ai.dispose();
    },
    skip: !Platform.isWindows,
  );

  test(
    'offline days get honest individual journals without invented trades',
    () async {
      var clock = DateTime.parse('2026-08-24T14:00:00+08:00');
      final backend = _CoordinatorBackend();
      final memory = StockAgentMemoryService.forTesting(backend);
      final ai = _FakeDecisionService();
      final coordinator = StockAgentCoordinator(
        paper: const WindowsStockAgentPaperRunner(),
        memory: memory,
        ai: ai,
        bars: _FakeDailyBars(),
        clock: () => clock,
      );
      await coordinator.start();
      clock = DateTime.parse('2026-08-26T16:00:00+08:00');
      final result = await coordinator.runToday();
      expect(result.experiment.version, 3);
      expect(ai.calls, 1);
      for (final day in ['2026-08-24', '2026-08-25']) {
        final journal = await memory.readDay(
          StockAgentCoordinator.experimentId,
          day,
        );
        final event = (journal['events'] as List).single as Map;
        expect(event['kind'], 'missed_cycle');
        expect((event['detail'] as Map)['delayedRecovery'], isTrue);
        expect((journal['openingAccount'] as Map)['cash'], 1000);
        expect((journal['closingAccount'] as Map)['cash'], 1000);
      }
      final replay = await coordinator.runToday();
      expect(replay.alreadyRan, isTrue);
      expect(ai.calls, 1);
      expect(backend.events, hasLength(3));
      ai.dispose();
    },
    skip: !Platform.isWindows,
  );

  test(
    'expiry recovers all 30 absent days without fabricated AI decisions',
    () async {
      var clock = DateTime.parse('2026-08-24T14:00:00+08:00');
      final backend = _CoordinatorBackend();
      final memory = StockAgentMemoryService.forTesting(backend);
      final ai = _FakeDecisionService();
      final coordinator = StockAgentCoordinator(
        paper: const WindowsStockAgentPaperRunner(),
        memory: memory,
        ai: ai,
        bars: _FakeDailyBars(),
        clock: () => clock,
      );
      await coordinator.start();
      clock = DateTime.parse('2026-09-23T08:00:00+08:00');
      final finished = await coordinator.finalize();
      expect(finished.experiment.version, 30);
      expect(backend.days.length, 30);
      expect(ai.calls, 0);
      expect((finished.terminal['terminal'] as Map)['netValue'], 1000);
      final reports = StockAgentReportService(
        memory: memory,
        store: _FakeReportStore(),
      );
      final month = await reports.generate(
        experiment: finished.experiment,
        periodId: 'month',
        now: clock,
        terminal: finished.terminal,
      );
      expect((month['days'] as List), hasLength(30));
      expect((month['summary'] as Map)['missedDayCount'], 30);
      expect((month['summary'] as Map)['terminalNetValue'], 1000);
      final replay = await coordinator.finalize();
      expect(replay.experiment.version, 30);
      expect(backend.events.length, 30);
      final completed = await memory.completeExperiment(
        StockAgentCoordinator.experimentId,
        clock,
      );
      expect(completed.status, 'completed');
      ai.dispose();
    },
    skip: !Platform.isWindows,
  );

  test(
    'weekly report archives seven verified days and detects corruption',
    () async {
      var clock = DateTime.parse('2026-08-24T14:00:00+08:00');
      final backend = _CoordinatorBackend();
      final memory = StockAgentMemoryService.forTesting(backend);
      final ai = _FakeDecisionService();
      final coordinator = StockAgentCoordinator(
        paper: const WindowsStockAgentPaperRunner(),
        memory: memory,
        ai: ai,
        bars: _FakeDailyBars(),
        clock: () => clock,
      );
      await coordinator.start();
      clock = DateTime.parse('2026-09-01T16:00:00+08:00');
      final run = await coordinator.runToday();
      final store = _FakeReportStore();
      final reports = StockAgentReportService(memory: memory, store: store);
      final generated = await reports.generate(
        experiment: run.experiment,
        periodId: 'week-1',
        now: clock,
      );
      expect((generated['days'] as List), hasLength(7));
      expect((generated['summary'] as Map)['missedDayCount'], 7);
      expect(await reports.read(run.experiment.id, 'week-1'), generated);
      expect(store.uploads, 1);
      await reports.generate(
        experiment: run.experiment,
        periodId: 'week-1',
        now: clock,
      );
      expect(store.uploads, 1);
      final index = store.indexes['week-1']!;
      store.files[index['archiveUrl']] = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        reports.read(run.experiment.id, 'week-1'),
        throwsStateError,
      );
      ai.dispose();
    },
    skip: !Platform.isWindows,
  );
}

class _FakeReportStore implements StockAgentReportStore {
  final indexes = <String, Map<String, dynamic>>{};
  final files = <String, Uint8List>{};
  int uploads = 0;

  @override
  Future<Map<String, dynamic>?> loadIndex(
    String experimentId,
    String periodId,
  ) async => indexes[periodId];

  @override
  Future<List<Map<String, dynamic>>> listIndexes(String experimentId) async =>
      indexes.values.toList();

  @override
  Future<void> saveIndex(
    String experimentId,
    String periodId,
    Map<String, dynamic> index,
  ) async {
    if (indexes.containsKey(periodId)) throw StateError('sealed');
    indexes[periodId] = index;
  }

  @override
  Future<String> upload(Uint8List bytes, String remoteName) async {
    uploads++;
    final url = 'webdav://stock_agent_reports/$remoteName';
    files[url] = Uint8List.fromList(bytes);
    return url;
  }

  @override
  Future<Uint8List> download(String url) async => files[url]!;

  @override
  Future<void> delete(String url) async {
    files.remove(url);
  }
}

class _FakeDailyBars implements StockAgentDailyBars {
  @override
  Future<StockAgentBarBatch> load({
    required DateTime asOf,
    required Map<String, dynamic> account,
  }) async {
    if ((account['pending'] as List? ?? const []).isEmpty) {
      return const StockAgentBarBatch(bars: []);
    }
    return StockAgentBarBatch(
      observedAt: DateTime.parse('2026-08-25T15:01:00+08:00'),
      bars: const [
        {
          'code': '600001',
          'exchange': 'SSE',
          'date': '2026-08-25',
          'open': 9.9,
          'high': 9.9,
          'low': 9.9,
          'close': 9.9,
          'previousClose': 9.9,
          'volume': 1000000,
        },
      ],
    );
  }
}

class _FakeDecisionService implements StockAgentDecisionService {
  int calls = 0;

  @override
  Future<StockAgentDecision> decide({
    required DateTime asOf,
    required StockAgentMemoryContext memory,
  }) async {
    calls++;
    final buying = calls == 1;
    return StockAgentDecision(
      mode: buying ? 'rebalance' : 'hold',
      researchMemo: '当时我看到虚拟账户和已经公布的行情，选择是否持有现金。',
      marketView: '仅依据测试日当时信息。',
      whyNow: buying ? '股票价格允许一千元买入整手。' : '已有仓位维持。',
      alternativesRejected: const ['没有使用未来价格'],
      uncertainties: const ['免费行情仅供个人模拟'],
      nextDayExpectation: '下一交易日观察。',
      monthExpectation: '一个月后复盘。',
      targets: buying
          ? const [
              StockAgentTarget(
                code: '600001',
                exchange: 'SSE',
                targetWeight: 1,
                reason: '使用当时可见的测试股票',
              ),
            ]
          : const [],
      sourceIds: const ['fake-market'],
      toolNames: const ['stock_history'],
      promptTokens: 100,
      completionTokens: 50,
      estimatedCostUsd: 0,
    );
  }

  @override
  void dispose() {}
}

class _CoordinatorBackend implements StockAgentMemoryBackend {
  StockAgentExperiment? experiment;
  final events = <String, StockAgentEvent>{};
  final days = <String, StockAgentDayIndex>{};
  final files = <String, Uint8List>{};
  bool failNextUpload = false;
  String? leaseOwner;
  DateTime? leaseUntil;

  @override
  Future<void> createExperiment(StockAgentExperiment value) async {
    if (experiment != null) throw StateError('exists');
    experiment = value;
  }

  @override
  Future<StockAgentExperiment?> loadExperiment(String id) async => experiment;

  @override
  Future<StockAgentExperiment> setStatus(String id, String status) async {
    final next = experiment!.copyWith(
      status: status,
      version: experiment!.version + 1,
    );
    experiment = next;
    return next;
  }

  @override
  Future<StockAgentExperiment> completeExperiment(
    String id,
    DateTime completedAt,
  ) async {
    if (experiment!.status == 'completed') return experiment!;
    final next = experiment!.copyWith(
      status: 'completed',
      version: experiment!.version + 1,
      updatedAt: completedAt,
    );
    experiment = next;
    return next;
  }

  @override
  Future<bool> claimRun(
    String id,
    String day,
    String owner,
    DateTime expiresAt,
  ) async {
    if (leaseOwner != null &&
        leaseOwner != owner &&
        leaseUntil?.isAfter(DateTime.now().toUtc()) == true) {
      return false;
    }
    leaseOwner = owner;
    leaseUntil = expiresAt;
    return true;
  }

  @override
  Future<void> releaseRun(String id, String owner) async {
    if (leaseOwner == owner) leaseOwner = null;
  }

  @override
  Future<StockAgentExperiment> commitEvent(
    StockAgentEvent event,
    StockAgentExperiment next, {
    required int expectedVersion,
  }) async {
    if (events.containsKey(event.id)) return experiment!;
    if (experiment?.version != expectedVersion) {
      throw StateError('version conflict');
    }
    events[event.id] = event;
    experiment = next;
    return next;
  }

  @override
  Future<List<StockAgentEvent>> loadDayEvents(String id, String day) async =>
      events.values.where((item) => item.logicalDay == day).toList();

  @override
  Future<StockAgentDayIndex?> loadDayIndex(String id, String day) async =>
      days[day];

  @override
  Future<List<StockAgentDayIndex>> loadDayIndexes(String id) async =>
      days.values.toList();

  @override
  Future<void> saveDayIndex(StockAgentDayIndex index) async {
    days[index.logicalDay] = index;
  }

  @override
  Future<String> uploadDay(Uint8List bytes, String remoteName) async {
    if (failNextUpload) {
      failNextUpload = false;
      throw StateError('temporary WebDAV failure');
    }
    final url = 'webdav://stock_agent_days/$remoteName';
    files[url] = Uint8List.fromList(bytes);
    return url;
  }

  @override
  Future<Uint8List> downloadDay(String url) async => files[url]!;

  @override
  Future<void> deleteDay(String url) async {
    files.remove(url);
  }

  @override
  Future<void> deleteExperimentData(String id) async {
    experiment = null;
    events.clear();
    days.clear();
  }
}
