import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/services/backup_service.dart';

void main() {
  test('backup timestamp normalization round-trips to Firestore Timestamp', () {
    final timestamp = Timestamp.fromDate(DateTime.utc(2026, 7, 10, 1, 2, 3));
    final normalized = BackupService.normalizeForBackup({
      'createdAt': timestamp,
      'items': [timestamp],
    });

    final restored = BackupService.restoreFirestoreTypes(normalized) as Map;
    expect(restored['createdAt'], isA<Timestamp>());
    expect(
      (restored['createdAt'] as Timestamp).millisecondsSinceEpoch,
      timestamp.millisecondsSinceEpoch,
    );
    expect((restored['items'] as List).single, isA<Timestamp>());
  });

  test(
    'backup collects webdav attachments and creates stable archive paths',
    () {
      final data = {
        'images': ['webdav://notes/a.png', 'webdav://notes/a.png'],
        'nested': {
          'voiceUrls': ['webdav://voice/clip.m4a'],
        },
      };

      expect(BackupService.collectAttachmentUrls(data), {
        'webdav://notes/a.png',
        'webdav://voice/clip.m4a',
      });
      expect(
        BackupService.attachmentArchivePath('webdav://notes/a.png'),
        'attachments/webdav/notes/a.png',
      );
    },
  );

  test('backup rewrites attachment and document references recursively', () {
    final rewritten =
        BackupService.rewriteStringRefs(
              {
                'id': 'note-a',
                'linkedNoteIds': ['note-b'],
                'snapshot': {
                  'images': ['webdav://notes/a.png'],
                },
              },
              {
                'note-a': 'note-a-copy',
                'note-b': 'note-b-copy',
                'webdav://notes/a.png': 'webdav://notes/restored.png',
              },
            )
            as Map;

    expect(rewritten['id'], 'note-a-copy');
    expect(rewritten['linkedNoteIds'], ['note-b-copy']);
    expect((rewritten['snapshot'] as Map)['images'], [
      'webdav://notes/restored.png',
    ]);
  });

  test('stock agent backup keeps day archive URLs and restores paused', () {
    final raw = {
      'stockAgentExperiments': [
        {
          'id': 'ai-paper-1000-first-month',
          'status': 'active',
          'runLease': {'owner': 'old-computer'},
        },
      ],
      'stockAgentDays': [
        {
          'experimentId': 'ai-paper-1000-first-month',
          'logicalDay': '2026-09-26',
          'archiveUrl': 'webdav://stock_agent_days/day.json',
        },
      ],
    };
    expect(BackupService.collectAttachmentUrls(raw), {
      'webdav://stock_agent_days/day.json',
    });
    final restored = BackupService.prepareStockAgentExperimentForRestore(
      Map<String, dynamic>.from(
        (raw['stockAgentExperiments'] as List).single as Map,
      ),
    );
    expect(restored['status'], 'paused');
    expect(restored, isNot(contains('runLease')));
  });

  test('copy import maps only conflicting root document ids', () {
    final idMap = BackupService.generateCopyIdMap(
      rootData: {
        'notes': [
          {'id': 'existing-note'},
          {'id': 'new-note'},
        ],
        'tasks': [
          {'id': 'existing-task'},
        ],
      },
      existingIds: {
        'notes': {'existing-note'},
        'tasks': <String>{},
      },
    );

    expect(idMap.keys, {'existing-note'});
    expect(idMap['existing-note'], isNot('existing-note'));
    expect(idMap.containsKey('new-note'), isFalse);
    expect(idMap.containsKey('existing-task'), isFalse);
  });

  test(
    'backup preview reads manifest counts and validates format metadata',
    () {
      void addJson(Archive archive, String path, Object value) {
        final bytes = utf8.encode(const JsonEncoder().convert(value));
        archive.addFile(ArchiveFile.bytes(path, bytes));
      }

      final archive = Archive();
      addJson(archive, 'manifest.json', {
        'formatVersion': BackupService.formatVersion,
        'exportedAt': '2026-07-10T12:00:00.000Z',
        'userId': 'source-user',
        'counts': {
          'tasks': 2,
          'notes': 3,
          'diaries': 1,
          'memos': 4,
          'noteVersions': 5,
          'aiChats': 1,
          'aiMessages': 6,
          'attachments': 2,
        },
        'attachments': [
          {'sourceUrl': 'webdav://notes/a.png', 'size': 100},
          {'sourceUrl': 'webdav://voice/a.m4a', 'size': 250},
        ],
      });

      final preview = BackupService.previewBackupZip(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );

      expect(preview.userId, 'source-user');
      expect(preview.counts['notes'], 3);
      expect(preview.attachmentCount, 2);
      expect(preview.attachmentBytes, 350);
      expect(preview.totalDocuments, 24);
    },
  );

  test(
    'note revision defaults for legacy data and serializes for conflicts',
    () {
      final now = DateTime.utc(2026, 7, 10);
      final legacy = Note.fromJson({
        'id': 'n1',
        'title': 'legacy',
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
        'userId': 'u1',
      });

      expect(legacy.revision, 0);
      expect(legacy.copyWith(revision: 3).toJson()['revision'], 3);
    },
  );
}
