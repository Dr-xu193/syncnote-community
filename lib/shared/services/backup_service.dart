import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/services/notification_service.dart';
import 'package:syncnote/shared/services/sync_status_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:uuid/uuid.dart';

enum BackupConflictStrategy { skip, overwrite, copyAsNew }

class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackupPreview {
  const BackupPreview({
    required this.formatVersion,
    required this.exportedAt,
    required this.userId,
    required this.counts,
    required this.attachmentCount,
    required this.attachmentBytes,
  });

  final int formatVersion;
  final DateTime exportedAt;
  final String userId;
  final Map<String, int> counts;
  final int attachmentCount;
  final int attachmentBytes;

  int get totalDocuments =>
      counts.values.fold<int>(0, (total, value) => total + value);
}

class BackupImportResult {
  const BackupImportResult({
    required this.writtenDocuments,
    required this.skippedDocuments,
    required this.uploadedAttachments,
  });

  final int writtenDocuments;
  final int skippedDocuments;
  final int uploadedAttachments;
}

class BackupService {
  BackupService._();

  static final BackupService instance = BackupService._();

  static const int formatVersion = 1;
  static const String _timestampMarker = '__syncnoteType';
  static const String _timestampType = 'timestamp';

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String get _uid {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw const BackupException('请先登录后再执行备份或恢复');
    }
    return uid;
  }

  DocumentReference<Map<String, dynamic>> get _userRef =>
      _db.collection(AppConfig.usersCollection).doc(_uid);

  static const Map<String, String> _rootCollections = {
    'tasks': AppConfig.tasksCollection,
    'notes': AppConfig.notesCollection,
    'diaries': AppConfig.diaryCollection,
    'memos': AppConfig.memosCollection,
  };

  static const Map<String, String> _dataFiles = {
    'tasks': 'data/tasks.json',
    'notes': 'data/notes.json',
    'diaries': 'data/diaries.json',
    'memos': 'data/memos.json',
    'settings': 'data/settings.json',
    'aiChats': 'data/ai_chats.json',
    'aiMessages': 'data/ai_messages.json',
    'aiResources': 'data/ai_resources.json',
    'aiMemories': 'data/ai_memories.json',
    'aiSettings': 'data/ai_settings.json',
    'aiUsage': 'data/ai_usage.json',
    'dailyAiState': 'data/daily_ai_state.json',
    'dailyAiReports': 'data/daily_ai_reports.json',
    'literatureLibrary': 'data/literature_library.json',
    'stockWatchlist': 'data/stock_watchlist.json',
    'stockFilters': 'data/stock_filters.json',
    'stockReports': 'data/stock_reports.json',
    'stockQuantReports': 'data/stock_quant_reports.json',
    'stockPortfolio': 'data/stock_portfolio.json',
    'stockPlans': 'data/stock_plans.json',
    'stockOrderDrafts': 'data/stock_order_drafts.json',
    'stockMonitor': 'data/stock_monitor.json',
    'stockAgentExperiments': 'data/stock_agent_experiments.json',
    'stockAgentDays': 'data/stock_agent_days.json',
    'stockAgentEvents': 'data/stock_agent_events.json',
    'stockAgentReports': 'data/stock_agent_reports.json',
    'noteVersions': 'data/note_versions.json',
  };

  static dynamic normalizeForBackup(Object? value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is Timestamp) {
      return {
        _timestampMarker: _timestampType,
        'value': value.toDate().toUtc().toIso8601String(),
      };
    }
    if (value is DateTime) {
      return {
        _timestampMarker: _timestampType,
        'value': value.toUtc().toIso8601String(),
      };
    }
    if (value is Iterable) {
      return value.map(normalizeForBackup).toList(growable: false);
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): normalizeForBackup(entry.value),
      };
    }
    return value.toString();
  }

  static dynamic restoreFirestoreTypes(Object? value) {
    if (value is List) {
      return value.map(restoreFirestoreTypes).toList(growable: false);
    }
    if (value is Map) {
      if (value[_timestampMarker] == _timestampType) {
        final raw = value['value'] as String?;
        final parsed = raw == null ? null : DateTime.tryParse(raw);
        if (parsed == null) return null;
        return Timestamp.fromDate(parsed);
      }
      return {
        for (final entry in value.entries)
          entry.key.toString(): restoreFirestoreTypes(entry.value),
      };
    }
    return value;
  }

  static Set<String> collectAttachmentUrls(Object? value) {
    final urls = <String>{};

    void visit(Object? current) {
      if (current is String) {
        if (current.startsWith('webdav://')) urls.add(current);
      } else if (current is Iterable) {
        for (final item in current) {
          visit(item);
        }
      } else if (current is Map) {
        for (final item in current.values) {
          visit(item);
        }
      }
    }

    visit(value);
    return urls;
  }

  @visibleForTesting
  static String attachmentArchivePath(String sourceUrl) {
    final uri = Uri.parse(sourceUrl);
    if (sourceUrl.startsWith('webdav://')) {
      final folder = _safePathPart(uri.host.isEmpty ? 'root' : uri.host);
      final fileName = _safePathPart(
        uri.pathSegments.isEmpty
            ? sha256Hex(utf8.encode(sourceUrl))
            : uri.pathSegments.join('_'),
      );
      return 'attachments/webdav/$folder/$fileName';
    }
    final digest = sha256Hex(utf8.encode(sourceUrl));
    final name = _safePathPart(sourceUrl.split(RegExp(r'[/\\]')).last);
    return 'attachments/local/${digest}_$name';
  }

  @visibleForTesting
  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static String _safePathPart(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return sanitized.isEmpty ? 'file' : sanitized;
  }

  @visibleForTesting
  static dynamic rewriteStringRefs(
    Object? value,
    Map<String, String> replacements,
  ) {
    if (value is String) return replacements[value] ?? value;
    if (value is List) {
      return value
          .map((item) => rewriteStringRefs(item, replacements))
          .toList(growable: false);
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): rewriteStringRefs(entry.value, replacements),
      };
    }
    return value;
  }

  @visibleForTesting
  static Map<String, String> generateCopyIdMap({
    required Map<String, List<Map<String, dynamic>>> rootData,
    required Map<String, Set<String>> existingIds,
  }) {
    final uuid = const Uuid();
    final idMap = <String, String>{};
    for (final entry in rootData.entries) {
      final existing = existingIds[entry.key] ?? const <String>{};
      for (final item in entry.value) {
        final id = item['id'] as String?;
        if (id != null && existing.contains(id)) {
          idMap[id] = uuid.v4();
        }
      }
    }
    return idMap;
  }

  Future<Uint8List> buildFullBackupZip() async {
    SyncStatusService.instance.setSyncing('正在生成完整备份...');
    try {
      final uid = _uid;
      final exportedAt = DateTime.now().toUtc();
      final archive = Archive();
      final dataChecksums = <String, String>{};

      final rawData = await _readAllBackupData();
      final attachmentUrls = collectAttachmentUrls(rawData).toList()..sort();
      final attachments = <Map<String, dynamic>>[];

      for (final url in attachmentUrls) {
        final bytes = await _readAttachmentBytes(url);
        final archivePath = attachmentArchivePath(url);
        attachments.add({
          'sourceUrl': url,
          'archivePath': archivePath,
          'size': bytes.length,
          'sha256': sha256Hex(bytes),
        });
        archive.addFile(ArchiveFile.bytes(archivePath, bytes));
      }

      void addJsonFile(String path, Object? value) {
        final content = _prettyJson(value);
        final bytes = utf8.encode(content);
        dataChecksums[path] = sha256Hex(bytes);
        archive.addFile(ArchiveFile.bytes(path, bytes));
      }

      for (final entry in _dataFiles.entries) {
        addJsonFile(entry.value, rawData[entry.key] ?? const []);
      }

      final counts = {
        'tasks': _asList(rawData['tasks']).length,
        'notes': _asList(rawData['notes']).length,
        'diaries': _asList(rawData['diaries']).length,
        'memos': _asList(rawData['memos']).length,
        'noteVersions': _asList(rawData['noteVersions']).length,
        'aiChats': _asList(rawData['aiChats']).length,
        'aiMessages': _asList(rawData['aiMessages']).length,
        'aiResources': _asList(rawData['aiResources']).length,
        'aiMemories': _asList(rawData['aiMemories']).length,
        'aiSettings': _asList(rawData['aiSettings']).length,
        'aiUsage': _asList(rawData['aiUsage']).length,
        'dailyAiState': _asList(rawData['dailyAiState']).length,
        'dailyAiReports': _asList(rawData['dailyAiReports']).length,
        'literatureLibrary': _asList(rawData['literatureLibrary']).length,
        'stockWatchlist': _asList(rawData['stockWatchlist']).length,
        'stockFilters': _asList(rawData['stockFilters']).length,
        'stockReports': _asList(rawData['stockReports']).length,
        'stockAgentExperiments': _asList(
          rawData['stockAgentExperiments'],
        ).length,
        'stockAgentDays': _asList(rawData['stockAgentDays']).length,
        'stockAgentEvents': _asList(rawData['stockAgentEvents']).length,
        'stockAgentReports': _asList(rawData['stockAgentReports']).length,
        'attachments': attachments.length,
      };

      final manifest = {
        'formatVersion': formatVersion,
        'app': AppConfig.appName,
        'appVersion': AppConfig.appVersion,
        'firebaseProjectId': AppConfig.firebaseProjectId,
        'exportedAt': exportedAt.toIso8601String(),
        'userId': uid,
        'counts': counts,
        'dataChecksums': dataChecksums,
        'attachments': attachments,
      };
      addJsonFile('manifest.json', manifest);

      final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
      SyncStatusService.instance.markOnline();
      return zipBytes;
    } catch (e) {
      SyncStatusService.instance.reportFailure(e);
      rethrow;
    }
  }

  static BackupPreview previewBackupZip(Uint8List zipBytes) {
    final archive = _decodeZip(zipBytes);
    final manifest = _readJsonMap(archive, 'manifest.json');
    final version = manifest['formatVersion'] as int? ?? 0;
    if (version != formatVersion) {
      throw BackupException('不支持的备份格式版本：$version');
    }
    final counts = Map<String, int>.from(
      (manifest['counts'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key.toString(), (value as num).toInt()),
      ),
    );
    final attachments = List<Map<String, dynamic>>.from(
      (manifest['attachments'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
    return BackupPreview(
      formatVersion: version,
      exportedAt:
          DateTime.tryParse(manifest['exportedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      userId: manifest['userId'] as String? ?? '',
      counts: counts,
      attachmentCount: attachments.length,
      attachmentBytes: attachments.fold<int>(
        0,
        (total, item) => total + ((item['size'] as num?)?.toInt() ?? 0),
      ),
    );
  }

  Future<BackupImportResult> importBackupZip(
    Uint8List zipBytes, {
    required BackupConflictStrategy strategy,
  }) async {
    SyncStatusService.instance.setSyncing('正在恢复 ZIP 备份...');
    final uid = _uid;
    final archive = _decodeZip(zipBytes);
    final manifest = _readJsonMap(archive, 'manifest.json');
    if ((manifest['formatVersion'] as int? ?? 0) != formatVersion) {
      throw const BackupException('备份格式版本不兼容');
    }
    _verifyDataChecksums(archive, manifest);

    final uploadedAttachments = <String>[];
    final journal = <_WriteJournalEntry>[];
    final writeQueue = _BackupWriteQueue(_db);
    var writtenDocuments = 0;
    var skippedDocuments = 0;

    try {
      final attachmentMap = await _restoreAttachments(
        archive,
        manifest,
        uploadedAttachments,
      );
      final rootData = {
        for (final key in _rootCollections.keys)
          key: _readJsonList(archive, _dataFiles[key]!),
      };
      final existingIds = await _readExistingIds(rootData.keys);
      final idMap = strategy == BackupConflictStrategy.copyAsNew
          ? generateCopyIdMap(rootData: rootData, existingIds: existingIds)
          : <String, String>{};

      for (final entry in rootData.entries) {
        final collection = _rootCollections[entry.key]!;
        for (final raw in entry.value) {
          final originalId = raw['id'] as String? ?? const Uuid().v4();
          final exists = existingIds[entry.key]?.contains(originalId) ?? false;
          if (exists && strategy == BackupConflictStrategy.skip) {
            skippedDocuments++;
            continue;
          }
          final targetId = idMap[originalId] ?? originalId;
          final data = _prepareImportedData(
            raw,
            uid: uid,
            targetId: targetId,
            replacements: {...attachmentMap, ...idMap},
          );
          await writeQueue.setWithJournal(
            _userRef.collection(collection).doc(targetId),
            data,
            journal,
          );
          writtenDocuments++;
        }
      }

      final noteVersions = _readJsonList(archive, _dataFiles['noteVersions']!);
      for (final raw in noteVersions) {
        final noteId = raw['noteId'] as String? ?? '';
        if (noteId.isEmpty) continue;
        final mappedNoteId = idMap[noteId] ?? noteId;
        if (strategy == BackupConflictStrategy.skip &&
            idMap[noteId] == null &&
            (existingIds['notes']?.contains(noteId) ?? false)) {
          skippedDocuments++;
          continue;
        }
        final data = _prepareImportedData(
          Map<String, dynamic>.from(raw['data'] as Map? ?? const {}),
          uid: uid,
          replacements: {...attachmentMap, ...idMap},
        );
        final versionId = data['id'] as String? ?? const Uuid().v4();
        await writeQueue.setWithJournal(
          _userRef
              .collection(AppConfig.notesCollection)
              .doc(mappedNoteId)
              .collection('versions')
              .doc(versionId),
          data,
          journal,
        );
        writtenDocuments++;
      }

      final aiChats = _readJsonList(archive, _dataFiles['aiChats']!);
      final chatExisting = await _readExistingAiChatIds();
      final chatIdMap = <String, String>{};
      for (final raw in aiChats) {
        final id = raw['id'] as String? ?? const Uuid().v4();
        final exists = chatExisting.contains(id);
        if (exists && strategy == BackupConflictStrategy.skip) {
          skippedDocuments++;
          continue;
        }
        final targetId = exists && strategy == BackupConflictStrategy.copyAsNew
            ? const Uuid().v4()
            : id;
        if (targetId != id) chatIdMap[id] = targetId;
        final data = _prepareImportedData(
          raw,
          uid: uid,
          targetId: targetId,
          replacements: {...attachmentMap, ...idMap, ...chatIdMap},
        );
        await writeQueue.setWithJournal(
          _userRef.collection('aiChats').doc(targetId),
          data,
          journal,
        );
        writtenDocuments++;
      }

      final aiMessages = _readJsonList(archive, _dataFiles['aiMessages']!);
      for (final raw in aiMessages) {
        final chatId = raw['chatId'] as String? ?? '';
        if (chatId.isEmpty) continue;
        if (strategy == BackupConflictStrategy.skip &&
            chatExisting.contains(chatId) &&
            !chatIdMap.containsKey(chatId)) {
          skippedDocuments++;
          continue;
        }
        final mappedChatId = chatIdMap[chatId] ?? chatId;
        final data = _prepareImportedData(
          Map<String, dynamic>.from(raw['data'] as Map? ?? const {}),
          uid: uid,
          replacements: {...attachmentMap, ...idMap, ...chatIdMap},
        );
        final messageId = data['id'] as String? ?? const Uuid().v4();
        await writeQueue.setWithJournal(
          _userRef
              .collection('aiChats')
              .doc(mappedChatId)
              .collection('messages')
              .doc(messageId),
          data,
          journal,
        );
        writtenDocuments++;
      }

      final aiResources = _readOptionalJsonList(
        archive,
        _dataFiles['aiResources']!,
      );
      for (final raw in aiResources) {
        final chatId = raw['chatId'] as String? ?? '';
        if (chatId.isEmpty) continue;
        final mappedChatId = chatIdMap[chatId] ?? chatId;
        final data = _prepareImportedData(
          Map<String, dynamic>.from(raw['data'] as Map? ?? const {}),
          uid: uid,
          replacements: {...attachmentMap, ...idMap, ...chatIdMap},
        );
        final resourceId = data['id'] as String? ?? const Uuid().v4();
        await writeQueue.setWithJournal(
          _userRef
              .collection('aiChats')
              .doc(mappedChatId)
              .collection('resources')
              .doc(resourceId),
          data,
          journal,
        );
        writtenDocuments++;
      }

      for (final entry in const {
        'aiMemories': 'aiMemories',
        'aiSettings': 'ai_settings',
        'aiUsage': 'ai_usage',
        'dailyAiState': 'daily_ai_state',
        'dailyAiReports': 'daily_ai_reports',
        'literatureLibrary': AppConfig.literatureLibraryCollection,
        'stockWatchlist': AppConfig.stockWatchlistCollection,
        'stockFilters': AppConfig.stockFiltersCollection,
        'stockReports': AppConfig.stockReportsCollection,
        'stockQuantReports': AppConfig.stockQuantReportsCollection,
        'stockPortfolio': AppConfig.stockPortfolioCollection,
        'stockPlans': AppConfig.stockPlansCollection,
        'stockOrderDrafts': AppConfig.stockOrderDraftsCollection,
        'stockMonitor': AppConfig.stockMonitorCollection,
      }.entries) {
        final records = _readOptionalJsonList(archive, _dataFiles[entry.key]!);
        for (final raw in records) {
          final data = _prepareImportedData(
            raw,
            uid: uid,
            replacements: {...attachmentMap, ...idMap, ...chatIdMap},
          );
          final recordId = data['id'] as String? ?? const Uuid().v4();
          await writeQueue.setWithJournal(
            _userRef.collection(entry.value).doc(recordId),
            data,
            journal,
          );
          writtenDocuments++;
        }
      }

      final stockExperiments = _readOptionalJsonList(
        archive,
        _dataFiles['stockAgentExperiments']!,
      );
      final stockDays = _readOptionalJsonList(
        archive,
        _dataFiles['stockAgentDays']!,
      );
      final stockEvents = _readOptionalJsonList(
        archive,
        _dataFiles['stockAgentEvents']!,
      );
      final stockReports = _readOptionalJsonList(
        archive,
        _dataFiles['stockAgentReports']!,
      );
      final stockRoot = _userRef.collection(
        AppConfig.stockAgentExperimentsCollection,
      );
      final existingStockIds = (await stockRoot.get()).docs
          .map((doc) => doc.id)
          .toSet();
      for (final raw in stockExperiments) {
        final id = '${raw['id'] ?? ''}';
        if (id.isEmpty) throw const BackupException('股票实验备份缺少 ID');
        final exists = existingStockIds.contains(id);
        if (exists && strategy == BackupConflictStrategy.skip) {
          skippedDocuments +=
              1 +
              stockDays.where((item) => item['experimentId'] == id).length +
              stockEvents.where((item) => item['experimentId'] == id).length +
              stockReports.where((item) => item['experimentId'] == id).length;
          continue;
        }
        if (exists && strategy == BackupConflictStrategy.copyAsNew) {
          throw const BackupException('股票实验包含不可改写的逐日日记，不能复制成另一场；请选择跳过或覆盖');
        }
        final experimentData = prepareStockAgentExperimentForRestore(
          _prepareImportedData(raw, uid: uid, replacements: attachmentMap),
        );
        await writeQueue.setWithJournal(
          stockRoot.doc(id),
          experimentData,
          journal,
        );
        writtenDocuments++;
        for (final day in stockDays.where(
          (item) => item['experimentId'] == id,
        )) {
          final logicalDay = '${day['logicalDay'] ?? ''}';
          if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(logicalDay)) {
            throw const BackupException('股票日记日期无效');
          }
          final dayRef = stockRoot.doc(id).collection('days').doc(logicalDay);
          await writeQueue.setWithJournal(
            dayRef,
            _prepareImportedData(day, uid: uid, replacements: attachmentMap),
            journal,
          );
          writtenDocuments++;
          for (final event in stockEvents.where(
            (item) =>
                item['experimentId'] == id && item['logicalDay'] == logicalDay,
          )) {
            final eventId = '${event['id'] ?? ''}';
            if (eventId.isEmpty) throw const BackupException('股票日记事件缺少 ID');
            await writeQueue.setWithJournal(
              dayRef.collection('events').doc(eventId),
              _prepareImportedData(
                event,
                uid: uid,
                replacements: attachmentMap,
              ),
              journal,
            );
            writtenDocuments++;
          }
        }
        for (final report in stockReports.where(
          (item) => item['experimentId'] == id,
        )) {
          final reportId = '${report['periodId'] ?? ''}';
          if (reportId.isEmpty) throw const BackupException('股票报告周期缺失');
          await writeQueue.setWithJournal(
            stockRoot.doc(id).collection('reports').doc(reportId),
            _prepareImportedData(report, uid: uid, replacements: attachmentMap),
            journal,
          );
          writtenDocuments++;
        }
      }

      final settings = _readJsonMap(archive, _dataFiles['settings']!);
      if (settings.isNotEmpty) {
        final data = _prepareImportedData(
          settings,
          uid: uid,
          replacements: {...attachmentMap, ...idMap, ...chatIdMap},
        );
        await writeQueue.setWithJournal(_userRef, data, journal, merge: true);
        writtenDocuments++;
      }

      await writeQueue.flush();
      final tasks = await _userRef.collection(AppConfig.tasksCollection).get();
      await NotificationService.instance.syncTaskAlarms(
        tasks.docs
            .map((doc) {
              final data = Map<String, dynamic>.from(doc.data());
              data['id'] ??= doc.id;
              return Task.fromJson(data);
            })
            .toList(growable: false),
      );
      SyncStatusService.instance.markOnline();
      return BackupImportResult(
        writtenDocuments: writtenDocuments,
        skippedDocuments: skippedDocuments,
        uploadedAttachments: uploadedAttachments.length,
      );
    } catch (e) {
      await _rollback(journal, uploadedAttachments);
      SyncStatusService.instance.reportFailure(e);
      throw BackupException('恢复失败，已回滚本次写入：$e');
    }
  }

  Future<Map<String, dynamic>> _readAllBackupData() async {
    final result = <String, dynamic>{};
    for (final entry in _rootCollections.entries) {
      final snapshot = await _userRef.collection(entry.value).get();
      result[entry.key] = snapshot.docs
          .map((doc) {
            final data = Map<String, dynamic>.from(doc.data());
            data['id'] ??= doc.id;
            return normalizeForBackup(data);
          })
          .toList(growable: false);
    }

    final settings = await _userRef.get();
    result['settings'] = normalizeForBackup(settings.data() ?? const {});

    final noteVersions = <Map<String, dynamic>>[];
    final notes = await _userRef.collection(AppConfig.notesCollection).get();
    for (final note in notes.docs) {
      final versions = await note.reference.collection('versions').get();
      for (final version in versions.docs) {
        final data = Map<String, dynamic>.from(version.data());
        data['id'] ??= version.id;
        noteVersions.add({
          'noteId': note.id,
          'id': version.id,
          'data': normalizeForBackup(data),
        });
      }
    }
    result['noteVersions'] = noteVersions;

    final aiChats = <Map<String, dynamic>>[];
    final aiMessages = <Map<String, dynamic>>[];
    final aiResources = <Map<String, dynamic>>[];
    final chats = await _userRef.collection('aiChats').get();
    for (final chat in chats.docs) {
      final data = Map<String, dynamic>.from(chat.data());
      data['id'] ??= chat.id;
      aiChats.add(normalizeForBackup(data) as Map<String, dynamic>);
      final messages = await chat.reference.collection('messages').get();
      for (final message in messages.docs) {
        final messageData = Map<String, dynamic>.from(message.data());
        messageData['id'] ??= message.id;
        aiMessages.add({
          'chatId': chat.id,
          'id': message.id,
          'data': normalizeForBackup(messageData),
        });
      }
      final resources = await chat.reference.collection('resources').get();
      for (final resource in resources.docs) {
        final resourceData = Map<String, dynamic>.from(resource.data());
        resourceData['id'] ??= resource.id;
        aiResources.add({
          'chatId': chat.id,
          'id': resource.id,
          'data': normalizeForBackup(resourceData),
        });
      }
    }
    result['aiChats'] = aiChats;
    result['aiMessages'] = aiMessages;
    result['aiResources'] = aiResources;

    final stockAgentExperiments = <Map<String, dynamic>>[];
    final stockAgentDays = <Map<String, dynamic>>[];
    final stockAgentEvents = <Map<String, dynamic>>[];
    final stockAgentReports = <Map<String, dynamic>>[];
    final stockRoots = await _userRef
        .collection(AppConfig.stockAgentExperimentsCollection)
        .get();
    for (final experiment in stockRoots.docs) {
      final data = Map<String, dynamic>.from(experiment.data());
      data['id'] ??= experiment.id;
      data.remove('runLease');
      stockAgentExperiments.add(
        normalizeForBackup(data) as Map<String, dynamic>,
      );
      final days = await experiment.reference.collection('days').get();
      for (final day in days.docs) {
        final dayData = Map<String, dynamic>.from(day.data());
        dayData['experimentId'] = experiment.id;
        dayData['logicalDay'] = day.id;
        dayData['staleArchiveUrls'] = <String>[];
        stockAgentDays.add(normalizeForBackup(dayData) as Map<String, dynamic>);
        final events = await day.reference.collection('events').get();
        for (final event in events.docs) {
          final eventData = Map<String, dynamic>.from(event.data());
          eventData['id'] = event.id;
          eventData['experimentId'] = experiment.id;
          eventData['logicalDay'] = day.id;
          stockAgentEvents.add(
            normalizeForBackup(eventData) as Map<String, dynamic>,
          );
        }
      }
      final reports = await experiment.reference.collection('reports').get();
      for (final report in reports.docs) {
        final reportData = Map<String, dynamic>.from(report.data());
        reportData['experimentId'] = experiment.id;
        reportData['periodId'] = report.id;
        stockAgentReports.add(
          normalizeForBackup(reportData) as Map<String, dynamic>,
        );
      }
    }
    result['stockAgentExperiments'] = stockAgentExperiments;
    result['stockAgentDays'] = stockAgentDays;
    result['stockAgentEvents'] = stockAgentEvents;
    result['stockAgentReports'] = stockAgentReports;

    for (final entry in const {
      'aiMemories': 'aiMemories',
      'aiSettings': 'ai_settings',
      'aiUsage': 'ai_usage',
      'dailyAiState': 'daily_ai_state',
      'dailyAiReports': 'daily_ai_reports',
      'literatureLibrary': AppConfig.literatureLibraryCollection,
      'stockWatchlist': AppConfig.stockWatchlistCollection,
      'stockFilters': AppConfig.stockFiltersCollection,
      'stockReports': AppConfig.stockReportsCollection,
      'stockQuantReports': AppConfig.stockQuantReportsCollection,
      'stockPortfolio': AppConfig.stockPortfolioCollection,
      'stockPlans': AppConfig.stockPlansCollection,
      'stockOrderDrafts': AppConfig.stockOrderDraftsCollection,
      'stockMonitor': AppConfig.stockMonitorCollection,
    }.entries) {
      final snapshot = await _userRef.collection(entry.value).get();
      result[entry.key] = snapshot.docs
          .map((doc) {
            final data = Map<String, dynamic>.from(doc.data());
            data['id'] ??= doc.id;
            return normalizeForBackup(data);
          })
          .toList(growable: false);
    }

    return result;
  }

  Future<Uint8List> _readAttachmentBytes(String sourceUrl) async {
    if (sourceUrl.startsWith('webdav://')) {
      return UploadService.instance.downloadCloudFileBytes(sourceUrl);
    }
    final file = File(sourceUrl.replaceFirst(RegExp(r'^file:///?'), ''));
    if (await file.exists()) return file.readAsBytes();
    throw BackupException('附件不存在或无法读取：$sourceUrl');
  }

  Future<Map<String, String>> _restoreAttachments(
    Archive archive,
    Map<String, dynamic> manifest,
    List<String> uploaded,
  ) async {
    final attachments = List<Map<String, dynamic>>.from(
      (manifest['attachments'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
    final tempDir = await getTemporaryDirectory();
    final attachmentMap = <String, String>{};
    for (final item in attachments) {
      final sourceUrl = item['sourceUrl'] as String? ?? '';
      final archivePath = item['archivePath'] as String? ?? '';
      final expectedHash = item['sha256'] as String? ?? '';
      final file = archive.findFile(archivePath);
      if (file == null || !file.isFile) {
        throw BackupException('备份缺少附件：$archivePath');
      }
      final bytes = file.content;
      if (expectedHash.isNotEmpty && sha256Hex(bytes) != expectedHash) {
        throw BackupException('附件校验失败：$archivePath');
      }
      final uri = Uri.tryParse(sourceUrl);
      final folder = sourceUrl.startsWith('webdav://') && uri != null
          ? (uri.host.isEmpty ? 'restore' : uri.host)
          : 'restore';
      final tempFile = File(
        '${tempDir.path}/syncnote_restore_${DateTime.now().microsecondsSinceEpoch}_${_safePathPart(archivePath.split('/').last)}',
      );
      await tempFile.writeAsBytes(bytes, flush: true);
      final newUrl = await UploadService.instance.uploadFile(tempFile, folder);
      try {
        await tempFile.delete();
      } catch (_) {}
      if (newUrl == null) {
        throw BackupException('附件重新上传失败：$sourceUrl');
      }
      uploaded.add(newUrl);
      attachmentMap[sourceUrl] = newUrl;
    }
    return attachmentMap;
  }

  Future<Map<String, Set<String>>> _readExistingIds(
    Iterable<String> dataKeys,
  ) async {
    final result = <String, Set<String>>{};
    for (final key in dataKeys) {
      final collection = _rootCollections[key];
      if (collection == null) continue;
      final snapshot = await _userRef.collection(collection).get();
      result[key] = snapshot.docs.map((doc) => doc.id).toSet();
    }
    return result;
  }

  Future<Set<String>> _readExistingAiChatIds() async {
    final snapshot = await _userRef.collection('aiChats').get();
    return snapshot.docs.map((doc) => doc.id).toSet();
  }

  Map<String, dynamic> _prepareImportedData(
    Map<String, dynamic> raw, {
    required String uid,
    String? targetId,
    Map<String, String> replacements = const {},
  }) {
    final rewritten = rewriteStringRefs(raw, replacements);
    final restored = Map<String, dynamic>.from(
      restoreFirestoreTypes(rewritten) as Map,
    );
    if (targetId != null) restored['id'] = targetId;
    if (restored.containsKey('userId')) restored['userId'] = uid;
    return restored;
  }

  @visibleForTesting
  static Map<String, dynamic> prepareStockAgentExperimentForRestore(
    Map<String, dynamic> value,
  ) {
    final restored = Map<String, dynamic>.from(value)..remove('runLease');
    // Import must not silently resume a paid AI run while its nested events
    // and journals are still being written. The user resumes explicitly.
    if (restored['status'] == 'active') restored['status'] = 'paused';
    return restored;
  }

  Future<void> _rollback(
    List<_WriteJournalEntry> journal,
    List<String> uploadedAttachments,
  ) async {
    for (final entry in journal.reversed) {
      try {
        if (entry.existed && entry.oldData != null) {
          await entry.ref.set(entry.oldData!);
        } else {
          await entry.ref.delete();
        }
      } catch (e) {
        debugPrint('Backup rollback document failed: $e');
      }
    }
    for (final url in uploadedAttachments) {
      try {
        await UploadService.instance.deleteFile(url);
      } catch (e) {
        debugPrint('Backup rollback attachment failed: $e');
      }
    }
  }

  static Archive _decodeZip(Uint8List zipBytes) {
    try {
      return ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      throw BackupException('无法读取 ZIP 备份：$e');
    }
  }

  static String _prettyJson(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  static List<Map<String, dynamic>> _asList(Object? value) =>
      value is List ? value.cast<Map<String, dynamic>>() : const [];

  static String _readText(Archive archive, String path) {
    final file = archive.findFile(path);
    if (file == null || !file.isFile) {
      throw BackupException('备份缺少文件：$path');
    }
    return utf8.decode(file.content);
  }

  static Map<String, dynamic> _readJsonMap(Archive archive, String path) {
    final decoded = jsonDecode(_readText(archive, path));
    if (decoded is! Map) {
      throw BackupException('备份文件格式错误：$path');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static List<Map<String, dynamic>> _readJsonList(
    Archive archive,
    String path,
  ) {
    final decoded = jsonDecode(_readText(archive, path));
    if (decoded is! List) {
      throw BackupException('备份文件格式错误：$path');
    }
    return decoded
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }

  static List<Map<String, dynamic>> _readOptionalJsonList(
    Archive archive,
    String path,
  ) => archive.findFile(path) == null ? const [] : _readJsonList(archive, path);

  void _verifyDataChecksums(Archive archive, Map<String, dynamic> manifest) {
    final checksums = Map<String, dynamic>.from(
      manifest['dataChecksums'] as Map? ?? const {},
    );
    for (final entry in checksums.entries) {
      final file = archive.findFile(entry.key);
      if (file == null || !file.isFile) {
        throw BackupException('备份缺少文件：${entry.key}');
      }
      final actual = sha256Hex(file.content);
      if (actual != entry.value) {
        throw BackupException('备份校验失败：${entry.key}');
      }
    }
  }
}

class _BackupWriteQueue {
  _BackupWriteQueue(this.db);

  static const int maxBatchSize = 400;

  final FirebaseFirestore db;
  final List<_PendingBackupSet> _pending = [];

  Future<void> setWithJournal(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> data,
    List<_WriteJournalEntry> journal, {
    bool merge = false,
  }) async {
    final old = await ref.get();
    journal.add(
      _WriteJournalEntry(ref: ref, existed: old.exists, oldData: old.data()),
    );
    _pending.add(_PendingBackupSet(ref: ref, data: data, merge: merge));
    if (_pending.length >= maxBatchSize) {
      await flush();
    }
  }

  Future<void> flush() async {
    if (_pending.isEmpty) return;
    final batch = db.batch();
    for (final item in _pending) {
      batch.set(
        item.ref,
        item.data,
        item.merge ? SetOptions(merge: true) : null,
      );
    }
    _pending.clear();
    await batch.commit();
  }
}

class _PendingBackupSet {
  const _PendingBackupSet({
    required this.ref,
    required this.data,
    required this.merge,
  });

  final DocumentReference<Map<String, dynamic>> ref;
  final Map<String, dynamic> data;
  final bool merge;
}

class _WriteJournalEntry {
  const _WriteJournalEntry({
    required this.ref,
    required this.existed,
    required this.oldData,
  });

  final DocumentReference<Map<String, dynamic>> ref;
  final bool existed;
  final Map<String, dynamic>? oldData;
}
