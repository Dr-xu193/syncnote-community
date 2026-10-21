import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/features/exploration/models/stock_agent_memory_models.dart';
import 'package:syncnote/features/exploration/services/stock_agent_memory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one thousand yuan state and event IDs survive retries', () async {
    final backend = _FakeMemoryBackend();
    final service = StockAgentMemoryService.forTesting(backend);
    await service.createExperiment(_experiment());
    final event = _event(0, id: 'decision-day-one', codes: ['600001']);
    final next = await service.recordEvent(
      event: event,
      nextAccount: const {'initialCash': 1000, 'cash': 900},
      nextMemory: const {
        'pinnedEventIds': ['decision-day-one'],
      },
      expectedVersion: 0,
    );
    expect(next.version, 1);
    expect(next.account['cash'], 900);
    final replay = await service.recordEvent(
      event: event,
      nextAccount: const {'initialCash': 1000, 'cash': 900},
      nextMemory: const {
        'pinnedEventIds': ['decision-day-one'],
      },
      expectedVersion: 0,
    );
    expect(replay.version, 1);
    expect(backend.events.length, 1);
    await expectLater(
      service.recordEvent(
        event: _event(
          0,
          id: 'decision-day-one',
          detail: const {'changed': true},
        ),
        nextAccount: const {'initialCash': 1000, 'cash': 800},
        nextMemory: const {},
        expectedVersion: 1,
      ),
      throwsStateError,
    );
    await expectLater(
      service.recordEvent(
        event: _event(1, id: 'wrong-capital'),
        nextAccount: const {'initialCash': 2000, 'cash': 2000},
        nextMemory: const {},
        expectedVersion: 1,
      ),
      throwsStateError,
    );
  });

  test(
    'daily JSON is verified, sealed, and never silently truncated',
    () async {
      final backend = _FakeMemoryBackend();
      final service = StockAgentMemoryService.forTesting(backend);
      await service.createExperiment(_experiment());
      await service.recordEvent(
        event: _event(0, id: 'first', codes: ['600001']),
        nextAccount: const {'initialCash': 1000, 'cash': 1000},
        nextMemory: const {
          'openHypotheses': ['观察量价'],
        },
        expectedVersion: 0,
      );
      const day = '2026-09-01';
      final first = await service.writeDay(
        experimentId: 'one-month',
        logicalDay: day,
        openingAccount: const {'cash': 1000},
        closingAccount: const {'cash': 1000},
        memoryAtClose: const {
          'openHypotheses': ['观察量价'],
        },
        seal: false,
      );
      expect(first.eventIds, ['first']);
      expect(first.codes, ['600001']);
      expect((await service.readDay('one-month', day))['events'], hasLength(1));

      final sealed = await service.writeDay(
        experimentId: 'one-month',
        logicalDay: day,
        openingAccount: const {'cash': 1000},
        closingAccount: const {'cash': 1000},
        memoryAtClose: const {
          'openHypotheses': ['观察量价'],
        },
        seal: true,
      );
      expect(sealed.sealed, isTrue);
      expect(sealed.staleArchiveUrls, isEmpty);
      expect(backend.files.keys, [sealed.archiveUrl]);
      await expectLater(
        service.writeDay(
          experimentId: 'one-month',
          logicalDay: day,
          openingAccount: const {},
          closingAccount: const {},
          memoryAtClose: const {},
          seal: false,
        ),
        throwsStateError,
      );
      backend.files[sealed.archiveUrl] = Uint8List.fromList(utf8.encode('{}'));
      await expectLater(service.readDay('one-month', day), throwsStateError);
    },
  );

  test('failed archive verification does not publish a day index', () async {
    final backend = _FakeMemoryBackend()..corruptNextDownload = true;
    final service = StockAgentMemoryService.forTesting(backend);
    await service.createExperiment(_experiment());
    await service.recordEvent(
      event: _event(0, id: 'before-failure'),
      nextAccount: const {'initialCash': 1000, 'cash': 1000},
      nextMemory: const {},
      expectedVersion: 0,
    );
    await expectLater(
      service.writeDay(
        experimentId: 'one-month',
        logicalDay: '2026-09-01',
        openingAccount: const {'cash': 1000},
        closingAccount: const {'cash': 1000},
        memoryAtClose: const {},
        seal: true,
      ),
      throwsStateError,
    );
    expect(backend.dayIndexes, isEmpty);
    expect(backend.files, isEmpty); // Failed upload is cleaned up.
    expect(backend.events, hasLength(1)); // Durable source event survives.
  });

  test('memory cannot turn an unreferenced guess into a fact', () async {
    final backend = _FakeMemoryBackend();
    final service = StockAgentMemoryService.forTesting(backend);
    await service.createExperiment(_experiment());
    await expectLater(
      service.recordEvent(
        event: _event(0, id: 'guess'),
        nextAccount: const {'initialCash': 1000, 'cash': 1000},
        nextMemory: {
          'entries': [
            {
              'id': 'untraceable',
              'kind': 'observation',
              'content': '这只股票一定会涨',
              'sourceEventIds': <String>[],
              'updatedAt': DateTime.utc(2026, 9, 1).toIso8601String(),
            },
          ],
        },
        expectedVersion: 0,
      ),
      throwsStateError,
    );
    expect(backend.events, isEmpty);
  });

  test('index-write failure preserves the last verified daily file', () async {
    final backend = _FakeMemoryBackend();
    final service = StockAgentMemoryService.forTesting(backend);
    await service.createExperiment(_experiment());
    await service.recordEvent(
      event: _event(0, id: 'first'),
      nextAccount: const {'initialCash': 1000, 'cash': 1000},
      nextMemory: const {},
      expectedVersion: 0,
    );
    final verified = await service.writeDay(
      experimentId: 'one-month',
      logicalDay: '2026-09-01',
      openingAccount: const {'cash': 1000},
      closingAccount: const {'cash': 1000},
      memoryAtClose: const {},
      seal: false,
    );
    await service.recordEvent(
      event: _event(0, id: 'second'),
      nextAccount: const {'initialCash': 1000, 'cash': 1000},
      nextMemory: const {},
      expectedVersion: 1,
    );
    backend.failNextIndexSave = true;
    await expectLater(
      service.writeDay(
        experimentId: 'one-month',
        logicalDay: '2026-09-01',
        openingAccount: const {'cash': 1000},
        closingAccount: const {'cash': 1000},
        memoryAtClose: const {},
        seal: false,
      ),
      throwsStateError,
    );
    expect(backend.files.keys, [verified.archiveUrl]);
    expect(
      (await service.readDay('one-month', '2026-09-01'))['events'],
      hasLength(1),
    );
    final repaired = await service.writeDay(
      experimentId: 'one-month',
      logicalDay: '2026-09-01',
      openingAccount: const {'cash': 1000},
      closingAccount: const {'cash': 1000},
      memoryAtClose: const {},
      seal: true,
    );
    expect(
      (await service.readDay('one-month', '2026-09-01'))['events'],
      hasLength(2),
    );
    expect(backend.files.keys, [repaired.archiveUrl]);
  });

  test('oversized event is rejected before any cloud write', () async {
    final backend = _FakeMemoryBackend();
    final service = StockAgentMemoryService.forTesting(backend);
    await service.createExperiment(_experiment());
    await expectLater(
      service.recordEvent(
        event: _event(
          0,
          id: 'oversized',
          detail: {'body': List.filled(40000, 'x').join()},
        ),
        nextAccount: const {'initialCash': 1000, 'cash': 1000},
        nextMemory: const {},
        expectedVersion: 0,
      ),
      throwsStateError,
    );
    expect(backend.events, isEmpty);
  });

  test('raw market bars cannot leak into a Firestore event', () async {
    final backend = _FakeMemoryBackend();
    final service = StockAgentMemoryService.forTesting(backend);
    await service.createExperiment(_experiment());
    await expectLater(
      service.recordEvent(
        event: _event(
          0,
          id: 'bulk',
          detail: const {
            'evidence': {
              'bars': [1, 2, 3],
            },
          },
        ),
        nextAccount: const {'initialCash': 1000, 'cash': 1000},
        nextMemory: const {},
        expectedVersion: 0,
      ),
      throwsStateError,
    );
    expect(backend.events, isEmpty);
  });

  test(
    'a past hypothesis can be found by a topic without reading all days',
    () async {
      final backend = _FakeMemoryBackend();
      final service = StockAgentMemoryService.forTesting(backend);
      await service.createExperiment(_experiment());
      for (var offset = 0; offset < 3; offset++) {
        await service.recordEvent(
          event: _event(
            offset,
            id: 'hypothesis-$offset',
            tags: offset == 0 ? ['供需逆转'] : const [],
          ),
          nextAccount: const {'initialCash': 1000, 'cash': 1000},
          nextMemory: const {},
          expectedVersion: offset,
        );
        await service.writeDay(
          experimentId: 'one-month',
          logicalDay: _date(offset),
          openingAccount: const {'cash': 1000},
          closingAccount: const {'cash': 1000},
          memoryAtClose: const {},
          seal: true,
        );
      }
      backend.dayEventReads = 0;
      final context = await service.buildContext(
        experimentId: 'one-month',
        question: '重新研究供需逆转是否成立',
        maxEvents: 5,
      );
      expect(context.sourceEventIds, contains('hypothesis-0'));
      expect(
        backend.dayEventReads,
        3,
      ); // Only two recent days plus the topic day.
    },
  );

  test(
    'day thirty can retrieve day one without loading every daily file',
    () async {
      final backend = _FakeMemoryBackend();
      final service = StockAgentMemoryService.forTesting(backend);
      await service.createExperiment(_experiment());
      var version = 0;
      for (var offset = 0; offset < 30; offset++) {
        final id = offset == 0 ? 'first-thesis' : 'day-$offset';
        await service.recordEvent(
          event: _event(offset, id: id, codes: offset == 0 ? ['600001'] : []),
          nextAccount: const {'initialCash': 1000, 'cash': 1000},
          nextMemory: const {
            'pinnedEventIds': ['first-thesis'],
          },
          expectedVersion: version,
        );
        version++;
        if (offset == 29) {
          for (var index = 0; index < 25; index++) {
            await service.recordEvent(
              event: _event(offset, id: 'recent-$index'),
              nextAccount: const {'initialCash': 1000, 'cash': 1000},
              nextMemory: const {
                'pinnedEventIds': ['first-thesis'],
              },
              expectedVersion: version,
            );
            version++;
          }
        }
        final day = _date(offset);
        await service.writeDay(
          experimentId: 'one-month',
          logicalDay: day,
          openingAccount: const {'cash': 1000},
          closingAccount: const {'cash': 1000},
          memoryAtClose: const {
            'pinnedEventIds': ['first-thesis'],
          },
          seal: true,
        );
      }
      backend.dayEventReads = 0;
      final context = await service.buildContext(
        experimentId: 'one-month',
        currentCodes: const ['600001'],
        maxEvents: 6,
      );
      expect(context.sourceEventIds, contains('first-thesis'));
      expect(context.sourceEventIds.length, lessThanOrEqualTo(6));
      expect(backend.dayEventReads, lessThan(30));
      final original = await service.readDay('one-month', '2026-09-01');
      expect((original['events'] as List).first['id'], 'first-thesis');
      await service.deleteExperiment('one-month');
      expect(backend.files, isEmpty);
      expect(backend.experiments, isEmpty);
      expect(backend.events, isEmpty);
    },
  );
}

String _date(int offset) => DateTime.utc(
  2026,
  9,
  1,
).add(Duration(days: offset)).toIso8601String().split('T').first;

StockAgentExperiment _experiment() => StockAgentExperiment(
  id: 'one-month',
  startedAt: DateTime.utc(2026, 9, 1),
  endsAt: DateTime.utc(2026, 9, 30, 16),
  version: 0,
  account: const {'initialCash': 1000, 'cash': 1000},
  memory: const {},
  updatedAt: DateTime.utc(2026, 9, 1),
);

StockAgentEvent _event(
  int offset, {
  required String id,
  List<String> codes = const [],
  List<String> tags = const [],
  Map<String, dynamic> detail = const {'reason': '按当时证据记录的判断'},
}) {
  final day = DateTime.utc(2026, 9, 1).add(Duration(days: offset));
  return StockAgentEvent(
    id: id,
    experimentId: 'one-month',
    logicalDay: _date(offset),
    kind: 'decision',
    occurredAt: day.add(const Duration(hours: 8)),
    recordedAt: day.add(const Duration(hours: 8)),
    detail: detail,
    codes: codes,
    tags: tags,
  );
}

class _FakeMemoryBackend implements StockAgentMemoryBackend {
  final experiments = <String, StockAgentExperiment>{};
  final events = <String, StockAgentEvent>{};
  final dayIndexes = <String, StockAgentDayIndex>{};
  final files = <String, Uint8List>{};
  bool corruptNextDownload = false;
  bool failNextIndexSave = false;
  int dayEventReads = 0;
  String? leaseOwner;
  DateTime? leaseUntil;

  String _key(String id, String day) => '$id/$day';

  @override
  Future<void> createExperiment(StockAgentExperiment experiment) async {
    if (experiments.containsKey(experiment.id)) {
      throw StateError('already exists');
    }
    experiments[experiment.id] = experiment;
  }

  @override
  Future<StockAgentExperiment?> loadExperiment(String id) async =>
      experiments[id];

  @override
  Future<StockAgentExperiment> setStatus(String id, String status) async {
    final current = experiments[id]!;
    final next = current.copyWith(status: status, version: current.version + 1);
    experiments[id] = next;
    return next;
  }

  @override
  Future<StockAgentExperiment> completeExperiment(
    String id,
    DateTime completedAt,
  ) async {
    final current = experiments[id]!;
    if (current.status == 'completed') return current;
    final next = current.copyWith(
      status: 'completed',
      version: current.version + 1,
      updatedAt: completedAt,
    );
    experiments[id] = next;
    return next;
  }

  @override
  Future<bool> claimRun(
    String id,
    String day,
    String owner,
    DateTime expiresAt,
  ) async {
    if (leaseOwner != null &&
        leaseOwner != owner &&
        leaseUntil?.isAfter(DateTime.now().toUtc()) == true) {
      return false;
    }
    leaseOwner = owner;
    leaseUntil = expiresAt;
    return true;
  }

  @override
  Future<void> releaseRun(String id, String owner) async {
    if (leaseOwner == owner) leaseOwner = null;
  }

  @override
  Future<StockAgentExperiment> commitEvent(
    StockAgentEvent event,
    StockAgentExperiment next, {
    required int expectedVersion,
  }) async {
    final key = '${event.experimentId}/${event.logicalDay}/${event.id}';
    final existing = events[key];
    if (existing != null) {
      if (jsonEncode(existing.toJson()) != jsonEncode(event.toJson())) {
        throw StateError('conflicting event ID');
      }
      return experiments[event.experimentId]!;
    }
    final current = experiments[event.experimentId]!;
    if (current.version != expectedVersion ||
        next.version != expectedVersion + 1) {
      throw StateError('version conflict');
    }
    if (dayIndexes[_key(event.experimentId, event.logicalDay)]?.sealed ==
        true) {
      throw StateError('sealed day');
    }
    events[key] = event;
    experiments[event.experimentId] = next;
    return next;
  }

  @override
  Future<List<StockAgentEvent>> loadDayEvents(String id, String day) async {
    dayEventReads++;
    final prefix = '$id/$day/';
    return events.entries
        .where((item) => item.key.startsWith(prefix))
        .map((item) => item.value)
        .toList(growable: false);
  }

  @override
  Future<StockAgentDayIndex?> loadDayIndex(String id, String day) async =>
      dayIndexes[_key(id, day)];

  @override
  Future<List<StockAgentDayIndex>> loadDayIndexes(String id) async => dayIndexes
      .entries
      .where((item) => item.key.startsWith('$id/'))
      .map((item) => item.value)
      .toList(growable: false);

  @override
  Future<void> saveDayIndex(StockAgentDayIndex index) async {
    if (failNextIndexSave) {
      failNextIndexSave = false;
      throw StateError('simulated Firestore failure');
    }
    final key = _key(index.experimentId, index.logicalDay);
    final existing = dayIndexes[key];
    if (existing?.sealed == true && existing?.sha256 != index.sha256) {
      throw StateError('sealed day cannot change');
    }
    if ((await loadDayEvents(index.experimentId, index.logicalDay)).length !=
        index.eventIds.length) {
      throw StateError('event race');
    }
    dayIndexes[key] = index;
  }

  @override
  Future<String> uploadDay(Uint8List bytes, String remoteName) async {
    final url = 'webdav://stock_agent_days/$remoteName';
    files[url] = Uint8List.fromList(bytes);
    return url;
  }

  @override
  Future<Uint8List> downloadDay(String url) async {
    if (corruptNextDownload) {
      corruptNextDownload = false;
      return Uint8List.fromList(utf8.encode('corrupted'));
    }
    return files[url]!;
  }

  @override
  Future<void> deleteDay(String url) async {
    files.remove(url);
  }

  @override
  Future<void> deleteExperimentData(String id) async {
    events.removeWhere((key, _) => key.startsWith('$id/'));
    dayIndexes.removeWhere((key, _) => key.startsWith('$id/'));
    experiments.remove(id);
  }
}
