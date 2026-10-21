import 'package:flutter/material.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/models/memo_model.dart';
import 'package:syncnote/shared/models/diary_model.dart';
import 'package:intl/intl.dart';

class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key});

  Future<void> _showEmptyTrashDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text('清空回收站'),
          ],
        ),
        content: const Text('确认要永久删除回收站内的所有内容吗？此操作不可逆，数据将无法找回。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await FirestoreService.instance.emptyTrash();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🗑️ 回收站已成功清空'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            '回收站',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: '清空回收站',
              onPressed: () => _showEmptyTrashDialog(context),
            ),
          ],
          bottom: TabBar(
            isScrollable: false,
            indicatorColor: theme.colorScheme.primary,
            labelColor: theme.colorScheme.primary,
            unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
            tabs: const [
              Tab(icon: Icon(Icons.check_circle_outline_rounded), text: '任务'),
              Tab(icon: Icon(Icons.note_alt_outlined), text: '笔记'),
              Tab(icon: Icon(Icons.sticky_note_2_outlined), text: '备忘'),
              Tab(icon: Icon(Icons.menu_book_outlined), text: '日记'),
            ],
          ),
        ),
        body: Container(
          color: isDark ? Colors.grey[950] : Colors.grey[50],
          child: TabBarView(
            children: [
              _DeletedTasksList(),
              _DeletedNotesList(),
              _DeletedMemosList(),
              _DeletedDiariesList(),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrashEmptyWidget extends StatelessWidget {
  const _TrashEmptyWidget();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.delete_outline_rounded,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            '回收站为空',
            style: TextStyle(
              fontSize: 16,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeletedTasksList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Task>>(
      stream: FirestoreService.instance.watchDeletedTasks(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final tasks = snapshot.data ?? [];
        if (tasks.isEmpty) return const _TrashEmptyWidget();

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          itemCount: tasks.length,
          itemBuilder: (ctx, i) {
            final task = tasks[i];
            final dateStr = task.deletedAt != null
                ? DateFormat('MM-dd HH:mm').format(task.deletedAt!)
                : '未知';
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.blue.withValues(alpha: 0.1),
                  child: const Icon(
                    Icons.check_circle_outline,
                    color: Colors.blue,
                  ),
                ),
                title: Text(
                  task.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('删除时间: $dateStr'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.restore_rounded,
                        color: Colors.green,
                      ),
                      tooltip: '恢复',
                      onPressed: () =>
                          FirestoreService.instance.restoreTask(task.id),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_forever_rounded,
                        color: Colors.red,
                      ),
                      tooltip: '永久删除',
                      onPressed: () => FirestoreService.instance
                          .permanentlyDeleteTask(task.id),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _DeletedNotesList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Note>>(
      stream: FirestoreService.instance.watchDeletedNotes(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final notes = snapshot.data ?? [];
        if (notes.isEmpty) return const _TrashEmptyWidget();

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          itemCount: notes.length,
          itemBuilder: (ctx, i) {
            final note = notes[i];
            final dateStr = note.deletedAt != null
                ? DateFormat('MM-dd HH:mm').format(note.deletedAt!)
                : '未知';
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.orange.withValues(alpha: 0.1),
                  child: const Icon(
                    Icons.note_alt_outlined,
                    color: Colors.orange,
                  ),
                ),
                title: Text(
                  note.title.isEmpty ? '无标题笔记' : note.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('删除时间: $dateStr'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.restore_rounded,
                        color: Colors.green,
                      ),
                      tooltip: '恢复',
                      onPressed: () =>
                          FirestoreService.instance.restoreNote(note.id),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_forever_rounded,
                        color: Colors.red,
                      ),
                      tooltip: '永久删除',
                      onPressed: () => FirestoreService.instance
                          .permanentlyDeleteNote(note.id),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _DeletedMemosList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Memo>>(
      stream: FirestoreService.instance.watchDeletedMemos(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final memos = snapshot.data ?? [];
        if (memos.isEmpty) return const _TrashEmptyWidget();

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          itemCount: memos.length,
          itemBuilder: (ctx, i) {
            final memo = memos[i];
            final dateStr = memo.deletedAt != null
                ? DateFormat('MM-dd HH:mm').format(memo.deletedAt!)
                : '未知';
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.amber.withValues(alpha: 0.1),
                  child: const Icon(
                    Icons.sticky_note_2_outlined,
                    color: Colors.amber,
                  ),
                ),
                title: Text(
                  memo.content.length > 30
                      ? '${memo.content.substring(0, 30)}...'
                      : memo.content,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                subtitle: Text('删除时间: $dateStr'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.restore_rounded,
                        color: Colors.green,
                      ),
                      tooltip: '恢复',
                      onPressed: () =>
                          FirestoreService.instance.restoreMemo(memo.id),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_forever_rounded,
                        color: Colors.red,
                      ),
                      tooltip: '永久删除',
                      onPressed: () => FirestoreService.instance
                          .permanentlyDeleteMemo(memo.id),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _DeletedDiariesList extends StatelessWidget {
  String _getMoodEmoji(Mood mood) {
    switch (mood) {
      case Mood.great:
        return '🌟';
      case Mood.good:
        return '😊';
      case Mood.neutral:
        return '😐';
      case Mood.bad:
        return '😢';
      case Mood.awful:
        return '😤';
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<DiaryEntry>>(
      stream: FirestoreService.instance.watchDeletedDiaries(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final diaries = snapshot.data ?? [];
        if (diaries.isEmpty) return const _TrashEmptyWidget();

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          itemCount: diaries.length,
          itemBuilder: (ctx, i) {
            final entry = diaries[i];
            final diaryDateStr = DateFormat('yyyy年MM月dd日').format(entry.date);
            final dateStr = entry.deletedAt != null
                ? DateFormat('MM-dd HH:mm').format(entry.deletedAt!)
                : '未知';
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.green.withValues(alpha: 0.1),
                  child: Text(
                    _getMoodEmoji(entry.mood),
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
                title: Text(
                  '$diaryDateStr 的日记',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('删除时间: $dateStr'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.restore_rounded,
                        color: Colors.green,
                      ),
                      tooltip: '恢复',
                      onPressed: () =>
                          FirestoreService.instance.restoreDiaryEntry(entry.id),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_forever_rounded,
                        color: Colors.red,
                      ),
                      tooltip: '永久删除',
                      onPressed: () => FirestoreService.instance
                          .permanentlyDeleteDiaryEntry(entry.id),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
