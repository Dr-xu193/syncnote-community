import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';

void main() {
  group('Task completedAt rules', () {
    final createdAt = DateTime.utc(2026, 7, 1);
    final completedAt = DateTime.utc(2026, 7, 9, 12, 30);

    Task task({TaskStatus status = TaskStatus.todo, DateTime? completion}) {
      return Task(
        id: 'task-1',
        title: 'test',
        status: status,
        completedAt: completion,
        createdAt: createdAt,
        updatedAt: createdAt,
        userId: 'user-1',
      );
    }

    test('records completion time when a task becomes done', () {
      final completed = task().copyWith(
        status: TaskStatus.done,
        updatedAt: completedAt,
      );

      expect(completed.completedAt, completedAt);
      expect(completed.effectiveCompletedAt, completedAt);
    });

    test('clears completion time when a task is reopened', () {
      final reopened = task(
        status: TaskStatus.done,
        completion: completedAt,
      ).copyWith(status: TaskStatus.todo, updatedAt: completedAt);

      expect(reopened.completedAt, isNull);
      expect(reopened.effectiveCompletedAt, isNull);
    });

    test('legacy done task falls back to updatedAt', () {
      expect(task(status: TaskStatus.done).effectiveCompletedAt, createdAt);
    });
  });

  group('WebDAV attachment discovery', () {
    test('finds nested URLs and removes duplicates', () {
      final urls = FirestoreService.extractWebdavUrls({
        'images': ['webdav://images/a.jpg', 'local.jpg'],
        'nested': {
          'voice': 'webdav://voices/a.m4a',
          'again': 'webdav://images/a.jpg',
        },
        'ignored': 'https://example.com/a.jpg',
      });

      expect(urls, equals({'webdav://images/a.jpg', 'webdav://voices/a.m4a'}));
    });

    test('keeps an attachment that is still referenced elsewhere', () {
      final removable = FirestoreService.unreferencedAttachmentUrls(
        {'webdav://images/shared.jpg', 'webdav://images/orphan.jpg'},
        {'webdav://images/shared.jpg'},
      );

      expect(removable, {'webdav://images/orphan.jpg'});
    });
  });
}
