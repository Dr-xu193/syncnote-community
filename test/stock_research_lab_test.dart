import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/screens/stock_research_screen.dart';
import 'package:syncnote/features/exploration/services/exploration_ai_service.dart';
import 'package:syncnote/features/exploration/services/stock_indicator_engine.dart';
import 'package:syncnote/features/exploration/services/stock_market_gateway.dart';
import 'package:syncnote/features/exploration/services/stock_order_draft_service.dart';
import 'package:syncnote/features/exploration/services/stock_plan_runner.dart';
import 'package:syncnote/features/exploration/services/stock_quant_runner.dart';
import 'package:syncnote/features/exploration/services/stock_evidence_validator.dart';
import 'package:syncnote/features/exploration/services/stock_research_repository.dart';
import 'package:syncnote/shared/models/note_model.dart';

void main() {
  test('stock search can sort a provider result with no matches', () async {
    final gateway = PublicChinaStockGateway(
      client: MockClient(
        (_) async => http.Response(
          '{"QuotationCodeTable":{"Data":[]}}',
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    expect(await gateway.search('不存在的股票'), isEmpty);
    gateway.dispose();
  });

  test('stock AI research uses Flash with maximum reasoning effort', () async {
    final requests = <Map<String, dynamic>>[];
    final ai = ExplorationAiService(
      client: MockClient((request) async {
        requests.add(
          Map<String, dynamic>.from(jsonDecode(request.body) as Map),
        );
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '{}'},
              },
            ],
          }),
          200,
        );
      }),
    );
    final report = _report();

    await ai.recommendStocks(
      preset: StockScreenPreset.trend,
      candidates: [(quote: report.quote, indicators: report.indicators)],
    );
    await ai.analyzeStock(
      quote: report.quote,
      indicators: report.indicators,
      sourceNotes: const ['测试数据'],
    );

    expect(requests, hasLength(2));
    expect(
      requests.every((body) => body['model'] == explorationFlashModel),
      isTrue,
    );
    expect(requests.every((body) => body['reasoning_effort'] == 'max'), isTrue);
    expect(
      requests.every((body) => (body['thinking'] as Map)['type'] == 'enabled'),
      isTrue,
    );
    expect(requests[0]['max_tokens'], 24000);
    expect(requests[1]['max_tokens'], 20000);
    ai.dispose();

    var failedCalls = 0;
    final failingAi = ExplorationAiService(
      client: MockClient((_) async {
        failedCalls++;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'length',
                'message': {'content': '', 'reasoning_content': 'budget used'},
              },
            ],
          }),
          200,
        );
      }),
    );
    await expectLater(
      failingAi.analyzeStock(
        quote: report.quote,
        indicators: report.indicators,
        sourceNotes: const ['测试数据'],
      ),
      throwsA(isA<ExplorationAiException>()),
    );
    expect(failedCalls, 1); // Never silently downgrade stock research.
    failingAi.dispose();
  });

  test('indicator engine calculates reproducible moving averages and RSI', () {
    final candles = List.generate(80, (index) {
      final close = 10 + index * 0.2;
      return StockCandle(
        timestamp: DateTime(2026, 1, index + 1),
        open: close - 0.1,
        high: close + 0.2,
        low: close - 0.3,
        close: close,
        volume: 1000 + index * 10,
        amount: 100000,
      );
    });
    final result = StockIndicatorEngine.calculate(candles);
    expect(result.sma5, closeTo((25 + 25.2 + 25.4 + 25.6 + 25.8) / 5, 1e-9));
    expect(result.sma60, isNotNull);
    expect(result.rsi14, 100);
    expect(result.macd, greaterThan(0));
    expect(result.volumeRatio, greaterThan(1));
  });

  test('screening is deterministic and applies preset boundaries', () {
    final universe = List.generate(60, (index) {
      return _quote(
        code: '${600000 + index}',
        name: index == 0 ? 'ST 测试' : '股票$index',
        change: ((index % 12) - 3).toDouble(),
        turnover: ((index % 15) + 1).toDouble(),
        amount: 1e8 + index * 1e7,
        pe: (8 + index).toDouble(),
        marketCap: 5e9 + index * 1e9,
      );
    });
    final first = StockIndicatorEngine.screenUniverse(
      universe,
      StockScreenPreset.trend,
    );
    final second = StockIndicatorEngine.screenUniverse(
      universe,
      StockScreenPreset.trend,
    );
    expect(first.map((item) => item.code), second.map((item) => item.code));
    expect(first, isNotEmpty);
    expect(first.every((item) => item.changePercent > 0), isTrue);
    expect(first.any((item) => item.name.startsWith('ST')), isFalse);
  });

  test(
    'price-limit breadth respects board rules and excludes new listings',
    () {
      expect(
        PublicChinaStockGateway.isLimitMoveForTesting(
          _quote(code: '600000', change: 9.96),
          up: true,
        ),
        isTrue,
      );
      expect(
        PublicChinaStockGateway.isLimitMoveForTesting(
          _quote(code: '300001', change: 10.01),
          up: true,
        ),
        isFalse,
      );
      expect(
        PublicChinaStockGateway.isLimitMoveForTesting(
          _quote(code: '300001', change: 19.98),
          up: true,
        ),
        isTrue,
      );
      expect(
        PublicChinaStockGateway.isLimitMoveForTesting(
          _quote(code: '301999', name: 'N新股', change: 180),
          up: true,
        ),
        isFalse,
      );
      expect(
        PublicChinaStockGateway.isLimitMoveForTesting(
          _quote(code: '600001', name: '*ST测试', change: -4.95),
          up: false,
        ),
        isTrue,
      );
      expect(
        PublicChinaStockGateway.isLimitMoveForTesting(
          _quote(code: '000001', name: '*ST测试', change: -4.95),
          up: false,
        ),
        isFalse,
      );
      expect(
        PublicChinaStockGateway.isLimitMoveForTesting(
          _quote(code: '000001', name: '*ST测试', change: -9.95),
          up: false,
        ),
        isTrue,
      );
      expect(
        PublicChinaStockGateway.isLimitMoveForTesting(
          _quote(code: '920001', change: 29.8),
          up: true,
        ),
        isTrue,
      );
    },
  );

  test('Sina industry fallback keeps numeric ranking without a GBK codec', () {
    final rows = PublicChinaStockGateway.parseSinaSectorsForTesting(
      'var sectors = {'
      '"new_blhy":"new_blhy,garbled,19,17.06,0.71,4.35,1,2,sz1",'
      '"new_fdc":"new_fdc,garbled,123,6.73,-0.07,-1.03,1,2,sz2"'
      '};',
    );

    expect(rows, hasLength(2));
    expect(rows.first.name, '玻璃行业');
    expect(rows.first.changePercent, 4.35);
    expect(rows.last.name, '房地产');
    expect(rows.last.changePercent, -1.03);
  });

  test(
    'public gateway preserves provider time, rankings and adjustment',
    () async {
      final client = MockClient((request) async {
        if (request.url.host == 'vip.stock.finance.sina.com.cn') {
          final ascending = request.url.queryParameters['asc'] == '1';
          final rows = List.generate(
            120,
            (index) => {
              'symbol': 'sh${600000 + index}',
              'code': '${600000 + index}',
              'name': '股票$index',
              'trade': '${10 + index / 10}',
              'pricechange': ascending ? '-0.2' : '0.2',
              'changepercent': ascending
                  ? '${-2 - index / 10}'
                  : '${2 + index / 10}',
              'settlement': '10',
              'open': '10',
              'high': '12',
              'low': '9',
              'volume': '1000',
              'amount': '200000000',
              'ticktime': '15:00:00',
              'per': '18',
              'mktcap': '1000000',
              'turnoverratio': '3',
            },
          );
          return http.Response.bytes(
            utf8.encode(jsonEncode(rows)),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.host == 'push2ex.eastmoney.com') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'data': {
                  'qdate': 20260731,
                  'fenbu': [
                    {'-1': 60},
                    {'1': 60},
                  ],
                },
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.host == 'push2.eastmoney.com' &&
            request.url.path.contains('ulist')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'data': {
                  'diff': [
                    {
                      'f2': 3800,
                      'f3': 1.2,
                      'f4': 45,
                      'f6': 8e11,
                      'f12': '000001',
                      'f14': '上证指数',
                      'f18': 3755,
                      'f124': 1785600000,
                    },
                  ],
                },
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.host == 'push2.eastmoney.com' &&
            request.url.queryParameters['fs'] == 'm:90+t:2') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'data': {
                  'diff': [
                    {'f3': 3.2, 'f12': 'BK1', 'f14': '人工智能', 'f128': '龙头'},
                  ],
                },
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.host == 'push2.eastmoney.com') {
          final rows = List.generate(
            120,
            (index) => {
              'f2': 10 + index / 10,
              'f3': index.isEven ? 2.0 : -1.0,
              'f4': 0.2,
              'f5': 1000,
              'f6': 2e8,
              'f8': 3.0,
              'f9': 18.0,
              'f12': '${600000 + index}',
              'f14': '股票$index',
              'f15': 12,
              'f16': 9,
              'f17': 10,
              'f18': 10,
              'f20': 1e10,
              'f21': 8e9,
              'f100': '测试行业',
              'f124': 1785600000,
            },
          );
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'data': {'diff': rows},
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.host == 'web.ifzq.gtimg.cn') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'data': {
                  'sh600001': {
                    'qfqday': [
                      ['2026-07-30', '10', '11', '11.2', '9.8', '1000'],
                      ['2026-07-31', '11', '12', '12.3', '10.8', '1200'],
                    ],
                    'qt': {
                      'sh600001': [
                        '1',
                        '测试股份',
                        '600001',
                        '12',
                        '11',
                        '11',
                        '1200',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '20260731150000',
                        '1',
                        '9.09',
                        '12.3',
                        '10.8',
                        '',
                        '1200',
                        '1.5',
                        '18',
                        '',
                        '',
                        '',
                        '',
                        '',
                        '100',
                      ],
                    },
                  },
                },
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });
      final gateway = PublicChinaStockGateway(client: client);
      final radar = await gateway.fetchRadar();
      expect(radar.gainers.length, 10);
      expect(radar.losers.length, 10);
      expect(radar.breadth.rising, 60);
      expect(radar.providerTimestamp.year, 2026);
      final series = await gateway.fetchSeries(
        '600001',
        adjustment: StockAdjustment.forward,
      );
      expect(series.candles.length, 2);
      expect(series.adjustment, StockAdjustment.forward);
      expect(series.dataNote, contains('前复权'));
      // Tencent returns Shanghai wall time. The gateway stores the true UTC
      // instant so the result is independent of the computer's time zone.
      expect(series.quote.providerTimestamp, DateTime.utc(2026, 7, 31, 7));
      gateway.dispose();
    },
  );

  test('plan repository blocks bulk payloads', () async {
    final backend = _MemoryStockBackend();
    final repository = StockResearchRepository.forTesting(backend);
    final plan = StockPlanRecord(
      id: 'plan-guarded',
      createdAt: DateTime.utc(2026),
      status: 'draft',
      payload: const {'candles': []},
    );
    await expectLater(repository.savePlan(plan), throwsA(isA<StateError>()));
    expect(backend.plans, isEmpty);
  });

  test('monitor repository saves a compact portable snapshot', () async {
    final backend = _MemoryStockBackend();
    final repository = StockResearchRepository.forTesting(backend);
    final now = DateTime.utc(2026, 8, 31, 15);
    await repository.saveMonitor(
      StockMonitorSnapshot(
        asOf: now,
        equity: 100000,
        peakEquity: 101000,
        drawdown: -0.01,
        alerts: [
          StockMonitorAlert(
            kind: 'drawdown',
            severity: 'info',
            message: '观察',
            occurredAt: now,
          ),
        ],
        updatedAt: now,
      ),
    );
    expect(backend.monitor, isNotNull);
    expect(backend.monitor!.alerts, hasLength(1));
  });

  test(
    'stock AI evidence validator accepts exact values and rejects drift',
    () {
      final quote = _quote();
      final indicators = StockIndicatorEngine.calculate(
        List.generate(
          80,
          (index) => StockCandle(
            timestamp: DateTime.utc(2026, 1, 1).add(Duration(days: index)),
            open: 10,
            high: 11,
            low: 9,
            close: 10 + index.toDouble(),
            volume: 1000,
            amount: 10000,
          ),
        ),
      );
      const validator = StockEvidenceValidator();
      expect(
        validator
            .validate(
              quote: quote,
              indicators: indicators,
              analysis: const {
                'data_citations': [
                  {'field': 'quote.price', 'value': 100, 'source': 'test'},
                ],
              },
            )
            .passed,
        isTrue,
      );
      expect(
        validator
            .validate(
              quote: quote,
              indicators: indicators,
              analysis: const {
                'data_citations': [
                  {'field': 'quote.price', 'value': 101, 'source': 'test'},
                ],
              },
            )
            .passed,
        isFalse,
      );
    },
  );

  test(
    'stock reports never persist candle arrays or full-market minute data',
    () {
      final report = _report();
      final stored = report.toFirestore();
      String collectKeys(Object? value) {
        if (value is Map) {
          return '${value.keys.join(' ')} ${value.values.map(collectKeys).join(' ')}';
        }
        if (value is List) return value.map(collectKeys).join(' ');
        return '';
      }

      final persistedKeys = collectKeys(stored);
      expect(persistedKeys, isNot(contains('candles')));
      expect(persistedKeys, isNot(contains('minute_data')));
      expect(stored['quote'], isA<Map>());
      expect(stored['indicators'], isA<Map>());
    },
  );

  test(
    'quant bridge keeps Shanghai trading dates and syncs no candle history',
    () {
      StockSeries series(String code) => StockSeries(
        quote: _quote(code: code),
        period: StockPeriod.day,
        adjustment: StockAdjustment.none,
        candles: List.generate(
          65,
          (index) => StockCandle(
            timestamp: DateTime.utc(
              2025,
              12,
              31,
              16,
            ).add(Duration(days: index)),
            open: 10,
            high: 11,
            low: 9,
            close: 10,
            volume: 1000,
            amount: 10000,
          ),
        ),
        provider: '测试公开源',
        providerTimestamp: DateTime.utc(2026),
        fetchedAt: DateTime.utc(2026),
        dataNote: '原始日线',
      );

      final first = series('600001');
      final second = series('600002');
      final payload = WindowsStockQuantRunner.buildSnapshotPayload(
        series: [
          StockQuantInputSeries(executionSeries: first, signalSeries: first),
          StockQuantInputSeries(executionSeries: second, signalSeries: second),
        ],
        preset: StockScreenPreset.trend,
      );
      final rows = payload['series']! as List;
      final bars = (rows.first as Map)['bars']! as List;
      expect((bars.first as Map)['date'], '2026-01-01');
      expect((bars.first as Map)['signalClose'], 10);
      expect(payload['trustTier'], 'public_validation');

      final report = StockQuantReport(
        id: 'quant-1',
        strategyName: 'trend',
        provider: '测试公开源',
        trustTier: 'public_validation',
        createdAt: DateTime.utc(2026),
        report: const {
          'out_of_sample': {'total_return': 0.1},
          'qualification': {'qualified_for_plan': false},
        },
      ).toFirestore();
      String collectKeys(Object? value) {
        if (value is Map) {
          return '${value.keys.join(' ')} ${value.values.map(collectKeys).join(' ')}';
        }
        if (value is List) return value.map(collectKeys).join(' ');
        return '';
      }

      final keys = collectKeys(report);
      expect(keys, isNot(contains('candles')));
      expect(keys, isNot(contains('bars')));
    },
  );

  test(
    'quant repository blocks bulk and oversized Firestore reports',
    () async {
      final backend = _MemoryStockBackend();
      final repository = StockResearchRepository.forTesting(backend);
      StockQuantReport report(Map<String, dynamic> body) => StockQuantReport(
        id: 'guarded',
        strategyName: 'test',
        provider: 'test',
        trustTier: 'public_validation',
        createdAt: DateTime.utc(2026),
        report: body,
      );

      await expectLater(
        repository.saveQuantReport(report({'bars': const []})),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repository.saveQuantReport(report({'payload': 'x' * (513 * 1024)})),
        throwsA(isA<StateError>()),
      );
      expect(backend.quantReports, isEmpty);
    },
  );

  test(
    'stock report archive verifies, compacts and restores exactly',
    () async {
      final backend = _MemoryStockBackend();
      final repository = StockResearchRepository.forTesting(backend);
      final report = _report();
      final archived = await repository.archiveReport(report);
      expect(archived.archived, isTrue);
      expect(archived.analysis, isEmpty);
      expect(backend.remote, hasLength(1));
      final restored = await repository.restoreReport(archived);
      expect(restored.archived, isFalse);
      expect(restored.analysis['summary'], report.analysis['summary']);
      expect(backend.remote, isEmpty);
    },
  );

  testWidgets('stock lab exposes radar, explorer, watchlist and reports', (
    tester,
  ) async {
    final backend = _MemoryStockBackend();
    final repository = StockResearchRepository.forTesting(backend);
    final gateway = _FakeGateway();
    final ai = ExplorationAiService(
      client: MockClient((_) async => http.Response('{}', 500)),
    );
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: StockResearchScreen(
          gateway: gateway,
          repository: repository,
          ai: ai,
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in ['市场雷达', '自主探索', '关注池', '研究记录', '组合计划', '模拟盘']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('涨幅前十'), findsOneWidget);
    await tester.tap(find.text('组合计划'));
    await tester.pumpAndSettle();
    expect(find.text('当前组合'), findsOneWidget);
    expect(find.text('录入当前组合'), findsOneWidget);
    expect(find.text('计划门禁'), findsOneWidget);
    expect(find.textContaining('个人研究模式'), findsOneWidget);
    ai.dispose();
  });

  testWidgets('qualified plan creates a visible human-only order draft', (
    tester,
  ) async {
    final backend = _MemoryStockBackend();
    backend.portfolio = StockPortfolio(
      equity: 100000,
      cash: 80000,
      asOf: DateTime.utc(2026, 8, 31, 9),
      positions: const [],
      updatedAt: DateTime.utc(2026, 8, 31, 9),
    );
    backend.quantReports['qualified'] = StockQuantReport(
      id: 'qualified',
      strategyName: 'test',
      provider: '授权主源',
      trustTier: 'primary_authorized',
      createdAt: DateTime.utc(2026, 8, 31, 9),
      report: const {
        'qualification': {'qualified_for_plan': true, 'reasons': []},
      },
    );
    final ai = ExplorationAiService(
      client: MockClient((_) async => http.Response('{}', 500)),
    );
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: StockResearchScreen(
          gateway: _FakeGateway(),
          repository: StockResearchRepository.forTesting(backend),
          ai: ai,
          planRunner: const _FakePlanRunner(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('组合计划'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已开启：禁止生成和确认'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成待人工确认计划'));
    await tester.pumpAndSettle();
    expect(find.text('生成待人工确认委托草稿'), findsOneWidget);
    await tester.tap(find.text('生成待人工确认委托草稿'));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(500, 700), const Offset(500, -500));
    await tester.pumpAndSettle();
    expect(find.text('人工委托草稿'), findsOneWidget);
    expect(find.textContaining('幂等键已锁定'), findsOneWidget);
    await tester.tap(find.text('人工确认'));
    await tester.pumpAndSettle();
    expect(find.text('人工确认委托草稿'), findsOneWidget);
    expect(find.textContaining('不会连接券商'), findsOneWidget);
    ai.dispose();
  });

  testWidgets(
    'Windows quant action renders and persists a lightweight report',
    (tester) async {
      final backend = _MemoryStockBackend();
      final ai = ExplorationAiService(
        client: MockClient((_) async => http.Response('{}', 500)),
      );
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: StockResearchScreen(
            gateway: _QuantGateway(),
            repository: StockResearchRepository.forTesting(backend),
            ai: ai,
            quantRunner: const _FakeQuantRunner(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('自主探索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('多因子回测'));
      await tester.pumpAndSettle();
      expect(find.textContaining('多因子样本外报告'), findsOneWidget);
      expect(find.text('仅研究，不生成计划'), findsOneWidget);
      expect(backend.quantReports, hasLength(1));
      ai.dispose();
    },
  );

  testWidgets(
    'research records expose evidence status and attribution editor',
    (tester) async {
      final backend = _MemoryStockBackend();
      backend.reports['evidence-report'] = _report().copyWith(
        analysis: const {
          'summary': '待核对报告',
          '_evidencePassed': false,
          '_evidenceIssues': ['AI 没有返回字段级数值证据引用'],
        },
      );
      final ai = ExplorationAiService(
        client: MockClient((_) async => http.Response('{}', 500)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: StockResearchScreen(
            gateway: _FakeGateway(),
            repository: StockResearchRepository.forTesting(backend),
            ai: ai,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('研究记录'));
      await tester.pumpAndSettle();
      expect(find.text('证据待核对'), findsOneWidget);
      await tester.tap(find.text('复盘'));
      await tester.pumpAndSettle();
      expect(find.text('复盘归因'), findsOneWidget);
      expect(find.text('未归因'), findsOneWidget);
      await tester.tap(find.text('未归因'));
      await tester.pumpAndSettle();
      expect(find.text('数据错误'), findsOneWidget);
      await tester.tap(find.text('取消'), warnIfMissed: false);
      ai.dispose();
    },
  );

  test('order draft service is lot-sized, idempotent and human-gated', () {
    final service = const StockOrderDraftService();
    final payload = {
      'ready': true,
      'sourceSnapshotHash': 'snapshot-1',
      'plans': [
        {
          'planId': 'plan-1',
          'candidate': {'instrument': '600519.SSE', 'price': 100.0},
          'tranches': [
            {'tranche': 1, 'targetShares': 100},
            {'tranche': 2, 'targetShares': 200},
          ],
        },
      ],
    };
    final now = DateTime.utc(2026, 8, 31, 9);
    final batch = service.build(
      planPayload: payload,
      batchId: 'batch-1',
      now: now,
    );
    expect(batch.drafts, hasLength(2));
    expect(
      batch.drafts.map((item) => item.idempotencyKey).toSet(),
      hasLength(2),
    );
    expect(batch.drafts.every((item) => !item.brokerSubmissionAllowed), isTrue);
    expect(
      () => service.confirm(batch, confirmationPhrase: '确认'),
      throwsStateError,
    );
    final confirmed = service.confirm(
      batch,
      confirmationPhrase: '确认草稿',
      now: now,
    );
    expect(confirmed.status, 'confirmed');
    expect(
      confirmed.drafts.every((item) => item.status == 'confirmed'),
      isTrue,
    );
    expect(
      service.confirm(confirmed, confirmationPhrase: '确认草稿', now: now).status,
      'confirmed',
    );
    expect(service.cancel(confirmed).status, 'confirmed');
    final stopped = service.cancel(batch, emergencyStop: true);
    expect(stopped.status, 'cancelled');
    expect(stopped.emergencyStop, isTrue);
  });
}

StockQuote _quote({
  String code = '600519',
  String name = '贵州茅台',
  double change = 1.2,
  double turnover = 1.5,
  double amount = 5e9,
  double pe = 20,
  double marketCap = 1e12,
}) => StockQuote(
  symbol: 'sh$code',
  code: code,
  name: name,
  exchange: '上海',
  price: 100,
  previousClose: 99,
  open: 99,
  high: 101,
  low: 98,
  change: 1,
  changePercent: change,
  volume: 100000,
  amount: amount,
  turnoverRate: turnover,
  pe: pe,
  marketCap: marketCap,
  industry: '食品饮料',
  provider: '测试源',
  providerTimestamp: DateTime(2026, 7, 31, 15),
  fetchedAt: DateTime(2026, 7, 31, 15, 1),
);

StockResearchReport _report() {
  final quote = _quote();
  final indicators = StockIndicatorEngine.calculate(
    List.generate(
      80,
      (index) => StockCandle(
        timestamp: DateTime(2026, 1, index + 1),
        open: (10 + index).toDouble(),
        high: (11 + index).toDouble(),
        low: (9 + index).toDouble(),
        close: 10.5 + index,
        volume: 1000,
        amount: 10000,
      ),
    ),
  );
  return StockResearchReport(
    id: 'report-1',
    quote: quote,
    indicators: indicators,
    analysis: const {
      'summary': '结构化研究结论',
      'bull_evidence': ['证据A'],
      'bear_evidence': ['证据B'],
      'risks': ['风险A'],
    },
    sources: const ['测试源'],
    model: explorationFlashModel,
    estimatedCostUsd: 0.01,
    createdAt: DateTime(2026, 7, 31),
    dataTimestamp: DateTime(2026, 7, 31, 15),
    reviewAt: DateTime(2026, 8, 30),
    linkedNoteId: 'note-1',
    userConclusion: '',
    reviewResult: '',
    archived: false,
    archiveUrl: '',
    archiveSha256: '',
  );
}

class _MemoryStockBackend implements StockResearchBackend {
  final watchController = StreamController<List<StockWatchItem>>.broadcast();
  final filterController = StreamController<List<StockSavedFilter>>.broadcast();
  final reportController =
      StreamController<List<StockResearchReport>>.broadcast();
  final Map<String, Uint8List> remote = {};
  final Map<String, StockResearchReport> reports = {};
  final Map<String, StockQuantReport> quantReports = {};
  StockPortfolio? portfolio;
  final Map<String, StockPlanRecord> plans = {};
  final Map<String, StockOrderDraftBatch> orderDrafts = {};
  StockMonitorSnapshot? monitor;
  final List<Note> notes = [];

  @override
  String? get currentUserId => 'test-user';

  @override
  Stream<List<StockWatchItem>> watchWatchlist() =>
      Stream.value(const <StockWatchItem>[]);

  @override
  Stream<List<StockSavedFilter>> watchFilters() =>
      Stream.value(const <StockSavedFilter>[]);

  @override
  Stream<List<StockResearchReport>> watchReports() =>
      Stream.value(reports.values.toList());

  @override
  Stream<List<StockQuantReport>> watchQuantReports() =>
      Stream.value(quantReports.values.toList());

  @override
  Stream<StockPortfolio?> watchPortfolio() => Stream.value(portfolio);

  @override
  Stream<List<StockPlanRecord>> watchPlans() =>
      Stream.value(plans.values.toList());

  @override
  Stream<List<StockOrderDraftBatch>> watchOrderDrafts() =>
      Stream.value(orderDrafts.values.toList());

  @override
  Stream<StockMonitorSnapshot?> watchMonitor() => Stream.value(monitor);

  @override
  Future<void> saveWatchItem(StockWatchItem item) async {}

  @override
  Future<void> deleteWatchItem(String id) async {}

  @override
  Future<void> saveFilter(StockSavedFilter filter) async {}

  @override
  Future<void> deleteFilter(String id) async {}

  @override
  Future<void> saveReport(StockResearchReport report) async {
    reports[report.id] = report;
  }

  @override
  Future<void> saveQuantReport(StockQuantReport report) async {
    quantReports[report.id] = report;
  }

  @override
  Future<void> savePortfolio(StockPortfolio value) async => portfolio = value;

  @override
  Future<void> savePlan(StockPlanRecord plan) async => plans[plan.id] = plan;

  @override
  Future<void> saveOrderDraftBatch(StockOrderDraftBatch batch) async =>
      orderDrafts[batch.id] = batch;

  @override
  Future<void> saveMonitor(StockMonitorSnapshot snapshot) async =>
      monitor = snapshot;

  @override
  Future<void> addNote(Note note) async => notes.add(note);

  @override
  Future<String> uploadArchive(Uint8List bytes, String remoteName) async {
    final url = 'webdav://stock_reports/$remoteName';
    remote[url] = Uint8List.fromList(bytes);
    return url;
  }

  @override
  Future<Uint8List> downloadArchive(String url) async => remote[url]!;

  @override
  Future<void> deleteArchive(String url) async => remote.remove(url);
}

class _FakeGateway implements StockMarketGateway {
  final quote = _quote();

  @override
  Future<StockMarketRadar> fetchRadar({bool force = false}) async {
    return StockMarketRadar(
      indices: [quote],
      gainers: [quote],
      losers: [quote],
      sectors: const [
        StockSectorStrength(name: '测试行业', changePercent: 1, leader: '测试股'),
      ],
      breadth: const StockMarketBreadth(
        rising: 1,
        falling: 1,
        flat: 0,
        limitUp: 0,
        limitDown: 0,
        totalAmount: 1e9,
      ),
      provider: '测试网关',
      providerTimestamp: DateTime(2026, 7, 31, 15),
      fetchedAt: DateTime(2026, 7, 31, 15),
      marketStatus: '休市',
    );
  }

  @override
  Future<List<StockQuote>> search(String query) async => [quote];

  @override
  Future<StockSeries> fetchSeries(
    String code, {
    StockPeriod period = StockPeriod.day,
    StockAdjustment adjustment = StockAdjustment.forward,
    int limit = 180,
  }) async => StockSeries(
    quote: quote,
    period: period,
    adjustment: adjustment,
    candles: const [],
    provider: '测试网关',
    providerTimestamp: DateTime(2026, 7, 31, 15),
    fetchedAt: DateTime(2026, 7, 31, 15),
    dataNote: '测试',
  );

  @override
  Future<List<StockQuote>> scan(
    StockScreenPreset preset, {
    int limit = 30,
  }) async => [quote];

  @override
  void dispose() {}
}

class _QuantGateway extends _FakeGateway {
  @override
  Future<List<StockQuote>> scan(
    StockScreenPreset preset, {
    int limit = 30,
  }) async => [_quote(code: '600001'), _quote(code: '600002')];

  @override
  Future<StockSeries> fetchSeries(
    String code, {
    StockPeriod period = StockPeriod.day,
    StockAdjustment adjustment = StockAdjustment.forward,
    int limit = 180,
  }) async => StockSeries(
    quote: _quote(code: code),
    period: period,
    adjustment: adjustment,
    candles: List.generate(
      80,
      (index) => StockCandle(
        timestamp: DateTime.utc(2026, 1, 1).add(Duration(days: index)),
        open: 10,
        high: 11,
        low: 9,
        close: 10,
        volume: 1000,
        amount: 10000,
      ),
    ),
    provider: '测试网关',
    providerTimestamp: DateTime(2026, 7, 31, 15),
    fetchedAt: DateTime(2026, 7, 31, 15),
    dataNote: '测试',
  );
}

class _FakeQuantRunner implements StockQuantRunner {
  const _FakeQuantRunner();

  @override
  bool get canRunLocally => true;

  @override
  Future<StockQuantReport> run({
    required List<StockQuantInputSeries> series,
    required StockScreenPreset preset,
    StockQuantDataSource dataSource = StockQuantDataSource.free,
  }) async => StockQuantReport(
    id: 'quant-widget',
    strategyName: 'medium_trend-top2',
    provider: '测试网关',
    trustTier: 'public_validation',
    createdAt: DateTime(2026, 8, 30),
    report: const {
      'factor_coverage': 0.57,
      'out_of_sample': {
        'total_return': 0.02,
        'max_drawdown': -0.01,
        'sharpe': 0.8,
      },
      'qualification': {
        'qualified_for_plan': false,
        'reasons': ['数据源不是已授权主数据源，只能用于公开验证'],
      },
      'latestRanking': [
        {'instrument': '600001.SSE'},
        {'instrument': '600002.SSE'},
      ],
    },
  );
}

class _FakePlanRunner implements StockPlanRunner {
  const _FakePlanRunner();

  @override
  bool get canRunLocally => true;

  @override
  Future<Map<String, dynamic>> buildPlan({
    required StockPortfolio portfolio,
    required StockQuantReport report,
  }) async => {
    'ready': true,
    'sourceSnapshotHash': 'snapshot-test',
    'plans': [
      {
        'planId': 'plan-test',
        'candidate': {'instrument': '600519.SSE', 'price': 100.0},
        'tranches': [
          {'tranche': 1, 'targetShares': 100},
        ],
      },
    ],
  };
}
