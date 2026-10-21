import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/services/news_exploration_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_ai_service.dart';
import 'package:syncnote/features/exploration/services/stock_agent_memory_service.dart';
import 'package:syncnote/features/exploration/services/stock_indicator_engine.dart';
import 'package:syncnote/features/exploration/services/stock_market_gateway.dart';

/// Read-only bridge from the new agent to SyncNote's existing personal data
/// sources. It deliberately has no order, repository-write or broker method.
class StockAgentExistingReadTools implements StockAgentReadTools {
  const StockAgentExistingReadTools({
    required this.experimentId,
    required this.market,
    required this.news,
    required this.memory,
  });

  final String experimentId;
  final StockMarketGateway market;
  final NewsExplorationService news;
  final StockAgentMemoryService memory;

  @override
  Future<Map<String, dynamic>> execute(
    String name,
    Map<String, dynamic> arguments, {
    required DateTime asOf,
  }) async {
    switch (name) {
      case 'market_radar':
        final radar = await market.fetchRadar();
        return {
          'sourceId': _sourceId(
            'radar',
            radar.providerTimestamp,
            radar.provider,
          ),
          'sourceObservedAt': radar.providerTimestamp.toUtc().toIso8601String(),
          'provider': radar.provider,
          'marketStatus': radar.marketStatus,
          'indices': radar.indices.map((item) => item.toJson()).toList(),
          'gainers': radar.gainers.map((item) => item.toJson()).toList(),
          'losers': radar.losers.map((item) => item.toJson()).toList(),
          'sectors': radar.sectors
              .map(
                (item) => {
                  'name': item.name,
                  'changePercent': item.changePercent,
                  'leader': item.leader,
                },
              )
              .toList(),
          'breadth': {
            'rising': radar.breadth.rising,
            'falling': radar.breadth.falling,
            'flat': radar.breadth.flat,
            'limitUp': radar.breadth.limitUp,
            'limitDown': radar.breadth.limitDown,
          },
        };
      case 'browse_universe':
        final runs = await Future.wait(StockScreenPreset.values.map(_scanOne));
        final byCode = <String, StockQuote>{};
        for (final run in runs) {
          for (final quote in run.rows) {
            byCode.putIfAbsent(quote.code, () => quote);
          }
        }
        final candidates = byCode.values.take(56).toList();
        final observedAt = candidates.isEmpty
            ? asOf
            : candidates
                  .map((item) => item.providerTimestamp)
                  .reduce((a, b) => a.isAfter(b) ? a : b);
        return {
          'sourceId': _sourceId('universe', observedAt, 'market'),
          'sourceObservedAt': observedAt.toUtc().toIso8601String(),
          'coverage': '七类现有公开源筛选候选的去重合集，不代表全市场完整清单',
          'sourceErrors': runs
              .where((run) => run.error.isNotEmpty)
              .map((run) => run.error)
              .toList(),
          'candidates': candidates.map((item) => item.toJson()).toList(),
        };
      case 'search_stocks':
        final query = '${arguments['query'] ?? ''}'.trim();
        final values = (await market.search(query)).take(25).toList();
        final observedAt = values.isEmpty
            ? asOf
            : values
                  .map((item) => item.providerTimestamp)
                  .reduce((a, b) => a.isAfter(b) ? a : b);
        return {
          'sourceId': _sourceId('search:$query', observedAt, 'market'),
          'sourceObservedAt': observedAt.toUtc().toIso8601String(),
          'query': query,
          'results': values.map((item) => item.toJson()).toList(),
        };
      case 'stock_history':
        final code = '${arguments['code'] ?? ''}';
        final limit = (arguments['limit'] as num?)?.toInt() ?? 60;
        final series = await market.fetchSeries(
          code,
          period: StockPeriod.day,
          adjustment: StockAdjustment.none,
          limit: limit,
        );
        final indicators = StockIndicatorEngine.calculate(series.candles);
        return {
          'sourceId': _sourceId(
            code,
            series.providerTimestamp,
            series.provider,
          ),
          'sourceObservedAt': series.providerTimestamp
              .toUtc()
              .toIso8601String(),
          'provider': series.provider,
          'dataNote': series.dataNote,
          'quote': series.quote.toJson(),
          'indicators': indicators.toJson(),
          'candles': series.candles.map((item) => item.toJson()).toList(),
        };
      case 'search_news':
        final query = '${arguments['query'] ?? ''}'.trim().toLowerCase();
        final snapshot = await news.load(now: asOf);
        final matches = snapshot.articles
            .where((item) => item.publishedAt != null)
            .where((item) => !item.publishedAt!.isAfter(asOf))
            .where(
              (item) =>
                  '${item.title} ${item.summary} ${item.keywords.join(' ')}'
                      .toLowerCase()
                      .contains(query),
            )
            .take(10)
            .toList();
        final observedAt = matches.isEmpty
            ? asOf
            : matches
                  .map((item) => item.publishedAt!)
                  .reduce((a, b) => a.isAfter(b) ? a : b);
        return {
          'sourceId': _sourceId('news:$query', observedAt, 'news'),
          'sourceObservedAt': observedAt.toUtc().toIso8601String(),
          'query': query,
          'snapshotCached': snapshot.cached,
          'articles': matches
              .map(
                (item) => {
                  'id': item.id,
                  'title': item.title,
                  'url': item.url,
                  'source': item.sourceName,
                  'publishedAt': item.publishedAt!.toUtc().toIso8601String(),
                  'summary': item.summary,
                  'excerpt': item.fullContent.length > 500
                      ? item.fullContent.substring(0, 500)
                      : item.fullContent,
                  'contentComplete': item.contentComplete,
                },
              )
              .toList(),
        };
      case 'read_journal_day':
        final day = '${arguments['day'] ?? ''}';
        final currentBeijingDay = asOf
            .toUtc()
            .add(const Duration(hours: 8))
            .toIso8601String()
            .split('T')
            .first;
        if (day.compareTo(currentBeijingDay) > 0) {
          throw StateError('不能读取决策时点之后的日记');
        }
        final eventId = '${arguments['eventId'] ?? ''}';
        final original = await memory.readDay(experimentId, day);
        final events = (original['events'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        if (eventId.isNotEmpty) {
          final matching = events
              .where((item) => item['id'] == eventId)
              .toList();
          if (matching.isEmpty) throw StateError('所查原始日记事件不存在');
          return {
            'sourceId': eventId,
            'logicalDay': day,
            'event': matching.single,
          };
        }
        return {
          'sourceId': 'journal-$day',
          'logicalDay': day,
          'eventCount': events.length,
          'events': events
              .map(
                (item) => {
                  'id': item['id'],
                  'kind': item['kind'],
                  'occurredAt': item['occurredAt'],
                  'codes': item['codes'],
                  'summary': _clip('${item['detail'] ?? ''}', 180),
                },
              )
              .take(40)
              .toList(),
          'moreAvailable': events.length > 40,
        };
      default:
        throw StateError('未授权的股票数据工具');
    }
  }

  Future<({List<StockQuote> rows, String error})> _scanOne(
    StockScreenPreset preset,
  ) async {
    try {
      return (rows: await market.scan(preset, limit: 8), error: '');
    } catch (error) {
      return (rows: <StockQuote>[], error: '${preset.name}: $error');
    }
  }

  static String _sourceId(String subject, DateTime asOf, String provider) {
    final value = '$subject|${asOf.toUtc().toIso8601String()}|$provider';
    return 'stock-${sha256.convert(utf8.encode(value)).toString().substring(0, 20)}';
  }

  static String _clip(String text, int maxLength) =>
      text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';
}
