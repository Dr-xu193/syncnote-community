import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/services/news_exploration_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_memory_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_read_tools.dart';
import 'package:syncnote/features/exploration/services/stock_market_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final asOf = DateTime.utc(2026, 9, 25, 8);

  test(
    'AI may browse diverse public candidates without a required strategy',
    () async {
      final news = _FakeNews();
      final tools = StockAgentExistingReadTools(
        experimentId: 'one-month',
        market: _FakeMarket(asOf),
        news: news,
        memory: StockAgentMemoryService.instance,
      );
      final result = await tools.execute(
        'browse_universe',
        const {},
        asOf: asOf,
      );
      expect(result['candidates'], hasLength(1));
      expect('${result['coverage']}', contains('不代表全市场完整清单'));
      expect(result['sourceErrors'], hasLength(1));
      news.dispose();
    },
  );

  test(
    'stock history gives numerical bars and a separately dated source',
    () async {
      final news = _FakeNews();
      final tools = StockAgentExistingReadTools(
        experimentId: 'one-month',
        market: _FakeMarket(asOf),
        news: news,
        memory: StockAgentMemoryService.instance,
      );
      final result = await tools.execute('stock_history', const {
        'code': '600001',
        'limit': 80,
      }, asOf: asOf);
      expect(result['candles'], hasLength(80));
      expect(result['indicators'], contains('sma20'));
      expect(result['sourceId'], isNotEmpty);
      news.dispose();
    },
  );

  test(
    'news retrieval does not leak articles published after the decision',
    () async {
      final news = _FakeNews();
      final tools = StockAgentExistingReadTools(
        experimentId: 'one-month',
        market: _FakeMarket(asOf),
        news: news,
        memory: StockAgentMemoryService.instance,
      );
      final result = await tools.execute('search_news', const {
        'query': '产业链',
      }, asOf: asOf);
      expect(result['articles'], hasLength(1));
      expect((result['articles'] as List).single['id'], 'known-now');
      news.dispose();
    },
  );
}

class _FakeMarket implements StockMarketGateway {
  _FakeMarket(this.asOf);

  final DateTime asOf;

  StockQuote get quote => StockQuote(
    symbol: 'sh600001',
    code: '600001',
    name: '测试股票',
    exchange: '上海',
    price: 9.8,
    previousClose: 9.7,
    open: 9.7,
    high: 9.9,
    low: 9.6,
    change: 0.1,
    changePercent: 1.03,
    volume: 100000,
    amount: 980000,
    turnoverRate: 1.2,
    pe: 15,
    marketCap: 1000000000,
    industry: '测试行业',
    provider: '测试源',
    providerTimestamp: asOf.subtract(const Duration(hours: 1)),
    fetchedAt: asOf,
  );

  @override
  Future<StockMarketRadar> fetchRadar({bool force = false}) async =>
      StockMarketRadar(
        indices: [quote],
        gainers: [quote],
        losers: const [],
        sectors: const [
          StockSectorStrength(name: '测试行业', changePercent: 1.2, leader: '测试股票'),
        ],
        breadth: const StockMarketBreadth(
          rising: 1,
          falling: 0,
          flat: 0,
          limitUp: 0,
          limitDown: 0,
          totalAmount: 980000,
        ),
        provider: '测试源',
        providerTimestamp: asOf.subtract(const Duration(hours: 1)),
        fetchedAt: asOf,
        marketStatus: '交易中',
      );

  @override
  Future<List<StockQuote>> search(String query) async => [quote];

  @override
  Future<List<StockQuote>> scan(
    StockScreenPreset preset, {
    int limit = 30,
  }) async {
    if (preset == StockScreenPreset.highRisk) throw StateError('这个公开源暂时不可用');
    return [quote];
  }

  @override
  Future<StockSeries> fetchSeries(
    String code, {
    StockPeriod period = StockPeriod.day,
    StockAdjustment adjustment = StockAdjustment.forward,
    int limit = 180,
  }) async {
    final candles = List.generate(80, (index) {
      final price = 8 + index * 0.02;
      return StockCandle(
        timestamp: DateTime.utc(2026, 6, 1).add(Duration(days: index)),
        open: price,
        high: price + 0.1,
        low: price - 0.1,
        close: price + 0.05,
        volume: 100000,
        amount: 1000000,
      );
    });
    return StockSeries(
      quote: quote,
      period: period,
      adjustment: adjustment,
      candles: candles,
      provider: '测试源',
      providerTimestamp: asOf.subtract(const Duration(hours: 1)),
      fetchedAt: asOf,
      dataNote: '只有过去已公布数据',
    );
  }

  @override
  void dispose() {}
}

class _FakeNews extends NewsExplorationService {
  @override
  Future<NewsRefreshResult> load({
    bool force = false,
    DateTime? now,
    ValueChanged<NewsLoadStage>? onStage,
  }) async {
    ExplorationNewsArticle article(String id, DateTime published) =>
        ExplorationNewsArticle(
          id: id,
          title: '产业链出现变化',
          url: 'https://example.com/$id',
          sourceId: 'test',
          sourceName: '测试新闻源',
          sourceAuthority: 1,
          region: '中国大陆',
          topic: '经济',
          publishedAt: published,
          summary: '仅用于测试新闻时点过滤',
        );
    return NewsRefreshResult(
      articles: [
        article('known-now', now!.subtract(const Duration(hours: 1))),
        article('future', now.add(const Duration(hours: 1))),
      ],
      successfulSources: 1,
      totalSources: 1,
      errors: const [],
      cached: true,
    );
  }
}
