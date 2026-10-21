import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/screens/stock_research_screen.dart';
import 'package:syncnote/features/exploration/services/exploration_ai_service.dart';
import 'package:syncnote/features/exploration/services/stock_data_quality.dart';
import 'package:syncnote/features/exploration/services/stock_market_gateway.dart';
import 'package:syncnote/features/exploration/services/stock_research_repository.dart';

void main() {
  final now = DateTime.utc(2026, 8, 27, 2); // 10:00 in Shanghai.

  StockQuote quote({
    String provider = '主源',
    double price = 10,
    DateTime? providerTimestamp,
    DateTime? fetchedAt,
  }) => StockQuote(
    symbol: 'sh600000',
    code: '600000',
    name: '测试股票',
    exchange: '上海',
    price: price,
    previousClose: 9,
    open: 9.2,
    high: price > 10.2 ? price : 10.2,
    low: 8.9,
    change: price - 9,
    changePercent: (price / 9 - 1) * 100,
    volume: 10000,
    amount: 1000000,
    turnoverRate: 1.2,
    pe: 15,
    marketCap: 1e10,
    industry: '测试',
    provider: provider,
    providerTimestamp:
        providerTimestamp ?? now.subtract(const Duration(minutes: 1)),
    fetchedAt: fetchedAt ?? now,
  );

  test('China market phase is independent of the computer time zone', () {
    final clock = ChinaMarketClock(now: () => now);
    final calendar = ChinaTradingCalendar();
    expect(clock.toShanghaiWallTime(now).hour, 10);
    expect(calendar.marketStatusAt(now, clock: clock), '交易中');

    final sameInstantFromAmerica = DateTime.parse('2026-08-26T19:00:00-07:00');
    expect(
      calendar.marketStatusAt(sameInstantFromAmerica, clock: clock),
      '交易中',
    );
  });

  test('injectable exchange holidays block the trading window', () {
    final clock = ChinaMarketClock(now: () => now);
    final calendar = ChinaTradingCalendar(holidays: const ['2026-08-27']);
    expect(calendar.marketStatusAt(now, clock: clock), '休市');
  });

  test('official 2026 exchange calendar closes weekday holidays', () {
    final clock = ChinaMarketClock();
    final calendar = ChinaTradingCalendar.mainland2026();
    expect(
      calendar.marketStatusAt(DateTime.utc(2026, 1, 2, 2), clock: clock),
      '休市',
    );
    expect(
      calendar.marketStatusAt(DateTime.utc(2026, 1, 5, 2), clock: clock),
      '交易中',
    );
    expect(calendar.version, 'SSE-2025-45/2026');
  });

  test('valid fresh quote is actionable and stale quote is blocked', () {
    final quality = StockDataQuality(clock: ChinaMarketClock(now: () => now));
    expect(quality.evaluateQuote(quote()).canResearch, isTrue);
    expect(quality.evaluateQuote(quote()).canCreatePlan, isFalse);

    final stale = quote(
      providerTimestamp: now.subtract(const Duration(days: 1)),
    );
    final report = quality.evaluateQuote(stale);
    expect(report.level, StockDataQualityLevel.stale);
    expect(report.shouldBlockResearch, isTrue);
  });

  test(
    'only an authorized research provider may open the future plan gate',
    () {
      final quality = StockDataQuality(clock: ChinaMarketClock(now: () => now));
      final authorized = quality.evaluateQuote(
        quote(provider: 'Tushare Pro 授权研究源'),
      );
      expect(authorized.canResearch, isTrue);
      expect(authorized.canCreatePlan, isTrue);
      expect(authorized.trustTier, StockDataTrustTier.authorizedResearch);

      final publicPrimary = quality.evaluateQuote(
        quote(provider: '东方财富公开行情接口'),
        crossSourceQuotes: [quote(provider: 'Tushare Pro 授权研究源')],
      );
      expect(publicPrimary.canResearch, isTrue);
      expect(publicPrimary.canCreatePlan, isFalse);
      expect(publicPrimary.trustTier, StockDataTrustTier.publicValidation);
    },
  );

  test('cross-source price disagreement blocks research', () {
    final quality = StockDataQuality(clock: ChinaMarketClock(now: () => now));
    final report = quality.evaluateQuote(
      quote(),
      crossSourceQuotes: [quote(provider: '备源', price: 10.2)],
    );
    expect(report.level, StockDataQualityLevel.conflicted);
    expect(
      report.issues.map((item) => item.code),
      contains(StockDataIssueCode.crossSourcePriceConflict),
    );
  });

  test('duplicate and malformed candles are rejected deterministically', () {
    final quality = StockDataQuality(clock: ChinaMarketClock(now: () => now));
    final timestamp = now.subtract(const Duration(days: 1));
    final series = StockSeries(
      quote: quote(),
      period: StockPeriod.day,
      adjustment: StockAdjustment.forward,
      candles: [
        StockCandle(
          timestamp: timestamp,
          open: 9,
          high: 10.2,
          low: 8.8,
          close: 10,
          volume: 100,
          amount: 1000,
        ),
        StockCandle(
          timestamp: timestamp,
          open: 10,
          high: 9,
          low: 11,
          close: 10,
          volume: 100,
          amount: 1000,
        ),
      ],
      provider: '主源',
      providerTimestamp: now,
      fetchedAt: now,
      dataNote: 'test',
    );
    final report = quality.evaluateSeries(series);
    expect(report.level, StockDataQualityLevel.conflicted);
    expect(
      report.issues.map((item) => item.code),
      containsAll([
        StockDataIssueCode.duplicateCandleTimestamp,
        StockDataIssueCode.invalidCandleOhlc,
      ]),
    );
  });

  test('mainland exchanges include Beijing Stock Exchange codes', () {
    expect(PublicChinaStockGateway.exchangeForCodeForTesting('600000'), '上海');
    expect(PublicChinaStockGateway.exchangeForCodeForTesting('000001'), '深圳');
    expect(PublicChinaStockGateway.exchangeForCodeForTesting('920001'), '北京');
    expect(PublicChinaStockGateway.exchangeForCodeForTesting('830001'), '北京');
  });

  testWidgets('stale data is visible and disables Flash research', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final staleQuote = quote(
      providerTimestamp: DateTime.now().toUtc().subtract(
        // Five days guarantees an older-than-latest trading date even when
        // this test runs during a weekend in Beijing.
        const Duration(days: 5),
      ),
      fetchedAt: DateTime.now().toUtc(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: StockDetailScreen(
          initialQuote: staleQuote,
          gateway: _StaleGateway(staleQuote),
          repository: StockResearchRepository.instance,
          ai: ExplorationAiService(),
          initialWatchItem: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Keep the assertion failure diagnostic useful when this layout changes.
    final renderedText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .where((value) => value.isNotEmpty)
        .join(' | ');
    expect(renderedText, contains('数据已过期'));
    expect(find.text('数据已过期'), findsOneWidget);
    expect(find.textContaining('门禁未通过时'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '正反研究 · Flash'),
    );
    expect(button.onPressed, isNull);
  });
}

class _StaleGateway implements StockMarketGateway {
  _StaleGateway(this.value);

  final StockQuote value;

  @override
  Future<StockSeries> fetchSeries(
    String code, {
    StockPeriod period = StockPeriod.day,
    StockAdjustment adjustment = StockAdjustment.forward,
    int limit = 180,
  }) async {
    final day = DateTime.now().toUtc().subtract(const Duration(days: 2));
    return StockSeries(
      quote: value,
      period: period,
      adjustment: adjustment,
      candles: [
        StockCandle(
          timestamp: day,
          open: 9.2,
          high: 10.2,
          low: 8.9,
          close: 10,
          volume: 1000,
          amount: 10000,
        ),
      ],
      provider: value.provider,
      providerTimestamp: value.providerTimestamp,
      fetchedAt: value.fetchedAt,
      dataNote: 'stale test',
    );
  }

  @override
  Future<StockMarketRadar> fetchRadar({bool force = false}) =>
      throw UnimplementedError();

  @override
  Future<List<StockQuote>> scan(
    StockScreenPreset preset, {
    int limit = 30,
  }) async => const [];

  @override
  Future<List<StockQuote>> search(String query) async => const [];

  @override
  void dispose() {}
}
