import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/shared/services/backup_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';

class CollectionStorageAudit {
  const CollectionStorageAudit({
    required this.documents,
    required this.sampledDocuments,
    required this.estimatedBytes,
  });

  final int documents;
  final int sampledDocuments;
  final int estimatedBytes;
}

class StorageAuditSnapshot {
  const StorageAuditSnapshot({
    required this.generatedAt,
    required this.collections,
    required this.webdav,
  });

  final DateTime generatedAt;
  final Map<String, CollectionStorageAudit> collections;
  final WebdavInventory webdav;

  int get firestoreDocuments =>
      collections.values.fold(0, (total, item) => total + item.documents);

  int get estimatedFirestoreBytes =>
      collections.values.fold(0, (total, item) => total + item.estimatedBytes);

  double firestoreUsageRatio({int referenceBytes = 1024 * 1024 * 1024}) =>
      referenceBytes <= 0 ? 0 : estimatedFirestoreBytes / referenceBytes;

  String capacityLevel({int referenceBytes = 1024 * 1024 * 1024}) {
    final ratio = firestoreUsageRatio(referenceBytes: referenceBytes);
    if (ratio >= .85) return '优先冷归档';
    if (ratio >= .75) return '生成归档建议';
    if (ratio >= .60) return '接近提醒线';
    return '正常';
  }
}

class BackupAuditResult {
  const BackupAuditResult({required this.preview, required this.archiveBytes});

  final BackupPreview preview;
  final int archiveBytes;
}

class StorageAuditService {
  StorageAuditService._();

  static final StorageAuditService instance = StorageAuditService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static const Map<String, String> auditedCollections = {
    '任务': AppConfig.tasksCollection,
    '笔记': AppConfig.notesCollection,
    '日记': AppConfig.diaryCollection,
    '备忘录': AppConfig.memosCollection,
    '云文件索引': AppConfig.cloudFilesCollection,
    'AI 对话': 'aiChats',
    '探索状态': AppConfig.explorationStateCollection,
    '文献收藏': AppConfig.literatureLibraryCollection,
    '股票关注': AppConfig.stockWatchlistCollection,
    '股票筛选器': AppConfig.stockFiltersCollection,
    '股票报告索引': AppConfig.stockReportsCollection,
    '股票量化报告': AppConfig.stockQuantReportsCollection,
    '股票组合': AppConfig.stockPortfolioCollection,
    '股票计划': AppConfig.stockPlansCollection,
    '股票委托草稿': AppConfig.stockOrderDraftsCollection,
    '股票模拟盘': AppConfig.stockMonitorCollection,
    'AI 股票实验账户': AppConfig.stockAgentExperimentsCollection,
    'AI 长期记忆': 'aiMemories',
    'AI 专属资料': 'aiResources',
    '搜索索引': 'search_index',
    '归档索引': 'archive_index',
  };

  String get _uid {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('请先登录后再查看存储审计');
    return uid;
  }

  CollectionReference<Map<String, dynamic>> _collection(String name) =>
      _db.collection(AppConfig.usersCollection).doc(_uid).collection(name);

  Future<StorageAuditSnapshot> audit() async {
    final entries = await Future.wait(
      auditedCollections.entries.map((entry) async {
        final collection = _collection(entry.value);
        final results = await Future.wait([
          collection.count().get(),
          collection.limit(30).get(),
        ]);
        final count = (results[0] as AggregateQuerySnapshot).count ?? 0;
        final sample = results[1] as QuerySnapshot<Map<String, dynamic>>;
        final sampleBytes = sample.docs.fold<int>(
          0,
          (total, doc) => total + estimateDocumentBytes(doc.id, doc.data()),
        );
        final average = sample.docs.isEmpty
            ? 0
            : (sampleBytes / sample.docs.length).ceil();
        return MapEntry(
          entry.key,
          CollectionStorageAudit(
            documents: count,
            sampledDocuments: sample.docs.length,
            estimatedBytes: average * count,
          ),
        );
      }),
    );
    var dayDocuments = 0;
    var dayBytes = 0;
    var eventDocuments = 0;
    var eventBytes = 0;
    var reportDocuments = 0;
    var reportBytes = 0;
    final experiments = await _collection(
      AppConfig.stockAgentExperimentsCollection,
    ).get();
    for (final experiment in experiments.docs) {
      final days = await experiment.reference.collection('days').get();
      for (final day in days.docs) {
        dayDocuments++;
        dayBytes += estimateDocumentBytes(day.id, day.data());
        final events = await day.reference.collection('events').get();
        for (final event in events.docs) {
          eventDocuments++;
          eventBytes += estimateDocumentBytes(event.id, event.data());
        }
      }
      final reports = await experiment.reference.collection('reports').get();
      for (final report in reports.docs) {
        reportDocuments++;
        reportBytes += estimateDocumentBytes(report.id, report.data());
      }
    }
    final webdav = await UploadService.instance.auditRemoteInventory();
    return StorageAuditSnapshot(
      generatedAt: DateTime.now(),
      collections: Map.unmodifiable(
        Map.fromEntries([
          ...entries,
          MapEntry(
            'AI 股票逐日日记索引',
            CollectionStorageAudit(
              documents: dayDocuments,
              sampledDocuments: dayDocuments,
              estimatedBytes: dayBytes,
            ),
          ),
          MapEntry(
            'AI 股票事件',
            CollectionStorageAudit(
              documents: eventDocuments,
              sampledDocuments: eventDocuments,
              estimatedBytes: eventBytes,
            ),
          ),
          MapEntry(
            'AI 股票周/月报索引',
            CollectionStorageAudit(
              documents: reportDocuments,
              sampledDocuments: reportDocuments,
              estimatedBytes: reportBytes,
            ),
          ),
        ]),
      ),
      webdav: webdav,
    );
  }

  Future<BackupAuditResult> verifyFullBackup() async {
    final bytes = await BackupService.instance.buildFullBackupZip();
    final preview = BackupService.previewBackupZip(bytes);
    return BackupAuditResult(preview: preview, archiveBytes: bytes.length);
  }

  @visibleForTesting
  static int estimateDocumentBytes(String id, Map<String, dynamic> data) {
    final normalized = BackupService.normalizeForBackup(data);
    return utf8.encode(jsonEncode({'id': id, 'data': normalized})).length;
  }
}
