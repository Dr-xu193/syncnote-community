import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/services/stock_data_quality.dart';
import 'package:syncnote/features/exploration/services/stock_quant_runner.dart';
import 'package:uuid/uuid.dart';

abstract interface class StockShadowRunner {
  bool get canRunLocally;

  Future<StockMonitorSnapshot> run({
    required List<StockQuantInputSeries> series,
    StockPortfolio? portfolio,
    List<StockPlanRecord> plans = const [],
    StockMonitorSnapshot? previous,
  });
}

class WindowsStockShadowRunner implements StockShadowRunner {
  const WindowsStockShadowRunner();

  @override
  bool get canRunLocally => !kIsWeb && Platform.isWindows;

  @override
  Future<StockMonitorSnapshot> run({
    required List<StockQuantInputSeries> series,
    StockPortfolio? portfolio,
    List<StockPlanRecord> plans = const [],
    StockMonitorSnapshot? previous,
  }) async {
    if (!canRunLocally) {
      throw UnsupportedError('模拟盘只在 Windows 本地运行；Android 仅查看同步状态');
    }
    if (series.length < 2) throw ArgumentError('模拟盘至少需要两只股票');
    final quality = StockDataQuality();
    for (final item in series) {
      final report = quality.evaluateSeries(item.executionSeries);
      if (report.shouldBlockResearch) {
        throw StateError('模拟盘行情未通过质量门禁：${report.blockingReason}');
      }
    }
    final home = WindowsStockQuantRunner.resolveQuantHome();
    final python = WindowsStockQuantRunner.resolvePython(home);
    final id = const Uuid().v4();
    final temp = Directory.systemTemp;
    final input = File(
      '${temp.path}${Platform.pathSeparator}shadow-$id-input.json',
    );
    final output = File(
      '${temp.path}${Platform.pathSeparator}shadow-$id-output.json',
    );
    try {
      final payload =
          WindowsStockQuantRunner.buildSnapshotPayload(
              series: series,
              preset: StockScreenPreset.trend,
            )
            ..['initialCash'] = portfolio?.equity ?? previous?.equity ?? 100000
            ..['previousPeakEquity'] = previous?.peakEquity ?? 0
            ..['plans'] = plans
                .map((item) => item.payload)
                .toList(growable: false);
      await input.writeAsString(jsonEncode(payload), flush: true);
      final environment = Map<String, String>.from(Platform.environment);
      final sourcePath = '${home.path}${Platform.pathSeparator}src';
      final currentPythonPath = environment['PYTHONPATH'];
      environment['PYTHONPATH'] =
          currentPythonPath == null || currentPythonPath.isEmpty
          ? sourcePath
          : '$sourcePath${Platform.isWindows ? ';' : ':'}$currentPythonPath';
      final result = await Process.run(
        python.path,
        [
          '-m',
          'syncnote_quant',
          'run-shadow',
          '--input',
          input.path,
          '--output',
          output.path,
        ],
        workingDirectory: home.path,
        environment: environment,
        runInShell: false,
      );
      if (result.exitCode != 0 || !await output.exists()) {
        throw StateError(
          '${result.stderr}'.trim().isEmpty
              ? '模拟盘执行失败'
              : '${result.stderr}'.trim(),
        );
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(await output.readAsString()) as Map,
      );
      return StockMonitorSnapshot(
        asOf: DateTime.tryParse('${data['as_of'] ?? ''}') ?? DateTime.now(),
        equity: _number(data['equity']),
        peakEquity: _number(data['peak_equity']),
        drawdown: _number(data['drawdown']),
        alerts: (data['alerts'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) => StockMonitorAlert(
                kind: '${item['kind'] ?? ''}',
                severity: '${item['severity'] ?? 'info'}',
                message: '${item['message'] ?? ''}',
                occurredAt:
                    DateTime.tryParse('${item['occurred_at'] ?? ''}') ??
                    DateTime.now(),
              ),
            )
            .toList(growable: false),
        updatedAt: DateTime.now(),
      );
    } finally {
      if (await input.exists()) await input.delete();
      if (await output.exists()) await output.delete();
    }
  }

  static double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
}
