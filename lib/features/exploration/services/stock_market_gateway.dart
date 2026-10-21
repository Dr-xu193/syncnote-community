import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/services/stock_data_quality.dart';
import 'package:syncnote/features/exploration/services/stock_indicator_engine.dart';

abstract interface class StockMarketGateway {
  Future<StockMarketRadar> fetchRadar({bool force = false});

  Future<List<StockQuote>> search(String query);

  Future<StockSeries> fetchSeries(
    String code, {
    StockPeriod period = StockPeriod.day,
    StockAdjustment adjustment = StockAdjustment.forward,
    int limit = 180,
  });

  Future<List<StockQuote>> scan(StockScreenPreset preset, {int limit = 30});

  void dispose();
}

// Sina's legacy industry endpoint is GBK encoded. Numeric fields and stable
// industry IDs are ASCII, so the gateway parses those bytes losslessly and
// maps the provider taxonomy to display names without a platform codec.
const _sinaIndustryNames = <String, String>{
  'new_blhy': '玻璃行业',
  'new_cbzz': '船舶制造',
  'new_cmyl': '传媒娱乐',
  'new_dlhy': '电力行业',
  'new_dqhy': '电器行业',
  'new_dzqj': '电子器件',
  'new_dzxx': '电子信息',
  'new_fdc': '房地产',
  'new_fdsb': '发电设备',
  'new_fjzz': '飞机制造',
  'new_fzhy': '纺织行业',
  'new_fzjx': '纺织机械',
  'new_fzxl': '服装鞋类',
  'new_glql': '公路桥梁',
  'new_gsgq': '供水供气',
  'new_gthy': '钢铁行业',
  'new_hbhy': '环保行业',
  'new_hghy': '化工行业',
  'new_hqhy': '化纤行业',
  'new_jdhy': '家电行业',
  'new_jdly': '酒店旅游',
  'new_jjhy': '家具行业',
  'new_jrhy': '金融行业',
  'new_jtys': '交通运输',
  'new_jxhy': '机械行业',
  'new_jzjc': '建筑建材',
  'new_kfq': '开发区',
  'new_ljhy': '酿酒行业',
  'new_mtc': '摩托车',
  'new_mthy': '煤炭行业',
  'new_nlmy': '农林牧渔',
  'new_nyhf': '农药化肥',
  'new_qczz': '汽车制造',
  'new_qtxy': '其他行业',
  'new_slzp': '塑料制品',
  'new_snhy': '水泥行业',
  'new_sphy': '食品行业',
  'new_stock': '次新股',
  'new_swzz': '生物制药',
  'new_sybh': '商业百货',
  'new_syhy': '石油行业',
  'new_tchy': '陶瓷行业',
  'new_wzwm': '物资外贸',
  'new_ylqx': '医疗器械',
  'new_yqyb': '仪器仪表',
  'new_ysbz': '印刷包装',
  'new_ysjs': '有色金属',
  'new_zhhy': '综合行业',
  'new_zzhy': '造纸行业',
};

class StockGatewayException implements Exception {
  const StockGatewayException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PublicChinaStockGateway implements StockMarketGateway {
  PublicChinaStockGateway({
    http.Client? client,
    ChinaMarketClock? clock,
    ChinaTradingCalendar? calendar,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? ChinaMarketClock(),
       _calendar = calendar ?? ChinaTradingCalendar.mainland2026();

  static const providerName = '腾讯证券 / 东方财富 / 新浪财经公开行情接口（个人验证）';
  static const providerRisk = '个人研究验证接口，不是授权 Level-1 商用行情；正式多人发布前必须切换持牌行情网关。';

  final http.Client _client;
  final ChinaMarketClock _clock;
  final ChinaTradingCalendar _calendar;
  StockMarketRadar? _radarCache;
  DateTime? _radarFetchedAt;
  DateTime? _distributionDate;

  @override
  Future<StockMarketRadar> fetchRadar({bool force = false}) async {
    final now = _clock.nowInstant();
    if (!force &&
        _radarCache != null &&
        _radarFetchedAt != null &&
        now.difference(_radarFetchedAt!) < const Duration(seconds: 90)) {
      return _radarCache!;
    }
    final summaryResults = await Future.wait<Object>([
      _withFallback(_fetchIndices(), const <StockQuote>[]),
      _withFallback(_fetchSectors(), const <StockSectorStrength>[]),
      _withFallback(
        _fetchMarketDistribution(),
        const StockMarketBreadth(
          rising: 0,
          falling: 0,
          flat: 0,
          limitUp: 0,
          limitDown: 0,
          totalAmount: 0,
        ),
      ),
    ]);
    final indices = summaryResults[0] as List<StockQuote>;
    final sectors = summaryResults[1] as List<StockSectorStrength>;
    final distribution = summaryResults[2] as StockMarketBreadth;
    final moverResults = await Future.wait([
      _withFallback(_fetchMoverCandidates(up: true), const <StockQuote>[]),
      _withFallback(_fetchMoverCandidates(up: false), const <StockQuote>[]),
    ]);
    final gainers = moverResults[0];
    final losers = moverResults[1];
    if (indices.isEmpty && gainers.isEmpty && losers.isEmpty) {
      if (_radarCache != null) return _radarCache!;
      throw const StockGatewayException('市场雷达主数据源暂时均不可用');
    }
    final timestampCandidates = [...indices, ...gainers, ...losers];
    final providerTimestamp = timestampCandidates
        .map((item) => item.providerTimestamp)
        .fold<DateTime>(DateTime.fromMillisecondsSinceEpoch(0), (a, b) {
          return b.isAfter(a) ? b : a;
        });
    final marketStatus = _marketStatus(now);
    final radar = StockMarketRadar(
      indices: List.unmodifiable(indices),
      gainers: List.unmodifiable(gainers.take(10)),
      losers: List.unmodifiable(losers.take(10)),
      sectors: List.unmodifiable(sectors.take(10)),
      breadth: StockMarketBreadth(
        rising: distribution.rising,
        falling: distribution.falling,
        flat: distribution.flat,
        limitUp: gainers.where((item) => _isLimitMove(item, up: true)).length,
        limitDown: losers.where((item) => _isLimitMove(item, up: false)).length,
        totalAmount: 0,
      ),
      provider: providerName,
      providerTimestamp: providerTimestamp,
      fetchedAt: now,
      marketStatus: marketStatus,
    );
    _radarCache = radar;
    _radarFetchedAt = now;
    return radar;
  }

  Future<T> _withFallback<T>(Future<T> request, T fallback) async {
    try {
      return await request.timeout(const Duration(seconds: 12));
    } catch (_) {
      return fallback;
    }
  }

  @override
  Future<List<StockQuote>> search(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.length < 2) return const [];
    // The provider parser deliberately returns fixed-length/const lists.
    // Sorting those directly throws on both valid and empty search results.
    final matches = List<StockQuote>.of(await _searchQuotes(normalized));
    matches.sort((a, b) {
      int rank(StockQuote item) {
        if (item.code == normalized) return 0;
        if (item.name.toLowerCase() == normalized) return 1;
        if (item.code.startsWith(normalized)) return 2;
        if (item.name.toLowerCase().startsWith(normalized)) return 3;
        return 4;
      }

      final compared = rank(a).compareTo(rank(b));
      if (compared != 0) return compared;
      return b.amount.compareTo(a.amount);
    });
    if (matches.isEmpty && RegExp(r'^\d{6}$').hasMatch(normalized)) {
      try {
        final series = await fetchSeries(normalized, limit: 2);
        return [series.quote];
      } catch (_) {
        return const [];
      }
    }
    return List.unmodifiable(matches.take(20));
  }

  @override
  Future<List<StockQuote>> scan(
    StockScreenPreset preset, {
    int limit = 30,
  }) async {
    final universe = await _fetchScanUniverse(preset);
    return StockIndicatorEngine.screenUniverse(universe, preset, limit: limit);
  }

  @override
  Future<StockSeries> fetchSeries(
    String code, {
    StockPeriod period = StockPeriod.day,
    StockAdjustment adjustment = StockAdjustment.forward,
    int limit = 180,
  }) async {
    final normalizedCode = _normalizeCode(code);
    if (period == StockPeriod.minute) {
      return _fetchMinuteSeries(normalizedCode);
    }
    final marketCode = _tencentCode(normalizedCode);
    final periodName = switch (period) {
      StockPeriod.day => 'day',
      StockPeriod.week => 'week',
      StockPeriod.month => 'month',
      StockPeriod.minute => 'day',
    };
    final adjustmentName = switch (adjustment) {
      StockAdjustment.none => '',
      StockAdjustment.forward => 'qfq',
      StockAdjustment.backward => 'hfq',
    };
    final key = '$adjustmentName$periodName';
    final parameter =
        '$marketCode,$periodName,,,${limit.clamp(20, 500)},'
        '${adjustmentName.isEmpty ? 'none' : adjustmentName}';
    final uri = Uri.https('web.ifzq.gtimg.cn', '/appstock/app/fqkline/get', {
      'param': parameter,
    });
    final envelope = await _getJson(uri);
    final data = Map<String, dynamic>.from(
      envelope['data'] as Map? ?? const {},
    );
    final stock = Map<String, dynamic>.from(
      data[marketCode] as Map? ?? const {},
    );
    final rawRows =
        stock[key] as List? ?? stock[periodName] as List? ?? const [];
    final candles = rawRows
        .whereType<List>()
        .map(_parseTencentCandle)
        .whereType<StockCandle>()
        .toList(growable: false);
    if (candles.isEmpty) {
      throw const StockGatewayException('行情供应商没有返回 K 线数据');
    }
    final quote = _quoteFromTencent(
      marketCode,
      Map<String, dynamic>.from(stock['qt'] as Map? ?? const {}),
      candles,
    );
    return StockSeries(
      quote: quote,
      period: period,
      adjustment: adjustment,
      candles: List.unmodifiable(candles),
      provider: '腾讯证券公开行情接口',
      providerTimestamp: quote.providerTimestamp,
      fetchedAt: _clock.nowInstant(),
      dataNote:
          '${_periodLabel(period)} · ${_adjustmentLabel(adjustment)}；$providerRisk',
    );
  }

  Future<StockSeries> _fetchMinuteSeries(String normalizedCode) async {
    final marketCode = _tencentCode(normalizedCode);
    final uri = Uri.https('web.ifzq.gtimg.cn', '/appstock/app/minute/query', {
      'code': marketCode,
    });
    final envelope = await _getJson(uri);
    final data = Map<String, dynamic>.from(
      envelope['data'] as Map? ?? const {},
    );
    final stock = Map<String, dynamic>.from(
      data[marketCode] as Map? ?? const {},
    );
    final minute = Map<String, dynamic>.from(stock['data'] as Map? ?? const {});
    final date =
        DateTime.tryParse('${minute['date'] ?? ''}') ??
        _clock.toShanghaiWallTime(_clock.nowInstant());
    final rows = minute['data'] as List? ?? const [];
    var previousVolume = 0.0;
    var previousAmount = 0.0;
    final candles = <StockCandle>[];
    for (final raw in rows) {
      final parts = '$raw'.split(RegExp(r'\s+'));
      if (parts.length < 4 || parts[0].length != 4) continue;
      final close = double.tryParse(parts[1]) ?? 0;
      final cumulativeVolume = double.tryParse(parts[2]) ?? previousVolume;
      final cumulativeAmount = double.tryParse(parts[3]) ?? previousAmount;
      final hour = int.tryParse(parts[0].substring(0, 2)) ?? 0;
      final minuteValue = int.tryParse(parts[0].substring(2, 4)) ?? 0;
      candles.add(
        StockCandle(
          timestamp: _clock.fromShanghaiWallTime(
            DateTime.utc(date.year, date.month, date.day, hour, minuteValue),
          ),
          open: close,
          high: close,
          low: close,
          close: close,
          volume: (cumulativeVolume - previousVolume).clamp(0, double.infinity),
          amount: (cumulativeAmount - previousAmount).clamp(0, double.infinity),
        ),
      );
      previousVolume = cumulativeVolume;
      previousAmount = cumulativeAmount;
    }
    if (candles.isEmpty) {
      throw const StockGatewayException('行情供应商没有返回分时数据');
    }
    final quote = StockQuote(
      symbol: marketCode,
      code: normalizedCode,
      name: normalizedCode,
      exchange: marketCode.startsWith('sh') ? '上海' : '深圳',
      price: candles.last.close,
      previousClose: candles.first.close,
      open: candles.first.open,
      high: candles.map((item) => item.high).reduce((a, b) => a > b ? a : b),
      low: candles.map((item) => item.low).reduce((a, b) => a < b ? a : b),
      change: candles.last.close - candles.first.close,
      changePercent: candles.first.close == 0
          ? 0
          : (candles.last.close / candles.first.close - 1) * 100,
      volume: previousVolume,
      amount: previousAmount,
      turnoverRate: 0,
      pe: 0,
      marketCap: 0,
      industry: '',
      provider: '腾讯证券公开行情接口',
      providerTimestamp: candles.last.timestamp,
      fetchedAt: _clock.nowInstant(),
      tradeStatus: _marketStatus(_clock.nowInstant()),
    );
    return StockSeries(
      quote: quote,
      period: StockPeriod.minute,
      adjustment: StockAdjustment.none,
      candles: List.unmodifiable(candles),
      provider: '腾讯证券公开行情接口',
      providerTimestamp: candles.last.timestamp,
      fetchedAt: _clock.nowInstant(),
      dataNote: '当日分时成交数据，不适用复权；$providerRisk',
    );
  }

  Future<List<StockQuote>> _fetchMoverCandidates({required bool up}) async {
    final pages = await Future.wait([
      _fetchSinaPage(1, sort: 'changepercent', ascending: !up),
      _fetchSinaPage(2, sort: 'changepercent', ascending: !up),
    ]);
    final rows = pages
        .expand((page) => page)
        .map(_quoteFromSina)
        .where((item) => item.isValid)
        .toList();
    rows.sort(
      up
          ? (a, b) => b.changePercent.compareTo(a.changePercent)
          : (a, b) => a.changePercent.compareTo(b.changePercent),
    );
    return rows;
  }

  Future<StockMarketBreadth> _fetchMarketDistribution() async {
    final uri = Uri.https('push2ex.eastmoney.com', '/getTopicZDFenBu', {
      'quoteTopic': '0',
      'dpt': 'wzchanges',
      'ut': '7eea3edcaed734bea9cbfc24409ed989',
    });
    final envelope = await _getJson(uri);
    final data = Map<String, dynamic>.from(
      envelope['data'] as Map? ?? const {},
    );
    final qdate = '${data['qdate'] ?? ''}';
    if (RegExp(r'^\d{8}$').hasMatch(qdate)) {
      _distributionDate = DateTime(
        int.parse(qdate.substring(0, 4)),
        int.parse(qdate.substring(4, 6)),
        int.parse(qdate.substring(6, 8)),
      );
    }
    var rising = 0;
    var falling = 0;
    var flat = 0;
    for (final raw in data['fenbu'] as List? ?? const []) {
      final row = Map<String, dynamic>.from(raw as Map? ?? const {});
      for (final entry in row.entries) {
        final bucket = int.tryParse(entry.key) ?? 0;
        final count = (entry.value as num?)?.toInt() ?? 0;
        if (bucket > 0) {
          rising += count;
        } else if (bucket < 0) {
          falling += count;
        } else {
          flat += count;
        }
      }
    }
    if (rising + falling + flat < 100) {
      throw const StockGatewayException('市场涨跌分布不完整');
    }
    return StockMarketBreadth(
      rising: rising,
      falling: falling,
      flat: flat,
      limitUp: 0,
      limitDown: 0,
      totalAmount: 0,
    );
  }

  Future<List<StockQuote>> _searchQuotes(String query) async {
    final uri = Uri.https('searchapi.eastmoney.com', '/api/suggest/get', {
      'input': query,
      'type': '14',
      'token': 'D43BF722C8E33BE4945601EA47572E2C',
      'count': '20',
    });
    final envelope = await _getJson(uri);
    final table = Map<String, dynamic>.from(
      envelope['QuotationCodeTable'] as Map? ?? const {},
    );
    final suggestions = (table['Data'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .where((row) => '${row['Classify'] ?? ''}' == 'AStock')
        .toList(growable: false);
    final secids = suggestions
        .map((row) => '${row['QuoteID'] ?? ''}')
        .where((value) => RegExp(r'^[01]\.\d{6}$').hasMatch(value))
        .toList(growable: false);
    if (secids.isEmpty) return const [];
    final quoteUri = Uri.https('push2.eastmoney.com', '/api/qt/ulist.np/get', {
      'fltt': '2',
      'secids': secids.join(','),
      'fields':
          'f2,f3,f4,f5,f6,f8,f9,f12,f14,f15,f16,f17,f18,f20,f21,f100,f124',
    });
    final quoteEnvelope = await _getJson(quoteUri);
    final data = Map<String, dynamic>.from(
      quoteEnvelope['data'] as Map? ?? const {},
    );
    return (data['diff'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) => _quoteFromEastmoney(Map<String, dynamic>.from(raw)))
        .where((item) => item.isValid)
        .toList(growable: false);
  }

  Future<List<StockQuote>> _fetchScanUniverse(StockScreenPreset preset) async {
    final requests = switch (preset) {
      StockScreenPreset.oversold => const [('changepercent', true, 5)],
      StockScreenPreset.qualityValue => const [('mktcap', false, 5)],
      StockScreenPreset.highRisk => const [
        ('changepercent', false, 2),
        ('changepercent', true, 2),
        ('turnoverratio', false, 2),
      ],
      _ => const [('changepercent', false, 5)],
    };
    final rows = <Map<String, dynamic>>[];
    for (final request in requests) {
      final pages = await Future.wait([
        for (var page = 1; page <= request.$3; page++)
          _fetchSinaPageSafe(page, sort: request.$1, ascending: request.$2),
      ]);
      rows.addAll(pages.expand((page) => page));
    }
    final byCode = <String, StockQuote>{};
    for (final row in rows) {
      final quote = _quoteFromSina(row);
      if (quote.isValid) byCode[quote.code] = quote;
    }
    if (byCode.length < 30) {
      for (final quote in await _fetchEastmoneyStockUniverse(preset)) {
        byCode[quote.code] = quote;
      }
    }
    if (byCode.isEmpty) {
      throw const StockGatewayException('新浪和东方财富均未返回可筛选股票');
    }
    return byCode.values.toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _fetchSinaPageSafe(
    int page, {
    required String sort,
    required bool ascending,
  }) async {
    try {
      return await _fetchSinaPage(page, sort: sort, ascending: ascending);
    } catch (_) {
      return const [];
    }
  }

  Future<List<StockQuote>> _fetchEastmoneyStockUniverse(
    StockScreenPreset preset,
  ) async {
    final ascending = preset == StockScreenPreset.oversold;
    final field = preset == StockScreenPreset.qualityValue ? 'f20' : 'f3';
    final uri = Uri.https('push2.eastmoney.com', '/api/qt/clist/get', {
      'pn': '1',
      'pz': '500',
      'po': ascending ? '0' : '1',
      'np': '1',
      'fltt': '2',
      'invt': '2',
      'fid': field,
      'fs': 'm:0+t:6,m:0+t:80,m:0+t:81+s:2048,m:1+t:2,m:1+t:23',
      'fields':
          'f2,f3,f4,f5,f6,f8,f9,f12,f14,f15,f16,f17,f18,f20,f21,f100,f124',
    });
    try {
      final envelope = await _getJson(uri);
      final data = Map<String, dynamic>.from(
        envelope['data'] as Map? ?? const {},
      );
      return (data['diff'] as List? ?? const [])
          .whereType<Map>()
          .map((raw) => _quoteFromEastmoney(Map<String, dynamic>.from(raw)))
          .where((item) => item.isValid)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchSinaPage(
    int page, {
    required String sort,
    required bool ascending,
  }) async {
    final uri = Uri.https(
      'vip.stock.finance.sina.com.cn',
      '/quotes_service/api/json_v2.php/Market_Center.getHQNodeData',
      {
        'page': '$page',
        'num': '100',
        'sort': sort,
        'asc': ascending ? '1' : '0',
        'node': 'hs_a',
        'symbol': '',
        '_s_r_a': 'page',
      },
    );
    final response = await _client
        .get(
          uri,
          headers: const {
            'User-Agent': 'Mozilla/5.0 SyncNote-Stock-Lab/1.0',
            'Accept': 'application/json,text/plain,*/*',
            'Referer': 'https://finance.sina.com.cn/',
          },
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StockGatewayException('新浪行情接口返回 ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const StockGatewayException('新浪行情接口响应格式无效');
    }
    final rows = decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
    return rows;
  }

  static bool _isLimitMove(StockQuote quote, {required bool up}) {
    final name = quote.name.trim().toUpperCase();
    if (name.startsWith('N') || name.startsWith('C')) return false;
    final isSpecialTreatment = name.contains('ST');
    final isTwentyPercentBoard =
        quote.code.startsWith('300') ||
        quote.code.startsWith('301') ||
        quote.code.startsWith('688') ||
        quote.code.startsWith('689');
    final isBeijing =
        quote.code.startsWith('4') ||
        quote.code.startsWith('8') ||
        quote.code.startsWith('92');
    final isShanghaiMain = quote.code.startsWith('6') && !isTwentyPercentBoard;
    final shanghaiDate = quote.providerTimestamp.toUtc().add(
      const Duration(hours: 8),
    );
    final beforeShenzhenRiskWarningChange = shanghaiDate.isBefore(
      DateTime.utc(2026, 7, 6),
    );
    final threshold = isBeijing
        ? 29.5
        : isTwentyPercentBoard
        ? 19.5
        : isSpecialTreatment &&
              (isShanghaiMain || beforeShenzhenRiskWarningChange)
        ? 4.8
        : 9.5;
    return up
        ? quote.changePercent >= threshold
        : quote.changePercent <= -threshold;
  }

  static bool isLimitMoveForTesting(StockQuote quote, {required bool up}) =>
      _isLimitMove(quote, up: up);

  Future<List<StockQuote>> _fetchIndices() async {
    final uri = Uri.https('push2.eastmoney.com', '/api/qt/ulist.np/get', {
      'fltt': '2',
      'secids': '1.000001,0.399001,0.399006,1.000300',
      'fields': 'f2,f3,f4,f6,f12,f14,f18,f124',
    });
    final envelope = await _getJson(uri);
    final data = Map<String, dynamic>.from(
      envelope['data'] as Map? ?? const {},
    );
    return (data['diff'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final item = Map<String, dynamic>.from(raw);
          final code = '${item['f12'] ?? ''}';
          final timestamp = _unixDate(item['f124']);
          return StockQuote(
            symbol: code,
            code: code,
            name: '${item['f14'] ?? code}',
            exchange: code.startsWith('0') ? '上海' : '深圳',
            price: _number(item['f2']),
            previousClose: _number(item['f18']),
            open: 0,
            high: 0,
            low: 0,
            change: _number(item['f4']),
            changePercent: _number(item['f3']),
            volume: 0,
            amount: _number(item['f6']),
            turnoverRate: 0,
            pe: 0,
            marketCap: 0,
            industry: '指数',
            provider: '东方财富公开行情接口',
            providerTimestamp: timestamp,
            fetchedAt: _clock.nowInstant(),
            tradeStatus: _marketStatus(_clock.nowInstant()),
          );
        })
        .toList(growable: false);
  }

  Future<List<StockSectorStrength>> _fetchSectors() async {
    final results = await Future.wait([
      _fetchEastmoneySectors(),
      _fetchSinaSectors(),
    ]);
    return results.firstWhere(
      (rows) => rows.isNotEmpty,
      orElse: () => const <StockSectorStrength>[],
    );
  }

  Future<List<StockSectorStrength>> _fetchEastmoneySectors() async {
    final uri = Uri.https('push2.eastmoney.com', '/api/qt/clist/get', {
      'pn': '1',
      'pz': '10',
      'po': '1',
      'np': '1',
      'fltt': '2',
      'invt': '2',
      'fid': 'f3',
      'fs': 'm:90+t:2',
      'fields': 'f3,f12,f14,f128',
    });
    try {
      final response = await _client
          .get(
            uri,
            headers: const {
              'User-Agent': 'Mozilla/5.0 SyncNote-Stock-Lab/1.0',
              'Accept': 'application/json,text/plain,*/*',
              'Referer': 'https://quote.eastmoney.com/',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return const [];
      final envelope = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map,
      );
      final data = Map<String, dynamic>.from(
        envelope['data'] as Map? ?? const {},
      );
      final rows = (data['diff'] as List? ?? const [])
          .whereType<Map>()
          .map((raw) {
            final item = Map<String, dynamic>.from(raw);
            return StockSectorStrength(
              name: '${item['f14'] ?? ''}',
              changePercent: _number(item['f3']),
              leader: '${item['f128'] ?? ''}',
            );
          })
          .where((item) => item.name.isNotEmpty)
          .toList(growable: false);
      if (rows.isNotEmpty) return rows;
    } catch (_) {
      return const [];
    }
    return const [];
  }

  Future<List<StockSectorStrength>> _fetchSinaSectors() async {
    try {
      final response = await _client
          .get(
            Uri.parse(
              'https://vip.stock.finance.sina.com.cn/q/view/newSinaHy.php',
            ),
            headers: const {
              'User-Agent': 'Mozilla/5.0 SyncNote-Stock-Lab/1.0',
              'Accept': 'text/plain,*/*',
              'Referer': 'https://finance.sina.com.cn/',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return const [];
      return _parseSinaSectors(latin1.decode(response.bodyBytes));
    } catch (_) {
      return const [];
    }
  }

  static List<StockSectorStrength> _parseSinaSectors(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return const [];
    try {
      final decoded = Map<String, dynamic>.from(
        jsonDecode(raw.substring(start, end + 1)) as Map,
      );
      final rows = <StockSectorStrength>[];
      for (final value in decoded.values) {
        final parts = '$value'.split(',');
        if (parts.length < 6) continue;
        final code = parts[0].trim();
        final name = _sinaIndustryNames[code] ?? code;
        final change = _number(parts[5]);
        if (name.isEmpty || !change.isFinite) continue;
        rows.add(
          StockSectorStrength(
            name: name,
            changePercent: change,
            leader: parts.length > 8 ? parts[8].trim() : '',
          ),
        );
      }
      rows.sort((a, b) => b.changePercent.compareTo(a.changePercent));
      return rows;
    } catch (_) {
      return const [];
    }
  }

  static List<StockSectorStrength> parseSinaSectorsForTesting(String raw) =>
      _parseSinaSectors(raw);

  StockQuote _quoteFromSina(Map<String, dynamic> item) {
    final symbol = '${item['symbol'] ?? ''}'.toLowerCase();
    final code = '${item['code'] ?? ''}';
    final tradeDate =
        _distributionDate ?? _clock.toShanghaiWallTime(_clock.nowInstant());
    final timeParts = '${item['ticktime'] ?? ''}'
        .split(':')
        .map((value) => int.tryParse(value) ?? 0)
        .toList(growable: false);
    final providerTimestamp = _clock.fromShanghaiWallTime(
      DateTime.utc(
        tradeDate.year,
        tradeDate.month,
        tradeDate.day,
        timeParts.isNotEmpty ? timeParts[0] : 0,
        timeParts.length > 1 ? timeParts[1] : 0,
        timeParts.length > 2 ? timeParts[2] : 0,
      ),
    );
    return StockQuote(
      symbol: symbol.isEmpty ? '${_marketPrefix(code)}$code' : symbol,
      code: code,
      name: '${item['name'] ?? code}',
      exchange: symbol.startsWith('sh')
          ? '上海'
          : symbol.startsWith('bj')
          ? '北京'
          : '深圳',
      price: _number(item['trade']),
      previousClose: _number(item['settlement']),
      open: _number(item['open']),
      high: _number(item['high']),
      low: _number(item['low']),
      change: _number(item['pricechange']),
      changePercent: _number(item['changepercent']),
      volume: _number(item['volume']),
      amount: _number(item['amount']),
      turnoverRate: _number(item['turnoverratio']),
      pe: _number(item['per']),
      marketCap: _number(item['mktcap']) * 10000,
      industry: '',
      provider: '新浪财经公开行情接口',
      providerTimestamp: providerTimestamp,
      fetchedAt: _clock.nowInstant(),
      tradeStatus: _marketStatus(_clock.nowInstant()),
    );
  }

  StockQuote _quoteFromEastmoney(Map<String, dynamic> item) {
    final code = '${item['f12'] ?? ''}';
    final previous = _number(item['f18']);
    final price = _number(item['f2']);
    final exchange = _exchangeForCode(code);
    return StockQuote(
      symbol: '${_marketPrefix(code)}$code',
      code: code,
      name: '${item['f14'] ?? code}',
      exchange: exchange,
      price: price,
      previousClose: previous,
      open: _number(item['f17']),
      high: _number(item['f15']),
      low: _number(item['f16']),
      change: _number(item['f4']),
      changePercent: _number(item['f3']),
      volume: _number(item['f5']),
      amount: _number(item['f6']),
      turnoverRate: _number(item['f8']),
      pe: _number(item['f9']),
      marketCap: _number(item['f20']),
      industry: '${item['f100'] ?? ''}',
      provider: '东方财富公开行情接口',
      providerTimestamp: _unixDate(item['f124']),
      fetchedAt: _clock.nowInstant(),
      tradeStatus: _marketStatus(_clock.nowInstant()),
    );
  }

  StockQuote _quoteFromTencent(
    String marketCode,
    Map<String, dynamic> qt,
    List<StockCandle> candles,
  ) {
    final raw = qt[marketCode] as List? ?? const [];
    String value(int index) => index < raw.length ? '${raw[index] ?? ''}' : '';
    final code = value(2).isEmpty ? marketCode.substring(2) : value(2);
    final providerTimestamp = _parseTencentTimestamp(value(30));
    final price = _number(value(3), fallback: candles.last.close);
    final previous = _number(value(4), fallback: candles.first.close);
    return StockQuote(
      symbol: marketCode,
      code: code,
      name: value(1).isEmpty ? code : value(1),
      exchange: marketCode.startsWith('sh') ? '上海' : '深圳',
      price: price,
      previousClose: previous,
      open: _number(value(5), fallback: candles.first.open),
      high: _number(value(33), fallback: candles.last.high),
      low: _number(value(34), fallback: candles.last.low),
      change: _number(value(31), fallback: price - previous),
      changePercent: _number(value(32)),
      volume: _number(value(36)),
      amount: _number(value(37)) * 10000,
      turnoverRate: _number(value(38)),
      pe: _number(value(39)),
      marketCap: _number(value(45)) * 100000000,
      industry: '',
      provider: '腾讯证券公开行情接口',
      providerTimestamp: providerTimestamp,
      fetchedAt: _clock.nowInstant(),
      tradeStatus: _marketStatus(_clock.nowInstant()),
    );
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await _client
            .get(
              uri,
              headers: const {
                'User-Agent': 'Mozilla/5.0 SyncNote-Stock-Lab/1.0',
                'Accept': 'application/json,text/plain,*/*',
                'Referer': 'https://quote.eastmoney.com/',
              },
            )
            .timeout(const Duration(seconds: 25));
        if (response.statusCode != 200) {
          throw StockGatewayException('行情接口返回 ${response.statusCode}');
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map) {
          throw const StockGatewayException('行情接口响应格式无效');
        }
        return Map<String, dynamic>.from(decoded);
      } catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 500 << attempt));
        }
      }
    }
    throw StockGatewayException('行情暂时不可用：$lastError');
  }

  StockCandle? _parseTencentCandle(List raw) {
    if (raw.length < 6) return null;
    final date = DateTime.tryParse('${raw[0]}');
    if (date == null) return null;
    final open = _number(raw[1]);
    final close = _number(raw[2]);
    final high = _number(raw[3]);
    final low = _number(raw[4]);
    if (open <= 0 || close <= 0 || high <= 0 || low <= 0) return null;
    return StockCandle(
      timestamp: _clock.fromShanghaiWallTime(
        // Daily/weekly/monthly provider rows carry a trading date, not an
        // executable close-time event. Anchor them at Shanghai midnight so an
        // in-progress trading day is never misclassified as future data.
        DateTime.utc(date.year, date.month, date.day),
      ),
      open: open,
      close: close,
      high: high,
      low: low,
      volume: _number(raw[5]),
      amount: raw.length > 6 ? _number(raw[6]) : 0,
    );
  }

  static String _normalizeCode(String raw) {
    final match = RegExp(r'(\d{6})').firstMatch(raw.trim());
    if (match == null) throw const StockGatewayException('请输入 6 位 A 股代码');
    return match.group(1)!;
  }

  static String _tencentCode(String code) => '${_marketPrefix(code)}$code';

  static String _exchangeForCode(String code) => code.startsWith('6')
      ? '上海'
      : code.startsWith('4') || code.startsWith('8') || code.startsWith('9')
      ? '北京'
      : '深圳';

  static String _marketPrefix(String code) => switch (_exchangeForCode(code)) {
    '上海' => 'sh',
    '北京' => 'bj',
    _ => 'sz',
  };

  static String exchangeForCodeForTesting(String code) =>
      _exchangeForCode(code);

  static DateTime _unixDate(Object? value) {
    final seconds = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
    if (seconds <= 0) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  DateTime _parseTencentTimestamp(String raw) {
    if (raw.length < 14) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    return _clock.fromShanghaiWallTime(
      DateTime.utc(
        int.tryParse(raw.substring(0, 4)) ?? 1970,
        int.tryParse(raw.substring(4, 6)) ?? 1,
        int.tryParse(raw.substring(6, 8)) ?? 1,
        int.tryParse(raw.substring(8, 10)) ?? 0,
        int.tryParse(raw.substring(10, 12)) ?? 0,
        int.tryParse(raw.substring(12, 14)) ?? 0,
      ),
    );
  }

  static double _number(Object? value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    final parsed = double.tryParse('$value');
    return parsed?.isFinite == true ? parsed! : fallback;
  }

  String _marketStatus(DateTime instant) =>
      _calendar.marketStatusAt(instant, clock: _clock);

  static String _periodLabel(StockPeriod period) => switch (period) {
    StockPeriod.minute => '分时',
    StockPeriod.day => '日 K',
    StockPeriod.week => '周 K',
    StockPeriod.month => '月 K',
  };

  static String _adjustmentLabel(StockAdjustment adjustment) =>
      switch (adjustment) {
        StockAdjustment.none => '不复权',
        StockAdjustment.forward => '前复权',
        StockAdjustment.backward => '后复权',
      };

  @override
  void dispose() => _client.close();
}
