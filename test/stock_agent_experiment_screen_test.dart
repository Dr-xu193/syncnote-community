import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/features/exploration/screens/stock_agent_experiment_screen.dart';
import 'package:syncnote/features/exploration/services/stock_agent_coordinator.dart';
import 'package:syncnote/features/exploration/services/stock_agent_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('one experiment starts with exactly 1000 yuan in the UI', (
    tester,
  ) async {
    final controller = _FakeController();
    await tester.pumpWidget(
      MaterialApp(home: StockAgentExperimentScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('启动 30 天虚拟实验'), findsOneWidget);
    await tester.tap(find.text('启动 30 天虚拟实验'));
    await tester.pumpAndSettle();
    expect(find.text('当前虚拟账户'), findsOneWidget);
    expect(find.textContaining('现金：¥1000.00'), findsOneWidget);
    expect(controller.started, isTrue);
  });

  testWidgets('Android-style read-only controller cannot start or trade', (
    tester,
  ) async {
    final controller = _FakeController(canRunLocally: false);
    await tester.pumpWidget(
      MaterialApp(home: StockAgentExperimentScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('请在 Windows 端启动；手机端只负责查看。'), findsOneWidget);
    expect(find.text('启动 30 天虚拟实验'), findsNothing);
  });

  testWidgets('a dated JSON journal exposes detailed decision reasons', (
    tester,
  ) async {
    final controller = _FakeController()..started = true;
    await tester.pumpWidget(
      MaterialApp(home: StockAgentExperimentScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('2026-09-01'), findsOneWidget);
    await tester.tap(find.text('2026-09-01'));
    await tester.pumpAndSettle();
    expect(find.textContaining('完整研究过程'), findsOneWidget);
    expect(find.textContaining('根据当时成交量形成判断'), findsOneWidget);
  });

  testWidgets('weekly report links back to its original daily journal', (
    tester,
  ) async {
    final controller = _FakeController()
      ..started = true
      ..savedReport = true;
    await tester.pumpWidget(
      MaterialApp(home: StockAgentExperimentScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('第1周 · 查看'));
    await tester.pumpAndSettle();
    expect(find.text('周报与期末复盘'), findsOneWidget);
    expect(find.textContaining('虚拟业绩不是实际投资回报'), findsOneWidget);
    await tester.tap(find.textContaining('2026-09-01 · 当天选择持币'));
    await tester.pumpAndSettle();
    expect(find.textContaining('完整研究过程'), findsOneWidget);
  });
}

class _FakeController implements StockAgentExperimentController {
  _FakeController({this.canRunLocally = true});

  @override
  final bool canRunLocally;
  bool started = false;
  bool savedReport = false;
  String status = 'active';

  StockAgentExperiment get experiment => StockAgentExperiment(
    id: StockAgentCoordinator.experimentId,
    startedAt: DateTime.utc(2026, 9, 1),
    endsAt: DateTime.utc(2026, 9, 30, 16),
    version: 0,
    account: const {
      'initialCash': 1000,
      'cash': 1000,
      'positions': [],
      'lastEquity': 1000,
      'lastProcessedDay': '2026-09-01',
    },
    memory: const {},
    updatedAt: DateTime.utc(2026, 9, 1),
    status: status,
  );

  @override
  Future<StockAgentExperiment?> load() async => started ? experiment : null;

  @override
  Future<StockAgentExperiment> start() async {
    started = true;
    return experiment;
  }

  @override
  Future<StockAgentRunResult> runToday() async => StockAgentRunResult(
    experiment: experiment,
    alreadyRan: true,
    journalSaved: true,
  );

  @override
  Future<StockAgentExperiment> setStatus(String value) async {
    status = value;
    return experiment;
  }

  @override
  Future<List<StockAgentDayIndex>> listDays() async => [
    StockAgentDayIndex(
      experimentId: StockAgentCoordinator.experimentId,
      logicalDay: '2026-09-01',
      archiveUrl: 'webdav://stock_agent_days/day.json',
      sha256: List.filled(64, 'a').join(),
      byteLength: 500,
      sealed: true,
      codes: const ['600001'],
      tags: const ['每日决策'],
      eventIds: const ['cycle-2026-09-01'],
      updatedAt: DateTime.utc(2026, 9, 1),
    ),
  ];

  @override
  Future<Map<String, dynamic>> readDay(String day) async => {
    'logicalDay': day,
    'events': [
      {
        'kind': 'daily_cycle',
        'recordedAt': '2026-09-01T08:00:00Z',
        'detail': {
          'decision': {
            'marketView': '市场信息不完整',
            'researchMemo': '根据当时成交量形成判断',
            'whyNow': '观察到价格变化',
            'alternativesRejected': ['暂不追涨'],
            'uncertainties': ['数据可能延迟'],
            'nextDayExpectation': '再观察',
            'monthExpectation': '月末检验',
            'targets': [],
            'model': 'deepseek-flash',
            'estimatedCostUsd': 0.01,
          },
          'paperEvents': [],
        },
      },
    ],
  };

  @override
  Future<List<Map<String, dynamic>>> listReports() async => savedReport
      ? [
          {
            'periodId': 'week-1',
            'archiveUrl': 'webdav://stock_agent_reports/week.json',
          },
        ]
      : const [];

  @override
  Future<Map<String, dynamic>> readReport(String periodId) async => {
    'periodId': periodId,
    'firstDay': '2026-09-01',
    'lastDay': '2026-09-07',
    'summary': {'closingCash': 1000, 'fillCount': 0, 'missedDayCount': 0},
    'days': [
      {
        'logicalDay': '2026-09-01',
        'status': 'ran',
        'decision': {'whyNow': '当天选择持币'},
        'eventIds': ['cycle-2026-09-01'],
        'fills': <Map>[],
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> generateReport(String periodId) async =>
      const {};
}
