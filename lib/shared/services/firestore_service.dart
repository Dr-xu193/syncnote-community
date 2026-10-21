import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/shared/models/diary_model.dart';
import 'package:syncnote/shared/models/memo_model.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/models/note_version_model.dart';
import 'package:syncnote/shared/models/ai_chat_model.dart';
import 'package:syncnote/shared/models/ai_assistant_model.dart';
import 'package:syncnote/shared/models/cloud_file_item.dart';
import 'package:syncnote/shared/models/content_index_model.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:syncnote/shared/utils/content_index_text.dart';
import 'package:uuid/uuid.dart';

class NoteSaveConflictException implements Exception {
  const NoteSaveConflictException({
    required this.cloudNote,
    required this.localNote,
  });

  final Note cloudNote;
  final Note localNote;

  @override
  String toString() => '笔记已在其他设备更新，请先处理保存冲突';
}

class FirestorePage<T> {
  const FirestorePage({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });

  final List<T> items;
  final DocumentSnapshot<Map<String, dynamic>>? cursor;
  final bool hasMore;
}

class ContentIndexPage {
  const ContentIndexPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
  });

  final List<ContentIndexEntry> items;
  final DocumentSnapshot<Map<String, dynamic>>? cursor;
  final bool hasMore;
}

// ---------------------------------------------------------------------------
// FirestoreService — singleton
// ---------------------------------------------------------------------------

/// Central Firestore data-access layer for SyncNote.
///
/// All operations are scoped to the currently authenticated user.
/// Throws [StateError] if any method is called while the user is signed out.
class FirestoreService {
  FirestoreService._();

  /// The single shared instance.
  static final FirestoreService instance = FirestoreService._();

  // ── Internal references ──────────────────────────────────────────────────

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  Future<void>? _preparePagedFuture;

  // ── Auth helpers ─────────────────────────────────────────────────────────

  /// Returns the current user's UID, or null if not authenticated.
  String? get _uidOrNull => _auth.currentUser?.uid;

  /// Returns the current user's UID.
  ///
  /// Throws a [StateError] if the user is not authenticated.
  String get _uid {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError(
        'FirestoreService: no authenticated user. '
        'Ensure the user is signed in before calling Firestore methods.',
      );
    }
    return user.uid;
  }

  // ── Collection helper ────────────────────────────────────────────────────

  /// Returns the subcollection reference for [name] under the current user.
  ///
  /// Path: `users/{uid}/{name}`
  CollectionReference<Map<String, dynamic>> _col(String name) {
    return _db.collection(AppConfig.usersCollection).doc(_uid).collection(name);
  }

  /// Returns null if user is not authenticated.
  CollectionReference<Map<String, dynamic>>? _colOrNull(String name) {
    final uid = _uidOrNull;
    if (uid == null) return null;
    return _db.collection(AppConfig.usersCollection).doc(uid).collection(name);
  }

  DocumentReference<Map<String, dynamic>> _indexRef(
    IndexedContentType type,
    String sourceId,
  ) => _col(AppConfig.searchIndexCollection).doc('${type.name}_$sourceId');

  ContentIndexEntry _taskIndex(Task task) => ContentIndexEntry(
    id: 'task_${task.id}',
    sourceId: task.id,
    type: IndexedContentType.task,
    title: task.title,
    summary: compactIndexSummary(task.description),
    searchTerms: buildSearchTerms([task.title, task.description, ...task.tags]),
    tags: task.tags,
    category: '',
    isArchived: task.isArchived,
    isDeleted: task.isDeleted,
    primaryDate: task.dueDate ?? task.createdAt,
    updatedAt: task.updatedAt,
  );

  ContentIndexEntry _noteIndex(Note note) => ContentIndexEntry(
    id: 'note_${note.id}',
    sourceId: note.id,
    type: IndexedContentType.note,
    title: note.title,
    summary: compactIndexSummary(note.content),
    searchTerms: buildSearchTerms([
      note.title,
      note.content,
      note.category,
      ...note.tags,
      ...note.aiKeywords,
    ]),
    tags: note.tags,
    category: note.category,
    isArchived: note.isArchived,
    isDeleted: note.isDeleted,
    primaryDate: note.createdAt,
    updatedAt: note.updatedAt,
  );

  ContentIndexEntry _memoIndex(Memo memo) => ContentIndexEntry(
    id: 'memo_${memo.id}',
    sourceId: memo.id,
    type: IndexedContentType.memo,
    title: '备忘录',
    summary: compactIndexSummary(memo.content),
    searchTerms: buildSearchTerms([memo.content]),
    tags: const [],
    category: '',
    isArchived: false,
    isDeleted: memo.isDeleted,
    primaryDate: memo.createdAt,
    updatedAt: memo.updatedAt,
  );

  ContentIndexEntry _diaryIndex(DiaryEntry entry) => ContentIndexEntry(
    id: 'diary_${entry.id}',
    sourceId: entry.id,
    type: IndexedContentType.diary,
    title: '日记 ${entry.date.toIso8601String().split('T').first}',
    summary: compactIndexSummary(entry.content),
    searchTerms: buildSearchTerms([entry.content, entry.mood.name]),
    tags: const [],
    category: entry.mood.name,
    isArchived: false,
    isDeleted: entry.isDeleted,
    primaryDate: entry.date,
    updatedAt: entry.updatedAt,
  );

  Future<void> _writeIndex(ContentIndexEntry entry) =>
      _indexRef(entry.type, entry.sourceId).set(entry.toJson());

  Future<void> _deleteIndex(IndexedContentType type, String sourceId) =>
      _indexRef(type, sourceId).delete();

  Future<void> _refreshTaskIndex(String id) async {
    final task = await getTask(id);
    if (task == null) {
      await _deleteIndex(IndexedContentType.task, id);
    } else {
      await _writeIndex(_taskIndex(task));
    }
  }

  static const List<String> _attachmentCollections = [
    AppConfig.tasksCollection,
    AppConfig.notesCollection,
    AppConfig.memosCollection,
    AppConfig.diaryCollection,
  ];

  @visibleForTesting
  static Set<String> extractWebdavUrls(Object? value) {
    final urls = <String>{};

    void visit(Object? current) {
      if (current is String) {
        if (current.startsWith('webdav://')) {
          urls.add(current);
        }
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
  static Set<String> unreferencedAttachmentUrls(
    Set<String> candidates,
    Set<String> referenced,
  ) => candidates.difference(referenced);

  @visibleForTesting
  static String recurrenceOccurrenceId(String seriesId, DateTime dueDate) =>
      '${seriesId}_${dueDate.toUtc().millisecondsSinceEpoch}';

  @visibleForTesting
  static Set<String> extractWikiTitles(String content) {
    final titles = <String>{};
    for (final match in RegExp(r'\[\[(.*?)\]\]').allMatches(content)) {
      final title = match.group(1)?.trim().toLowerCase();
      if (title != null && title.isNotEmpty) titles.add(title);
    }
    for (final match in RegExp(
      r'\[.*?\]\(wiki:\/\/(.*?)\)',
    ).allMatches(content)) {
      final value = match.group(1);
      if (value != null) {
        titles.add(Uri.decodeComponent(value).trim().toLowerCase());
      }
    }
    return titles;
  }

  @visibleForTesting
  static bool shouldCreateNoteVersion(DateTime? latest, DateTime now) =>
      latest == null || now.difference(latest).inMinutes >= 10;

  Future<Set<String>> _findReferencedAttachmentUrls(
    Set<String> candidates,
  ) async {
    final referenced = <String>{};
    if (candidates.isEmpty) return referenced;

    for (final collectionName in _attachmentCollections) {
      final snapshot = await _col(collectionName).get();
      for (final document in snapshot.docs) {
        final documentUrls = extractWebdavUrls(document.data());
        referenced.addAll(documentUrls.intersection(candidates));
        if (collectionName == AppConfig.notesCollection) {
          final versions = await document.reference
              .collection('versions')
              .get();
          for (final version in versions.docs) {
            referenced.addAll(
              extractWebdavUrls(version.data()).intersection(candidates),
            );
          }
        }
        if (referenced.length == candidates.length) {
          return referenced;
        }
      }
    }
    final chats = await _col('aiChats').get();
    for (final chat in chats.docs) {
      referenced.addAll(
        extractWebdavUrls(chat.data()).intersection(candidates),
      );
      final messages = await chat.reference.collection('messages').get();
      for (final message in messages.docs) {
        referenced.addAll(
          extractWebdavUrls(message.data()).intersection(candidates),
        );
      }
    }
    return referenced;
  }

  /// Removes WebDAV files only when no current Firestore document references
  /// them. Soft-deleted documents are included because they can be restored.
  Future<Set<String>> deleteAttachmentsIfUnreferenced(
    Iterable<String> urls,
  ) async {
    final candidates = urls.where((url) => url.startsWith('webdav://')).toSet();
    if (candidates.isEmpty) return const <String>{};

    final referenced = await _findReferencedAttachmentUrls(candidates);
    final deleted = <String>{};
    for (final url in unreferencedAttachmentUrls(candidates, referenced)) {
      if (await UploadService.instance.deleteFile(url)) {
        deleted.add(url);
      }
    }
    return deleted;
  }

  // ==========================================================================
  // TASKS
  // ==========================================================================

  /// Real-time stream of non-deleted [Task]s in stable display order.
  ///
  /// Active tasks retain their manual/AI order. Completed tasks automatically
  /// move behind all active tasks and are sorted by completion recency.
  Stream<List<Task>> watchTasks() {
    final col = _colOrNull(AppConfig.tasksCollection);
    if (col == null) return Stream.value([]);
    return col.snapshots().map((snap) {
      final tasks = snap.docs
          .map((doc) => Task.fromJson(doc.data()))
          .where((t) => !t.isDeleted)
          .toList(growable: true);
      tasks.sort(compareTasksForDisplay);
      return List<Task>.unmodifiable(tasks);
    });
  }

  /// Real-time stream of soft-deleted [Task]s, ordered by [deletedAt] desc.
  Stream<List<Task>> watchDeletedTasks() {
    final col = _colOrNull(AppConfig.tasksCollection);
    if (col == null) return Stream.value([]);
    return col.snapshots().map((snap) {
      final tasks = snap.docs
          .map((doc) => Task.fromJson(doc.data()))
          .where((t) => t.isDeleted)
          .toList(growable: true);
      tasks.sort((a, b) {
        final da = a.deletedAt;
        final db = b.deletedAt;
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });
      return List<Task>.unmodifiable(tasks);
    });
  }

  /// Fetches a one-time snapshot of active, non-completed tasks.
  Future<List<Task>> getActiveTasks() async {
    final col = _colOrNull(AppConfig.tasksCollection);
    if (col == null) return [];
    final snap = await col.get();
    return snap.docs
        .map((doc) => Task.fromJson(doc.data()))
        .where(
          (t) =>
              !t.isDeleted &&
              !t.isArchived &&
              t.parentId == null &&
              t.status != TaskStatus.done,
        )
        .toList();
  }

  /// Fetches a single [Task] by its [id].
  Future<Task?> getTask(String id) async {
    final col = _colOrNull(AppConfig.tasksCollection);
    if (col == null) return null;
    final doc = await col.doc(id).get();
    if (!doc.exists || doc.data() == null) return null;
    return Task.fromJson(doc.data()!);
  }

  /// Writes a new [task] document, keyed by [task.id].
  Future<void> addTask(Task task) async {
    await _col(AppConfig.tasksCollection).doc(task.id).set(task.toJson());
    await _writeIndex(_taskIndex(task));
  }

  /// Updates an existing [task], setting [updatedAt] to the current time.
  Future<void> updateTask(Task task) async {
    final data = task.toJson()..['updatedAt'] = Timestamp.now();
    await _col(AppConfig.tasksCollection).doc(task.id).update(data);
    await _refreshTaskIndex(task.id);
  }

  /// Updates multiple tasks atomically using a Firestore WriteBatch.
  Future<void> updateTasksBatch(List<Task> tasks) async {
    if (tasks.isEmpty) return;
    final batch = FirebaseFirestore.instance.batch();
    final col = _col(AppConfig.tasksCollection);
    for (final task in tasks) {
      final data = task.toJson()..['updatedAt'] = Timestamp.now();
      batch.update(col.doc(task.id), data);
    }
    await batch.commit();
    for (final task in tasks) {
      await _refreshTaskIndex(task.id);
    }
  }

  Future<void> migrateLegacyTaskFields() async {
    final snapshot = await _col(AppConfig.tasksCollection).get();
    if (snapshot.docs.isEmpty) return;
    final pending =
        <(DocumentReference<Map<String, dynamic>>, Map<String, dynamic>)>[];
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final updates = <String, dynamic>{};
      final updatedAt = Task.fromJson(data).updatedAt;
      if (!data.containsKey('completedAt') &&
          data['status'] == TaskStatus.done.name) {
        updates['completedAt'] = Timestamp.fromDate(updatedAt);
      }
      if (!data.containsKey('statusChangedAt')) {
        updates['statusChangedAt'] = Timestamp.fromDate(updatedAt);
      }
      if (!data.containsKey('sortOrder')) {
        updates['sortOrder'] = Task.fromJson(
          data,
        ).createdAt.microsecondsSinceEpoch.toDouble();
      }
      final parsed = Task.fromJson(data);
      if (data['displayOrderKey'] != parsed.displayOrderKey) {
        updates['displayOrderKey'] = parsed.displayOrderKey;
      }
      if ((data['isRecurring'] as bool? ?? false) &&
          !data.containsKey('recurrenceSeriesId')) {
        updates['recurrenceSeriesId'] = doc.id;
      }
      if (updates.isNotEmpty) {
        pending.add((doc.reference, updates));
      }
    }
    for (var offset = 0; offset < pending.length; offset += 400) {
      final batch = _db.batch();
      for (final update in pending.skip(offset).take(400)) {
        batch.update(update.$1, update.$2);
      }
      await batch.commit();
    }
  }

  Future<void> changeTaskStatus(Task task, TaskStatus status) async {
    final taskRef = _col(AppConfig.tasksCollection).doc(task.id);
    // The Windows Firestore SDK can terminate the native process when this
    // operation is sent through runTransaction. Status changes only need a
    // read of the current task followed by an atomic batch write; the next
    // recurring task has a deterministic ID, so this remains idempotent.
    final snapshot = await taskRef.get();
    if (!snapshot.exists || snapshot.data() == null) return;

    final current = Task.fromJson(snapshot.data()!);
    if (current.status == status) return;

    final now = DateTime.now();
    final updated = current.copyWith(
      status: status,
      statusChangedAt: now,
      completedAt: status == TaskStatus.done ? now : null,
      clearCompletedAt: status != TaskStatus.done,
      updatedAt: now,
    );
    final batch = _db.batch()..update(taskRef, updated.toJson());

    if (status == TaskStatus.done) {
      final nextDue = current.nextRecurrenceDueDate();
      if (nextDue != null) {
        final seriesId = current.recurrenceSeriesId ?? current.id;
        final nextId = recurrenceOccurrenceId(seriesId, nextDue);
        final nextRef = _col(AppConfig.tasksCollection).doc(nextId);
        final nextSnapshot = await nextRef.get();
        if (!nextSnapshot.exists) {
          final shift = nextDue.difference(current.dueDate!);
          final nextReminders = current.reminderTimes
              .map((time) => time.add(shift))
              .toList(growable: false);
          final nextTask = current.copyWith(
            id: nextId,
            status: TaskStatus.todo,
            dueDate: nextDue,
            reminderTimes: nextReminders,
            subTaskIds: const [],
            statusChangedAt: now,
            sortOrder: now.microsecondsSinceEpoch.toDouble(),
            recurrenceSeriesId: seriesId,
            recurrenceOccurrenceKey: nextDue.toUtc().toIso8601String(),
            createdAt: now,
            updatedAt: now,
            clearCompletedAt: true,
            clearDeletedAt: true,
          );
          batch.set(nextRef, nextTask.toJson());
        }
      }
    }

    await batch.commit();
    await _refreshTaskIndex(task.id);
    if (task.parentId != null) {
      await _syncParentTaskStatus(task.parentId!);
    }
  }

  Future<void> _syncParentTaskStatus(String parentId) async {
    final parent = await getTask(parentId);
    if (parent == null || parent.isDeleted) return;
    final childrenSnapshot = await _col(
      AppConfig.tasksCollection,
    ).where('parentId', isEqualTo: parentId).get();
    final children = childrenSnapshot.docs
        .map((doc) => Task.fromJson(doc.data()))
        .where((child) => !child.isDeleted)
        .toList();
    if (children.isEmpty) return;
    final allDone = children.every((child) => child.status == TaskStatus.done);
    final target = allDone ? TaskStatus.done : TaskStatus.inProgress;
    if (parent.status != target) {
      await changeTaskStatus(parent, target);
    }
  }

  Future<void> addSubtask(Task parent, Task subtask) async {
    final parentRef = _col(AppConfig.tasksCollection).doc(parent.id);
    final childRef = _col(AppConfig.tasksCollection).doc(subtask.id);
    await _db.runTransaction((transaction) async {
      final parentSnapshot = await transaction.get(parentRef);
      if (!parentSnapshot.exists) {
        throw StateError('父任务不存在');
      }
      transaction.set(childRef, subtask.copyWith(parentId: parent.id).toJson());
      transaction.update(parentRef, {
        'subTaskIds': FieldValue.arrayUnion([subtask.id]),
        'updatedAt': Timestamp.now(),
      });
    });
  }

  Future<void> reorderTasks(List<Task> tasks) async {
    if (tasks.isEmpty) return;
    final batch = _db.batch();
    for (var index = 0; index < tasks.length; index++) {
      final reordered = tasks[index].copyWith(sortOrder: index.toDouble());
      batch.update(_col(AppConfig.tasksCollection).doc(tasks[index].id), {
        'sortOrder': index.toDouble(),
        'displayOrderKey': reordered.displayOrderKey,
        'updatedAt': Timestamp.now(),
      });
    }
    await batch.commit();
    for (final task in tasks) {
      await _refreshTaskIndex(task.id);
    }
  }

  /// Soft-deletes the task with [id] by setting `isDeleted = true`.
  Future<void> deleteTask(String id) async {
    final reference = _col(AppConfig.tasksCollection).doc(id);
    final snapshot = await reference.get();
    if (!snapshot.exists || snapshot.data() == null) return;
    final task = Task.fromJson(snapshot.data()!);
    final batch = _db.batch();
    batch.update(reference, {
      'isDeleted': true,
      'deletedAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
    if (task.parentId != null) {
      batch.update(_col(AppConfig.tasksCollection).doc(task.parentId), {
        'subTaskIds': FieldValue.arrayRemove([task.id]),
        'updatedAt': Timestamp.now(),
      });
    }
    for (final childId in task.subTaskIds) {
      batch.update(_col(AppConfig.tasksCollection).doc(childId), {
        'isDeleted': true,
        'deletedAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
      });
    }
    await batch.commit();
    await _refreshTaskIndex(task.id);
    if (task.parentId != null) {
      await _syncParentTaskStatus(task.parentId!);
    }
  }

  /// Restores a soft-deleted task with [id].
  Future<void> restoreTask(String id) async {
    final reference = _col(AppConfig.tasksCollection).doc(id);
    final snapshot = await reference.get();
    if (!snapshot.exists || snapshot.data() == null) return;
    final task = Task.fromJson(snapshot.data()!);
    final batch = _db.batch();
    batch.update(reference, {
      'isDeleted': false,
      'deletedAt': null,
      'updatedAt': Timestamp.now(),
    });
    if (task.parentId != null) {
      batch.update(_col(AppConfig.tasksCollection).doc(task.parentId), {
        'subTaskIds': FieldValue.arrayUnion([task.id]),
        'updatedAt': Timestamp.now(),
      });
    }
    for (final childId in task.subTaskIds) {
      batch.update(_col(AppConfig.tasksCollection).doc(childId), {
        'isDeleted': false,
        'deletedAt': null,
        'updatedAt': Timestamp.now(),
      });
    }
    await batch.commit();
    await _refreshTaskIndex(task.id);
    if (task.parentId != null) {
      await _syncParentTaskStatus(task.parentId!);
    }
  }

  /// Permanently removes the task document with [id] from Firestore.
  Future<void> permanentlyDeleteTask(String id) async {
    final reference = _col(AppConfig.tasksCollection).doc(id);
    final snapshot = await reference.get();
    if (!snapshot.exists || snapshot.data() == null) return;
    final task = Task.fromJson(snapshot.data()!);
    final batch = _db.batch();
    batch.delete(reference);
    if (task.parentId != null) {
      batch.update(_col(AppConfig.tasksCollection).doc(task.parentId), {
        'subTaskIds': FieldValue.arrayRemove([task.id]),
        'updatedAt': Timestamp.now(),
      });
    }
    for (final childId in task.subTaskIds) {
      batch.delete(_col(AppConfig.tasksCollection).doc(childId));
    }
    await batch.commit();
    await _deleteIndex(IndexedContentType.task, id);
  }

  // ==========================================================================
  // NOTES
  // ==========================================================================

  /// Real-time stream of non-deleted [Note]s, ordered by [createdAt] desc.
  Stream<List<Note>> watchNotes() {
    final col = _colOrNull(AppConfig.notesCollection);
    if (col == null) return Stream.value([]);
    return col.snapshots().map((snap) {
      final notes = snap.docs
          .map((doc) => Note.fromJson(doc.data()))
          .where((n) => !n.isDeleted)
          .toList(growable: true);
      notes.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return List<Note>.unmodifiable(notes);
    });
  }

  Stream<List<Note>> watchNoteBacklinks(String noteId) {
    return watchNotes().map(
      (notes) => notes
          .where((note) => note.linkedNoteIds.contains(noteId))
          .toList(growable: false),
    );
  }

  /// Real-time stream of soft-deleted [Note]s, ordered by [deletedAt] desc.
  Stream<List<Note>> watchDeletedNotes() {
    final col = _colOrNull(AppConfig.notesCollection);
    if (col == null) return Stream.value([]);
    return col.snapshots().map((snap) {
      final notes = snap.docs
          .map((doc) => Note.fromJson(doc.data()))
          .where((n) => n.isDeleted)
          .toList(growable: true);
      notes.sort((a, b) {
        final da = a.deletedAt;
        final db = b.deletedAt;
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });
      return List<Note>.unmodifiable(notes);
    });
  }

  /// Writes a new [note] document, keyed by [note.id].
  Future<void> addNote(Note note) async {
    final stored = note.copyWith(revision: 1);
    await _col(AppConfig.notesCollection).doc(note.id).set(stored.toJson());
    await _writeIndex(_noteIndex(stored));
  }

  /// Updates an existing [note], stamping [updatedAt] with the current time.
  Future<void> updateNote(Note note) async {
    final data = note.copyWith(revision: note.revision + 1).toJson()
      ..['updatedAt'] = Timestamp.now();
    await _col(AppConfig.notesCollection).doc(note.id).update(data);
    final stored = await getNoteById(note.id);
    if (stored != null) await _writeIndex(_noteIndex(stored));
  }

  Future<Set<String>> resolveLinkedNoteIds(
    String content, {
    String? currentId,
  }) async {
    final notes = await getNotesOnce();
    final byTitle = {
      for (final note in notes)
        if (note.id != currentId && note.title.trim().isNotEmpty)
          note.title.trim().toLowerCase(): note.id,
    };
    final titles = extractWikiTitles(content);
    return titles.map((title) => byTitle[title]).whereType<String>().toSet();
  }

  Future<void> updateNoteWithHistory(
    Note oldNote,
    Note updatedNote, {
    bool force = false,
  }) async {
    final noteRef = _col(AppConfig.notesCollection).doc(oldNote.id);
    final currentSnapshot = await noteRef.get();
    if (!currentSnapshot.exists || currentSnapshot.data() == null) {
      throw StateError('笔记不存在，无法保存');
    }
    final currentCloudNote = Note.fromJson(currentSnapshot.data()!);
    if (!force && currentCloudNote.revision != oldNote.revision) {
      throw NoteSaveConflictException(
        cloudNote: currentCloudNote,
        localNote: updatedNote,
      );
    }
    final versions = noteRef.collection('versions');
    final recent = await versions
        .orderBy('createdAt', descending: true)
        .limit(6)
        .get();
    final now = DateTime.now();
    final latest = recent.docs.isEmpty
        ? null
        : (recent.docs.first.data()['createdAt'] as Timestamp).toDate();
    if (shouldCreateNoteVersion(latest, now)) {
      final version = NoteVersion(
        id: const Uuid().v4(),
        note: currentCloudNote,
        createdAt: now,
        source: 'save',
      );
      await versions.doc(version.id).set(version.toJson());
    }
    final linkedIds = await resolveLinkedNoteIds(
      updatedNote.content,
      currentId: updatedNote.id,
    );
    await noteRef.update(
      updatedNote
          .copyWith(
            linkedNoteIds: linkedIds.toList(),
            revision: currentCloudNote.revision + 1,
          )
          .toJson(),
    );
    final stored = await getNoteById(updatedNote.id);
    if (stored != null) await _writeIndex(_noteIndex(stored));
    final allVersions = await versions
        .orderBy('createdAt', descending: true)
        .get();
    for (final doc in allVersions.docs.skip(AppConfig.maxVersionsPerNote)) {
      await doc.reference.delete();
    }
  }

  Stream<List<NoteVersion>> watchNoteVersions(String noteId) {
    return _col(AppConfig.notesCollection)
        .doc(noteId)
        .collection('versions')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => NoteVersion.fromJson(doc.data()))
              .toList(growable: false),
        );
  }

  Future<void> restoreNoteVersion(Note current, NoteVersion version) async {
    final now = DateTime.now();
    final versions = _col(
      AppConfig.notesCollection,
    ).doc(current.id).collection('versions');
    final snapshot = NoteVersion(
      id: const Uuid().v4(),
      note: current,
      createdAt: now,
      source: 'beforeRestore',
    );
    await versions.doc(snapshot.id).set(snapshot.toJson());
    final restored = version.note.copyWith(
      id: current.id,
      userId: current.userId,
      createdAt: current.createdAt,
      updatedAt: now,
      revision: current.revision + 1,
    );
    await _col(
      AppConfig.notesCollection,
    ).doc(current.id).update(restored.toJson());
    await _writeIndex(_noteIndex(restored));
    final all = await versions.orderBy('createdAt', descending: true).get();
    for (final doc in all.docs.skip(AppConfig.maxVersionsPerNote)) {
      await doc.reference.delete();
    }
  }

  Future<void> deleteNoteVersion(String noteId, NoteVersion version) async {
    await _col(
      AppConfig.notesCollection,
    ).doc(noteId).collection('versions').doc(version.id).delete();
    await deleteAttachmentsIfUnreferenced(
      extractWebdavUrls(version.note.toJson()),
    );
  }

  Future<void> clearNoteVersions(String noteId) async {
    final versions = await _col(
      AppConfig.notesCollection,
    ).doc(noteId).collection('versions').get();
    final attachments = <String>{};
    final batch = _db.batch();
    for (final doc in versions.docs) {
      attachments.addAll(extractWebdavUrls(doc.data()));
      batch.delete(doc.reference);
    }
    await batch.commit();
    await deleteAttachmentsIfUnreferenced(attachments);
  }

  Future<void> migrateWikiLinks() async {
    final notes = await getNotesOnce();
    for (final note in notes) {
      final ids = await resolveLinkedNoteIds(note.content, currentId: note.id);
      if (!setEquals(ids, note.linkedNoteIds.toSet())) {
        await _col(AppConfig.notesCollection).doc(note.id).update({
          'linkedNoteIds': ids.toList(),
          'updatedAt': Timestamp.now(),
          'revision': FieldValue.increment(1),
        });
      }
    }
  }

  Stream<List<AiChat>> watchAiChats() {
    return _col('aiChats')
        .orderBy('updatedAt', descending: true)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.map((doc) {
            final data = doc.data()..['id'] = doc.id;
            return AiChat.fromJson(data);
          }).toList(),
        );
  }

  Stream<List<AiChatMessage>> watchAiChatMessages(String chatId) {
    return _col('aiChats')
        .doc(chatId)
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .limit(80)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.reversed
              .map((doc) {
                final data = doc.data()..['id'] = doc.id;
                return AiChatMessage.fromJson(data);
              })
              .toList(growable: false),
        );
  }

  Future<AiChat> createAiChat([String title = '新对话']) async {
    final id = const Uuid().v4();
    final now = DateTime.now();
    final chat = AiChat(id: id, title: title, createdAt: now, updatedAt: now);
    await _col('aiChats').doc(id).set({
      'id': id,
      'title': title,
      'memorySummary': '',
      'sourceRefs': <String>[],
      'enabledSources': aiContextSourceNames.toList()..sort(),
      'createdAt': Timestamp.fromDate(now),
      'updatedAt': Timestamp.fromDate(now),
    });
    return chat;
  }

  Future<void> addAiChatMessage(String chatId, AiChatMessage message) async {
    final chatRef = _col('aiChats').doc(chatId);
    final batch = _db.batch();
    batch.set(chatRef.collection('messages').doc(message.id), message.toJson());
    batch.update(chatRef, {
      'updatedAt': Timestamp.now(),
      if (message.sourceRefs.isNotEmpty)
        'sourceRefs': FieldValue.arrayUnion(message.sourceRefs),
    });
    await batch.commit();
  }

  Future<void> updateAiChatMemory(String chatId, String summary) async {
    await _col('aiChats').doc(chatId).update({
      'memorySummary': summary,
      'updatedAt': Timestamp.now(),
    });
  }

  Future<void> renameAiChat(String chatId, String title) async {
    await _col(
      'aiChats',
    ).doc(chatId).update({'title': title, 'updatedAt': Timestamp.now()});
  }

  Future<void> deleteAiChat(String chatId) async {
    final ref = _col('aiChats').doc(chatId);
    final messages = await ref.collection('messages').get();
    final resources = await ref.collection('resources').get();
    final children = [...messages.docs, ...resources.docs];
    for (var offset = 0; offset < children.length; offset += 400) {
      final batch = _db.batch();
      for (final child in children.skip(offset).take(400)) {
        batch.delete(child.reference);
      }
      await batch.commit();
    }
    final batch = _db.batch();
    batch.delete(ref);
    await batch.commit();
  }

  Future<void> clearAiChats() async {
    final chats = await _col('aiChats').get();
    for (final chat in chats.docs) {
      await deleteAiChat(chat.id);
    }
  }

  /// Fetches a single note document by its [id]. Returns null if not found.
  Future<Note?> getNoteById(String id) async {
    final doc = await _col(AppConfig.notesCollection).doc(id).get();
    if (!doc.exists || doc.data() == null) return null;
    return Note.fromJson(doc.data()!);
  }

  /// Soft-deletes the note with [id].
  Future<void> deleteNote(String id) async {
    await _col(AppConfig.notesCollection).doc(id).update({
      'isDeleted': true,
      'deletedAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
    final note = await getNoteById(id);
    if (note != null) await _writeIndex(_noteIndex(note));
  }

  /// Restores a soft-deleted note with [id].
  Future<void> restoreNote(String id) async {
    await _col(AppConfig.notesCollection).doc(id).update({
      'isDeleted': false,
      'deletedAt': null,
      'updatedAt': Timestamp.now(),
    });
    final note = await getNoteById(id);
    if (note != null) await _writeIndex(_noteIndex(note));
  }

  /// Permanently removes the note document with [id] from Firestore.
  Future<void> permanentlyDeleteNote(String id) async {
    final attachments = <String>{};
    final docSnap = await _col(AppConfig.notesCollection).doc(id).get();
    if (docSnap.exists) {
      final data = docSnap.data();
      if (data != null) {
        attachments.addAll(extractWebdavUrls(data));
      }
    }
    final versions = await _col(
      AppConfig.notesCollection,
    ).doc(id).collection('versions').get();
    final batch = _db.batch();
    for (final version in versions.docs) {
      attachments.addAll(extractWebdavUrls(version.data()));
      batch.delete(version.reference);
    }
    if (versions.docs.isNotEmpty) await batch.commit();
    await _col(AppConfig.notesCollection).doc(id).delete();
    await _deleteIndex(IndexedContentType.note, id);
    await deleteAttachmentsIfUnreferenced(attachments);
  }

  // ==========================================================================
  // DIARY
  // ==========================================================================

  /// Real-time stream of non-deleted [DiaryEntry]s, ordered by [date] desc.
  Stream<List<DiaryEntry>> watchDiaryEntries() {
    final col = _colOrNull(AppConfig.diaryCollection);
    if (col == null) return Stream.value([]);
    return col.snapshots().map((snap) {
      final entries = snap.docs
          .map((doc) => DiaryEntry.fromJson(doc.data()))
          .where((e) => !e.isDeleted)
          .toList(growable: true);
      entries.sort((a, b) => b.date.compareTo(a.date));
      return List<DiaryEntry>.unmodifiable(entries);
    });
  }

  /// Fetches a single [DiaryEntry] whose [date] field matches the given
  /// [date] string (format: `YYYY-MM-DD`).
  ///
  /// Returns `null` if no entry exists for that day.
  Future<DiaryEntry?> getDiaryEntry(String date) async {
    final startOfDay = DateTime.parse(date); // YYYY-MM-DD → midnight UTC
    final endOfDay = startOfDay.add(const Duration(days: 1));

    final snap = await _col(AppConfig.diaryCollection)
        .where('isDeleted', isEqualTo: false)
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .where('date', isLessThan: Timestamp.fromDate(endOfDay))
        .limit(1)
        .get();

    if (snap.docs.isEmpty) return null;
    return DiaryEntry.fromJson(snap.docs.first.data());
  }

  Future<DiaryEntry?> getDiaryEntryById(String id) async {
    final doc = await _col(AppConfig.diaryCollection).doc(id).get();
    if (!doc.exists || doc.data() == null) return null;
    return DiaryEntry.fromJson(doc.data()!);
  }

  /// Upserts a [DiaryEntry] document, keyed by [entry.id].
  ///
  /// Uses [SetOptions(merge: true)] so existing fields not present in the
  /// payload are not overwritten.
  Future<void> saveDiaryEntry(DiaryEntry entry) async {
    final data = entry.toJson()..['updatedAt'] = Timestamp.now();
    await _col(
      AppConfig.diaryCollection,
    ).doc(entry.id).set(data, SetOptions(merge: true));
    final stored = await getDiaryEntryById(entry.id);
    if (stored != null) await _writeIndex(_diaryIndex(stored));
  }

  /// Soft-deletes the diary entry with [id].
  Future<void> deleteDiaryEntry(String id) async {
    await _col(AppConfig.diaryCollection).doc(id).update({
      'isDeleted': true,
      'deletedAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
    final stored = await getDiaryEntryById(id);
    if (stored != null) await _writeIndex(_diaryIndex(stored));
  }

  // ==========================================================================
  // CLOUD FILES
  // ==========================================================================

  Stream<List<CloudFileItem>> watchCloudFiles() {
    final col = _colOrNull(AppConfig.cloudFilesCollection);
    if (col == null) return Stream.value(const []);
    return col.snapshots().map((snap) {
      final files =
          snap.docs
              .map((doc) => CloudFileItem.fromJson(doc.data()))
              .toList(growable: true)
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return List<CloudFileItem>.unmodifiable(files);
    });
  }

  Future<void> addCloudFile(CloudFileItem file) async {
    await _col(AppConfig.cloudFilesCollection).doc(file.id).set(file.toJson());
  }

  Future<void> renameCloudFile(String id, String name) async {
    await _col(
      AppConfig.cloudFilesCollection,
    ).doc(id).update({'name': name, 'updatedAt': Timestamp.now()});
  }

  Future<void> deleteCloudFile(String id) async {
    await _col(AppConfig.cloudFilesCollection).doc(id).delete();
  }

  // ==========================================================================
  // EXPLORATION STATE
  // ==========================================================================

  /// Reads one user-scoped exploration state document.
  ///
  /// Path: `users/{uid}/exploration_state/{id}`.
  Future<Map<String, dynamic>?> loadExplorationState(String id) async {
    final snapshot = await _col(
      AppConfig.explorationStateCollection,
    ).doc(id).get();
    return snapshot.data();
  }

  /// Upserts one user-scoped exploration state document.
  Future<void> saveExplorationState(
    String id,
    Map<String, dynamic> data,
  ) async {
    await _col(AppConfig.explorationStateCollection).doc(id).set({
      ...data,
      'updatedAt': Timestamp.now(),
    }, SetOptions(merge: true));
  }

  Future<void> deleteExplorationState(String id) async {
    await _col(AppConfig.explorationStateCollection).doc(id).delete();
  }

  Stream<List<LiteratureLibraryItem>> watchLiteratureLibrary() {
    final col = _colOrNull(AppConfig.literatureLibraryCollection);
    if (col == null) return Stream.value(const []);
    return col.snapshots().map((snapshot) {
      final rows =
          snapshot.docs
              .map((doc) => LiteratureLibraryItem.fromJson(doc.data()))
              .toList(growable: true)
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return List<LiteratureLibraryItem>.unmodifiable(rows);
    });
  }

  Future<LiteratureLibraryItem?> getLiteratureLibraryItem(String id) async {
    final snapshot = await _col(
      AppConfig.literatureLibraryCollection,
    ).doc(id).get();
    final data = snapshot.data();
    return data == null ? null : LiteratureLibraryItem.fromJson(data);
  }

  Future<void> saveLiteratureLibraryItem(LiteratureLibraryItem item) async {
    await _col(
      AppConfig.literatureLibraryCollection,
    ).doc(item.id).set(item.toJson());
  }

  Future<void> deleteLiteratureLibraryItem(String id) async {
    await _col(AppConfig.literatureLibraryCollection).doc(id).delete();
  }

  // ==========================================================================
  // MEMOS
  // ==========================================================================

  /// Real-time stream of non-deleted [Memo]s.
  ///
  /// Sort order: pinned memos first, then by [createdAt] desc.
  /// Because Firestore does not support multi-field ordering on different
  /// fields with inequality filters in a single query, we fetch all active
  /// memos and sort client-side.
  Stream<List<Memo>> watchMemos() {
    final col = _colOrNull(AppConfig.memosCollection);
    if (col == null) return Stream.value([]);
    return col.snapshots().map((snap) {
      final memos = snap.docs
          .map((doc) => Memo.fromJson(doc.data()))
          .where((m) => !m.isDeleted)
          .toList(growable: true);
      memos.sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        return b.createdAt.compareTo(a.createdAt);
      });
      return List<Memo>.unmodifiable(memos);
    });
  }

  /// Writes a new [memo] document, keyed by [memo.id].
  Future<void> addMemo(Memo memo) async {
    await _col(AppConfig.memosCollection).doc(memo.id).set(memo.toJson());
    await _writeIndex(_memoIndex(memo));
  }

  /// Updates an existing [memo], stamping [updatedAt] with the current time.
  Future<void> updateMemo(Memo memo) async {
    final data = memo.toJson()..['updatedAt'] = Timestamp.now();
    await _col(AppConfig.memosCollection).doc(memo.id).update(data);
    final stored = await getMemo(memo.id);
    if (stored != null) await _writeIndex(_memoIndex(stored));
  }

  Future<Memo?> getMemo(String id) async {
    final doc = await _col(AppConfig.memosCollection).doc(id).get();
    if (!doc.exists || doc.data() == null) return null;
    return Memo.fromJson(doc.data()!);
  }

  /// Soft-deletes the memo with [id].
  Future<void> deleteMemo(String id) async {
    await _col(AppConfig.memosCollection).doc(id).update({
      'isDeleted': true,
      'deletedAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    });
    final stored = await getMemo(id);
    if (stored != null) await _writeIndex(_memoIndex(stored));
  }

  /// Toggles the pin state of the memo with [id].
  Future<void> toggleMemoPin(String id, bool isPinned) async {
    await _col(
      AppConfig.memosCollection,
    ).doc(id).update({'isPinned': isPinned, 'updatedAt': Timestamp.now()});
    final stored = await getMemo(id);
    if (stored != null) {
      await _col(
        AppConfig.memosCollection,
      ).doc(id).update({'displayOrderKey': stored.displayOrderKey});
      await _writeIndex(_memoIndex(stored));
    }
  }

  /// Real-time stream of soft-deleted [Memo]s, ordered by [deletedAt] desc.
  Stream<List<Memo>> watchDeletedMemos() {
    final col = _colOrNull(AppConfig.memosCollection);
    if (col == null) return Stream.value([]);
    return col.snapshots().map((snap) {
      final memos = snap.docs
          .map((doc) => Memo.fromJson(doc.data()))
          .where((m) => m.isDeleted)
          .toList(growable: true);
      memos.sort((a, b) {
        final da = a.deletedAt;
        final db = b.deletedAt;
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });
      return List<Memo>.unmodifiable(memos);
    });
  }

  /// Restores a soft-deleted memo with [id].
  Future<void> restoreMemo(String id) async {
    await _col(AppConfig.memosCollection).doc(id).update({
      'isDeleted': false,
      'deletedAt': null,
      'updatedAt': Timestamp.now(),
    });
    final stored = await getMemo(id);
    if (stored != null) await _writeIndex(_memoIndex(stored));
  }

  /// Permanently removes the memo document with [id] from Firestore.
  Future<void> permanentlyDeleteMemo(String id) async {
    final attachments = <String>{};
    final docSnap = await _col(AppConfig.memosCollection).doc(id).get();
    if (docSnap.exists) {
      final data = docSnap.data();
      if (data != null) {
        attachments.addAll(extractWebdavUrls(data));
      }
    }
    await _col(AppConfig.memosCollection).doc(id).delete();
    await _deleteIndex(IndexedContentType.memo, id);
    await deleteAttachmentsIfUnreferenced(attachments);
  }

  // ==========================================================================
  // DELETED DIARY
  // ==========================================================================

  /// Real-time stream of soft-deleted [DiaryEntry]s, ordered by [deletedAt] desc.
  Stream<List<DiaryEntry>> watchDeletedDiaries() {
    final col = _colOrNull(AppConfig.diaryCollection);
    if (col == null) return Stream.value([]);
    return col.snapshots().map((snap) {
      final entries = snap.docs
          .map((doc) => DiaryEntry.fromJson(doc.data()))
          .where((e) => e.isDeleted)
          .toList(growable: true);
      entries.sort((a, b) {
        final da = a.deletedAt;
        final db = b.deletedAt;
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });
      return List<DiaryEntry>.unmodifiable(entries);
    });
  }

  /// Restores a soft-deleted diary entry with [id].
  Future<void> restoreDiaryEntry(String id) async {
    await _col(AppConfig.diaryCollection).doc(id).update({
      'isDeleted': false,
      'deletedAt': null,
      'updatedAt': Timestamp.now(),
    });
    final stored = await getDiaryEntryById(id);
    if (stored != null) await _writeIndex(_diaryIndex(stored));
  }

  /// Permanently removes the diary entry document with [id] from Firestore.
  Future<void> permanentlyDeleteDiaryEntry(String id) async {
    final attachments = <String>{};
    final docSnap = await _col(AppConfig.diaryCollection).doc(id).get();
    if (docSnap.exists) {
      final data = docSnap.data();
      if (data != null) {
        attachments.addAll(extractWebdavUrls(data));
      }
    }
    await _col(AppConfig.diaryCollection).doc(id).delete();
    await _deleteIndex(IndexedContentType.diary, id);
    await deleteAttachmentsIfUnreferenced(attachments);
  }

  // ==========================================================================
  // AUTO PURGE
  // ==========================================================================

  Set<String> _collectAttachmentCandidates(
    QuerySnapshot<Map<String, dynamic>> querySnap,
  ) {
    final candidates = <String>{};
    for (final doc in querySnap.docs) {
      candidates.addAll(extractWebdavUrls(doc.data()));
    }
    return candidates;
  }

  /// Queries all collections (tasks, notes, memos, diary) and permanently deletes
  /// any document soft-deleted more than 30 days ago.
  Future<void> purgeExpiredTrash() async {
    final uid = _uidOrNull;
    if (uid == null) return;

    final threshold = DateTime.now().subtract(const Duration(days: 30));
    final thresholdTimestamp = Timestamp.fromDate(threshold);

    final collections = [
      AppConfig.tasksCollection,
      AppConfig.notesCollection,
      AppConfig.memosCollection,
      AppConfig.diaryCollection,
    ];

    for (final colName in collections) {
      try {
        final querySnap = await _col(colName)
            .where('isDeleted', isEqualTo: true)
            .where('deletedAt', isLessThanOrEqualTo: thresholdTimestamp)
            .get();

        if (querySnap.docs.isEmpty) continue;

        final attachments = _collectAttachmentCandidates(querySnap);
        if (colName == AppConfig.notesCollection) {
          for (final doc in querySnap.docs) {
            final versions = await doc.reference.collection('versions').get();
            for (final version in versions.docs) {
              attachments.addAll(extractWebdavUrls(version.data()));
              await version.reference.delete();
            }
          }
        }

        final batch = _db.batch();
        for (final doc in querySnap.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
        await deleteAttachmentsIfUnreferenced(attachments);

        debugPrint(
          'Purged ${querySnap.docs.length} expired items from $colName',
        );
      } catch (e) {
        debugPrint('Error purging collection $colName: $e');
      }
    }
  }

  /// Permanently deletes all soft-deleted items across all collections.
  Future<void> emptyTrash() async {
    final uid = _uidOrNull;
    if (uid == null) return;

    final collections = [
      AppConfig.tasksCollection,
      AppConfig.notesCollection,
      AppConfig.memosCollection,
      AppConfig.diaryCollection,
    ];

    for (final colName in collections) {
      try {
        final querySnap = await _col(
          colName,
        ).where('isDeleted', isEqualTo: true).get();

        if (querySnap.docs.isEmpty) continue;

        final attachments = _collectAttachmentCandidates(querySnap);
        if (colName == AppConfig.notesCollection) {
          for (final doc in querySnap.docs) {
            final versions = await doc.reference.collection('versions').get();
            for (final version in versions.docs) {
              attachments.addAll(extractWebdavUrls(version.data()));
              await version.reference.delete();
            }
          }
        }

        final batch = _db.batch();
        for (final doc in querySnap.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
        await deleteAttachmentsIfUnreferenced(attachments);
      } catch (e) {
        debugPrint('Error emptying trash for collection $colName: $e');
      }
    }
  }

  // ==========================================================================
  // ONE-OFF GETTERS FOR EXPORT/BACKUP
  // ==========================================================================

  Future<List<Task>> getTasksOnce() async {
    final col = _colOrNull(AppConfig.tasksCollection);
    if (col == null) return [];
    final snap = await col.get();
    return snap.docs
        .map((doc) => Task.fromJson(doc.data()))
        .where((t) => !t.isDeleted)
        .toList();
  }

  Future<List<Note>> getNotesOnce() async {
    final col = _colOrNull(AppConfig.notesCollection);
    if (col == null) return [];
    final snap = await col.get();
    return snap.docs
        .map((doc) => Note.fromJson(doc.data()))
        .where((n) => !n.isDeleted)
        .toList();
  }

  Future<List<DiaryEntry>> getDiariesOnce() async {
    final col = _colOrNull(AppConfig.diaryCollection);
    if (col == null) return [];
    final snap = await col.get();
    return snap.docs
        .map((doc) => DiaryEntry.fromJson(doc.data()))
        .where((d) => !d.isDeleted)
        .toList();
  }

  Future<List<Memo>> getMemosOnce() async {
    final col = _colOrNull(AppConfig.memosCollection);
    if (col == null) return [];
    final snap = await col.get();
    return snap.docs
        .map((doc) => Memo.fromJson(doc.data()))
        .where((m) => !m.isDeleted)
        .toList();
  }

  /// One-time, resumable migration that adds cursor sort keys and the light
  /// search index. It is intentionally separated from normal reads so opening
  /// a list never scans every full document after the migration has completed.
  Future<void> preparePagedCollections({bool force = false}) async {
    if (!force) {
      return _preparePagedFuture ??= _preparePagedCollectionsInternal();
    }
    await _preparePagedCollectionsInternal(force: true);
  }

  Future<void> _preparePagedCollectionsInternal({bool force = false}) async {
    final marker = _col(AppConfig.migrationsCollection).doc('paged_content_v1');
    if (!force && (await marker.get()).exists) return;

    await migrateLegacyTaskFields();
    final memoSnapshot = await _col(AppConfig.memosCollection).get();
    for (var offset = 0; offset < memoSnapshot.docs.length; offset += 400) {
      final batch = _db.batch();
      for (final doc in memoSnapshot.docs.skip(offset).take(400)) {
        final memo = Memo.fromJson(doc.data());
        batch.update(doc.reference, {'displayOrderKey': memo.displayOrderKey});
      }
      await batch.commit();
    }
    await rebuildContentIndex();
    await marker.set({'version': 1, 'completedAt': Timestamp.now()});
  }

  Future<void> rebuildContentIndex() async {
    final entries = <ContentIndexEntry>[];
    final tasks = await _col(AppConfig.tasksCollection).get();
    entries.addAll(
      tasks.docs.map((doc) => _taskIndex(Task.fromJson(doc.data()))),
    );
    final notes = await _col(AppConfig.notesCollection).get();
    entries.addAll(
      notes.docs.map((doc) => _noteIndex(Note.fromJson(doc.data()))),
    );
    final memos = await _col(AppConfig.memosCollection).get();
    entries.addAll(
      memos.docs.map((doc) => _memoIndex(Memo.fromJson(doc.data()))),
    );
    final diaries = await _col(AppConfig.diaryCollection).get();
    entries.addAll(
      diaries.docs.map((doc) => _diaryIndex(DiaryEntry.fromJson(doc.data()))),
    );
    for (var offset = 0; offset < entries.length; offset += 400) {
      final batch = _db.batch();
      for (final entry in entries.skip(offset).take(400)) {
        batch.set(_indexRef(entry.type, entry.sourceId), entry.toJson());
      }
      await batch.commit();
    }
  }

  Future<List<ContentIndexEntry>> searchContentIndex(
    String query, {
    int limit = 60,
  }) async {
    final terms = querySearchTerms(query)
      ..sort((a, b) => b.length.compareTo(a.length));
    if (terms.isEmpty) return const [];
    final snapshot = await _col(
      AppConfig.searchIndexCollection,
    ).where('searchTerms', arrayContains: terms.first).limit(limit * 2).get();
    final required = terms.take(6).toSet();
    final entries =
        snapshot.docs
            .map((doc) => ContentIndexEntry.fromJson(doc.data()))
            .where((entry) => !entry.isDeleted)
            .where((entry) => required.every(entry.searchTerms.contains))
            .toList(growable: true)
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return entries.take(limit).toList(growable: false);
  }

  Stream<FirestorePage<Task>> watchTasksPage({int limit = 50}) {
    final col = _colOrNull(AppConfig.tasksCollection);
    if (col == null) {
      return Stream.value(
        const FirestorePage(items: [], cursor: null, hasMore: false),
      );
    }
    return col.orderBy('displayOrderKey').limit(limit + 1).snapshots().map((
      snap,
    ) {
      final activeDocs = snap.docs.where(
        (doc) => !(doc.data()['isDeleted'] as bool? ?? false),
      );
      final docs = activeDocs.take(limit).toList(growable: false);
      final items =
          docs.map((doc) => Task.fromJson(doc.data())).toList(growable: true)
            ..sort(compareTasksForDisplay);
      return FirestorePage(
        items: List<Task>.unmodifiable(items),
        cursor: docs.isEmpty ? null : docs.last,
        hasMore: snap.docs.length > limit,
      );
    });
  }

  Stream<FirestorePage<Note>> watchNotesPage({int limit = 50}) {
    final col = _colOrNull(AppConfig.notesCollection);
    if (col == null) {
      return Stream.value(
        const FirestorePage(items: [], cursor: null, hasMore: false),
      );
    }
    return col
        .orderBy('createdAt', descending: true)
        .limit(limit + 1)
        .snapshots()
        .map((snap) {
          final activeDocs = snap.docs.where(
            (doc) => !(doc.data()['isDeleted'] as bool? ?? false),
          );
          final docs = activeDocs.take(limit).toList(growable: false);
          return FirestorePage(
            items: docs
                .map((doc) => Note.fromJson(doc.data()))
                .toList(growable: false),
            cursor: docs.isEmpty ? null : docs.last,
            hasMore: snap.docs.length > limit,
          );
        });
  }

  Stream<FirestorePage<Memo>> watchMemosPage({int limit = 50}) {
    final col = _colOrNull(AppConfig.memosCollection);
    if (col == null) {
      return Stream.value(
        const FirestorePage(items: [], cursor: null, hasMore: false),
      );
    }
    return col.orderBy('displayOrderKey').limit(limit + 1).snapshots().map((
      snap,
    ) {
      final activeDocs = snap.docs.where(
        (doc) => !(doc.data()['isDeleted'] as bool? ?? false),
      );
      final docs = activeDocs.take(limit).toList(growable: false);
      return FirestorePage(
        items: docs
            .map((doc) => Memo.fromJson(doc.data()))
            .toList(growable: false),
        cursor: docs.isEmpty ? null : docs.last,
        hasMore: snap.docs.length > limit,
      );
    });
  }

  Stream<List<DiaryEntry>> watchDiaryRange(DateTime from, DateTime to) {
    final col = _colOrNull(AppConfig.diaryCollection);
    if (col == null) return Stream.value(const []);
    return col
        .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .where('date', isLessThan: Timestamp.fromDate(to))
        .orderBy('date', descending: true)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .where((doc) => !(doc.data()['isDeleted'] as bool? ?? false))
              .map((doc) => DiaryEntry.fromJson(doc.data()))
              .toList(growable: false),
        );
  }

  Future<FirestorePage<Note>> getNotesPage({
    int limit = 50,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    Query<Map<String, dynamic>> query = _col(
      AppConfig.notesCollection,
    ).orderBy('createdAt', descending: true).limit(limit + 1);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snap = await query.get();
    final docs = snap.docs
        .where((doc) => !(doc.data()['isDeleted'] as bool? ?? false))
        .take(limit)
        .toList(growable: false);
    return FirestorePage(
      items: docs
          .map((doc) => Note.fromJson(doc.data()))
          .toList(growable: false),
      cursor: docs.isEmpty ? startAfter : docs.last,
      hasMore: snap.docs.length > limit,
    );
  }

  Future<FirestorePage<Memo>> getMemosPage({
    int limit = 50,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    Query<Map<String, dynamic>> query = _col(
      AppConfig.memosCollection,
    ).orderBy('displayOrderKey').limit(limit + 1);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snap = await query.get();
    final docs = snap.docs
        .where((doc) => !(doc.data()['isDeleted'] as bool? ?? false))
        .take(limit)
        .toList(growable: false);
    return FirestorePage(
      items: docs
          .map((doc) => Memo.fromJson(doc.data()))
          .toList(growable: false),
      cursor: docs.isEmpty ? startAfter : docs.last,
      hasMore: snap.docs.length > limit,
    );
  }

  Future<FirestorePage<Task>> getTasksPage({
    int limit = 50,
    DocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) async {
    Query<Map<String, dynamic>> query = _col(
      AppConfig.tasksCollection,
    ).orderBy('displayOrderKey').limit(limit + 1);
    if (startAfter != null) query = query.startAfterDocument(startAfter);
    final snap = await query.get();
    final docs = snap.docs
        .where((doc) => !(doc.data()['isDeleted'] as bool? ?? false))
        .take(limit)
        .toList(growable: false);
    return FirestorePage(
      items:
          (docs.map((doc) => Task.fromJson(doc.data())).toList(growable: true)
            ..sort(compareTasksForDisplay)),
      cursor: docs.isEmpty ? startAfter : docs.last,
      hasMore: snap.docs.length > limit,
    );
  }
}
