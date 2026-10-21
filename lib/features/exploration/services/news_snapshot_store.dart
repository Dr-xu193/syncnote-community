import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:uuid/uuid.dart';

abstract interface class NewsSnapshotBackend {
  Future<Map<String, dynamic>?> loadMetadata();

  Future<void> saveMetadata(Map<String, dynamic> data);

  Future<String> uploadSnapshot(Uint8List bytes, String remoteFileName);

  Future<Uint8List> downloadSnapshot(String webdavUrl);

  Future<void> deleteSnapshot(String webdavUrl);

  Future<bool> acquireLease({
    required String day,
    required String owner,
    required DateTime now,
    required Duration duration,
  });

  Future<void> releaseLease({required String owner, required bool failed});
}

class _ProductionNewsSnapshotBackend implements NewsSnapshotBackend {
  DocumentReference<Map<String, dynamic>>? get _stateRef {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return FirebaseFirestore.instance
        .collection(AppConfig.usersCollection)
        .doc(uid)
        .collection(AppConfig.explorationStateCollection)
        .doc('news_current');
  }

  @override
  Future<Map<String, dynamic>?> loadMetadata() {
    return FirestoreService.instance.loadExplorationState('news_current');
  }

  @override
  Future<void> saveMetadata(Map<String, dynamic> data) {
    return FirestoreService.instance.saveExplorationState('news_current', data);
  }

  @override
  Future<String> uploadSnapshot(Uint8List bytes, String remoteFileName) {
    return UploadService.instance.uploadCloudFile(
      stream: Stream<List<int>>.value(bytes),
      contentLength: bytes.length,
      remoteFileName: remoteFileName,
      contentType: 'application/gzip',
      folder: 'news',
    );
  }

  @override
  Future<Uint8List> downloadSnapshot(String webdavUrl) {
    return UploadService.instance.downloadCloudFileBytes(
      webdavUrl,
      maxBytes: 12 * 1024 * 1024,
    );
  }

  @override
  Future<void> deleteSnapshot(String webdavUrl) async {
    await UploadService.instance.deleteFile(webdavUrl);
  }

  @override
  Future<bool> acquireLease({
    required String day,
    required String owner,
    required DateTime now,
    required Duration duration,
  }) async {
    final ref = _stateRef;
    if (ref == null) return false;
    return FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      final data = snapshot.data() ?? const <String, dynamic>{};
      final expiresAt = (data['leaseExpiresAt'] as Timestamp?)?.toDate();
      final active =
          data['refreshStatus'] == 'refreshing' &&
          expiresAt != null &&
          expiresAt.isAfter(now.toUtc());
      if (active && data['leaseOwner'] != owner) return false;
      transaction.set(ref, {
        'refreshStatus': 'refreshing',
        'refreshDay': day,
        'leaseOwner': owner,
        'leaseExpiresAt': Timestamp.fromDate(now.toUtc().add(duration)),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return true;
    });
  }

  @override
  Future<void> releaseLease({
    required String owner,
    required bool failed,
  }) async {
    final ref = _stateRef;
    if (ref == null) return;
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      if (snapshot.data()?['leaseOwner'] != owner) return;
      transaction.set(ref, {
        'refreshStatus': failed ? 'failed' : 'completed',
        'leaseOwner': FieldValue.delete(),
        'leaseExpiresAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }
}

class NewsSnapshotStore {
  NewsSnapshotStore._(this._backend);

  static final NewsSnapshotStore instance = NewsSnapshotStore._(
    _ProductionNewsSnapshotBackend(),
  );

  @visibleForTesting
  NewsSnapshotStore.forTesting(NewsSnapshotBackend backend)
    : _backend = backend;

  final NewsSnapshotBackend _backend;
  static const currentSchemaVersion = 2;
  String? _memoryDay;
  List<ExplorationNewsArticle> _memoryArticles = const [];

  Future<List<ExplorationNewsArticle>> load(DateTime day) async {
    final stamp = dayStamp(day);
    if (_memoryDay == stamp && _memoryArticles.isNotEmpty) {
      return List<ExplorationNewsArticle>.from(_memoryArticles);
    }
    final metadata = await _backend.loadMetadata();
    if (metadata?['day'] != stamp ||
        metadata?['schemaVersion'] != currentSchemaVersion) {
      return const [];
    }
    final url = '${metadata?['snapshotUrl'] ?? ''}';
    final expectedHash = '${metadata?['sha256'] ?? ''}';
    if (!url.startsWith('webdav://') || expectedHash.isEmpty) return const [];
    final bytes = await _backend.downloadSnapshot(url);
    if (sha256.convert(bytes).toString() != expectedHash) {
      throw const FormatException('今日新闻快照校验失败');
    }
    final decoded = jsonDecode(utf8.decode(gzip.decode(bytes)));
    final payload = Map<String, dynamic>.from(decoded as Map);
    if (payload['day'] != stamp ||
        payload['schemaVersion'] != currentSchemaVersion) {
      throw const FormatException('新闻快照版本或日期不一致');
    }
    final articles = (payload['articles'] as List? ?? const [])
        .map(
          (item) => ExplorationNewsArticle.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .where((item) => item.id.isNotEmpty && item.title.isNotEmpty)
        .toList(growable: false);
    if (articles.length != (metadata?['articleCount'] as num?)?.toInt()) {
      throw const FormatException('新闻快照条目数量不一致');
    }
    _remember(stamp, articles);
    return List<ExplorationNewsArticle>.from(articles);
  }

  Future<void> save(List<ExplorationNewsArticle> articles, DateTime day) async {
    if (articles.isEmpty) throw ArgumentError('不能用空新闻覆盖今日快照');
    final stamp = dayStamp(day);
    final oldMetadata = await _backend.loadMetadata();
    final oldUrl = '${oldMetadata?['snapshotUrl'] ?? ''}';
    final payload = utf8.encode(
      jsonEncode({
        'schemaVersion': currentSchemaVersion,
        'day': stamp,
        'articles': articles.map((item) => item.toJson()).toList(),
      }),
    );
    final bytes = Uint8List.fromList(gzip.encode(payload));
    final hash = sha256.convert(bytes).toString();
    final remoteName = 'news_${stamp}_${const Uuid().v4()}.json.gz';
    String? uploadedUrl;
    try {
      uploadedUrl = await _backend.uploadSnapshot(bytes, remoteName);
      final roundTrip = await _backend.downloadSnapshot(uploadedUrl);
      if (sha256.convert(roundTrip).toString() != hash) {
        throw const FormatException('新闻快照上传后校验失败');
      }
      final decoded = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(gzip.decode(roundTrip))) as Map,
      );
      if (decoded['day'] != stamp ||
          (decoded['articles'] as List? ?? const []).length !=
              articles.length) {
        throw const FormatException('新闻快照上传后解析失败');
      }
      await _backend.saveMetadata({
        'day': stamp,
        'snapshotUrl': uploadedUrl,
        'sha256': hash,
        'articleCount': articles.length,
        'schemaVersion': currentSchemaVersion,
        'generatedAt': day.toUtc().toIso8601String(),
      });
      _remember(stamp, articles);
      if (oldUrl.startsWith('webdav://') && oldUrl != uploadedUrl) {
        try {
          await _backend.deleteSnapshot(oldUrl);
        } catch (_) {
          // The verified current snapshot is already committed. A stale remote
          // object can be removed by a later storage audit without data loss.
        }
      }
    } catch (_) {
      if (uploadedUrl != null && uploadedUrl != oldUrl) {
        try {
          await _backend.deleteSnapshot(uploadedUrl);
        } catch (_) {
          // Keep the original exception; orphan cleanup is best effort.
        }
      }
      rethrow;
    }
  }

  Future<String?> acquireLease(DateTime day, DateTime now) async {
    final owner = const Uuid().v4();
    final acquired = await _backend.acquireLease(
      day: dayStamp(day),
      owner: owner,
      now: now,
      duration: const Duration(minutes: 5),
    );
    return acquired ? owner : null;
  }

  Future<void> releaseLease(String owner, {required bool failed}) {
    return _backend.releaseLease(owner: owner, failed: failed);
  }

  void _remember(String day, List<ExplorationNewsArticle> articles) {
    _memoryDay = day;
    _memoryArticles = List<ExplorationNewsArticle>.unmodifiable(articles);
  }

  @visibleForTesting
  static String dayStamp(DateTime value) {
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
