import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/services/stock_data_quality.dart';
import 'package:uuid/uuid.dart';

abstract interface class StockQuantRunner {
  bool get canRunLocally;

  Future<StockQuantReport> run({
    required List<StockQuantInputSeries> series,
    required StockScreenPreset preset,
    StockQuantDataSource dataSource = StockQuantDataSource.free,
  });
}

enum StockQuantDataSource { free, tushare }

class StockQuantInputSeries {
  const StockQuantInputSeries({
    required this.executionSeries,
    required this.signalSeries,
  });

  final StockSeries executionSeries;
  final StockSeries signalSeries;
}

class WindowsStockQuantRunner implements StockQuantRunner {
  const WindowsStockQuantRunner();

  @override
  bool get canRunLocally => !kIsWeb && Platform.isWindows;

  @override
  Future<StockQuantReport> run({
    required List<StockQuantInputSeries> series,
    required StockScreenPreset preset,
    StockQuantDataSource dataSource = StockQuantDataSource.free,
  }) async {
    if (!canRunLocally) {
      throw UnsupportedError('量化回测只在 Windows 本地运行；移动端仅查看同步报告');
    }
    final quality = StockDataQuality();
    for (final item in series) {
      final executionQuality = quality.evaluateSeries(item.executionSeries);
      final signalQuality = quality.evaluateSeries(item.signalSeries);
      if (executionQuality.shouldBlockResearch) {
        throw StateError(
          '${item.executionSeries.quote.code} 原始日线未通过质量门禁：'
          '${executionQuality.blockingReason}',
        );
      }
      if (signalQuality.shouldBlockResearch) {
        throw StateError(
          '${item.signalSeries.quote.code} 复权日线未通过质量门禁：'
          '${signalQuality.blockingReason}',
        );
      }
    }
    final home = resolveQuantHome();
    final python = resolvePython(home);
    final temp = Directory.systemTemp;
    final id = const Uuid().v4();
    final input = File(
      '${temp.path}${Platform.pathSeparator}quant-$id-input.json',
    );
    final output = File(
      '${temp.path}${Platform.pathSeparator}quant-$id-output.json',
    );
    try {
      final payload = buildSnapshotPayload(
        series: series,
        preset: preset,
        dataSource: dataSource,
      );
      await input.writeAsString(jsonEncode(payload), flush: true);
      final environment = Map<String, String>.from(Platform.environment);
      final sourcePath = '${home.path}${Platform.pathSeparator}src';
      final existingPythonPath = environment['PYTHONPATH'];
      environment['PYTHONPATH'] =
          existingPythonPath == null || existingPythonPath.isEmpty
          ? sourcePath
          : '$sourcePath${Platform.isWindows ? ';' : ':'}$existingPythonPath';
      final process = await Process.run(
        python.path,
        [
          '-m',
          'syncnote_quant',
          'backtest-snapshot',
          '--input',
          input.path,
          '--output',
          output.path,
        ],
        workingDirectory: home.path,
        environment: environment,
        runInShell: false,
      );
      if (process.exitCode != 0 || !await output.exists()) {
        throw StateError(_processError(process));
      }
      final report = Map<String, dynamic>.from(
        jsonDecode(await output.readAsString()) as Map,
      );
      return StockQuantReport(
        id: id,
        strategyName: '${report['strategy_name'] ?? ''}',
        provider: '${report['provider'] ?? ''}',
        trustTier: '${report['trust_tier'] ?? ''}',
        createdAt:
            DateTime.tryParse('${report['generated_at'] ?? ''}') ??
            DateTime.now(),
        report: report,
      );
    } finally {
      if (await input.exists()) await input.delete();
      if (await output.exists()) await output.delete();
    }
  }

  static Map<String, dynamic> buildSnapshotPayload({
    required List<StockQuantInputSeries> series,
    required StockScreenPreset preset,
    StockQuantDataSource dataSource = StockQuantDataSource.free,
  }) {
    if (series.length < 2) throw ArgumentError('至少需要两只股票进行横截面回测');
    final now = DateTime.now().toUtc();
    return {
      'provider': series
          .map((item) => item.executionSeries.provider)
          .toSet()
          .join(' / '),
      'trustTier': 'public_validation',
      'requestedSource': dataSource.name,
      'generatedAt': now.toIso8601String(),
      'profile': switch (preset) {
        StockScreenPreset.qualityValue => 'quality_value',
        StockScreenPreset.improving => 'event_observation',
        _ => 'medium_trend',
      },
      'topN': series.length.clamp(2, 5),
      'minimumCoverage': 0.25,
      'maximumWeight': 0.1,
      'series': series
          .map((item) {
            final execution = item.executionSeries;
            final signalByDate = {
              for (final candle in item.signalSeries.candles)
                _dateOnly(candle.timestamp): candle,
            };
            final quote = execution.quote;
            return {
              'code': quote.code,
              'exchange': _exchange(quote),
              'industry': quote.industry.isEmpty ? '未分类' : quote.industry,
              'isSt': quote.name.toUpperCase().contains('ST'),
              'executionProvider': execution.provider,
              'signalProvider': item.signalSeries.provider,
              'providerTimestamp': execution.providerTimestamp
                  .toUtc()
                  .toIso8601String(),
              'fetchedAt': execution.fetchedAt.toUtc().toIso8601String(),
              'bars': List.generate(execution.candles.length, (index) {
                final candle = execution.candles[index];
                final signal = signalByDate[_dateOnly(candle.timestamp)];
                return {
                  'date': _dateOnly(candle.timestamp),
                  'open': candle.open,
                  'high': candle.high,
                  'low': candle.low,
                  'close': candle.close,
                  if (signal != null) 'signalClose': signal.close,
                  if (index > 0)
                    'previousClose': execution.candles[index - 1].close,
                  'volume': candle.volume,
                  'amount': candle.amount,
                  'isSt': quote.name.toUpperCase().contains('ST'),
                };
              }),
            };
          })
          .toList(growable: false),
    };
  }

  static Directory resolveQuantHome() {
    final configured = Platform.environment['SYNCNOTE_QUANT_HOME'];
    if (configured != null && configured.isNotEmpty) {
      final directory = Directory(configured);
      if (File(
        '${directory.path}${Platform.pathSeparator}pyproject.toml',
      ).existsSync()) {
        return directory;
      }
    }
    final starts = <Directory>{
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    };
    for (final start in starts) {
      var current = start.absolute;
      for (var depth = 0; depth < 8; depth++) {
        final direct = Directory(
          '${current.path}${Platform.pathSeparator}quant_core',
        );
        if (File(
          '${direct.path}${Platform.pathSeparator}pyproject.toml',
        ).existsSync()) {
          return direct;
        }
        final parent = current.parent;
        if (parent.path == current.path) break;
        current = parent;
      }
    }
    throw StateError(
      '找不到 quant_core。请设置 SYNCNOTE_QUANT_HOME 为仓库中的 quant_core 目录。',
    );
  }

  static File resolvePython(Directory home) {
    final configured = Platform.environment['SYNCNOTE_QUANT_PYTHON'];
    if (configured != null && File(configured).existsSync()) {
      return File(configured);
    }
    final candidate = File(
      '${home.path}${Platform.pathSeparator}.venv${Platform.pathSeparator}'
      'Scripts${Platform.pathSeparator}python.exe',
    );
    if (candidate.existsSync()) return candidate;
    throw StateError(
      '量化 Python 环境未安装。请在 quant_core 中创建 .venv 并安装 .[all,dev]，'
      '或设置 SYNCNOTE_QUANT_PYTHON。',
    );
  }

  static String _processError(ProcessResult result) {
    final stdout = '${result.stdout}'.trim();
    if (stdout.isNotEmpty) {
      try {
        final value = jsonDecode(stdout.split('\n').last);
        if (value is Map && value['error'] != null) return '${value['error']}';
      } catch (_) {}
    }
    final stderr = '${result.stderr}'.trim();
    return stderr.isNotEmpty ? stderr : '量化核心执行失败（${result.exitCode}）';
  }

  static String _exchange(StockQuote quote) {
    final raw = quote.exchange.toUpperCase();
    if (raw.contains('BSE') || raw.contains('北京') || raw.contains('北交')) {
      return 'BSE';
    }
    if (raw.contains('SZ') || raw.contains('深圳') || raw.contains('深交')) {
      return 'SZSE';
    }
    if (raw.contains('SH') || raw.contains('上海') || raw.contains('上交')) {
      return 'SSE';
    }
    if (quote.code.startsWith(RegExp(r'(4|8|92)'))) return 'BSE';
    return quote.code.startsWith(RegExp(r'(0|3)')) ? 'SZSE' : 'SSE';
  }

  static String _dateOnly(DateTime value) {
    final shanghai = value.toUtc().add(const Duration(hours: 8));
    return '${shanghai.year.toString().padLeft(4, '0')}-'
        '${shanghai.month.toString().padLeft(2, '0')}-'
        '${shanghai.day.toString().padLeft(2, '0')}';
  }
}
