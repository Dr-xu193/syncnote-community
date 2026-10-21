import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/features/exploration/services/stock_quant_runner.dart';
import 'package:uuid/uuid.dart';

abstract interface class StockPlanRunner {
  bool get canRunLocally;

  Future<Map<String, dynamic>> buildPlan({
    required StockPortfolio portfolio,
    required StockQuantReport report,
  });
}

class WindowsStockPlanRunner implements StockPlanRunner {
  const WindowsStockPlanRunner();

  @override
  bool get canRunLocally => !kIsWeb && Platform.isWindows;

  @override
  Future<Map<String, dynamic>> buildPlan({
    required StockPortfolio portfolio,
    required StockQuantReport report,
  }) async {
    final qualification = Map<String, dynamic>.from(
      report.report['qualification'] as Map? ?? const {},
    );
    if (qualification['qualified_for_plan'] != true) {
      throw StateError(
        '研究门禁未通过：${List<String>.from(qualification['reasons'] as List? ?? const []).join('；')}',
      );
    }
    if (!canRunLocally) {
      throw UnsupportedError('买入计划只在 Windows 本地生成；Android 仅查看');
    }
    final home = WindowsStockQuantRunner.resolveQuantHome();
    final python = WindowsStockQuantRunner.resolvePython(home);
    final rankings = (report.report['latestRanking'] as List? ?? const [])
        .whereType<Map>()
        .take(5)
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => item['code'] != null && item['exchange'] != null)
        .map(
          (item) => {
            'code': '${item['code']}',
            'exchange': '${item['exchange']}',
            'price': item['price'] ?? 0,
            'industry': item['industry'] ?? '未分类',
            'compositeScore': item['composite'] ?? 0,
            'liquidityAmount': item['liquidityAmount'] ?? 0,
            'stopDistance': 0.08,
            'correlations': Map<String, dynamic>.from(
              item['correlations'] as Map? ?? const {},
            ),
          },
        )
        .toList(growable: false);
    final payload = {
      'asOf': portfolio.asOf.toUtc().toIso8601String(),
      'equity': portfolio.equity,
      'cash': portfolio.cash,
      'positions': portfolio.positions.map((item) => item.toJson()).toList(),
      'sourceSnapshotHash': report.report['snapshot_hash'] ?? '',
      'sourceTrustTier': report.trustTier,
      'stage2Qualified': true,
      'candidates': rankings,
    };
    final id = const Uuid().v4();
    final temp = Directory.systemTemp;
    final input = File(
      '${temp.path}${Platform.pathSeparator}plan-$id-input.json',
    );
    final output = File(
      '${temp.path}${Platform.pathSeparator}plan-$id-output.json',
    );
    try {
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
          'build-plan',
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
              ? '买入计划生成失败'
              : '${result.stderr}'.trim(),
        );
      }
      return Map<String, dynamic>.from(
        jsonDecode(await output.readAsString()) as Map,
      );
    } finally {
      if (await input.exists()) await input.delete();
      if (await output.exists()) await output.delete();
    }
  }
}
