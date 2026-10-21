import 'dart:math' as math;

import 'package:syncnote/features/exploration/models/stock_models.dart';

class StockIndicatorEngine {
  const StockIndicatorEngine._();

  static StockIndicators calculate(List<StockCandle> candles) {
    final valid = candles.where((item) => item.close > 0).toList();
    final closes = valid.map((item) => item.close).toList(growable: false);
    final volumes = valid.map((item) => item.volume).toList(growable: false);
    final macdSeries = _macd(closes);
    final middle = _sma(closes, 20);
    final deviation = closes.length < 20
        ? null
        : _standardDeviation(closes.sublist(closes.length - 20));
    return StockIndicators(
      sma5: _sma(closes, 5),
      sma10: _sma(closes, 10),
      sma20: middle,
      sma60: _sma(closes, 60),
      rsi14: _rsi(closes, 14),
      macd: macdSeries.$1,
      macdSignal: macdSeries.$2,
      macdHistogram: macdSeries.$3,
      bollingerUpper: middle == null || deviation == null
          ? null
          : middle + deviation * 2,
      bollingerMiddle: middle,
      bollingerLower: middle == null || deviation == null
          ? null
          : middle - deviation * 2,
      return5: _returnFor(closes, 5),
      return20: _returnFor(closes, 20),
      volatility20: _volatility(closes, 20),
      volumeRatio: _volumeRatio(volumes),
    );
  }

  static List<StockQuote> screenUniverse(
    List<StockQuote> universe,
    StockScreenPreset preset, {
    int limit = 30,
  }) {
    final rows = universe
        .where((item) => item.isValid)
        .where((item) => !item.name.toUpperCase().contains('ST'))
        .where((item) => item.amount > 0)
        .toList();
    double score(StockQuote item) {
      final liquidity = math.log(math.max(item.amount, 1)) / math.ln10;
      return switch (preset) {
        StockScreenPreset.trend =>
          item.changePercent * 2 + item.turnoverRate * 0.25 + liquidity,
        StockScreenPreset.breakout =>
          item.changePercent * 2.4 + item.turnoverRate * 0.6 + liquidity,
        StockScreenPreset.oversold =>
          -item.changePercent * 2 + liquidity - item.turnoverRate * 0.05,
        StockScreenPreset.qualityValue =>
          (item.pe > 0 && item.pe <= 35 ? 18 - item.pe * 0.25 : -10) +
              math.log(math.max(item.marketCap, 1)) / math.ln10 +
              liquidity,
        StockScreenPreset.improving =>
          item.changePercent * 1.4 +
              (item.pe > 0 && item.pe < 60 ? 6 : 0) +
              liquidity,
        StockScreenPreset.sectorLeader =>
          item.changePercent +
              math.log(math.max(item.marketCap, 1)) / math.ln10 * 1.8 +
              liquidity,
        StockScreenPreset.highRisk =>
          item.changePercent.abs() * 2.2 + item.turnoverRate + liquidity,
      };
    }

    bool eligible(StockQuote item) => switch (preset) {
      StockScreenPreset.trend =>
        item.changePercent > 0 &&
            item.changePercent < 9.7 &&
            item.turnoverRate < 20,
      StockScreenPreset.breakout =>
        item.changePercent >= 2 && item.turnoverRate >= 1,
      StockScreenPreset.oversold =>
        item.changePercent <= -2 && item.changePercent > -10.5,
      StockScreenPreset.qualityValue =>
        item.pe > 0 && item.pe <= 35 && item.marketCap >= 3e9,
      StockScreenPreset.improving => item.changePercent > 0 && item.pe > 0,
      StockScreenPreset.sectorLeader =>
        item.marketCap >= 1e10 && item.changePercent > 0,
      StockScreenPreset.highRisk =>
        item.changePercent.abs() >= 7 || item.turnoverRate >= 20,
    };

    rows.removeWhere((item) => !eligible(item));
    rows.sort((a, b) {
      final compared = score(b).compareTo(score(a));
      return compared != 0 ? compared : a.code.compareTo(b.code);
    });
    return List<StockQuote>.unmodifiable(rows.take(limit));
  }

  static double? _sma(List<double> values, int period) {
    if (values.length < period) return null;
    final slice = values.sublist(values.length - period);
    return slice.reduce((a, b) => a + b) / period;
  }

  static double? _returnFor(List<double> values, int sessions) {
    if (values.length <= sessions ||
        values[values.length - 1 - sessions] == 0) {
      return null;
    }
    final previous = values[values.length - 1 - sessions];
    return (values.last / previous - 1) * 100;
  }

  static double? _rsi(List<double> values, int period) {
    if (values.length <= period) return null;
    var gains = 0.0;
    var losses = 0.0;
    for (var index = values.length - period; index < values.length; index++) {
      final delta = values[index] - values[index - 1];
      if (delta >= 0) {
        gains += delta;
      } else {
        losses -= delta;
      }
    }
    if (losses == 0) return 100;
    final relative = (gains / period) / (losses / period);
    return 100 - 100 / (1 + relative);
  }

  static (double?, double?, double?) _macd(List<double> values) {
    if (values.length < 35) return (null, null, null);
    final ema12 = _emaSeries(values, 12);
    final ema26 = _emaSeries(values, 26);
    final dif = List<double>.generate(
      values.length,
      (index) => ema12[index] - ema26[index],
    );
    final signal = _emaSeries(dif, 9);
    return (dif.last, signal.last, (dif.last - signal.last) * 2);
  }

  static List<double> _emaSeries(List<double> values, int period) {
    if (values.isEmpty) return const [];
    final multiplier = 2 / (period + 1);
    final output = <double>[values.first];
    for (var index = 1; index < values.length; index++) {
      output.add((values[index] - output.last) * multiplier + output.last);
    }
    return output;
  }

  static double _standardDeviation(List<double> values) {
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance =
        values
            .map((value) => math.pow(value - mean, 2).toDouble())
            .reduce((a, b) => a + b) /
        values.length;
    return math.sqrt(variance);
  }

  static double? _volatility(List<double> values, int period) {
    if (values.length <= period) return null;
    final returns = <double>[];
    for (var index = values.length - period; index < values.length; index++) {
      final previous = values[index - 1];
      if (previous > 0) returns.add(math.log(values[index] / previous));
    }
    if (returns.length < 2) return null;
    return _standardDeviation(returns) * math.sqrt(252) * 100;
  }

  static double? _volumeRatio(List<double> volumes) {
    if (volumes.length < 6) return null;
    final latest = volumes.last;
    final baseline =
        volumes
            .sublist(math.max(0, volumes.length - 6), volumes.length - 1)
            .reduce((a, b) => a + b) /
        math.min(5, volumes.length - 1);
    return baseline <= 0 ? null : latest / baseline;
  }
}
