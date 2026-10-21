import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/features/exploration/services/stock_agent_report_service.dart';

void main() {
  test('monthly report reconciles two real fills and links original days', () {
    final position = {
      'instrument': {'code': '600001', 'exchange': 'SSE'},
      'shares': 100,
      'averageCost': 9.05,
      'lastClose': 10,
    };
    final experiment = StockAgentExperiment(
      id: 'test-paper',
      startedAt: DateTime.parse('2026-08-24T14:00:00+08:00'),
      endsAt: DateTime.parse('2026-09-23T00:00:00+08:00'),
      version: 2,
      account: const {'initialCash': 1000},
      memory: const {},
      updatedAt: DateTime.utc(2026, 8, 26),
    );
    final report = StockAgentReportService.buildReport(
      experiment: experiment,
      periodId: 'month',
      generatedAt: DateTime.utc(2026, 9, 23),
      days: [
        {
          'logicalDay': '2026-08-24',
          'openingAccount': {'cash': 1000, 'positions': <Map>[]},
          'closingAccount': {
            'cash': 95,
            'positions': [position],
            'lastEquity': 1095,
            'cumulativeFees': 5,
          },
          'events': [
            {
              'id': 'cycle-2026-08-24',
              'kind': 'daily_cycle',
              'detail': {
                'paperEvents': [
                  {
                    'kind': 'fill',
                    'detail': {
                      'instrument': '600001.SSE',
                      'side': 'buy',
                      'shares': 100,
                      'price': 9,
                      'fees': 5,
                    },
                  },
                ],
                'decision': {
                  'mode': 'rebalance',
                  'whyNow': '证据支持虚拟买入',
                  'sourceIds': ['quote-1'],
                  'estimatedCostUsd': 0.01,
                },
              },
            },
          ],
        },
        {
          'logicalDay': '2026-08-25',
          'openingAccount': {
            'cash': 95,
            'positions': [position],
          },
          'closingAccount': {
            'cash': 1090,
            'positions': <Map>[],
            'lastEquity': 1090,
            'cumulativeFees': 10,
          },
          'events': [
            {
              'id': 'cycle-2026-08-25',
              'kind': 'daily_cycle',
              'detail': {
                'paperEvents': [
                  {
                    'kind': 'fill',
                    'detail': {
                      'instrument': '600001.SSE',
                      'side': 'sell',
                      'shares': 100,
                      'price': 10,
                      'fees': 5,
                    },
                  },
                ],
              },
            },
          ],
        },
      ],
      terminal: const {
        'terminal': {
          'cash': 1090,
          'marketValue': 0,
          'estimatedExitFees': 0,
          'netValue': 1090,
          'missingPrices': [],
        },
      },
    );
    final summary = report['summary'] as Map;
    expect(summary['fillCount'], 2);
    expect(summary['realizedPnLFromFills'], closeTo(90, 1e-6));
    expect(summary['terminalNetValue'], 1090);
    expect(summary['terminalReturn'], closeTo(0.09, 1e-6));
    expect(summary['estimatedModelCostUsd'], 0.01);
    final days = report['days'] as List;
    expect((days.first as Map)['eventIds'], ['cycle-2026-08-24']);
    expect((days.last as Map)['eventIds'], ['cycle-2026-08-25']);
  });

  test('missing terminal price stays unknown, never fabricated', () {
    final experiment = StockAgentExperiment(
      id: 'test-paper',
      startedAt: DateTime.parse('2026-08-24T14:00:00+08:00'),
      endsAt: DateTime.parse('2026-09-23T00:00:00+08:00'),
      version: 1,
      account: const {'initialCash': 1000},
      memory: const {},
      updatedAt: DateTime.utc(2026, 8, 24),
    );
    final report = StockAgentReportService.buildReport(
      experiment: experiment,
      periodId: 'month',
      generatedAt: DateTime.utc(2026, 9, 23),
      days: [
        {
          'logicalDay': '2026-08-24',
          'openingAccount': {'cash': 1000},
          'closingAccount': {'cash': 0, 'lastEquity': 1000},
          'events': [
            {
              'id': 'missed',
              'kind': 'missed_cycle',
              'detail': <String, dynamic>{},
            },
          ],
        },
      ],
      terminal: const {
        'terminal': {
          'netValue': null,
          'missingPrices': ['600001.SSE'],
        },
      },
    );
    final summary = report['summary'] as Map;
    expect(summary['terminalNetValue'], isNull);
    expect(summary['terminalReturn'], isNull);
    expect(summary['missingTerminalPrices'], ['600001.SSE']);
    expect(summary['missedDayCount'], 1);
  });
}
