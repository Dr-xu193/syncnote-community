import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';
import 'package:uuid/uuid.dart';

class TaskEditorScreen extends StatefulWidget {
  final Task? task;

  const TaskEditorScreen({super.key, this.task});

  @override
  State<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends State<TaskEditorScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _descController;
  late final TextEditingController _tagsController;

  late TaskPriority _priority;
  late TaskStatus _status;
  late RecurrenceType _recurrenceType;
  late List<DateTime> _reminderTimes;
  DateTime? _dueDate;
  bool _isArchived = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _titleController = TextEditingController(text: task?.title ?? '');
    _descController = TextEditingController(text: task?.description ?? '');
    _tagsController = TextEditingController(text: task?.tags.join(', ') ?? '');
    _priority = task?.priority ?? TaskPriority.normal;
    _status = task?.status ?? TaskStatus.todo;
    _dueDate = task?.dueDate;
    _reminderTimes = List<DateTime>.from(task?.reminderTimes ?? const []);
    _recurrenceType = task?.recurrenceType ?? RecurrenceType.none;
    _isArchived = task?.isArchived ?? false;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 10)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _pickDueDate() async {
    final oldDue = _dueDate;
    final picked = await _pickDateTime(_dueDate ?? DateTime.now());
    if (picked == null) return;
    setState(() {
      _dueDate = picked;
      if (_reminderTimes.isEmpty) {
        _reminderTimes.add(picked);
      } else if (oldDue != null) {
        _reminderTimes = _reminderTimes
            .map((time) => time == oldDue ? picked : time)
            .toList();
      }
    });
  }

  void _addRelativeReminder(Duration before) {
    final due = _dueDate;
    if (due == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先设置截止时间')));
      return;
    }
    final reminder = due.subtract(before);
    setState(() {
      if (!_reminderTimes.contains(reminder)) _reminderTimes.add(reminder);
      _reminderTimes.sort();
    });
  }

  Future<void> _addCustomReminder() async {
    final picked = await _pickDateTime(_dueDate ?? DateTime.now());
    if (picked == null) return;
    setState(() {
      if (!_reminderTimes.contains(picked)) _reminderTimes.add(picked);
      _reminderTimes.sort();
    });
  }

  List<String> _parseTags() => _tagsController.text
      .split(RegExp(r'[,，]'))
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toSet()
      .toList(growable: false);

  Future<void> _saveTask() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入任务名称')));
      return;
    }
    if (_recurrenceType != RecurrenceType.none && _dueDate == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('周期任务必须设置截止时间')));
      return;
    }

    setState(() => _isSaving = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw StateError('未登录');
      final now = DateTime.now();
      final recurrenceEnabled = _recurrenceType != RecurrenceType.none;

      if (widget.task == null) {
        final id = const Uuid().v4();
        final task = Task(
          id: id,
          title: title,
          description: _descController.text.trim(),
          status: _status,
          priority: _priority,
          dueDate: _dueDate,
          reminderTimes: _reminderTimes,
          isRecurring: recurrenceEnabled,
          recurrenceType: _recurrenceType,
          recurrenceSeriesId: recurrenceEnabled ? id : null,
          recurrenceOccurrenceKey: recurrenceEnabled && _dueDate != null
              ? _dueDate!.toUtc().toIso8601String()
              : null,
          tags: _parseTags(),
          isArchived: _isArchived,
          completedAt: _status == TaskStatus.done ? now : null,
          statusChangedAt: now,
          sortOrder: now.microsecondsSinceEpoch.toDouble(),
          createdAt: now,
          updatedAt: now,
          userId: user.uid,
        );
        await FirestoreService.instance.addTask(task);
      } else {
        final original = widget.task!;
        final updated = original.copyWith(
          title: title,
          description: _descController.text.trim(),
          priority: _priority,
          dueDate: _dueDate,
          clearDueDate: _dueDate == null,
          reminderTimes: _reminderTimes,
          isRecurring: recurrenceEnabled,
          recurrenceType: _recurrenceType,
          recurrenceSeriesId: recurrenceEnabled
              ? original.recurrenceSeriesId ?? original.id
              : null,
          recurrenceOccurrenceKey: recurrenceEnabled && _dueDate != null
              ? _dueDate!.toUtc().toIso8601String()
              : null,
          clearRecurrence: !recurrenceEnabled,
          tags: _parseTags(),
          isArchived: _isArchived,
          updatedAt: now,
        );
        await FirestoreService.instance.updateTask(updated);
        if (_status != original.status) {
          await FirestoreService.instance.changeTaskStatus(updated, _status);
        }
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _addSubtask(Task parent) async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加子任务'),
        content: TextField(
          controller: controller,
          autofocus: true,
          contextMenuBuilder:
              AiContextMenuHelper.editableTextContextMenuBuilder,
          decoration: const InputDecoration(hintText: '子任务名称'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty) return;
    final now = DateTime.now();
    final child = Task(
      id: const Uuid().v4(),
      title: title,
      parentId: parent.id,
      statusChangedAt: now,
      sortOrder: now.microsecondsSinceEpoch.toDouble(),
      createdAt: now,
      updatedAt: now,
      userId: parent.userId,
    );
    await FirestoreService.instance.addSubtask(parent, child);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.task == null ? '新建任务' : '编辑任务'),
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: '保存',
              icon: const Icon(Icons.check_rounded),
              onPressed: _saveTask,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleController,
            contextMenuBuilder:
                AiContextMenuHelper.editableTextContextMenuBuilder,
            decoration: const InputDecoration(
              labelText: '任务名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _descController,
            maxLines: 3,
            contextMenuBuilder:
                AiContextMenuHelper.editableTextContextMenuBuilder,
            decoration: const InputDecoration(
              labelText: '描述',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<TaskStatus>(
                  initialValue: _status,
                  decoration: const InputDecoration(
                    labelText: '状态',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: TaskStatus.todo, child: Text('待办')),
                    DropdownMenuItem(
                      value: TaskStatus.inProgress,
                      child: Text('进行中'),
                    ),
                    DropdownMenuItem(
                      value: TaskStatus.done,
                      child: Text('已完成'),
                    ),
                  ],
                  onChanged: (value) => setState(() => _status = value!),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<TaskPriority>(
                  initialValue: _priority,
                  decoration: const InputDecoration(
                    labelText: '优先级',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: TaskPriority.low, child: Text('低')),
                    DropdownMenuItem(
                      value: TaskPriority.normal,
                      child: Text('普通'),
                    ),
                    DropdownMenuItem(
                      value: TaskPriority.high,
                      child: Text('高'),
                    ),
                    DropdownMenuItem(
                      value: TaskPriority.urgent,
                      child: Text('紧急'),
                    ),
                  ],
                  onChanged: (value) => setState(() => _priority = value!),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ListTile(
            title: const Text('截止时间'),
            subtitle: Text(
              _dueDate == null
                  ? '未设置'
                  : DateFormat('yyyy-MM-dd HH:mm').format(_dueDate!),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_dueDate != null)
                  IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() {
                      _reminderTimes.remove(_dueDate);
                      _dueDate = null;
                    }),
                  ),
                const Icon(Icons.event_rounded),
              ],
            ),
            onTap: _pickDueDate,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          const SizedBox(height: 14),
          Text('提醒时间', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                label: const Text('到期时'),
                onPressed: () => _addRelativeReminder(Duration.zero),
              ),
              ActionChip(
                label: const Text('提前 2 小时'),
                onPressed: () => _addRelativeReminder(const Duration(hours: 2)),
              ),
              ActionChip(
                label: const Text('提前 1 天'),
                onPressed: () => _addRelativeReminder(const Duration(days: 1)),
              ),
              ActionChip(
                avatar: const Icon(Icons.add_alarm_rounded, size: 18),
                label: const Text('自定义'),
                onPressed: _addCustomReminder,
              ),
            ],
          ),
          for (final reminder in _reminderTimes)
            ListTile(
              dense: true,
              leading: const Icon(Icons.alarm_rounded),
              title: Text(DateFormat('yyyy-MM-dd HH:mm').format(reminder)),
              trailing: IconButton(
                tooltip: '删除提醒',
                icon: const Icon(Icons.close),
                onPressed: () =>
                    setState(() => _reminderTimes.remove(reminder)),
              ),
            ),
          const SizedBox(height: 10),
          DropdownButtonFormField<RecurrenceType>(
            initialValue: _recurrenceType,
            decoration: const InputDecoration(
              labelText: '重复',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: RecurrenceType.none, child: Text('不重复')),
              DropdownMenuItem(value: RecurrenceType.daily, child: Text('每天')),
              DropdownMenuItem(value: RecurrenceType.weekly, child: Text('每周')),
              DropdownMenuItem(
                value: RecurrenceType.monthly,
                child: Text('每月'),
              ),
            ],
            onChanged: (value) => setState(() => _recurrenceType = value!),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _tagsController,
            contextMenuBuilder:
                AiContextMenuHelper.editableTextContextMenuBuilder,
            decoration: const InputDecoration(
              labelText: '标签',
              hintText: '工作, 学习',
              prefixIcon: Icon(Icons.sell_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('归档任务'),
            subtitle: const Text('归档后不出现在当前任务和 AI 排程中'),
            value: _isArchived,
            onChanged: (value) => setState(() => _isArchived = value),
          ),
          if (widget.task != null) ...[
            const Divider(height: 32),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '子任务',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _addSubtask(widget.task!),
                  icon: const Icon(Icons.add),
                  label: const Text('添加'),
                ),
              ],
            ),
            StreamBuilder<List<Task>>(
              stream: FirestoreService.instance.watchTasks(),
              builder: (context, snapshot) {
                final children = (snapshot.data ?? const <Task>[])
                    .where((task) => task.parentId == widget.task!.id)
                    .toList();
                if (children.isEmpty) {
                  return const Text('暂无子任务');
                }
                return Column(
                  children: children
                      .map(
                        (child) => CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(child.title),
                          value: child.status == TaskStatus.done,
                          onChanged: (done) =>
                              FirestoreService.instance.changeTaskStatus(
                                child,
                                done == true
                                    ? TaskStatus.done
                                    : TaskStatus.todo,
                              ),
                          secondary: IconButton(
                            tooltip: '删除子任务',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () =>
                                FirestoreService.instance.deleteTask(child.id),
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              icon: const Icon(Icons.delete_outline),
              label: const Text('移入回收站'),
              onPressed: () async {
                await FirestoreService.instance.deleteTask(widget.task!.id);
                if (context.mounted) {
                  Navigator.pop(context);
                }
              },
            ),
          ],
        ],
      ),
    );
  }
}
