import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/features/exploration/models/stock_models.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:uuid/uuid.dart';

abstract interface class StockResearchBackend {
  String? get currentUserId;

  Stream<List<StockWatchItem>> watchWatchlist();

  Stream<List<StockSavedFilter>> watchFilters();

  Stream<List<StockResearchReport>> watchReports();

  Stream<List<StockQuantReport>> watchQuantReports();

  Stream<StockPortfolio?> watchPortfolio();

  Stream<List<StockPlanRecord>> watchPlans();

  Stream<List<StockOrderDraftBatch>> watchOrderDrafts();

  Stream<StockMonitorSnapshot?> watchMonitor();

  Future<void> saveWatchItem(StockWatchItem item);

  Future<void> deleteWatchItem(String id);

  Future<void> saveFilter(StockSavedFilter filter);

  Future<void> deleteFilter(String id);

  Future<void> saveReport(StockResearchReport report);

  Future<void> saveQuantReport(StockQuantReport report);

  Future<void> savePortfolio(StockPortfolio portfolio);

  Future<void> savePlan(StockPlanRecord plan);

  Future<void> saveOrderDraftBatch(StockOrderDraftBatch batch);

  Future<void> saveMonitor(StockMonitorSnapshot snapshot);

  Future<void> addNote(Note note);

  Future<String> uploadArchive(Uint8List bytes, String remoteName);

  Future<Uint8List> downloadArchive(String url);

  Future<void> deleteArchive(String url);
}

class _ProductionStockResearchBackend implements StockResearchBackend {
  CollectionReference<Map<String, dynamic>> _collection(String name) {
    final uid = currentUserId;
    if (uid == null) throw StateError('请先登录');
    return FirebaseFirestore.instance
        .collection(AppConfig.usersCollection)
        .doc(uid)
        .collection(name);
  }

  @override
  String? get currentUserId => FirebaseAuth.instance.currentUser?.uid;

  @override
  Stream<List<StockWatchItem>> watchWatchlist() =>
      _collection(AppConfig.stockWatchlistCollection)
          .orderBy('updatedAt', descending: true)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map((doc) => StockWatchItem.fromFirestore(doc.data()))
                .toList(growable: false),
          );

  @override
  Stream<List<StockSavedFilter>> watchFilters() =>
      _collection(AppConfig.stockFiltersCollection)
          .orderBy('updatedAt', descending: true)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map((doc) => StockSavedFilter.fromFirestore(doc.data()))
                .toList(growable: false),
          );

  @override
  Stream<List<StockResearchReport>> watchReports() =>
      _collection(AppConfig.stockReportsCollection)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map((doc) => StockResearchReport.fromJson(doc.data()))
                .toList(growable: false),
          );

  @override
  Stream<List<StockQuantReport>> watchQuantReports() =>
      _collection(AppConfig.stockQuantReportsCollection)
          .orderBy('createdAt', descending: true)
          .limit(20)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map((doc) => StockQuantReport.fromJson(doc.data()))
                .toList(growable: false),
          );

  @override
  Stream<StockPortfolio?> watchPortfolio() =>
      _collection(AppConfig.stockPortfolioCollection)
          .doc('current')
          .snapshots()
          .map(
            (snapshot) => snapshot.exists
                ? StockPortfolio.fromJson(snapshot.data() ?? const {})
                : null,
          );

  @override
  Stream<List<StockPlanRecord>> watchPlans() =>
      _collection(AppConfig.stockPlansCollection)
          .orderBy('createdAt', descending: true)
          .limit(20)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map((doc) => StockPlanRecord.fromJson(doc.data()))
                .toList(growable: false),
          );

  @override
  Stream<List<StockOrderDraftBatch>> watchOrderDrafts() =>
      _collection(AppConfig.stockOrderDraftsCollection)
          .orderBy('createdAt', descending: true)
          .limit(20)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map((doc) => StockOrderDraftBatch.fromJson(doc.data()))
                .toList(growable: false),
          );

  @override
  Stream<StockMonitorSnapshot?> watchMonitor() =>
      _collection(AppConfig.stockMonitorCollection)
          .doc('current')
          .snapshots()
          .map(
            (snapshot) => snapshot.exists
                ? StockMonitorSnapshot.fromJson(snapshot.data() ?? const {})
                : null,
          );

  @override
  Future<void> saveWatchItem(StockWatchItem item) => _collection(
    AppConfig.stockWatchlistCollection,
  ).doc(item.id).set(item.toFirestore());

  @override
  Future<void> deleteWatchItem(String id) =>
      _collection(AppConfig.stockWatchlistCollection).doc(id).delete();

  @override
  Future<void> saveFilter(StockSavedFilter filter) => _collection(
    AppConfig.stockFiltersCollection,
  ).doc(filter.id).set(filter.toFirestore());

  @override
  Future<void> deleteFilter(String id) =>
      _collection(AppConfig.stockFiltersCollection).doc(id).delete();

  @override
  Future<void> saveReport(StockResearchReport report) => _collection(
    AppConfig.stockReportsCollection,
  ).doc(report.id).set(report.toFirestore());

  @override
  Future<void> saveQuantReport(StockQuantReport report) => _collection(
    AppConfig.stockQuantReportsCollection,
  ).doc(report.id).set(report.toFirestore());

  @override
  Future<void> savePortfolio(StockPortfolio portfolio) => _collection(
    AppConfig.stockPortfolioCollection,
  ).doc('current').set(portfolio.toFirestore());

  @override
  Future<void> savePlan(StockPlanRecord plan) => _collection(
    AppConfig.stockPlansCollection,
  ).doc(plan.id).set(plan.toFirestore());

  @override
  Future<void> saveOrderDraftBatch(StockOrderDraftBatch batch) => _collection(
    AppConfig.stockOrderDraftsCollection,
  ).doc(batch.id).set(batch.toFirestore());

  @override
  Future<void> saveMonitor(StockMonitorSnapshot snapshot) => _collection(
    AppConfig.stockMonitorCollection,
  ).doc('current').set(snapshot.toFirestore());

  @override
  Future<void> addNote(Note note) => FirestoreService.instance.addNote(note);

  @override
  Future<String> uploadArchive(Uint8List bytes, String remoteName) =>
      UploadService.instance.uploadCloudFile(
        stream: Stream<List<int>>.value(bytes),
        contentLength: bytes.length,
        remoteFileName: remoteName,
        contentType: 'application/gzip',
        folder: 'stock_reports',
      );

  @override
  Future<Uint8List> downloadArchive(String url) => UploadService.instance
      .downloadCloudFileBytes(url, maxBytes: 12 * 1024 * 1024);

  @override
  Future<void> deleteArchive(String url) =>
      UploadService.instance.deleteFile(url);
}

class StockResearchRepository {
  StockResearchRepository._(this._backend);

  static final StockResearchRepository instance = StockResearchRepository._(
    _ProductionStockResearchBackend(),
  );

  @visibleForTesting
  StockResearchRepository.forTesting(StockResearchBackend backend)
    : _backend = backend;

  final StockResearchBackend _backend;

  Stream<List<StockWatchItem>> watchWatchlist() => _backend.watchWatchlist();

  Stream<List<StockSavedFilter>> watchFilters() => _backend.watchFilters();

  Stream<List<StockResearchReport>> watchReports() => _backend.watchReports();

  Stream<List<StockQuantReport>> watchQuantReports() =>
      _backend.watchQuantReports();

  Stream<StockPortfolio?> watchPortfolio() => _backend.watchPortfolio();

  Stream<List<StockPlanRecord>> watchPlans() => _backend.watchPlans();

  Stream<List<StockOrderDraftBatch>> watchOrderDrafts() =>
      _backend.watchOrderDrafts();

  Stream<StockMonitorSnapshot?> watchMonitor() => _backend.watchMonitor();

  Future<void> saveWatchItem(StockWatchItem item) =>
      _backend.saveWatchItem(item);

  Future<void> deleteWatchItem(String id) => _backend.deleteWatchItem(id);

  Future<void> saveFilter(StockSavedFilter filter) =>
      _backend.saveFilter(filter);

  Future<void> deleteFilter(String id) => _backend.deleteFilter(id);

  Future<void> saveQuantReport(StockQuantReport report) =>
      _validateAndSaveQuantReport(report);

  Future<void> savePortfolio(StockPortfolio portfolio) =>
      _backend.savePortfolio(portfolio);

  Future<void> savePlan(StockPlanRecord plan) => _validateAndSavePlan(plan);

  Future<void> saveOrderDraftBatch(StockOrderDraftBatch batch) =>
      _validateAndSaveOrderDraftBatch(batch);

  Future<void> saveMonitor(StockMonitorSnapshot snapshot) =>
      _validateAndSaveMonitor(snapshot);

  Future<void> _validateAndSavePlan(StockPlanRecord plan) async {
    if (_containsQuantBulkData(plan.payload)) {
      throw StateError('计划草稿包含 K 线或全市场矩阵，已阻止写入 Firestore');
    }
    final bytes = utf8.encode(jsonEncode(plan.payload));
    if (bytes.length > 512 * 1024) {
      throw StateError('计划草稿超过 512 KB，已阻止写入 Firestore');
    }
    await _backend.savePlan(plan);
  }

  Future<void> _validateAndSaveMonitor(StockMonitorSnapshot snapshot) async {
    final body = snapshot.toPortableJson();
    if (_containsQuantBulkData(body)) {
      throw StateError('监控快照包含禁止的大数据字段');
    }
    if (utf8.encode(jsonEncode(body)).length > 128 * 1024) {
      throw StateError('监控快照超过 128 KB');
    }
    await _backend.saveMonitor(snapshot);
  }

  Future<void> _validateAndSaveOrderDraftBatch(
    StockOrderDraftBatch batch,
  ) async {
    final body = batch.toJson();
    if (body['brokerSubmissionAllowed'] == true ||
        batch.drafts.any((item) => item.brokerSubmissionAllowed)) {
      throw StateError('委托草稿禁止连接或提交券商');
    }
    final keys = batch.drafts.map((item) => item.idempotencyKey).toSet();
    if (keys.length != batch.drafts.length) {
      throw StateError('委托草稿存在重复幂等键');
    }
    if (utf8.encode(jsonEncode(body)).length > 128 * 1024) {
      throw StateError('委托草稿超过 128 KB');
    }
    await _backend.saveOrderDraftBatch(batch);
  }

  Future<void> _validateAndSaveQuantReport(StockQuantReport report) async {
    if (_containsQuantBulkData(report.report)) {
      throw StateError('量化报告包含 K 线或全市场矩阵，已阻止写入 Firestore');
    }
    final bytes = utf8.encode(jsonEncode(report.report));
    if (bytes.length > 512 * 1024) {
      throw StateError('量化报告超过 512 KB，已阻止写入 Firestore');
    }
    await _backend.saveQuantReport(report);
  }

  Future<StockResearchReport> saveReport(
    StockResearchReport report, {
    bool createKnowledgeNote = true,
  }) async {
    var updated = report;
    if (createKnowledgeNote && report.linkedNoteId.isEmpty) {
      final note = await _createKnowledgeNote(report);
      updated = report.copyWith(linkedNoteId: note.id);
    }
    await _backend.saveReport(updated);
    return updated;
  }

  Future<StockResearchReport> archiveReport(StockResearchReport report) async {
    if (report.archived || report.analysis.isEmpty) return report;
    final portable = report.toPortableJson();
    final bytes = Uint8List.fromList(
      gzip.encode(utf8.encode(jsonEncode(portable))),
    );
    final checksum = sha256.convert(bytes).toString();
    final safeCode = report.quote.code.replaceAll(RegExp(r'[^0-9A-Za-z]'), '_');
    final remoteName =
        'stock-$safeCode-${report.createdAt.toUtc().millisecondsSinceEpoch}.json.gz';
    String? uploaded;
    try {
      uploaded = await _backend.uploadArchive(bytes, remoteName);
      final roundTrip = await _backend.downloadArchive(uploaded);
      if (sha256.convert(roundTrip).toString() != checksum) {
        throw StateError('股票报告远端校验失败');
      }
      final decoded = decodeArchive(roundTrip);
      if ('${decoded['id'] ?? ''}' != report.id) {
        throw StateError('股票报告远端记录不一致');
      }
      final archived = report.copyWith(
        analysis: const <String, dynamic>{},
        archived: true,
        archiveUrl: uploaded,
        archiveSha256: checksum,
      );
      await _backend.saveReport(archived);
      return archived;
    } catch (_) {
      if (uploaded != null) {
        try {
          await _backend.deleteArchive(uploaded);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<StockResearchReport> restoreReport(StockResearchReport report) async {
    if (!report.archived || report.archiveUrl.isEmpty) return report;
    final bytes = await _backend.downloadArchive(report.archiveUrl);
    if (sha256.convert(bytes).toString() != report.archiveSha256) {
      throw StateError('股票报告归档哈希不一致');
    }
    final restored = StockResearchReport.fromJson(decodeArchive(bytes));
    final online = restored.copyWith(
      archived: false,
      archiveUrl: '',
      archiveSha256: '',
    );
    await _backend.saveReport(online);
    await _backend.deleteArchive(report.archiveUrl);
    return online;
  }

  Future<void> updateReview(
    StockResearchReport report, {
    required String conclusion,
    required String result,
    String errorClass = '',
    bool? actualOutcome,
  }) {
    final analysis = Map<String, dynamic>.from(report.analysis);
    if (actualOutcome != null) {
      var probability = (analysis['confidence'] as num?)?.toDouble() ?? 0.5;
      if (probability > 1) probability /= 100;
      probability = probability.clamp(0.0, 1.0);
      final outcome = actualOutcome ? 1.0 : 0.0;
      analysis['_predictionProbability'] = probability;
      analysis['_actualOutcome'] = actualOutcome;
      analysis['_brierScore'] =
          (probability - outcome) * (probability - outcome);
      analysis['_reviewedAt'] = DateTime.now().toUtc().toIso8601String();
    }
    return _backend.saveReport(
      report.copyWith(
        analysis: analysis,
        userConclusion: conclusion,
        reviewResult: result,
        reviewErrorClass: errorClass,
      ),
    );
  }

  static Map<String, dynamic> decodeArchive(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(gzip.decode(bytes)));
    if (decoded is! Map) throw const FormatException('股票报告归档格式无效');
    return Map<String, dynamic>.from(decoded);
  }

  Future<Note> _createKnowledgeNote(StockResearchReport report) async {
    final uid = _backend.currentUserId;
    if (uid == null) throw StateError('请先登录后再保存股票研究记录');
    final now = DateTime.now();
    final analysis = report.analysis;
    final buffer = StringBuffer()
      ..writeln('# ${report.quote.name}（${report.quote.code}）研究记录')
      ..writeln()
      ..writeln('> 这是研究记录，不是投资建议。')
      ..writeln()
      ..writeln('数据来源：${report.sources.join('、')}')
      ..writeln('数据时间：${report.dataTimestamp.toLocal()}')
      ..writeln('记录时间：${report.createdAt.toLocal()}')
      ..writeln('价格：${report.quote.price.toStringAsFixed(2)}')
      ..writeln('涨跌幅：${report.quote.changePercent.toStringAsFixed(2)}%')
      ..writeln()
      ..writeln('## 核心判断')
      ..writeln('${analysis['summary'] ?? ''}')
      ..writeln()
      ..writeln('## 看多证据')
      ..writeln(_markdownList(analysis['bull_evidence']))
      ..writeln()
      ..writeln('## 看空证据')
      ..writeln(_markdownList(analysis['bear_evidence']))
      ..writeln()
      ..writeln('## 风险与失效条件')
      ..writeln(_markdownList(analysis['risks']))
      ..writeln(_markdownList(analysis['invalidation_conditions']))
      ..writeln()
      ..writeln('## 数据缺口与待验证')
      ..writeln(_markdownList(analysis['missing_data']))
      ..writeln(_markdownList(analysis['unknowns']))
      ..writeln()
      ..writeln('## 确定性指标')
      ..writeln('```json')
      ..writeln(
        const JsonEncoder.withIndent('  ').convert(report.indicators.toJson()),
      )
      ..writeln('```');
    final note = Note(
      id: const Uuid().v4(),
      title: '${report.quote.name}（${report.quote.code}）研究记录',
      content: buffer.toString(),
      contentType: NoteContentType.markdown,
      tags: [
        '股票',
        report.quote.code,
        if (report.quote.industry.isNotEmpty) report.quote.industry,
      ],
      category: '股票研究',
      createdAt: now,
      updatedAt: now,
      userId: uid,
      aiKeywords: [
        report.quote.name,
        report.quote.code,
        report.quote.industry,
      ].where((item) => item.isNotEmpty).toList(growable: false),
    );
    await _backend.addNote(note);
    return note;
  }

  static String _markdownList(Object? raw) {
    final rows = raw is List ? raw : const [];
    if (rows.isEmpty) return '- 暂无';
    return rows.map((item) => '- $item').join('\n');
  }
}

bool _containsQuantBulkData(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = '${entry.key}'.toLowerCase();
      if (key == 'bars' ||
          key == 'candles' ||
          key == 'minute_data' ||
          key == 'factor_matrix') {
        return true;
      }
      if (_containsQuantBulkData(entry.value)) return true;
    }
  } else if (value is Iterable) {
    return value.any(_containsQuantBulkData);
  }
  return false;
}
