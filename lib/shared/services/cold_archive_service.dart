import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/shared/services/backup_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:syncnote/shared/utils/content_index_text.dart';
import 'package:uuid/uuid.dart';

class ColdArchiveException implements Exception {
  const ColdArchiveException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ColdArchiveCandidate {
  const ColdArchiveCandidate({
    required this.collection,
    required this.id,
    required this.title,
    required this.reason,
    required this.estimatedBytes,
  });

  final String collection;
  final String id;
  final String title;
  final String reason;
  final int estimatedBytes;
}

class ColdArchiveIndexRecord {
  const ColdArchiveIndexRecord({
    required this.id,
    required this.archiveId,
    required this.collection,
    required this.sourceId,
    required this.title,
    required this.summary,
    required this.remoteUrl,
    required this.archivedAt,
  });

  final String id;
  final String archiveId;
  final String collection;
  final String sourceId;
  final String title;
  final String summary;
  final String remoteUrl;
  final DateTime archivedAt;

  factory ColdArchiveIndexRecord.fromJson(Map<String, dynamic> json) =>
      ColdArchiveIndexRecord(
        id: json['id'] as String? ?? '',
        archiveId: json['archiveId'] as String? ?? '',
        collection: json['collection'] as String? ?? '',
        sourceId: json['sourceId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        remoteUrl: json['remoteUrl'] as String? ?? '',
        archivedAt:
            (json['archivedAt'] as Timestamp?)?.toDate() ?? DateTime(1970),
      );
}

class ColdArchiveBundle {
  const ColdArchiveBundle({required this.manifest, required this.records});
  final Map<String, dynamic> manifest;
  final List<Map<String, dynamic>> records;
}

class ColdArchiveTransportAudit {
  const ColdArchiveTransportAudit({
    required this.archiveBytes,
    required this.recordCount,
  });
  final int archiveBytes;
  final int recordCount;
}

class ColdArchiveService {
  ColdArchiveService._();
  static final ColdArchiveService instance = ColdArchiveService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static const allowedCollections = <String>{
    AppConfig.tasksCollection,
    AppConfig.notesCollection,
    AppConfig.memosCollection,
    AppConfig.diaryCollection,
  };

  String get _uid {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw const ColdArchiveException('请先登录');
    return uid;
  }

  CollectionReference<Map<String, dynamic>> _collection(String name) =>
      _db.collection(AppConfig.usersCollection).doc(_uid).collection(name);

  Stream<List<ColdArchiveIndexRecord>> watchArchivedRecords() =>
      _collection(
        AppConfig.archiveIndexCollection,
      ).where('kind', isEqualTo: 'record').snapshots().map((snapshot) {
        final records =
            snapshot.docs
                .map((doc) => ColdArchiveIndexRecord.fromJson(doc.data()))
                .toList(growable: true)
              ..sort((a, b) => b.archivedAt.compareTo(a.archivedAt));
        return List<ColdArchiveIndexRecord>.unmodifiable(records);
      });

  Future<ColdArchiveIndexRecord?> getArchivedRecord(
    String collection,
    String sourceId,
  ) async {
    final snapshot = await _collection(
      AppConfig.archiveIndexCollection,
    ).doc('${collection}_$sourceId').get();
    final data = snapshot.data();
    return data == null ? null : ColdArchiveIndexRecord.fromJson(data);
  }

  Future<List<ColdArchiveCandidate>> findCandidates({DateTime? now}) async {
    final current = now ?? DateTime.now();
    final candidates = <ColdArchiveCandidate>[];
    for (final collection in allowedCollections) {
      final snapshot = await _collection(collection).get();
      for (final doc in snapshot.docs) {
        final data = doc.data();
        if (data['isDeleted'] as bool? ?? false) continue;
        if (data['isColdArchived'] as bool? ?? false) continue;
        final updatedAt = _date(data['updatedAt']) ?? current;
        String? reason;
        if (collection == AppConfig.tasksCollection) {
          final done = data['status'] == 'done';
          final archived = data['isArchived'] as bool? ?? false;
          if ((done || archived) &&
              updatedAt.isBefore(
                DateTime(current.year - 1, current.month, current.day),
              )) {
            reason = '已完成或已归档超过 12 个月';
          }
        } else if (collection == AppConfig.notesCollection) {
          final archived = data['isArchived'] as bool? ?? false;
          if (archived &&
              updatedAt.isBefore(
                DateTime(current.year - 2, current.month, current.day),
              )) {
            reason = '已归档且 24 个月未修改';
          }
        } else if (collection == AppConfig.diaryCollection) {
          final date = _date(data['date']) ?? updatedAt;
          if (date.isBefore(DateTime(current.year - 5, 1, 1))) {
            reason = '超过 5 年的日记';
          }
        }
        if (reason == null) continue;
        final normalized = BackupService.normalizeForBackup(data);
        candidates.add(
          ColdArchiveCandidate(
            collection: collection,
            id: doc.id,
            title: _title(collection, data),
            reason: reason,
            estimatedBytes: utf8.encode(jsonEncode(normalized)).length,
          ),
        );
      }
    }
    return candidates;
  }

  Future<String> archiveCandidates(List<ColdArchiveCandidate> candidates) =>
      archiveRecords(
        candidates
            .map((item) => (collection: item.collection, id: item.id))
            .toList(growable: false),
      );

  Future<String> archiveRecords(
    List<({String collection, String id})> requested,
  ) async {
    if (requested.isEmpty) throw const ColdArchiveException('没有可归档记录');
    if (requested.any(
      (item) => !allowedCollections.contains(item.collection),
    )) {
      throw const ColdArchiveException('包含不支持的归档类型');
    }
    final archiveId = const Uuid().v4();
    final now = DateTime.now();
    final records = <Map<String, dynamic>>[];
    for (final item in requested) {
      final snapshot = await _collection(item.collection).doc(item.id).get();
      final data = snapshot.data();
      if (!snapshot.exists || data == null) continue;
      if (data['isColdArchived'] as bool? ?? false) continue;
      records.add({
        'collection': item.collection,
        'id': item.id,
        'data': BackupService.normalizeForBackup(data),
      });
    }
    if (records.isEmpty) throw const ColdArchiveException('记录不存在或已归档');

    final manifestRef = _collection(
      AppConfig.archiveIndexCollection,
    ).doc('manifest_$archiveId');
    await manifestRef.set({
      'kind': 'manifest',
      'archiveId': archiveId,
      'state': 'preparing',
      'recordCount': records.length,
      'createdAt': Timestamp.fromDate(now),
    });

    String? remoteUrl;
    try {
      final bytes = buildBundleBytes(
        archiveId: archiveId,
        userId: _uid,
        records: records,
        createdAt: now,
      );
      await manifestRef.update({'state': 'uploading', 'bytes': bytes.length});
      remoteUrl = await UploadService.instance.uploadCloudFile(
        stream: Stream<List<int>>.value(bytes),
        contentLength: bytes.length,
        remoteFileName: '$archiveId.sna',
        contentType: 'application/vnd.syncnote.archive',
        folder: 'cold_archives',
      );
      await manifestRef.update({'state': 'verifying', 'remoteUrl': remoteUrl});
      final downloaded = await UploadService.instance.downloadCloudFileBytes(
        remoteUrl,
      );
      if (sha256.convert(downloaded) != sha256.convert(bytes)) {
        throw const ColdArchiveException('远端归档哈希不一致');
      }
      final verified = parseAndVerifyBundle(downloaded);
      if (verified.records.length != records.length) {
        throw const ColdArchiveException('远端归档记录数量不一致');
      }
      await manifestRef.update({'state': 'committing'});
      for (var offset = 0; offset < records.length; offset += 100) {
        final batch = _db.batch();
        for (final record in records.skip(offset).take(100)) {
          final collection = record['collection'] as String;
          final id = record['id'] as String;
          final raw = BackupService.restoreFirestoreTypes(record['data']);
          if (raw is! Map) throw const ColdArchiveException('归档记录格式无效');
          final original = raw.cast<String, dynamic>();
          final title = _title(collection, original);
          final summary = _summary(collection, original);
          final indexId = '${collection}_$id';
          batch
              .set(_collection(AppConfig.archiveIndexCollection).doc(indexId), {
                'kind': 'record',
                'id': indexId,
                'archiveId': archiveId,
                'collection': collection,
                'sourceId': id,
                'title': title,
                'summary': summary,
                'tags': original['tags'] ?? const <String>[],
                'category': original['category'] ?? '',
                'linkedNoteIds': original['linkedNoteIds'] ?? const <String>[],
                'primaryDate': _primaryDate(collection, original),
                'remoteUrl': remoteUrl,
                'archivedAt': Timestamp.fromDate(now),
              });
          batch.set(
            _collection(collection).doc(id),
            _coldStub(original, archiveId, remoteUrl, now),
          );
          batch.set(
            _collection(
              AppConfig.searchIndexCollection,
            ).doc('${_indexType(collection)}_$id'),
            {
              'isColdArchived': true,
              'archiveId': archiveId,
              'coldArchiveUrl': remoteUrl,
              'updatedAt': Timestamp.fromDate(now),
            },
            SetOptions(merge: true),
          );
        }
        await batch.commit();
      }
      await manifestRef.update({
        'state': 'cold',
        'verifiedAt': Timestamp.now(),
        'sha256': sha256.convert(bytes).toString(),
      });
      return archiveId;
    } catch (error) {
      await manifestRef.set({
        'state': 'failed',
        'error': error.toString(),
        'remoteUrl': ?remoteUrl,
        'updatedAt': Timestamp.now(),
      }, SetOptions(merge: true));
      rethrow;
    }
  }

  Future<void> restoreRecord(ColdArchiveIndexRecord record) async {
    final bytes = await UploadService.instance.downloadCloudFileBytes(
      record.remoteUrl,
    );
    final bundle = parseAndVerifyBundle(bytes);
    final archived = bundle.records.cast<Map<String, dynamic>>().firstWhere(
      (item) =>
          item['collection'] == record.collection &&
          item['id'] == record.sourceId,
      orElse: () => throw const ColdArchiveException('归档包中找不到该记录'),
    );
    final restored = BackupService.restoreFirestoreTypes(archived['data']);
    if (restored is! Map) throw const ColdArchiveException('归档正文格式无效');
    final batch = _db.batch();
    batch.set(
      _collection(record.collection).doc(record.sourceId),
      restored.cast<String, dynamic>(),
    );
    batch.delete(_collection(AppConfig.archiveIndexCollection).doc(record.id));
    batch.set(
      _collection(
        AppConfig.searchIndexCollection,
      ).doc('${_indexType(record.collection)}_${record.sourceId}'),
      {
        'isColdArchived': false,
        'archiveId': FieldValue.delete(),
        'coldArchiveUrl': FieldValue.delete(),
        'updatedAt': Timestamp.now(),
      },
      SetOptions(merge: true),
    );
    await batch.commit();

    // Keep this as a single-field query so restoring an archive never depends
    // on a separately deployed composite index. The manifest shares the same
    // archiveId, therefore only record entries count as remaining content.
    final archiveEntries = await _collection(
      AppConfig.archiveIndexCollection,
    ).where('archiveId', isEqualTo: record.archiveId).get();
    final hasRemainingRecord = archiveEntries.docs.any(
      (doc) => doc.data()['kind'] == 'record',
    );
    if (!hasRemainingRecord) {
      if (await UploadService.instance.deleteFile(record.remoteUrl)) {
        await _collection(
          AppConfig.archiveIndexCollection,
        ).doc('manifest_${record.archiveId}').delete();
      }
    }
  }

  Future<ColdArchiveTransportAudit> verifyRemoteTransport() async {
    final archiveId = 'self_test_${const Uuid().v4()}';
    final bytes = buildBundleBytes(
      archiveId: archiveId,
      userId: _uid,
      records: [
        {
          'collection': AppConfig.notesCollection,
          'id': 'self-test',
          'data': {'title': '冷归档自检', 'content': '此记录只存在于内存与临时远端自检包。'},
        },
      ],
      createdAt: DateTime.now(),
    );
    final remoteUrl = await UploadService.instance.uploadCloudFile(
      stream: Stream<List<int>>.value(bytes),
      contentLength: bytes.length,
      remoteFileName: '$archiveId.sna',
      contentType: 'application/vnd.syncnote.archive',
      folder: 'cold_archives',
    );
    try {
      final downloaded = await UploadService.instance.downloadCloudFileBytes(
        remoteUrl,
      );
      if (sha256.convert(downloaded) != sha256.convert(bytes)) {
        throw const ColdArchiveException('远端自检哈希不一致');
      }
      final bundle = parseAndVerifyBundle(downloaded);
      return ColdArchiveTransportAudit(
        archiveBytes: downloaded.length,
        recordCount: bundle.records.length,
      );
    } finally {
      await UploadService.instance.deleteFile(remoteUrl);
    }
  }

  static Uint8List buildBundleBytes({
    required String archiveId,
    required String userId,
    required List<Map<String, dynamic>> records,
    required DateTime createdAt,
  }) {
    final ndjson = records.map(jsonEncode).join('\n');
    final raw = utf8.encode(ndjson);
    final compressed = Uint8List.fromList(GZipEncoder().encode(raw));
    final attachments =
        records
            .expand(
              (record) => BackupService.collectAttachmentUrls(record['data']),
            )
            .toSet()
            .toList(growable: false)
          ..sort();
    final checksum = sha256.convert(compressed).toString();
    final manifest = <String, dynamic>{
      'archiveId': archiveId,
      'schemaVersion': 1,
      'userId': userId,
      'recordCount': records.length,
      'originalBytes': raw.length,
      'compressedBytes': compressed.length,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'minimumReaderVersion': 1,
      'recordsSha256': checksum,
    };
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))),
      )
      ..addFile(ArchiveFile.bytes('records.ndjson.gz', compressed))
      ..addFile(
        ArchiveFile.bytes(
          'checksums.json',
          utf8.encode(jsonEncode({'records.ndjson.gz': checksum})),
        ),
      )
      ..addFile(
        ArchiveFile.bytes(
          'attachments.json',
          utf8.encode(jsonEncode(attachments)),
        ),
      )
      ..addFile(
        ArchiveFile.bytes(
          'schema.json',
          utf8.encode(
            jsonEncode({'schemaVersion': 1, 'format': 'SyncNote SNA'}),
          ),
        ),
      );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static ColdArchiveBundle parseAndVerifyBundle(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    String read(String path) {
      final file = archive.findFile(path);
      if (file == null) throw ColdArchiveException('归档缺少 $path');
      return utf8.decode(file.content as List<int>);
    }

    final manifest = (jsonDecode(read('manifest.json')) as Map)
        .cast<String, dynamic>();
    final compressedFile = archive.findFile('records.ndjson.gz');
    if (compressedFile == null) {
      throw const ColdArchiveException('归档缺少 records.ndjson.gz');
    }
    final compressed = compressedFile.content as List<int>;
    final checksum = sha256.convert(compressed).toString();
    if (checksum != manifest['recordsSha256']) {
      throw const ColdArchiveException('归档记录校验失败');
    }
    final decoded = utf8.decode(GZipDecoder().decodeBytes(compressed));
    final records = decoded.trim().isEmpty
        ? <Map<String, dynamic>>[]
        : const LineSplitter()
              .convert(decoded)
              .map((line) => (jsonDecode(line) as Map).cast<String, dynamic>())
              .toList(growable: false);
    if (records.length != manifest['recordCount']) {
      throw const ColdArchiveException('归档记录数校验失败');
    }
    return ColdArchiveBundle(manifest: manifest, records: records);
  }

  static DateTime? _date(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static String _title(String collection, Map<String, dynamic> data) {
    if (collection == AppConfig.tasksCollection ||
        collection == AppConfig.notesCollection) {
      return data['title'] as String? ?? '无标题';
    }
    if (collection == AppConfig.diaryCollection) {
      return '日记 ${(_date(data['date']) ?? DateTime(1970)).toIso8601String().split('T').first}';
    }
    return '备忘录';
  }

  static String _summary(String collection, Map<String, dynamic> data) =>
      compactIndexSummary(
        collection == AppConfig.tasksCollection
            ? data['description'] as String? ?? ''
            : data['content'] as String? ?? '',
      );

  static Timestamp _primaryDate(String collection, Map<String, dynamic> data) {
    final value = collection == AppConfig.tasksCollection
        ? data['dueDate'] ?? data['createdAt']
        : collection == AppConfig.diaryCollection
        ? data['date']
        : data['createdAt'];
    return Timestamp.fromDate(_date(value) ?? DateTime(1970));
  }

  static String _indexType(String collection) => switch (collection) {
    AppConfig.tasksCollection => 'task',
    AppConfig.notesCollection => 'note',
    AppConfig.memosCollection => 'memo',
    AppConfig.diaryCollection => 'diary',
    _ => throw const ColdArchiveException('不支持的索引类型'),
  };

  static Map<String, dynamic> _coldStub(
    Map<String, dynamic> original,
    String archiveId,
    String remoteUrl,
    DateTime now,
  ) {
    final stub = Map<String, dynamic>.from(original);
    for (final key in const [
      'content',
      'description',
      'images',
      'voiceUrl',
      'voiceUrls',
    ]) {
      if (key == 'images' || key == 'voiceUrls') {
        if (stub.containsKey(key)) stub[key] = <String>[];
      } else if (key == 'voiceUrl') {
        if (stub.containsKey(key)) stub[key] = null;
      } else if (stub.containsKey(key)) {
        stub[key] = '';
      }
    }
    stub.addAll({
      'isColdArchived': true,
      'coldArchiveId': archiveId,
      'coldArchiveUrl': remoteUrl,
      'coldArchivedAt': Timestamp.fromDate(now),
    });
    return stub;
  }
}
