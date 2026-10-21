import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/notification_service.dart';

Task _task({
  String id = 'task-a',
  DateTime? dueDate,
  List<DateTime> reminders = const [],
  bool recurring = false,
  RecurrenceType recurrence = RecurrenceType.none,
}) {
  final now = DateTime(2026, 1, 1);
  return Task(
    id: id,
    title: 'test',
    dueDate: dueDate,
    reminderTimes: reminders,
    isRecurring: recurring,
    recurrenceType: recurrence,
    createdAt: now,
    updatedAt: now,
    userId: 'user-a',
  );
}

void main() {
  group('task recurrence rules', () {
    test('daily and weekly recurrence keep the wall-clock time', () {
      final due = DateTime(2026, 7, 9, 8, 30);

      expect(
        _task(
          dueDate: due,
          recurring: true,
          recurrence: RecurrenceType.daily,
        ).nextRecurrenceDueDate(),
        DateTime(2026, 7, 10, 8, 30),
      );
      expect(
        _task(
          dueDate: due,
          recurring: true,
          recurrence: RecurrenceType.weekly,
        ).nextRecurrenceDueDate(),
        DateTime(2026, 7, 16, 8, 30),
      );
    });

    test('monthly recurrence clamps to the last valid day', () {
      final task = _task(
        dueDate: DateTime(2026, 1, 31, 9),
        recurring: true,
        recurrence: RecurrenceType.monthly,
      );

      expect(task.nextRecurrenceDueDate(), DateTime(2026, 2, 28, 9));
    });

    test('recurrence occurrence IDs are deterministic', () {
      final due = DateTime.utc(2026, 7, 10, 8);
      expect(
        FirestoreService.recurrenceOccurrenceId('series-a', due),
        FirestoreService.recurrenceOccurrenceId('series-a', due),
      );
      expect(
        FirestoreService.recurrenceOccurrenceId('series-a', due),
        isNot(
          FirestoreService.recurrenceOccurrenceId(
            'series-a',
            due.add(const Duration(days: 1)),
          ),
        ),
      );
    });
  });

  group('task reminder rules', () {
    test('legacy task falls back to due date as its only reminder', () {
      final due = DateTime(2026, 7, 10, 10);
      expect(_task(dueDate: due).effectiveReminderTimes, [due]);
    });

    test('explicit reminders are sorted and deduplicated', () {
      final first = DateTime(2026, 7, 10, 8);
      final second = DateTime(2026, 7, 10, 9);
      expect(_task(reminders: [second, first, second]).effectiveReminderTimes, [
        first,
        second,
      ]);
    });

    test('notification IDs are stable and unique per reminder', () {
      final first = DateTime.utc(2026, 7, 10, 8);
      final second = DateTime.utc(2026, 7, 10, 9);

      expect(
        NotificationService.taskNotificationId('task-a', first),
        NotificationService.taskNotificationId('task-a', first),
      );
      expect(
        NotificationService.taskNotificationId('task-a', first),
        isNot(NotificationService.taskNotificationId('task-a', second)),
      );
    });
  });

  group('task display order', () {
    test('active tasks always appear before completed tasks', () {
      final now = DateTime(2026, 7, 29, 12);
      final active = _task(
        id: 'active',
        dueDate: now.add(const Duration(days: 1)),
      ).copyWith(sortOrder: 99);
      final completed = _task(id: 'completed', dueDate: now).copyWith(
        status: TaskStatus.done,
        completedAt: now,
        updatedAt: now,
        sortOrder: 0,
      );

      final tasks = [completed, active]..sort(compareTasksForDisplay);

      expect(tasks.map((task) => task.id), ['active', 'completed']);
    });

    test('active tasks preserve the persisted AI or manual order', () {
      final first = _task(id: 'first').copyWith(sortOrder: 1);
      final second = _task(id: 'second').copyWith(sortOrder: 2);

      final tasks = [second, first]..sort(compareTasksForDisplay);

      expect(tasks.map((task) => task.id), ['first', 'second']);
    });

    test('dated active tasks sort by due time then urgency automatically', () {
      final now = DateTime(2026, 7, 29, 12);
      final laterUrgent = _task(
        id: 'later',
        dueDate: now.add(const Duration(days: 2)),
      ).copyWith(priority: TaskPriority.urgent, sortOrder: 0);
      final soonNormal = _task(
        id: 'soon',
        dueDate: now.add(const Duration(hours: 2)),
      ).copyWith(priority: TaskPriority.normal, sortOrder: 99);
      final sameTimeUrgent = _task(
        id: 'same-urgent',
        dueDate: now.add(const Duration(hours: 2)),
      ).copyWith(priority: TaskPriority.urgent, sortOrder: 100);

      final tasks = [laterUrgent, soonNormal, sameTimeUrgent]
        ..sort(compareTasksForDisplay);

      expect(tasks.map((task) => task.id), ['same-urgent', 'soon', 'later']);
      expect(
        tasks.map((task) => task.displayOrderKey).toList(),
        [...tasks.map((task) => task.displayOrderKey)]..sort(),
      );
    });

    test('completed tasks sort by recent completion then urgency', () {
      final now = DateTime(2026, 7, 29, 12);
      Task completed(
        String id, {
        required DateTime completedAt,
        TaskPriority priority = TaskPriority.normal,
      }) {
        return _task(id: id).copyWith(
          status: TaskStatus.done,
          priority: priority,
          completedAt: completedAt,
          updatedAt: completedAt,
        );
      }

      final older = completed(
        'older',
        completedAt: now.subtract(const Duration(days: 1)),
        priority: TaskPriority.urgent,
      );
      final recentNormal = completed('recent-normal', completedAt: now);
      final recentUrgent = completed(
        'recent-urgent',
        completedAt: now,
        priority: TaskPriority.urgent,
      );

      final tasks = [older, recentNormal, recentUrgent]
        ..sort(compareTasksForDisplay);

      expect(tasks.map((task) => task.id), [
        'recent-urgent',
        'recent-normal',
        'older',
      ]);
    });
  });
}
