import 'package:syncnote/features/exploration/models/stock_models.dart';

class StockEvidenceValidation {
  const StockEvidenceValidation({required this.passed, required this.issues});

  final bool passed;
  final List<String> issues;
}

class StockEvidenceValidator {
  const StockEvidenceValidator();

  StockEvidenceValidation validate({
    required StockQuote quote,
    required StockIndicators indicators,
    required Map<String, dynamic> analysis,
  }) {
    final raw = analysis['data_citations'];
    if (raw is! List || raw.isEmpty) {
      return const StockEvidenceValidation(
        passed: false,
        issues: ['AI 没有返回字段级数值证据引用'],
      );
    }
    final values = <String, double>{
      'quote.price': quote.price,
      'quote.previousClose': quote.previousClose,
      'quote.changePercent': quote.changePercent,
      'quote.turnoverRate': quote.turnoverRate,
      'quote.amount': quote.amount,
      'quote.pe': quote.pe,
      'quote.marketCap': quote.marketCap,
      if (indicators.sma5 != null) 'indicators.sma5': indicators.sma5!,
      if (indicators.sma10 != null) 'indicators.sma10': indicators.sma10!,
      if (indicators.sma20 != null) 'indicators.sma20': indicators.sma20!,
      if (indicators.sma60 != null) 'indicators.sma60': indicators.sma60!,
      if (indicators.rsi14 != null) 'indicators.rsi14': indicators.rsi14!,
      if (indicators.macd != null) 'indicators.macd': indicators.macd!,
      if (indicators.macdSignal != null)
        'indicators.macdSignal': indicators.macdSignal!,
      if (indicators.macdHistogram != null)
        'indicators.macdHistogram': indicators.macdHistogram!,
      if (indicators.return5 != null) 'indicators.return5': indicators.return5!,
      if (indicators.return20 != null)
        'indicators.return20': indicators.return20!,
      if (indicators.volatility20 != null)
        'indicators.volatility20': indicators.volatility20!,
      if (indicators.volumeRatio != null)
        'indicators.volumeRatio': indicators.volumeRatio!,
    };
    final issues = <String>[];
    for (final item in raw) {
      if (item is! Map) {
        issues.add('证据引用格式无效');
        continue;
      }
      final field = '${item['field'] ?? ''}';
      final source = '${item['source'] ?? ''}'.trim();
      final expected = values[field];
      final value = item['value'];
      if (source.isEmpty) issues.add('$field 缺少来源');
      if (expected == null) {
        issues.add('$field 不是允许引用的确定性字段');
        continue;
      }
      final actual = value is num
          ? value.toDouble()
          : double.tryParse('$value');
      if (actual == null || !actual.isFinite) {
        issues.add('$field 的引用数值无效');
      } else {
        final tolerance = expected.abs() * 1e-6 + 1e-6;
        if ((actual - expected).abs() > tolerance) {
          issues.add('$field 的 AI 数值与本地确定性值不一致');
        }
      }
    }
    return StockEvidenceValidation(passed: issues.isEmpty, issues: issues);
  }
}
