import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/features/exploration/services/stock_agent_memory_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:uuid/uuid.dart';

abstract interface class StockAgentReportStore {
  Future<Map<String, dynamic>?> loadIndex(String experimentId, String periodId);
  Future<List<Map<String, dynamic>>> listIndexes(String experimentId);
  Future<void> saveIndex(
    String experimentId,
    String periodId,
    Map<String, dynamic> index,
  );
  Future<String> upload(Uint8List bytes, String remoteName);
  Future<Uint8List> download(String url);
  Future<void> delete(String url);
}

class _CloudStockAgentReportStore implements StockAgentReportStore {
  DocumentReference<Map<String, dynamic>> _ref(
    String experimentId,
    String periodId,
  ) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('请先登录');
    return FirebaseFirestore.instance
        .collection(AppConfig.usersCollection)
        .doc(uid)
        .collection(AppConfig.stockAgentExperimentsCollection)
        .doc(experimentId)
        .collection('reports')
        .doc(periodId);
  }

  @override
  Future<Map<String, dynamic>?> loadIndex(
    String experimentId,
    String periodId,
  ) async => (await _ref(experimentId, periodId).get()).data();

  @override
  Future<List<Map<String, dynamic>>> listIndexes(String experimentId) async {
    final snapshot = await _ref(experimentId, 'month').parent.get();
    return snapshot.docs.map((doc) => doc.data()).toList(growable: false);
  }

  @override
  Future<void> saveIndex(
    String experimentId,
    String periodId,
    Map<String, dynamic> index,
  ) => FirebaseFirestore.instance.runTransaction((transaction) async {
    final ref = _ref(experimentId, periodId);
    if ((await transaction.get(ref)).exists) {
      throw StateError('该期股票报告已经封存');
    }
    transaction.set(ref, index);
  });

  @override
  Future<String> upload(Uint8List bytes, String remoteName) =>
      UploadService.instance.uploadCloudFile(
        stream: Stream<List<int>>.value(bytes),
        contentLength: bytes.length,
        remoteFileName: remoteName,
        contentType: 'application/json; charset=utf-8',
        folder: 'stock_agent_reports',
      );

  @override
  Future<Uint8List> download(String url) => UploadService.instance
      .downloadCloudFileBytes(url, maxBytes: 4 * 1024 * 1024);

  @override
  Future<void> delete(String url) async {
    if (!await UploadService.instance.deleteFile(url)) {
      throw StateError('股票报告云文件清理失败');
    }
  }
}

/// Reports are projections of sealed daily JSON, not a second mutable trade
/// history. Every line retains the source day and event IDs for drill-down.
class StockAgentReportService {
  StockAgentReportService({required this.memory, StockAgentReportStore? store})
    : store = store ?? _CloudStockAgentReportStore();

  final StockAgentMemoryService memory;
  final StockAgentReportStore store;

  Future<List<Map<String, dynamic>>> list(String experimentId) =>
      store.listIndexes(experimentId);

  Future<bool> exists(String experimentId, String periodId) async =>
      await store.loadIndex(experimentId, periodId) != null;

  static DateTime _beijingDate(DateTime instant) {
    final wall = instant.toUtc().add(const Duration(hours: 8));
    return DateTime.utc(wall.year, wall.month, wall.day);
  }

  static String _day(DateTime date) => date.toIso8601String().split('T').first;

  Future<Map<String, dynamic>> read(
    String experimentId,
    String periodId,
  ) async {
    final index = await store.loadIndex(experimentId, periodId);
    if (index == null) throw StateError('该期报告尚未生成');
    final bytes = await store.download('${index['archiveUrl'] ?? ''}');
    if (bytes.length != index['byteLength'] ||
        sha256.convert(bytes).toString() != index['sha256']) {
      throw StateError('股票报告云端内容校验失败');
    }
    final data = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    if (data['experimentId'] != experimentId || data['periodId'] != periodId) {
      throw StateError('股票报告身份不一致');
    }
    return data;
  }

  Future<Map<String, dynamic>> generate({
    required StockAgentExperiment experiment,
    required String periodId,
    required DateTime now,
    Map<String, dynamic>? terminal,
  }) async {
    final existing = await store.loadIndex(experiment.id, periodId);
    if (existing != null) return read(experiment.id, periodId);
    final start = _beijingDate(experiment.startedAt);
    final totalDays = periodId == 'month'
        ? 30
        : int.tryParse(periodId.replaceFirst('week-', ''));
    if (totalDays == null ||
        (periodId != 'month' &&
            (!periodId.startsWith('week-') ||
                totalDays < 1 ||
                totalDays > 5))) {
      throw StateError('股票报告周期无效');
    }
    final startOffset = periodId == 'month' ? 0 : (totalDays - 1) * 7;
    final endOffset = periodId == 'month' ? 30 : (startOffset + 7).clamp(0, 30);
    final availableAt = start
        .add(Duration(days: endOffset))
        .subtract(const Duration(hours: 8));
    if (now.toUtc().isBefore(availableAt)) {
      throw StateError('本期尚未结束，不能封存报告');
    }
    if (periodId == 'month' && terminal == null) {
      throw StateError('月报必须包含连续账户内核的期末核算');
    }
    final days = <Map<String, dynamic>>[];
    for (var offset = startOffset; offset < endOffset; offset++) {
      final logicalDay = _day(start.add(Duration(days: offset)));
      final index = await memory.loadDayIndex(experiment.id, logicalDay);
      if (index?.sealed != true) {
        throw StateError('$logicalDay 日记尚未封存，不能生成完整报告');
      }
      days.add(await memory.readDay(experiment.id, logicalDay));
    }
    final report = buildReport(
      experiment: experiment,
      periodId: periodId,
      days: days,
      generatedAt: now,
      terminal: terminal,
    );
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(report)));
    if (bytes.length > 4 * 1024 * 1024) {
      throw StateError('报告超过 4 MB，不能静默截断逐日解释');
    }
    final digest = sha256.convert(bytes).toString();
    final remoteName =
        '${experiment.id}-$periodId-$digest-${const Uuid().v4()}.json';
    String? uploaded;
    try {
      uploaded = await store.upload(bytes, remoteName);
      final verified = await store.download(uploaded);
      if (verified.length != bytes.length ||
          sha256.convert(verified).toString() != digest) {
        throw StateError('股票报告上传后校验失败');
      }
      await store.saveIndex(experiment.id, periodId, {
        'id': periodId,
        'experimentId': experiment.id,
        'periodId': periodId,
        'archiveUrl': uploaded,
        'sha256': digest,
        'byteLength': bytes.length,
        'logicalDays': days.map((item) => item['logicalDay']).toList(),
        'generatedAt': now.toUtc().toIso8601String(),
      });
      return report;
    } catch (_) {
      if (uploaded != null) {
        try {
          await store.delete(uploaded);
        } catch (_) {}
      }
      rethrow;
    }
  }

  static Map<String, dynamic> buildReport({
    required StockAgentExperiment experiment,
    required String periodId,
    required List<Map<String, dynamic>> days,
    required DateTime generatedAt,
    Map<String, dynamic>? terminal,
  }) {
    if (days.isEmpty) throw StateError('报告没有原始日记');
    final rows = <Map<String, dynamic>>[];
    var fills = 0;
    var rejections = 0;
    var missed = 0;
    var aiFailures = 0;
    var realized = 0.0;
    var modelCostUsd = 0.0;
    for (final journal in days) {
      final events = (journal['events'] as List? ?? const []).whereType<Map>();
      final cycle = events.firstWhere(
        (item) =>
            item['kind'] == 'daily_cycle' || item['kind'] == 'missed_cycle',
        orElse: () => const {},
      );
      if (cycle.isEmpty) throw StateError('日记缺少每日主事件');
      final detail = Map<String, dynamic>.from(
        cycle['detail'] as Map? ?? const {},
      );
      final opening = Map<String, dynamic>.from(
        journal['openingAccount'] as Map? ?? const {},
      );
      final closing = Map<String, dynamic>.from(
        journal['closingAccount'] as Map? ?? const {},
      );
      final paperEvents = (detail['paperEvents'] as List? ?? const [])
          .whereType<Map>();
      final dailyFills = <Map<String, dynamic>>[];
      final dailyRejections = <Map<String, dynamic>>[];
      for (final event in paperEvents) {
        final kind = '${event['kind'] ?? ''}';
        if (kind == 'fill') {
          fills++;
          final fill = Map<String, dynamic>.from(
            event['detail'] as Map? ?? const {},
          );
          dailyFills.add(fill);
          if (fill['side'] == 'sell') {
            final instrument = '${fill['instrument'] ?? ''}';
            final previous = (opening['positions'] as List? ?? const [])
                .whereType<Map>()
                .where(
                  (item) =>
                      '${(item['instrument'] as Map?)?['code'] ?? ''}.${(item['instrument'] as Map?)?['exchange'] ?? ''}' ==
                      instrument,
                )
                .firstOrNull;
            if (previous != null) {
              final shares = (fill['shares'] as num?)?.toDouble() ?? 0;
              final price = (fill['price'] as num?)?.toDouble() ?? 0;
              final cost = (previous['averageCost'] as num?)?.toDouble() ?? 0;
              final fees = (fill['fees'] as num?)?.toDouble() ?? 0;
              realized += (price - cost) * shares - fees;
            }
          }
        } else if (kind == 'rejection') {
          rejections++;
          dailyRejections.add(
            Map<String, dynamic>.from(event['detail'] as Map? ?? const {}),
          );
        }
      }
      if (cycle['kind'] == 'missed_cycle') missed++;
      if (detail['aiError'] != null) aiFailures++;
      final decision = Map<String, dynamic>.from(
        detail['decision'] as Map? ?? const {},
      );
      modelCostUsd += (decision['estimatedCostUsd'] as num?)?.toDouble() ?? 0;
      rows.add({
        'logicalDay': journal['logicalDay'],
        'eventIds': events.map((item) => item['id']).toList(),
        'status': cycle['kind'] == 'missed_cycle' ? 'not_run' : 'ran',
        'openingCash': opening['cash'],
        'closingCash': closing['cash'],
        'reportedEquity': closing['lastEquity'],
        'cumulativeFees': closing['cumulativeFees'],
        'positionCount': (closing['positions'] as List? ?? const []).length,
        'decision': decision.isEmpty
            ? null
            : {
                'mode': decision['mode'],
                'whyNow': decision['whyNow'],
                'marketView': decision['marketView'],
                'alternativesRejected': decision['alternativesRejected'],
                'uncertainties': decision['uncertainties'],
                'nextDayExpectation': decision['nextDayExpectation'],
                'monthExpectation': decision['monthExpectation'],
                'sourceIds': decision['sourceIds'],
                'model': decision['model'],
                'estimatedCostUsd': decision['estimatedCostUsd'],
              },
        'aiError': detail['aiError'],
        'fills': dailyFills,
        'rejections': dailyRejections,
      });
    }
    final lastAccount = Map<String, dynamic>.from(
      days.last['closingAccount'] as Map? ?? const {},
    );
    final terminalData = Map<String, dynamic>.from(
      terminal?['terminal'] as Map? ?? const {},
    );
    final netValue = (terminalData['netValue'] as num?)?.toDouble();
    double? unrealized;
    if (netValue != null) {
      unrealized = 0;
      for (final raw
          in (lastAccount['positions'] as List? ?? const []).whereType<Map>()) {
        final shares = (raw['shares'] as num?)?.toDouble() ?? 0;
        final close = (raw['lastClose'] as num?)?.toDouble();
        final cost = (raw['averageCost'] as num?)?.toDouble() ?? 0;
        if (close == null) {
          unrealized = null;
          break;
        }
        unrealized = unrealized! + (close - cost) * shares;
      }
      if (unrealized != null) {
        unrealized -=
            (terminalData['estimatedExitFees'] as num?)?.toDouble() ?? 0;
      }
    }
    return {
      'schemaVersion': 1,
      'experimentId': experiment.id,
      'periodId': periodId,
      'generatedAt': generatedAt.toUtc().toIso8601String(),
      'firstDay': days.first['logicalDay'],
      'lastDay': days.last['logicalDay'],
      'initialCash': experiment.account['initialCash'],
      'summary': {
        'openingCash': (days.first['openingAccount'] as Map?)?['cash'],
        'closingCash': lastAccount['cash'],
        'lastReportedEquity': lastAccount['lastEquity'],
        'cumulativeFees': lastAccount['cumulativeFees'],
        'fillCount': fills,
        'rejectionCount': rejections,
        'missedDayCount': missed,
        'aiFailureCount': aiFailures,
        'estimatedModelCostUsd': modelCostUsd,
        'realizedPnLFromFills': realized,
        'unrealizedPnLAfterExitFees': unrealized,
        'terminalNetValue': netValue,
        'terminalReturn': netValue == null
            ? null
            : (netValue - StockAgentExperiment.initialCash) /
                  StockAgentExperiment.initialCash,
        'missingTerminalPrices': terminalData['missingPrices'] ?? const [],
      },
      'terminal': terminalData.isEmpty ? null : terminalData,
      'days': rows,
      'note': '这是虚拟实验复盘，不代表真实收益；逐日完整研究原文及证据请打开对应日记。',
    };
  }
}
