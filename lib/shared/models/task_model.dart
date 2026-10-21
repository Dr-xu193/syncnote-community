import 'package:cloud_firestore/cloud_firestore.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum TaskStatus { todo, inProgress, done }

enum TaskPriority { low, normal, high, urgent }

enum RecurrenceType { none, daily, weekly, monthly }

/// Stable cross-platform ordering for the main task list.
///
/// Active tasks keep their persisted order, which may come from manual
/// reordering or the AI scheduler. Completed tasks are always grouped after
/// every active task, without requiring another AI request. Within the
/// completed group, the most recently completed and then the most urgent task
/// appears first.
int compareTasksForDisplay(Task a, Task b) {
  final aCompleted = a.status == TaskStatus.done;
  final bCompleted = b.status == TaskStatus.done;
  if (aCompleted != bCompleted) return aCompleted ? 1 : -1;

  if (!aCompleted) {
    final dueOrder = _compareActiveDueDate(a, b);
    if (dueOrder != 0) return dueOrder;

    final priorityOrder = b.priority.index.compareTo(a.priority.index);
    if (priorityOrder != 0) return priorityOrder;

    final persistedOrder = a.sortOrder.compareTo(b.sortOrder);
    if (persistedOrder != 0) return persistedOrder;
    return a.id.compareTo(b.id);
  }

  final completionOrder = b.effectiveCompletedAt!.compareTo(
    a.effectiveCompletedAt!,
  );
  if (completionOrder != 0) return completionOrder;

  final priorityOrder = b.priority.index.compareTo(a.priority.index);
  if (priorityOrder != 0) return priorityOrder;

  final aDue = a.dueDate;
  final bDue = b.dueDate;
  if (aDue != null || bDue != null) {
    if (aDue == null) return 1;
    if (bDue == null) return -1;
    final dueOrder = aDue.compareTo(bDue);
    if (dueOrder != 0) return dueOrder;
  }

  final persistedOrder = a.sortOrder.compareTo(b.sortOrder);
  return persistedOrder != 0
      ? persistedOrder
      : a.createdAt.compareTo(b.createdAt);
}

int _compareActiveDueDate(Task a, Task b) {
  final aDue = a.dueDate;
  final bDue = b.dueDate;
  if (aDue == null && bDue == null) return 0;
  if (aDue == null) return 1;
  if (bDue == null) return -1;
  return aDue.compareTo(bDue);
}

// ---------------------------------------------------------------------------
// Task model
// ---------------------------------------------------------------------------

class Task {
  const Task({
    required this.id,
    required this.title,
    this.description = '',
    this.status = TaskStatus.todo,
    this.priority = TaskPriority.normal,
    this.dueDate,
    this.reminderTimes = const [],
    this.isRecurring = false,
    this.recurrenceType = RecurrenceType.none,
    this.parentId,
    this.subTaskIds = const [],
    this.tags = const [],
    this.isArchived = false,
    this.isDeleted = false,
    this.deletedAt,
    this.completedAt,
    this.statusChangedAt,
    this.sortOrder = 0,
    this.recurrenceSeriesId,
    this.recurrenceOccurrenceKey,
    required this.createdAt,
    required this.updatedAt,
    required this.userId,
  });

  final String id;
  final String title;
  final String description;
  final TaskStatus status;
  final TaskPriority priority;
  final DateTime? dueDate;
  final List<DateTime> reminderTimes;
  final bool isRecurring;
  final RecurrenceType recurrenceType;
  final String? parentId;
  final List<String> subTaskIds;
  final List<String> tags;
  final bool isArchived;
  final bool isDeleted;
  final DateTime? deletedAt;
  final DateTime? completedAt;
  final DateTime? statusChangedAt;
  final double sortOrder;

  /// A persisted, platform-independent key used by Firestore cursor pages.
  ///
  /// Dated active tasks naturally sort from overdue through upcoming tasks,
  /// undated active tasks follow, and completed tasks are always last.  The
  /// UI still uses [compareTasksForDisplay] inside a loaded page so a legacy
  /// record remains correct while the one-time migration is running.
  String get displayOrderKey {
    final completed = status == TaskStatus.done;
    final group = completed ? '9' : (dueDate == null ? '2' : '0');
    final time = completed
        ? _descendingTimeKey(effectiveCompletedAt ?? updatedAt)
        : (dueDate == null ? '9999999999999999' : _ascendingTimeKey(dueDate!));
    final priorityKey = 9 - priority.index;
    final manual = sortOrder.round().clamp(0, 9999999999999999);
    return '$group|$time|$priorityKey|${manual.toString().padLeft(16, '0')}|$id';
  }

  static String _ascendingTimeKey(DateTime value) => value
      .toUtc()
      .microsecondsSinceEpoch
      .clamp(0, 9999999999999999)
      .toString()
      .padLeft(16, '0');

  static String _descendingTimeKey(DateTime value) {
    final ascending = value.toUtc().microsecondsSinceEpoch.clamp(
      0,
      9999999999999999,
    );
    return (9999999999999999 - ascending).toString().padLeft(16, '0');
  }

  final String? recurrenceSeriesId;
  final String? recurrenceOccurrenceKey;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String userId;

  /// Uses updatedAt only for legacy completed tasks created before completedAt.
  DateTime? get effectiveCompletedAt =>
      status == TaskStatus.done ? completedAt ?? updatedAt : null;
  DateTime get effectiveStatusChangedAt => statusChangedAt ?? updatedAt;

  List<DateTime> get effectiveReminderTimes {
    final times = reminderTimes.isEmpty && dueDate != null
        ? <DateTime>[dueDate!]
        : List<DateTime>.from(reminderTimes);
    times.sort();
    return times.toSet().toList(growable: false);
  }

  DateTime? nextRecurrenceDueDate() {
    final current = dueDate;
    if (!isRecurring ||
        recurrenceType == RecurrenceType.none ||
        current == null) {
      return null;
    }
    return switch (recurrenceType) {
      RecurrenceType.none => null,
      RecurrenceType.daily => current.add(const Duration(days: 1)),
      RecurrenceType.weekly => current.add(const Duration(days: 7)),
      RecurrenceType.monthly => _addOneMonth(current),
    };
  }

  static DateTime _addOneMonth(DateTime value) {
    final targetMonth = value.month == 12 ? 1 : value.month + 1;
    final targetYear = value.month == 12 ? value.year + 1 : value.year;
    final lastDay = DateTime(targetYear, targetMonth + 1, 0).day;
    return DateTime(
      targetYear,
      targetMonth,
      value.day > lastDay ? lastDay : value.day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    );
  }

  // ---------------------------------------------------------------------------
  // Serialisation helpers
  // ---------------------------------------------------------------------------

  static DateTime _fromTs(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.parse(value);
    return DateTime.now();
  }

  static DateTime? _fromTsNullable(dynamic value) {
    if (value == null) return null;
    return _fromTs(value);
  }

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      status: TaskStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => TaskStatus.todo,
      ),
      priority: TaskPriority.values.firstWhere(
        (e) => e.name == json['priority'],
        orElse: () => TaskPriority.normal,
      ),
      dueDate: _fromTsNullable(json['dueDate']),
      reminderTimes: ((json['reminderTimes'] as List<dynamic>?) ?? [])
          .map((e) => _fromTs(e))
          .toList(),
      isRecurring: json['isRecurring'] as bool? ?? false,
      recurrenceType: RecurrenceType.values.firstWhere(
        (e) => e.name == json['recurrenceType'],
        orElse: () => RecurrenceType.none,
      ),
      parentId: json['parentId'] as String?,
      subTaskIds: List<String>.from(json['subTaskIds'] as List<dynamic>? ?? []),
      tags: List<String>.from(json['tags'] as List<dynamic>? ?? []),
      isArchived: json['isArchived'] as bool? ?? false,
      isDeleted: json['isDeleted'] as bool? ?? false,
      deletedAt: _fromTsNullable(json['deletedAt']),
      completedAt: _fromTsNullable(json['completedAt']),
      statusChangedAt: _fromTsNullable(json['statusChangedAt']),
      sortOrder:
          (json['sortOrder'] as num?)?.toDouble() ??
          _fromTs(json['createdAt']).microsecondsSinceEpoch.toDouble(),
      recurrenceSeriesId: json['recurrenceSeriesId'] as String?,
      recurrenceOccurrenceKey: json['recurrenceOccurrenceKey'] as String?,
      createdAt: _fromTs(json['createdAt']),
      updatedAt: _fromTs(json['updatedAt']),
      userId: json['userId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'status': status.name,
      'priority': priority.name,
      'dueDate': dueDate != null ? Timestamp.fromDate(dueDate!) : null,
      'reminderTimes': reminderTimes
          .map((dt) => Timestamp.fromDate(dt))
          .toList(),
      'isRecurring': isRecurring,
      'recurrenceType': recurrenceType.name,
      'parentId': parentId,
      'subTaskIds': subTaskIds,
      'tags': tags,
      'isArchived': isArchived,
      'isDeleted': isDeleted,
      'deletedAt': deletedAt != null ? Timestamp.fromDate(deletedAt!) : null,
      'completedAt': completedAt != null
          ? Timestamp.fromDate(completedAt!)
          : null,
      'statusChangedAt': statusChangedAt != null
          ? Timestamp.fromDate(statusChangedAt!)
          : null,
      'sortOrder': sortOrder,
      'displayOrderKey': displayOrderKey,
      'recurrenceSeriesId': recurrenceSeriesId,
      'recurrenceOccurrenceKey': recurrenceOccurrenceKey,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'userId': userId,
    };
  }

  // ---------------------------------------------------------------------------
  // copyWith
  // ---------------------------------------------------------------------------

  Task copyWith({
    String? id,
    String? title,
    String? description,
    TaskStatus? status,
    TaskPriority? priority,
    DateTime? dueDate,
    List<DateTime>? reminderTimes,
    bool? isRecurring,
    RecurrenceType? recurrenceType,
    String? parentId,
    List<String>? subTaskIds,
    List<String>? tags,
    bool? isArchived,
    bool? isDeleted,
    DateTime? deletedAt,
    DateTime? completedAt,
    DateTime? statusChangedAt,
    double? sortOrder,
    String? recurrenceSeriesId,
    String? recurrenceOccurrenceKey,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? userId,
    bool clearDueDate = false,
    bool clearDeletedAt = false,
    bool clearCompletedAt = false,
    bool clearRecurrence = false,
    bool clearParentId = false,
  }) {
    final nextStatus = status ?? this.status;
    final nextCompletedAt = clearCompletedAt || nextStatus != TaskStatus.done
        ? null
        : completedAt ??
              (status == TaskStatus.done && this.status != TaskStatus.done
                  ? updatedAt ?? DateTime.now()
                  : this.completedAt);

    return Task(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      dueDate: clearDueDate ? null : (dueDate ?? this.dueDate),
      reminderTimes: reminderTimes ?? this.reminderTimes,
      isRecurring: isRecurring ?? this.isRecurring,
      recurrenceType: recurrenceType ?? this.recurrenceType,
      parentId: clearParentId ? null : (parentId ?? this.parentId),
      subTaskIds: subTaskIds ?? this.subTaskIds,
      tags: tags ?? this.tags,
      isArchived: isArchived ?? this.isArchived,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      completedAt: nextCompletedAt,
      statusChangedAt: statusChangedAt ?? this.statusChangedAt,
      sortOrder: sortOrder ?? this.sortOrder,
      recurrenceSeriesId: clearRecurrence
          ? null
          : (recurrenceSeriesId ?? this.recurrenceSeriesId),
      recurrenceOccurrenceKey: clearRecurrence
          ? null
          : (recurrenceOccurrenceKey ?? this.recurrenceOccurrenceKey),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      userId: userId ?? this.userId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Task && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Task(id: $id, title: $title, status: ${status.name})';
}
