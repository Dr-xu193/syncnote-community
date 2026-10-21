import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/features/exploration/services/stock_agent_paper_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Windows JSON bridge keeps the same 1000-yuan account between processes',
    () async {
      const runner = WindowsStockAgentPaperRunner();
      final started = DateTime.parse('2026-08-24T14:00:00+08:00');
      final initial = await runner.start(
        experimentId: 'runner-probe',
        startedAt: started,
      );
      final state = Map<String, dynamic>.from(initial['state'] as Map);
      expect(state['initialCash'], 1000);
      final first = await runner.step(
        state: state,
        asOf: DateTime.parse('2026-08-24T16:00:00+08:00'),
        marketObservedAt: DateTime.parse('2026-08-24T15:01:00+08:00'),
        bars: [_bar('2026-08-24', 9.9)],
        intents: [
          {
            'intentId': 'paper-first-buy',
            'instrument': {'code': '600001', 'exchange': 'SSE'},
            'targetWeight': 1.0,
            'submittedAt': DateTime.parse(
              '2026-08-24T15:05:00+08:00',
            ).toIso8601String(),
          },
        ],
      );
      expect((first['state'] as Map)['cash'], 1000);
      final second = await runner.step(
        state: Map<String, dynamic>.from(first['state'] as Map),
        asOf: DateTime.parse('2026-08-25T16:00:00+08:00'),
        marketObservedAt: DateTime.parse('2026-08-25T15:01:00+08:00'),
        bars: [_bar('2026-08-25', 9.9)],
        intents: const [],
      );
      final after = Map<String, dynamic>.from(second['state'] as Map);
      expect((after['positions'] as List).single['shares'], 100);
      expect((after['cash'] as num).toDouble(), lessThan(5));
      final terminal = await runner.finish(
        state: after,
        asOf: DateTime.parse('${after['endsAt']}'),
      );
      expect((terminal['terminal'] as Map)['missingPrices'], ['600001.SSE']);
    },
    skip: !Platform.isWindows,
  );
}

Map<String, dynamic> _bar(String date, double price) => {
  'code': '600001',
  'exchange': 'SSE',
  'date': date,
  'open': price,
  'high': price,
  'low': price,
  'close': price,
  'previousClose': price,
  'volume': 1000000,
};
