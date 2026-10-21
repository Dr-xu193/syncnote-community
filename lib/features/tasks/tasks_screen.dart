import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncnote/features/tasks/task_editor_screen.dart';
import 'package:syncnote/features/tasks/widgets/task_stats_widget.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/controllers/cursor_paged_controller.dart';
import 'package:syncnote/shared/services/ai_service.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/widgets/nullable_string_filter_menu.dart';

enum _TaskTimeView { all, today, overdue, completedToday, archived }

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  static const int _pageSize = 50;
  TaskStatus? _statusFilter;
  _TaskTimeView _timeView = _TaskTimeView.all;
  String? _tagFilter;
  bool _manualOrderMode = false;
  late final CursorPagedController<Task> _tasksController;

  @override
  void initState() {
    super.initState();
    _tasksController = CursorPagedController<Task>(idOf: (task) => task.id);
    _prepareList();
  }

  Future<void> _prepareList() async {
    await FirestoreService.instance.preparePagedCollections();
    if (!mounted) return;
    _tasksController.start(
      firstPage: FirestoreService.instance.watchTasksPage(limit: _pageSize),
      loadPage: (cursor) => FirestoreService.instance.getTasksPage(
        limit: _pageSize,
        startAfter: cursor,
      ),
    );
  }

  @override
  void dispose() {
    _tasksController.dispose();
    super.dispose();
  }

  bool get _canReorder =>
      _manualOrderMode &&
      _statusFilter == null &&
      _tagFilter == null &&
      _timeView == _TaskTimeView.all;

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  List<Task> _filterTasks(List<Task> allTasks) {
    final now = DateTime.now();
    return allTasks.where((task) {
      if (task.parentId != null) return false;
      if (_timeView == _TaskTimeView.archived) return task.isArchived;
      if (task.isArchived) return false;
      if (_statusFilter != null && task.status != _statusFilter) return false;
      if (_tagFilter != null && !task.tags.contains(_tagFilter)) return false;

      return switch (_timeView) {
        _TaskTimeView.all => true,
        _TaskTimeView.today =>
          task.dueDate != null && _sameDay(task.dueDate!, now),
        _TaskTimeView.overdue =>
          task.status != TaskStatus.done &&
              task.dueDate != null &&
              task.dueDate!.isBefore(now),
        _TaskTimeView.completedToday =>
          task.effectiveCompletedAt != null &&
              _sameDay(task.effectiveCompletedAt!, now),
        _TaskTimeView.archived => task.isArchived,
      };
    }).toList();
  }

  Future<void> _runAiSchedule() async {
    NavigatorState? progressNavigator;
    void closeProgressDialog() {
      final navigator = progressNavigator;
      if (navigator != null && navigator.canPop()) {
        navigator.pop();
      }
    }

    try {
      final activeTasks = await FirestoreService.instance.getActiveTasks();
      if (activeTasks.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('当前没有可排程任务')));
        }
        return;
      }
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialog) {
          progressNavigator = Navigator.of(dialog);
          return const AlertDialog(
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Text('AI 正在安排任务顺序...'),
              ],
            ),
          );
        },
      );
      final sorted = await AIService.instance.prioritizeTasks(activeTasks);
      await FirestoreService.instance.reorderTasks(sorted);
      closeProgressDialog();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未完成任务的 AI 排程已完成')));
      }
    } catch (error) {
      closeProgressDialog();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('排程失败：$error')));
      }
    }
  }

  Future<void> _postpone(Task task) async {
    final oldDue = task.dueDate;
    final now = DateTime.now();
    final base = oldDue ?? now;
    final tomorrow = DateTime(
      now.year,
      now.month,
      now.day + 1,
      base.hour,
      base.minute,
    );
    final shift = oldDue == null ? Duration.zero : tomorrow.difference(oldDue);
    final reminders = oldDue == null
        ? <DateTime>[tomorrow]
        : task.reminderTimes
              .map((reminder) => reminder.add(shift))
              .toList(growable: false);
    await FirestoreService.instance.updateTask(
      task.copyWith(
        dueDate: tomorrow,
        reminderTimes: reminders,
        updatedAt: now,
      ),
    );
  }

  Future<void> _postponeToCustomDate(Task task) async {
    final initial = task.dueDate ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    final target = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final oldDue = task.dueDate;
    final shift = oldDue == null ? Duration.zero : target.difference(oldDue);
    final reminders = oldDue == null
        ? <DateTime>[target]
        : task.reminderTimes
              .map((reminder) => reminder.add(shift))
              .toList(growable: false);
    await FirestoreService.instance.updateTask(
      task.copyWith(
        dueDate: target,
        reminderTimes: reminders,
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('任务'),
        actions: [
          IconButton(
            tooltip: _manualOrderMode ? '退出手动微调' : '手动微调顺序',
            icon: Icon(
              _manualOrderMode
                  ? Icons.swap_vert_circle_rounded
                  : Icons.swap_vert_rounded,
            ),
            onPressed: () => setState(() {
              _manualOrderMode = !_manualOrderMode;
            }),
          ),
          IconButton(
            tooltip: '完成统计',
            icon: const Icon(Icons.bar_chart_rounded),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              builder: (_) => const TaskStatsSheet(),
            ),
          ),
          IconButton(
            tooltip: 'AI 排程（仅未完成任务）',
            icon: const Icon(Icons.auto_awesome),
            onPressed: _runAiSchedule,
          ),
          IconButton(
            tooltip: '新建任务',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const TaskEditorScreen())),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _tasksController,
        builder: (context, _) {
          if (!_tasksController.ready) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_tasksController.error != null &&
              _tasksController.items.isEmpty) {
            return Center(child: Text('云端任务加载失败：${_tasksController.error}'));
          }
          final allTasks = _tasksController.items;
          final tasks = _filterTasks(allTasks);
          final allTags = allTasks.expand((task) => task.tags).toSet().toList()
            ..sort();

          return Column(
            children: [
              _TaskFilters(
                status: _statusFilter,
                timeView: _timeView,
                tag: _tagFilter,
                tags: allTags,
                onStatusChanged: (value) =>
                    setState(() => _statusFilter = value),
                onTimeViewChanged: (value) => setState(() => _timeView = value),
                onTagChanged: (value) => setState(() => _tagFilter = value),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? const Center(child: Text('当前筛选下没有任务'))
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: _canReorder,
                        padding: const EdgeInsets.only(bottom: 80),
                        itemCount:
                            tasks.length + (_tasksController.hasMore ? 1 : 0),
                        onReorderItem: _canReorder
                            ? (oldIndex, newIndex) {
                                if (oldIndex >= tasks.length ||
                                    newIndex > tasks.length) {
                                  return;
                                }
                                final reordered = List<Task>.from(tasks);
                                final task = reordered.removeAt(oldIndex);
                                reordered.insert(newIndex, task);
                                FirestoreService.instance.reorderTasks(
                                  reordered,
                                );
                              }
                            : (_, _) {},
                        itemBuilder: (context, index) {
                          if (index == tasks.length) {
                            return Padding(
                              key: const ValueKey('load-more-tasks'),
                              padding: const EdgeInsets.all(16),
                              child: OutlinedButton.icon(
                                onPressed: _tasksController.loadingMore
                                    ? null
                                    : _tasksController.loadMore,
                                icon: _tasksController.loadingMore
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.expand_more_rounded),
                                label: Text('加载更多（已显示 ${tasks.length}）'),
                              ),
                            );
                          }
                          final task = tasks[index];
                          final children = allTasks
                              .where((item) => item.parentId == task.id)
                              .toList();
                          return _TaskCard(
                            key: ValueKey(task.id),
                            task: task,
                            children: children,
                            onPostpone: () => _postpone(task),
                            onCustomPostpone: () => _postponeToCustomDate(task),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TaskFilters extends StatelessWidget {
  const _TaskFilters({
    required this.status,
    required this.timeView,
    required this.tag,
    required this.tags,
    required this.onStatusChanged,
    required this.onTimeViewChanged,
    required this.onTagChanged,
  });

  final TaskStatus? status;
  final _TaskTimeView timeView;
  final String? tag;
  final List<String> tags;
  final ValueChanged<TaskStatus?> onStatusChanged;
  final ValueChanged<_TaskTimeView> onTimeViewChanged;
  final ValueChanged<String?> onTagChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: status == null,
                  onSelected: (_) => onStatusChanged(null),
                ),
                const SizedBox(width: 8),
                for (final entry in const [
                  (TaskStatus.todo, '待办'),
                  (TaskStatus.inProgress, '进行中'),
                  (TaskStatus.done, '已完成'),
                ]) ...[
                  ChoiceChip(
                    label: Text(entry.$2),
                    selected: status == entry.$1,
                    onSelected: (_) => onStatusChanged(entry.$1),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Row(
              children: [
                for (final entry in const [
                  (_TaskTimeView.all, '当前'),
                  (_TaskTimeView.today, '今日'),
                  (_TaskTimeView.overdue, '逾期'),
                  (_TaskTimeView.completedToday, '今日完成'),
                  (_TaskTimeView.archived, '归档'),
                ]) ...[
                  FilterChip(
                    label: Text(entry.$2),
                    selected: timeView == entry.$1,
                    onSelected: (_) => onTimeViewChanged(entry.$1),
                  ),
                  const SizedBox(width: 8),
                ],
                if (tags.isNotEmpty)
                  NullableStringFilterMenu(
                    tooltip: '按标签筛选',
                    values: tags,
                    selectedValue: tag,
                    allLabel: '全部标签',
                    onSelected: onTagChanged,
                    child: Chip(
                      avatar: const Icon(Icons.sell_outlined, size: 18),
                      label: Text(tag ?? '标签'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    super.key,
    required this.task,
    required this.children,
    required this.onPostpone,
    required this.onCustomPostpone,
  });

  final Task task;
  final List<Task> children;
  final VoidCallback onPostpone;
  final VoidCallback onCustomPostpone;

  Color _priorityColor() => switch (task.priority) {
    TaskPriority.low => Colors.green,
    TaskPriority.normal => Colors.blue,
    TaskPriority.high => Colors.orange,
    TaskPriority.urgent => Colors.red,
  };

  @override
  Widget build(BuildContext context) {
    final completedChildren = children
        .where((child) => child.status == TaskStatus.done)
        .length;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        leading: PopupMenuButton<TaskStatus>(
          tooltip: '更改状态',
          initialValue: task.status,
          onSelected: (status) =>
              FirestoreService.instance.changeTaskStatus(task, status),
          itemBuilder: (_) => const [
            PopupMenuItem(value: TaskStatus.todo, child: Text('待办')),
            PopupMenuItem(value: TaskStatus.inProgress, child: Text('进行中')),
            PopupMenuItem(value: TaskStatus.done, child: Text('已完成')),
          ],
          child: Icon(
            switch (task.status) {
              TaskStatus.todo => Icons.radio_button_unchecked,
              TaskStatus.inProgress => Icons.timelapse_rounded,
              TaskStatus.done => Icons.check_circle_rounded,
            },
            color: task.status == TaskStatus.done
                ? Colors.green
                : Theme.of(context).colorScheme.primary,
          ),
        ),
        title: Text(
          task.title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            decoration: task.status == TaskStatus.done
                ? TextDecoration.lineThrough
                : null,
          ),
        ),
        subtitle: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Icon(Icons.flag, size: 14, color: _priorityColor()),
            if (task.dueDate != null)
              Text(DateFormat('MM-dd HH:mm').format(task.dueDate!)),
            if (task.reminderTimes.length > 1)
              Text('${task.reminderTimes.length} 个提醒'),
            if (task.isRecurring) const Icon(Icons.repeat_rounded, size: 16),
            if (children.isNotEmpty)
              Text('子任务 $completedChildren/${children.length}'),
            ...task.tags.map((tag) => Chip(label: Text(tag))),
          ],
        ),
        trailing: PopupMenuButton<String>(
          tooltip: '更多操作',
          onSelected: (action) async {
            switch (action) {
              case 'edit':
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TaskEditorScreen(task: task),
                  ),
                );
              case 'postpone':
                onPostpone();
              case 'customPostpone':
                onCustomPostpone();
              case 'archive':
                await FirestoreService.instance.updateTask(
                  task.copyWith(
                    isArchived: !task.isArchived,
                    updatedAt: DateTime.now(),
                  ),
                );
              case 'delete':
                await FirestoreService.instance.deleteTask(task.id);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
            if (task.status != TaskStatus.done) ...const [
              PopupMenuItem(value: 'postpone', child: Text('延期到明天')),
              PopupMenuItem(value: 'customPostpone', child: Text('延期到指定时间')),
            ],
            PopupMenuItem(
              value: 'archive',
              child: Text(task.isArchived ? '取消归档' : '归档'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'delete', child: Text('移入回收站')),
          ],
        ),
        onExpansionChanged: (_) {},
        children: [
          if (task.description.isNotEmpty)
            ListTile(title: Text(task.description)),
          for (final child in children)
            CheckboxListTile(
              dense: true,
              title: Text(child.title),
              value: child.status == TaskStatus.done,
              onChanged: (done) => FirestoreService.instance.changeTaskStatus(
                child,
                done == true ? TaskStatus.done : TaskStatus.todo,
              ),
            ),
          if (children.isEmpty)
            const ListTile(dense: true, title: Text('没有子任务')),
        ],
      ),
    );
  }
}
