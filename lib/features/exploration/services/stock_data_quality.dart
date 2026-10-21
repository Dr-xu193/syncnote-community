import 'package:flutter/foundation.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';

/// A clock for mainland-China markets.
///
/// [now] always represents an instant.  Shanghai wall-clock fields are derived
/// from UTC+08:00 explicitly, so market decisions never depend on the computer's
/// local time zone.
class ChinaMarketClock {
  ChinaMarketClock({this.now});

  final DateTime Function()? now;

  static const shanghaiOffset = Duration(hours: 8);

  DateTime nowInstant() => (now?.call() ?? DateTime.now()).toUtc();

  /// Returns a UTC-backed value whose *fields* are Shanghai wall-clock fields.
  /// It is intended for calendar/hour inspection, not instant comparison.
  DateTime toShanghaiWallTime(DateTime instant) {
    final shifted = instant.toUtc().add(shanghaiOffset);
    return DateTime.utc(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }

  /// Converts Shanghai wall-clock fields to the corresponding UTC instant.
  DateTime fromShanghaiWallTime(DateTime wallTime) => DateTime.utc(
    wallTime.year,
    wallTime.month,
    wallTime.day,
    wallTime.hour,
    wallTime.minute,
    wallTime.second,
    wallTime.millisecond,
    wallTime.microsecond,
  ).subtract(shanghaiOffset);
}

/// Injectable exchange calendar. Dates use `yyyy-MM-dd` in Asia/Shanghai.
@immutable
class ChinaTradingCalendar {
  ChinaTradingCalendar({
    Iterable<String> holidays = const <String>[],
    Iterable<String> extraTradingDays = const <String>[],
    this.version = 'custom',
    this.source = '',
  }) : holidays = Set<String>.unmodifiable(holidays),
       extraTradingDays = Set<String>.unmodifiable(extraTradingDays);

  /// Official mainland exchange closures published in SSE announcement
  /// [2025] No.45. Weekends are handled separately and are not duplicated.
  factory ChinaTradingCalendar.mainland2026() => ChinaTradingCalendar(
    holidays: const {
      '2026-01-01',
      '2026-01-02',
      '2026-02-16',
      '2026-02-17',
      '2026-02-18',
      '2026-02-19',
      '2026-02-20',
      '2026-02-23',
      '2026-04-06',
      '2026-05-01',
      '2026-05-04',
      '2026-05-05',
      '2026-06-19',
      '2026-09-25',
      '2026-10-01',
      '2026-10-02',
      '2026-10-05',
      '2026-10-06',
      '2026-10-07',
    },
    version: 'SSE-2025-45/2026',
    source:
        'https://www.sse.com.cn/disclosure/announcement/general/c/c_20251222_10802507.shtml',
  );

  final Set<String> holidays;
  final Set<String> extraTradingDays;
  final String version;
  final String source;

  bool isTradingDay(DateTime shanghaiWallDate) {
    final key = dateKey(shanghaiWallDate);
    if (extraTradingDays.contains(key)) return true;
    if (holidays.contains(key)) return false;
    return shanghaiWallDate.weekday != DateTime.saturday &&
        shanghaiWallDate.weekday != DateTime.sunday;
  }

  String marketStatusAt(DateTime instant, {ChinaMarketClock? clock}) {
    final effectiveClock = clock ?? ChinaMarketClock();
    final now = effectiveClock.toShanghaiWallTime(instant);
    if (!isTradingDay(now)) return '休市';
    final minute = now.hour * 60 + now.minute;
    if ((minute >= 570 && minute <= 690) || (minute >= 780 && minute <= 900)) {
      return '交易中';
    }
    return '非交易时段';
  }

  /// The trading date a current quote is expected to represent.
  DateTime expectedLatestTradingDate(
    DateTime instant, {
    ChinaMarketClock? clock,
  }) {
    final effectiveClock = clock ?? ChinaMarketClock();
    var wall = effectiveClock.toShanghaiWallTime(instant);
    final minute = wall.hour * 60 + wall.minute;
    if (isTradingDay(wall) && minute >= 570) {
      return _dateOnly(wall);
    }
    wall = _dateOnly(wall).subtract(const Duration(days: 1));
    // A bounded loop prevents malformed custom calendars from hanging checks.
    for (var i = 0; i < 370; i++) {
      if (isTradingDay(wall)) return wall;
      wall = wall.subtract(const Duration(days: 1));
    }
    return wall;
  }

  static String dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static DateTime _dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);
}

enum StockDataQualityLevel { available, stale, conflicted, missing }

enum StockDataTrustTier { authorizedResearch, publicValidation, unknown }

enum StockDataIssueKind { stale, conflict, missing }

enum StockDataIssueCode {
  missingIdentity,
  missingProvider,
  missingQuote,
  missingOhlc,
  missingCandles,
  nonFiniteValue,
  negativeActivity,
  invalidQuoteOhlc,
  invalidCandleOhlc,
  quoteChangeMismatch,
  quotePercentMismatch,
  quoteCandleMismatch,
  duplicateCandleTimestamp,
  unorderedCandleTimestamp,
  futureTimestamp,
  staleProviderTimestamp,
  staleFetch,
  crossSourcePriceConflict,
  crossSourcePreviousCloseConflict,
}

@immutable
class StockDataIssue {
  const StockDataIssue({
    required this.code,
    required this.kind,
    required this.message,
  });

  final StockDataIssueCode code;
  final StockDataIssueKind kind;
  final String message;
}

/// Deterministic result consumed by the UI/service layer before AI research.
@immutable
class StockDataQualityReport {
  const StockDataQualityReport({
    required this.level,
    required this.trustTier,
    required this.checkedAt,
    required this.issues,
    required this.providers,
  });

  final StockDataQualityLevel level;
  final StockDataTrustTier trustTier;
  final DateTime checkedAt;
  final List<StockDataIssue> issues;
  final List<String> providers;

  bool get canResearch => level == StockDataQualityLevel.available;
  bool get canCreatePlan =>
      canResearch && trustTier == StockDataTrustTier.authorizedResearch;
  bool get shouldBlockResearch => !canResearch;
  String get blockingReason => issues.isEmpty ? '' : issues.first.message;
}

@immutable
class StockDataQualityPolicy {
  const StockDataQualityPolicy({
    this.maxIntradayProviderAge = const Duration(minutes: 15),
    this.maxFetchAge = const Duration(minutes: 10),
    this.futureTolerance = const Duration(minutes: 2),
    this.maxCrossSourceTimestampSkew = const Duration(minutes: 20),
    this.crossSourcePriceDeviation = 0.005,
    this.quoteToCandleDeviation = 0.01,
    this.changeAbsoluteTolerance = 0.011,
    this.changePercentTolerance = 0.06,
  });

  final Duration maxIntradayProviderAge;
  final Duration maxFetchAge;
  final Duration futureTolerance;
  final Duration maxCrossSourceTimestampSkew;
  final double crossSourcePriceDeviation;
  final double quoteToCandleDeviation;
  final double changeAbsoluteTolerance;
  final double changePercentTolerance;
}

/// Validates a quote/series before it is allowed into stock research or AI.
class StockDataQuality {
  StockDataQuality({
    ChinaMarketClock? clock,
    ChinaTradingCalendar? calendar,
    this.policy = const StockDataQualityPolicy(),
  }) : clock = clock ?? ChinaMarketClock(),
       calendar = calendar ?? ChinaTradingCalendar.mainland2026();

  final ChinaMarketClock clock;
  final ChinaTradingCalendar calendar;
  final StockDataQualityPolicy policy;

  StockDataQualityReport evaluateQuote(
    StockQuote quote, {
    Iterable<StockQuote> crossSourceQuotes = const <StockQuote>[],
  }) {
    final issues = <StockDataIssue>[];
    _validateQuote(quote, issues);
    _validateFreshness(quote, issues);
    _validateCrossSource(quote, crossSourceQuotes, issues);
    return _report(issues, <String>{
      if (quote.provider.trim().isNotEmpty) quote.provider.trim(),
      for (final item in crossSourceQuotes)
        if (item.provider.trim().isNotEmpty) item.provider.trim(),
    }, primaryProvider: quote.provider);
  }

  StockDataQualityReport evaluateSeries(
    StockSeries series, {
    Iterable<StockQuote> crossSourceQuotes = const <StockQuote>[],
  }) {
    final issues = <StockDataIssue>[];
    _validateQuote(series.quote, issues);
    _validateFreshness(series.quote, issues);
    _validateCandles(series, issues);
    _validateCrossSource(series.quote, crossSourceQuotes, issues);
    return _report(issues, <String>{
      if (series.provider.trim().isNotEmpty) series.provider.trim(),
      if (series.quote.provider.trim().isNotEmpty) series.quote.provider.trim(),
      for (final item in crossSourceQuotes)
        if (item.provider.trim().isNotEmpty) item.provider.trim(),
    }, primaryProvider: series.provider);
  }

  StockDataQualityReport evaluateCrossSource(Iterable<StockQuote> quotes) {
    final rows = quotes.toList(growable: false);
    if (rows.isEmpty) {
      return _report(<StockDataIssue>[
        const StockDataIssue(
          code: StockDataIssueCode.missingQuote,
          kind: StockDataIssueKind.missing,
          message: '没有可用于交叉校验的行情快照',
        ),
      ], const <String>{});
    }
    final primary = rows.first;
    return evaluateQuote(primary, crossSourceQuotes: rows.skip(1));
  }

  void _validateQuote(StockQuote quote, List<StockDataIssue> issues) {
    if (quote.code.trim().isEmpty || quote.name.trim().isEmpty) {
      _add(
        issues,
        StockDataIssueCode.missingIdentity,
        StockDataIssueKind.missing,
        '股票代码或名称缺失',
      );
    }
    if (quote.provider.trim().isEmpty) {
      _add(
        issues,
        StockDataIssueCode.missingProvider,
        StockDataIssueKind.missing,
        '行情来源缺失，不能追溯数据',
      );
    }
    final priceFields = <double>[
      quote.price,
      quote.previousClose,
      quote.open,
      quote.high,
      quote.low,
      quote.change,
      quote.changePercent,
    ];
    if (priceFields.any((value) => !value.isFinite)) {
      _add(
        issues,
        StockDataIssueCode.nonFiniteValue,
        StockDataIssueKind.conflict,
        '报价包含非有限数值',
      );
      return;
    }
    if (quote.price <= 0 || quote.previousClose <= 0) {
      _add(
        issues,
        StockDataIssueCode.missingQuote,
        StockDataIssueKind.missing,
        '现价或昨收缺失',
      );
    }
    if (quote.open <= 0 || quote.high <= 0 || quote.low <= 0) {
      _add(
        issues,
        StockDataIssueCode.missingOhlc,
        StockDataIssueKind.missing,
        '开盘价、最高价或最低价缺失',
      );
    } else {
      final top = _max4(quote.open, quote.price, quote.high, quote.low);
      final bottom = _min4(quote.open, quote.price, quote.high, quote.low);
      if (quote.high + 1e-9 < top || quote.low - 1e-9 > bottom) {
        _add(
          issues,
          StockDataIssueCode.invalidQuoteOhlc,
          StockDataIssueKind.conflict,
          '报价 OHLC 高低关系矛盾',
        );
      }
    }
    if (quote.volume < 0 || quote.amount < 0 || quote.turnoverRate < 0) {
      _add(
        issues,
        StockDataIssueCode.negativeActivity,
        StockDataIssueKind.conflict,
        '成交量、成交额或换手率出现负数',
      );
    }
    if (quote.price > 0 && quote.previousClose > 0) {
      final expectedChange = quote.price - quote.previousClose;
      final absoluteTolerance = _max(
        policy.changeAbsoluteTolerance,
        quote.price.abs() * 0.0001,
      );
      if ((quote.change - expectedChange).abs() > absoluteTolerance) {
        _add(
          issues,
          StockDataIssueCode.quoteChangeMismatch,
          StockDataIssueKind.conflict,
          '涨跌额与现价、昨收不一致',
        );
      }
      final expectedPercent = expectedChange / quote.previousClose * 100;
      if ((quote.changePercent - expectedPercent).abs() >
          policy.changePercentTolerance) {
        _add(
          issues,
          StockDataIssueCode.quotePercentMismatch,
          StockDataIssueKind.conflict,
          '涨跌幅与现价、昨收不一致',
        );
      }
    }
  }

  void _validateFreshness(StockQuote quote, List<StockDataIssue> issues) {
    final now = clock.nowInstant();
    if (quote.providerTimestamp.year < 2000) {
      _add(
        issues,
        StockDataIssueCode.staleProviderTimestamp,
        StockDataIssueKind.stale,
        '行情时间戳缺失或无效',
      );
      return;
    }
    if (quote.providerTimestamp.toUtc().isAfter(
          now.add(policy.futureTolerance),
        ) ||
        quote.fetchedAt.toUtc().isAfter(now.add(policy.futureTolerance))) {
      _add(
        issues,
        StockDataIssueCode.futureTimestamp,
        StockDataIssueKind.conflict,
        '行情时间晚于当前时间',
      );
    }
    if (now.difference(quote.fetchedAt.toUtc()) > policy.maxFetchAge) {
      _add(
        issues,
        StockDataIssueCode.staleFetch,
        StockDataIssueKind.stale,
        '本次行情快照已超过允许缓存时间',
      );
    }

    final expectedDate = calendar.expectedLatestTradingDate(now, clock: clock);
    final providerWall = clock.toShanghaiWallTime(quote.providerTimestamp);
    final providerDate = ChinaTradingCalendar.dateKey(providerWall);
    if (providerDate != ChinaTradingCalendar.dateKey(expectedDate)) {
      _add(
        issues,
        StockDataIssueCode.staleProviderTimestamp,
        StockDataIssueKind.stale,
        '行情不是最近应有交易日的数据',
      );
      return;
    }

    final nowWall = clock.toShanghaiWallTime(now);
    if (calendar.marketStatusAt(now, clock: clock) == '交易中' &&
        now.difference(quote.providerTimestamp.toUtc()) >
            policy.maxIntradayProviderAge) {
      _add(
        issues,
        StockDataIssueCode.staleProviderTimestamp,
        StockDataIssueKind.stale,
        '交易时段行情更新已超时',
      );
    }
    // A provider timestamp from later in the same Shanghai day is also invalid,
    // even when its UTC instant happened to evade the generic future tolerance.
    if (providerWall.year == nowWall.year &&
        providerWall.month == nowWall.month &&
        providerWall.day == nowWall.day &&
        providerWall.isAfter(nowWall.add(policy.futureTolerance))) {
      _add(
        issues,
        StockDataIssueCode.futureTimestamp,
        StockDataIssueKind.conflict,
        '行情交易时间晚于上海当前时间',
      );
    }
  }

  void _validateCandles(StockSeries series, List<StockDataIssue> issues) {
    if (series.candles.isEmpty) {
      _add(
        issues,
        StockDataIssueCode.missingCandles,
        StockDataIssueKind.missing,
        'K 线数据为空',
      );
      return;
    }
    final seen = <int>{};
    DateTime? previousTimestamp;
    for (var i = 0; i < series.candles.length; i++) {
      final candle = series.candles[i];
      final values = <double>[
        candle.open,
        candle.high,
        candle.low,
        candle.close,
        candle.volume,
        candle.amount,
      ];
      if (values.any((value) => !value.isFinite)) {
        _add(
          issues,
          StockDataIssueCode.nonFiniteValue,
          StockDataIssueKind.conflict,
          '第 ${i + 1} 根 K 线包含非有限数值',
        );
      }
      if (candle.volume < 0 || candle.amount < 0) {
        _add(
          issues,
          StockDataIssueCode.negativeActivity,
          StockDataIssueKind.conflict,
          '第 ${i + 1} 根 K 线成交数据为负数',
        );
      }
      final top = _max4(candle.open, candle.close, candle.high, candle.low);
      final bottom = _min4(candle.open, candle.close, candle.high, candle.low);
      if (candle.open <= 0 ||
          candle.close <= 0 ||
          candle.high + 1e-9 < top ||
          candle.low <= 0 ||
          candle.low - 1e-9 > bottom) {
        _add(
          issues,
          StockDataIssueCode.invalidCandleOhlc,
          StockDataIssueKind.conflict,
          '第 ${i + 1} 根 K 线 OHLC 关系无效',
        );
      }
      final timestamp = candle.timestamp.toUtc();
      if (!seen.add(timestamp.microsecondsSinceEpoch)) {
        _add(
          issues,
          StockDataIssueCode.duplicateCandleTimestamp,
          StockDataIssueKind.conflict,
          'K 线存在重复时间戳',
        );
      }
      if (previousTimestamp != null && !timestamp.isAfter(previousTimestamp)) {
        _add(
          issues,
          StockDataIssueCode.unorderedCandleTimestamp,
          StockDataIssueKind.conflict,
          'K 线没有按时间严格递增',
        );
      }
      if (timestamp.isAfter(clock.nowInstant().add(policy.futureTolerance))) {
        _add(
          issues,
          StockDataIssueCode.futureTimestamp,
          StockDataIssueKind.conflict,
          'K 线包含未来时间戳',
        );
      }
      previousTimestamp = timestamp;
    }

    final latestClose = series.candles.last.close;
    if (series.quote.price > 0 &&
        latestClose > 0 &&
        _relativeDeviation(series.quote.price, latestClose) >
            policy.quoteToCandleDeviation) {
      _add(
        issues,
        StockDataIssueCode.quoteCandleMismatch,
        StockDataIssueKind.conflict,
        '最新 K 线收盘价与报价偏差过大',
      );
    }
  }

  void _validateCrossSource(
    StockQuote primary,
    Iterable<StockQuote> references,
    List<StockDataIssue> issues,
  ) {
    for (final reference in references) {
      if (reference.code != primary.code ||
          reference.provider == primary.provider ||
          primary.price <= 0 ||
          reference.price <= 0) {
        continue;
      }
      final timestampSkew = primary.providerTimestamp
          .toUtc()
          .difference(reference.providerTimestamp.toUtc())
          .abs();
      if (timestampSkew > policy.maxCrossSourceTimestampSkew) continue;
      if (_relativeDeviation(primary.price, reference.price) >
          policy.crossSourcePriceDeviation) {
        _add(
          issues,
          StockDataIssueCode.crossSourcePriceConflict,
          StockDataIssueKind.conflict,
          '${primary.provider} 与 ${reference.provider} 的现价偏差超过阈值',
        );
      }
      if (primary.previousClose > 0 &&
          reference.previousClose > 0 &&
          _relativeDeviation(primary.previousClose, reference.previousClose) >
              policy.crossSourcePriceDeviation) {
        _add(
          issues,
          StockDataIssueCode.crossSourcePreviousCloseConflict,
          StockDataIssueKind.conflict,
          '${primary.provider} 与 ${reference.provider} 的昨收偏差超过阈值',
        );
      }
    }
  }

  StockDataQualityReport _report(
    List<StockDataIssue> issues,
    Set<String> providers, {
    String primaryProvider = '',
  }) {
    final level = issues.any((item) => item.kind == StockDataIssueKind.missing)
        ? StockDataQualityLevel.missing
        : issues.any((item) => item.kind == StockDataIssueKind.conflict)
        ? StockDataQualityLevel.conflicted
        : issues.any((item) => item.kind == StockDataIssueKind.stale)
        ? StockDataQualityLevel.stale
        : StockDataQualityLevel.available;
    return StockDataQualityReport(
      level: level,
      trustTier: _trustTier(primaryProvider),
      checkedAt: clock.nowInstant(),
      issues: List<StockDataIssue>.unmodifiable(issues),
      providers: List<String>.unmodifiable(providers.toList()..sort()),
    );
  }

  static StockDataTrustTier _trustTier(String primaryProvider) {
    if (primaryProvider.toLowerCase().contains('tushare') ||
        primaryProvider.contains('授权') ||
        primaryProvider.toLowerCase().contains('level-1')) {
      return StockDataTrustTier.authorizedResearch;
    }
    if (primaryProvider.contains('公开行情接口') ||
        primaryProvider.contains('个人验证')) {
      return StockDataTrustTier.publicValidation;
    }
    return StockDataTrustTier.unknown;
  }

  static void _add(
    List<StockDataIssue> issues,
    StockDataIssueCode code,
    StockDataIssueKind kind,
    String message,
  ) {
    if (issues.any((item) => item.code == code)) return;
    issues.add(StockDataIssue(code: code, kind: kind, message: message));
  }

  static double _relativeDeviation(double a, double b) {
    final denominator = (a.abs() + b.abs()) / 2;
    return denominator == 0 ? 0 : (a - b).abs() / denominator;
  }

  static double _max(double a, double b) => a > b ? a : b;

  static double _max4(double a, double b, double c, double d) =>
      _max(_max(a, b), _max(c, d));

  static double _min(double a, double b) => a < b ? a : b;

  static double _min4(double a, double b, double c, double d) =>
      _min(_min(a, b), _min(c, d));
}
