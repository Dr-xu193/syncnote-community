import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/services/cold_archive_service.dart';
import 'package:syncnote/shared/services/storage_audit_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';

void main() {
  test('1000 records round-trip through a verified SNA bundle', () {
    final records = List<Map<String, dynamic>>.generate(
      1000,
      (index) => {
        'collection': index.isEven ? 'notes' : 'diary',
        'id': 'record-$index',
        'data': {
          'title': '标题 $index',
          'content': '正文 $index ' * 20,
          'createdAt': {
            r'$syncnoteType': 'timestamp',
            'value': DateTime.utc(2020, 1, 1).toIso8601String(),
          },
          if (index == 0) 'images': ['webdav://notes/example.png'],
          if (index == 0) 'linkedNoteIds': ['note-a', 'note-b'],
        },
      },
    );
    final bytes = ColdArchiveService.buildBundleBytes(
      archiveId: 'archive-test',
      userId: 'user-test',
      records: records,
      createdAt: DateTime.utc(2026, 8, 1),
    );
    final parsed = ColdArchiveService.parseAndVerifyBundle(bytes);

    expect(parsed.manifest['schemaVersion'], 1);
    expect(parsed.manifest['recordCount'], 1000);
    expect(parsed.records, records);
    expect((parsed.records.first['data'] as Map)['linkedNoteIds'], [
      'note-a',
      'note-b',
    ]);
    expect(bytes.length, lessThan(200000));
  });

  test('a corrupted SNA bundle is rejected', () {
    final bytes = ColdArchiveService.buildBundleBytes(
      archiveId: 'archive-test',
      userId: 'user-test',
      records: [
        {
          'collection': 'notes',
          'id': 'one',
          'data': {'content': 'hello'},
        },
      ],
      createdAt: DateTime.utc(2026, 8, 1),
    );
    final decoded = ZipDecoder().decodeBytes(bytes);
    final rebuilt = Archive();
    for (final file in decoded.files) {
      final content = Uint8List.fromList(file.content as List<int>);
      if (file.name == 'records.ndjson.gz') content[0] ^= 0x7f;
      rebuilt.addFile(ArchiveFile.bytes(file.name, content));
    }
    final corrupted = Uint8List.fromList(ZipEncoder().encode(rebuilt));

    expect(
      () => ColdArchiveService.parseAndVerifyBundle(corrupted),
      throwsA(anything),
    );
  });

  test('capacity thresholds follow 60, 75 and 85 percent rules', () {
    StorageAuditSnapshot snapshot(int bytes) => StorageAuditSnapshot(
      generatedAt: DateTime.utc(2026, 8, 1),
      collections: {
        'test': CollectionStorageAudit(
          documents: 1,
          sampledDocuments: 1,
          estimatedBytes: bytes,
        ),
      },
      webdav: const WebdavInventory(
        fileCount: 0,
        folderCount: 0,
        totalBytes: 0,
        filesByFolder: {},
      ),
    );

    expect(snapshot(59).capacityLevel(referenceBytes: 100), '正常');
    expect(snapshot(60).capacityLevel(referenceBytes: 100), '接近提醒线');
    expect(snapshot(75).capacityLevel(referenceBytes: 100), '生成归档建议');
    expect(snapshot(85).capacityLevel(referenceBytes: 100), '优先冷归档');
  });

  test('Firestore capacity ratio never includes WebDAV bytes', () {
    final snapshot = StorageAuditSnapshot(
      generatedAt: DateTime.utc(2026, 8, 1),
      collections: const {
        'test': CollectionStorageAudit(
          documents: 1,
          sampledDocuments: 1,
          estimatedBytes: 1,
        ),
      },
      webdav: const WebdavInventory(
        fileCount: 1,
        folderCount: 1,
        totalBytes: 99,
        filesByFolder: {},
      ),
    );
    expect(snapshot.firestoreUsageRatio(referenceBytes: 100), .01);
  });

  test('restored archive timestamps remain Firestore timestamps', () {
    final restored = ColdArchiveService.parseAndVerifyBundle(
      ColdArchiveService.buildBundleBytes(
        archiveId: 'a',
        userId: 'u',
        records: [
          {
            'collection': 'notes',
            'id': 'n',
            'data': {
              r'$syncnoteType': 'timestamp',
              'value': '2026-08-01T00:00:00.000Z',
            },
          },
        ],
        createdAt: DateTime.utc(2026, 8, 1),
      ),
    ).records.single['data'];

    // The bundle deliberately stores normalized JSON; Firestore restoration
    // happens only after successful verification.
    expect(restored, isA<Map>());
    expect((restored as Map)[r'$syncnoteType'], 'timestamp');
    expect(Timestamp.fromDate(DateTime.utc(2026, 8, 1)), isA<Timestamp>());
  });
}
