import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:syncnote/features/exploration/services/stock_quant_runner.dart';
import 'package:uuid/uuid.dart';

abstract interface class StockAgentPaperRunner {
  bool get canRunLocally;

  Future<Map<String, dynamic>> start({
    required String experimentId,
    required DateTime startedAt,
  });

  Future<Map<String, dynamic>> step({
    required Map<String, dynamic> state,
    required DateTime asOf,
    required DateTime? marketObservedAt,
    required List<Map<String, dynamic>> bars,
    required List<Map<String, dynamic>> intents,
  });

  Future<Map<String, dynamic>> finish({
    required Map<String, dynamic> state,
    required DateTime asOf,
  });
}

/// Only a JSON bridge to the already-tested A-share paper core. No brokerage
/// credential, network request or permanent local file is used here.
class WindowsStockAgentPaperRunner implements StockAgentPaperRunner {
  const WindowsStockAgentPaperRunner();

  @override
  bool get canRunLocally => !kIsWeb && Platform.isWindows;

  @override
  Future<Map<String, dynamic>> start({
    required String experimentId,
    required DateTime startedAt,
  }) => _run('paper-start', {
    'experimentId': experimentId,
    'initialCash': 1000,
    'startedAt': startedAt.toIso8601String(),
  });

  @override
  Future<Map<String, dynamic>> step({
    required Map<String, dynamic> state,
    required DateTime asOf,
    required DateTime? marketObservedAt,
    required List<Map<String, dynamic>> bars,
    required List<Map<String, dynamic>> intents,
  }) => _run('paper-step', {
    'state': state,
    'asOf': asOf.toIso8601String(),
    'marketObservedAt': marketObservedAt?.toIso8601String(),
    'bars': bars,
    'intents': intents,
  });

  @override
  Future<Map<String, dynamic>> finish({
    required Map<String, dynamic> state,
    required DateTime asOf,
  }) => _run('paper-finish', {'state': state, 'asOf': asOf.toIso8601String()});

  Future<Map<String, dynamic>> _run(
    String command,
    Map<String, dynamic> payload,
  ) async {
    if (!canRunLocally) {
      throw UnsupportedError('AI 模拟账户只在 Windows 运行；Android 只读');
    }
    final home = WindowsStockQuantRunner.resolveQuantHome();
    final python = WindowsStockQuantRunner.resolvePython(home);
    final id = const Uuid().v4();
    final temp = Directory.systemTemp;
    final input = File(
      '${temp.path}${Platform.pathSeparator}paper-$id-input.json',
    );
    final output = File(
      '${temp.path}${Platform.pathSeparator}paper-$id-output.json',
    );
    try {
      await input.writeAsString(jsonEncode(payload), flush: true);
      final environment = Map<String, String>.from(Platform.environment);
      final sourcePath = '${home.path}${Platform.pathSeparator}src';
      final existing = environment['PYTHONPATH'];
      environment['PYTHONPATH'] = existing == null || existing.isEmpty
          ? sourcePath
          : '$sourcePath;${environment['PYTHONPATH']}';
      final process = await Process.start(
        python.path,
        [
          '-m',
          'syncnote_quant',
          command,
          '--input',
          input.path,
          '--output',
          output.path,
        ],
        workingDirectory: home.path,
        environment: environment,
        runInShell: false,
      );
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          process.kill();
          throw StateError('本地模拟账户执行超时');
        },
      );
      final stdoutText = await stdoutFuture;
      final stderrText = await stderrFuture;
      if (exitCode != 0 || !await output.exists()) {
        final detail = stderrText.trim().isNotEmpty ? stderrText : stdoutText;
        throw StateError('本地模拟账户执行失败：$detail');
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
