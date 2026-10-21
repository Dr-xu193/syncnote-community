import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/shared/services/upload_service.dart';

/// The event and current-state write is atomic inside Firestore. WebDAV is a
/// verified, retryable daily projection, never the live account transaction.
abstract interface class StockAgentMemoryBackend {
  Future<void> createExperiment(StockAgentExperiment experiment);

  Future<StockAgentExperiment?> loadExperiment(String id);

  Future<StockAgentExperiment> setStatus(String id, String status);

  Future<StockAgentExperiment> completeExperiment(
    String id,
    DateTime completedAt,
  );

  Future<bool> claimRun(
    String id,
    String day,
    String owner,
    DateTime expiresAt,
  );

  Future<void> releaseRun(String id, String owner);

  Future<StockAgentExperiment> commitEvent(
    StockAgentEvent event,
    StockAgentExperiment next, {
    required int expectedVersion,
  });

  Future<List<StockAgentEvent>> loadDayEvents(String id, String day);

  Future<StockAgentDayIndex?> loadDayIndex(String id, String day);

  Future<List<StockAgentDayIndex>> loadDayIndexes(String id);

  Future<void> saveDayIndex(StockAgentDayIndex index);

  Future<String> uploadDay(Uint8List bytes, String remoteName);

  Future<Uint8List> downloadDay(String url);

  Future<void> deleteDay(String url);

  Future<void> deleteExperimentData(String id);
}

class _ProductionStockAgentMemoryBackend implements StockAgentMemoryBackend {
  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _experiments {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('请先登录');
    return _firestore
        .collection(AppConfig.usersCollection)
        .doc(uid)
        .collection(AppConfig.stockAgentExperimentsCollection);
  }

  DocumentReference<Map<String, dynamic>> _experiment(String id) =>
      _experiments.doc(id);

  DocumentReference<Map<String, dynamic>> _day(String id, String day) =>
      _experiment(id).collection('days').doc(day);

  @override
  Future<void> createExperiment(StockAgentExperiment experiment) =>
      _firestore.runTransaction((transaction) async {
        final ref = _experiment(experiment.id);
        if ((await transaction.get(ref)).exists) {
          throw StateError('该股票实验已存在');
        }
        transaction.set(ref, experiment.toJson());
      });

  @override
  Future<StockAgentExperiment?> loadExperiment(String id) async {
    final data = (await _experiment(id).get()).data();
    return data == null ? null : StockAgentExperiment.fromJson(data);
  }

  @override
  Future<StockAgentExperiment> setStatus(String id, String status) =>
      _firestore.runTransaction((transaction) async {
        final ref = _experiment(id);
        final snapshot = await transaction.get(ref);
        final data = snapshot.data();
        if (data == null) throw StateError('股票实验不存在');
        final current = StockAgentExperiment.fromJson(data);
        if (current.status == 'completed') throw StateError('已结束实验不可重新启动');
        if (!{'active', 'paused'}.contains(status)) {
          throw StateError('股票实验状态无效');
        }
        final next = current.copyWith(
          status: status,
          version: current.version + 1,
          updatedAt: DateTime.now().toUtc(),
        );
        next.validate();
        transaction.set(ref, next.toJson());
        return next;
      });

  @override
  Future<StockAgentExperiment> completeExperiment(
    String id,
    DateTime completedAt,
  ) => _firestore.runTransaction((transaction) async {
    final ref = _experiment(id);
    final snapshot = await transaction.get(ref);
    final data = snapshot.data();
    if (data == null) throw StateError('股票实验不存在');
    final current = StockAgentExperiment.fromJson(data);
    if (current.status == 'completed') return current;
    if (completedAt.toUtc().isBefore(current.endsAt)) {
      throw StateError('30 天尚未结束');
    }
    final next = current.copyWith(
      status: 'completed',
      version: current.version + 1,
      updatedAt: completedAt.toUtc(),
    );
    next.validate();
    transaction.set(ref, next.toJson());
    return next;
  });

  @override
  Future<bool> claimRun(
    String id,
    String day,
    String owner,
    DateTime expiresAt,
  ) => _firestore.runTransaction((transaction) async {
    final ref = _experiment(id);
    final snapshot = await transaction.get(ref);
    final data = snapshot.data();
    if (data == null ||
        (data['status'] != 'active' &&
            !(day == 'final' && data['status'] == 'paused'))) {
      return false;
    }
    final lease = Map<String, dynamic>.from(
      data['runLease'] as Map? ?? const {},
    );
    final oldExpiry = DateTime.tryParse('${lease['expiresAt'] ?? ''}');
    if (lease['owner'] != owner &&
        oldExpiry != null &&
        oldExpiry.isAfter(DateTime.now().toUtc())) {
      return false;
    }
    transaction.set(ref, {
      'runLease': {
        'day': day,
        'owner': owner,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      },
    }, SetOptions(merge: true));
    return true;
  });

  @override
  Future<void> releaseRun(String id, String owner) =>
      _firestore.runTransaction((transaction) async {
        final ref = _experiment(id);
        final snapshot = await transaction.get(ref);
        if (snapshot.data()?['runLease'] is Map &&
            (snapshot.data()!['runLease'] as Map)['owner'] == owner) {
          transaction.update(ref, {'runLease': FieldValue.delete()});
        }
      });

  @override
  Future<StockAgentExperiment> commitEvent(
    StockAgentEvent event,
    StockAgentExperiment next, {
    required int expectedVersion,
  }) => _firestore.runTransaction((transaction) async {
    final experimentRef = _experiment(event.experimentId);
    final dayRef = _day(event.experimentId, event.logicalDay);
    final eventRef = dayRef.collection('events').doc(event.id);
    final experimentSnap = await transaction.get(experimentRef);
    final daySnap = await transaction.get(dayRef);
    final eventSnap = await transaction.get(eventRef);
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode(event.toJson())))
        .toString();
    final currentData = experimentSnap.data();
    if (currentData == null) throw StateError('股票实验不存在');
    final current = StockAgentExperiment.fromJson(currentData);
    if (eventSnap.exists) {
      if (eventSnap.data()?['contentHash'] != fingerprint) {
        throw StateError('同一事件 ID 的内容不一致');
      }
      return current; // A retry must never create a second trade.
    }
    if (daySnap.data()?['sealed'] == true) {
      throw StateError('该日记已封存，不能追加历史事件');
    }
    if (current.version != expectedVersion ||
        next.version != expectedVersion + 1) {
      throw StateError('股票实验状态版本冲突，请重新读取');
    }
    if (current.status != 'active' &&
        !(event.kind == 'missed_cycle' && current.status == 'paused')) {
      throw StateError('股票实验未处于运行状态');
    }
    transaction.set(eventRef, {...event.toJson(), 'contentHash': fingerprint});
    transaction.set(dayRef, {
      'experimentId': event.experimentId,
      'logicalDay': event.logicalDay,
      'updatedAt': event.recordedAt.toUtc().toIso8601String(),
      'eventCount': ((daySnap.data()?['eventCount'] as num?)?.toInt() ?? 0) + 1,
    }, SetOptions(merge: true));
    transaction.set(experimentRef, {
      ...next.toJson(),
      if (currentData['runLease'] != null) 'runLease': currentData['runLease'],
    });
    return next;
  });

  @override
  Future<List<StockAgentEvent>> loadDayEvents(String id, String day) async {
    final snapshot = await _day(id, day).collection('events').get();
    final values = snapshot.docs
        .map((doc) => StockAgentEvent.fromJson(doc.data()))
        .toList();
    values.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    return values;
  }

  @override
  Future<StockAgentDayIndex?> loadDayIndex(String id, String day) async {
    final data = (await _day(id, day).get()).data();
    return data == null ? null : StockAgentDayIndex.fromJson(data);
  }

  @override
  Future<List<StockAgentDayIndex>> loadDayIndexes(String id) async {
    final snapshot = await _experiment(id).collection('days').get();
    final values = snapshot.docs
        .map((doc) => StockAgentDayIndex.fromJson(doc.data()))
        .toList();
    values.sort((a, b) => a.logicalDay.compareTo(b.logicalDay));
    return values;
  }

  @override
  Future<void> saveDayIndex(StockAgentDayIndex index) =>
      _firestore.runTransaction((transaction) async {
        final ref = _day(index.experimentId, index.logicalDay);
        final snapshot = await transaction.get(ref);
        final existing = snapshot.data();
        if ((existing?['eventCount'] as num?)?.toInt() !=
            index.eventIds.length) {
          throw StateError('日记上传期间事件发生变化，请重新生成');
        }
        if (existing?['sealed'] == true &&
            (existing?['sha256'] != index.sha256 || !index.sealed)) {
          throw StateError('已封存日记不可覆盖');
        }
        transaction.set(ref, index.toJson());
      });

  @override
  Future<String> uploadDay(Uint8List bytes, String remoteName) =>
      UploadService.instance.uploadCloudFile(
        stream: Stream<List<int>>.value(bytes),
        contentLength: bytes.length,
        remoteFileName: remoteName,
        contentType: 'application/json; charset=utf-8',
        folder: 'stock_agent_days',
      );

  @override
  Future<Uint8List> downloadDay(String url) => UploadService.instance
      .downloadCloudFileBytes(url, maxBytes: 4 * 1024 * 1024);

  @override
  Future<void> deleteDay(String url) async {
    if (await UploadService.instance.deleteFile(url)) return;
    try {
      await UploadService.instance.downloadCloudFileBytes(url, maxBytes: 1);
    } catch (error) {
      if ('$error'.contains('HTTP 404')) return;
      throw StateError('坚果云股票日记删除后状态无法确认：$error');
    }
    throw StateError('坚果云股票日记仍然存在，删除失败');
  }

  @override
  Future<void> deleteExperimentData(String id) async {
    for (final report in (await _experiment(
      id,
    ).collection('reports').get()).docs) {
      final url = '${report.data()['archiveUrl'] ?? ''}';
      if (url.isNotEmpty) await deleteDay(url);
      await report.reference.delete();
    }
    for (final day in (await _experiment(id).collection('days').get()).docs) {
      for (final event
          in (await day.reference.collection('events').get()).docs) {
        await event.reference.delete();
      }
      await day.reference.delete();
    }
    await _experiment(id).delete();
  }
}

class StockAgentMemoryService {
  StockAgentMemoryService._(this._backend);

  static final StockAgentMemoryService instance = StockAgentMemoryService._(
    _ProductionStockAgentMemoryBackend(),
  );

  StockAgentMemoryService.forTesting(StockAgentMemoryBackend backend)
    : _backend = backend;

  final StockAgentMemoryBackend _backend;

  Future<StockAgentExperiment?> loadExperiment(String id) =>
      _backend.loadExperiment(id);

  Future<StockAgentExperiment> setStatus(String id, String status) =>
      _backend.setStatus(id, status);

  Future<StockAgentExperiment> completeExperiment(
    String id,
    DateTime completedAt,
  ) => _backend.completeExperiment(id, completedAt);

  Future<bool> claimRun(
    String id,
    String day,
    String owner,
    DateTime expiresAt,
  ) => _backend.claimRun(id, day, owner, expiresAt);

  Future<void> releaseRun(String id, String owner) =>
      _backend.releaseRun(id, owner);

  Future<List<StockAgentEvent>> loadDayEvents(String id, String day) =>
      _backend.loadDayEvents(id, day);

  Future<StockAgentDayIndex?> loadDayIndex(String id, String day) =>
      _backend.loadDayIndex(id, day);

  Future<List<StockAgentDayIndex>> loadDayIndexes(String id) =>
      _backend.loadDayIndexes(id);

  Future<void> createExperiment(StockAgentExperiment experiment) async {
    experiment.validate();
    if (experiment.version != 0 || experiment.status != 'active') {
      throw StateError('新实验必须从活动状态与版本 0 开始');
    }
    await _backend.createExperiment(experiment);
  }

  Future<StockAgentExperiment> recordEvent({
    required StockAgentEvent event,
    required Map<String, dynamic> nextAccount,
    required Map<String, dynamic> nextMemory,
    required int expectedVersion,
  }) async {
    event.validate();
    final current = await _backend.loadExperiment(event.experimentId);
    if (current == null) throw StateError('股票实验不存在');
    final delayedMissed =
        event.kind == 'missed_cycle' && event.detail['delayedRecovery'] == true;
    final firstDay = current.startedAt
        .toUtc()
        .add(const Duration(hours: 8))
        .toIso8601String()
        .split('T')
        .first;
    final endDay = current.endsAt
        .toUtc()
        .add(const Duration(hours: 8))
        .toIso8601String()
        .split('T')
        .first;
    if (event.recordedAt.isBefore(current.startedAt) ||
        (!event.recordedAt.isBefore(current.endsAt) && !delayedMissed) ||
        event.logicalDay.compareTo(firstDay) < 0 ||
        event.logicalDay.compareTo(endDay) >= 0) {
      throw StateError('事件不在 30 天实验期间');
    }
    final next = current.copyWith(
      version: expectedVersion + 1,
      account: nextAccount,
      memory: nextMemory,
      updatedAt: event.recordedAt,
    );
    next.validate();
    return _backend.commitEvent(event, next, expectedVersion: expectedVersion);
  }

  Future<StockAgentDayIndex> writeDay({
    required String experimentId,
    required String logicalDay,
    required Map<String, dynamic> openingAccount,
    required Map<String, dynamic> closingAccount,
    required Map<String, dynamic> memoryAtClose,
    required bool seal,
  }) async {
    final experiment = await _backend.loadExperiment(experimentId);
    if (experiment == null) throw StateError('股票实验不存在');
    final firstDay = experiment.startedAt
        .toUtc()
        .add(const Duration(hours: 8))
        .toIso8601String()
        .split('T')
        .first;
    final endDay = experiment.endsAt
        .toUtc()
        .add(const Duration(hours: 8))
        .toIso8601String()
        .split('T')
        .first;
    if (logicalDay.compareTo(firstDay) < 0 ||
        logicalDay.compareTo(endDay) >= 0) {
      throw StateError('日记日期不在 30 天实验期间');
    }
    final previous = await _backend.loadDayIndex(experimentId, logicalDay);
    if (previous?.sealed == true) {
      throw StateError('该日记已封存，不能改写');
    }
    final events = await _backend.loadDayEvents(experimentId, logicalDay);
    events.sort((a, b) {
      final byTime = a.recordedAt.compareTo(b.recordedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    for (final event in events) {
      event.validate();
      if (event.experimentId != experimentId ||
          event.logicalDay != logicalDay) {
        throw StateError('日记包含其他实验或日期的事件');
      }
    }
    final ids = events.map((item) => item.id).toList(growable: false);
    if (ids.length != ids.toSet().length) throw StateError('日记事件 ID 重复');
    if (seal && events.isEmpty) throw StateError('不能封存空白日记');
    final codes = events.expand((item) => item.codes).toSet().toList()..sort();
    final tags = events.expand((item) => item.tags).toSet().toList()..sort();
    final body = {
      'schemaVersion': 1,
      'experimentId': experimentId,
      'logicalDay': logicalDay,
      'openingAccount': openingAccount,
      'events': events.map((item) => item.toJson()).toList(growable: false),
      'closingAccount': closingAccount,
      'memoryAtClose': memoryAtClose,
      'sealed': seal,
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    if (bytes.length > 4 * 1024 * 1024) {
      throw StateError('当日日记超过 4 MB：不截断原文，请先调整重复证据');
    }
    final digest = sha256.convert(bytes).toString();
    final safeId = experimentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final remoteName = 'agent-$safeId-$logicalDay-$digest.json';
    String? uploaded;
    try {
      uploaded = await _backend.uploadDay(bytes, remoteName);
      final verified = await _backend.downloadDay(uploaded);
      if (sha256.convert(verified).toString() != digest) {
        throw StateError('坚果云日记上传后哈希校验失败');
      }
      final stale = <String>{...?previous?.staleArchiveUrls};
      if (previous != null &&
          previous.archiveUrl.isNotEmpty &&
          previous.archiveUrl != uploaded) {
        stale.add(previous.archiveUrl);
      }
      final index = StockAgentDayIndex(
        experimentId: experimentId,
        logicalDay: logicalDay,
        archiveUrl: uploaded,
        sha256: digest,
        byteLength: bytes.length,
        sealed: seal,
        codes: codes,
        tags: tags,
        eventIds: ids,
        updatedAt: DateTime.now().toUtc(),
        staleArchiveUrls: stale.toList()..sort(),
      );
      index.validate();
      await _backend.saveDayIndex(index);
      final remaining = <String>[];
      for (final oldUrl in index.staleArchiveUrls) {
        try {
          await _backend.deleteDay(oldUrl);
        } catch (_) {
          remaining.add(oldUrl);
        }
      }
      if (remaining.length == index.staleArchiveUrls.length) return index;
      final cleaned = index.copyWith(staleArchiveUrls: remaining);
      try {
        await _backend.saveDayIndex(cleaned);
        return cleaned;
      } catch (_) {
        // The verified current URL is already committed. Its stale-URL list
        // remains in Firestore so the next update or whole-experiment delete
        // can retry cleanup.
        return index;
      }
    } catch (_) {
      if (uploaded != null && uploaded != previous?.archiveUrl) {
        try {
          await _backend.deleteDay(uploaded);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> readDay(String experimentId, String day) async {
    final index = await _backend.loadDayIndex(experimentId, day);
    if (index == null || index.archiveUrl.isEmpty) {
      throw StateError('该日期尚无已保存的云端日记');
    }
    final bytes = await _backend.downloadDay(index.archiveUrl);
    if (bytes.length != index.byteLength ||
        sha256.convert(bytes).toString() != index.sha256) {
      throw StateError('股票日记内容或 SHA-256 校验失败');
    }
    final data = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    if (data['experimentId'] != experimentId || data['logicalDay'] != day) {
      throw StateError('股票日记身份与云端索引不一致');
    }
    return data;
  }

  Future<StockAgentMemoryContext> buildContext({
    required String experimentId,
    List<String> currentCodes = const [],
    String question = '',
    int maxEvents = 18,
    int maxEventBytes = 64 * 1024,
  }) async {
    if (maxEvents < 1 || maxEvents > 100) {
      throw ArgumentError.value(maxEvents, 'maxEvents', 'must be 1 to 100');
    }
    if (maxEventBytes < 32 * 1024 || maxEventBytes > 256 * 1024) {
      throw ArgumentError.value(
        maxEventBytes,
        'maxEventBytes',
        'must be 32–256 KiB',
      );
    }
    final experiment = await _backend.loadExperiment(experimentId);
    if (experiment == null) throw StateError('股票实验不存在');
    final indexes = await _backend.loadDayIndexes(experimentId);
    indexes.sort((a, b) => b.logicalDay.compareTo(a.logicalDay));
    final recentDays = indexes.take(2).map((item) => item.logicalDay).toSet();
    final pinned = List<String>.from(
      experiment.memory['pinnedEventIds'] as List? ?? const [],
    ).toSet();
    final codeSet = currentCodes.toSet();
    final query = question.trim().toLowerCase();
    final selectedDays = <String>{...recentDays};
    for (final index in indexes) {
      if (index.codes.any(codeSet.contains) ||
          index.eventIds.any(pinned.contains) ||
          (query.isNotEmpty &&
              index.tags.any((tag) => query.contains(tag.toLowerCase()))) ||
          (question.contains('第一天') && index == indexes.last)) {
        selectedDays.add(index.logicalDay);
      }
    }
    final recent = <StockAgentEvent>[];
    final relevant = <StockAgentEvent>[];
    for (final day in selectedDays) {
      final events = await _backend.loadDayEvents(experimentId, day);
      for (final event in events) {
        if (recentDays.contains(day)) {
          recent.add(event);
        } else if (event.codes.any(codeSet.contains) ||
            pinned.contains(event.id) ||
            (query.isNotEmpty &&
                event.tags.any((tag) => query.contains(tag.toLowerCase()))) ||
            (question.contains('第一天') && day == indexes.last.logicalDay)) {
          relevant.add(event);
        }
      }
    }
    recent.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    relevant.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    final candidates = [
      ...relevant.where((item) => pinned.contains(item.id)),
      ...recent,
      ...relevant.where((item) => !pinned.contains(item.id)),
    ];
    final chosen = <StockAgentEvent>[];
    var usedBytes = 0;
    for (final event in candidates) {
      if (chosen.length >= maxEvents) break;
      final bytes = utf8.encode(jsonEncode(event.toJson())).length;
      if (usedBytes + bytes > maxEventBytes) continue;
      chosen.add(event);
      usedBytes += bytes;
    }
    final recentBounded = chosen
        .where((item) => recentDays.contains(item.logicalDay))
        .toList(growable: false);
    final relevantBounded = chosen
        .where((item) => !recentDays.contains(item.logicalDay))
        .toList(growable: false);
    return StockAgentMemoryContext(
      experiment: experiment,
      recent: recentBounded,
      relevant: relevantBounded,
      sourceEventIds: [
        ...recentBounded.map((item) => item.id),
        ...relevantBounded.map((item) => item.id),
      ],
    );
  }

  Future<void> deleteExperiment(String experimentId) async {
    final indexes = await _backend.loadDayIndexes(experimentId);
    for (final index in indexes) {
      if (index.archiveUrl.isNotEmpty) {
        await _backend.deleteDay(index.archiveUrl);
      }
      for (final stale in index.staleArchiveUrls) {
        await _backend.deleteDay(stale);
      }
    }
    await _backend.deleteExperimentData(experimentId);
  }
}
