import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/models/memo_model.dart';
import 'package:syncnote/shared/models/diary_model.dart';
import 'package:syncnote/shared/models/content_index_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/cold_archive_service.dart';
import 'package:syncnote/shared/services/ai_service.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';
import 'package:go_router/go_router.dart';
import 'package:syncnote/features/tasks/task_editor_screen.dart';
import 'package:syncnote/features/notes/note_editor_screen.dart';
import 'package:syncnote/features/memos/memos_screen.dart';
import 'package:syncnote/features/diary/diary_screen.dart';
import 'package:syncnote/shared/models/ai_chat_model.dart';
import 'package:syncnote/shared/models/ai_assistant_model.dart';
import 'package:syncnote/shared/services/ai_assistant_service.dart';
import 'package:uuid/uuid.dart';

class SearchResultItem {
  final String id;
  final String title;
  final String subtitle;
  final String type;
  final String rawText;
  final dynamic originalObject;

  SearchResultItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.rawText,
    required this.originalObject,
  });
}

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final List<String> sourceRefs;
  final Map<String, dynamic>? retrievalPlan;
  final AiUsageRecord? usage;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.sourceRefs = const [],
    this.retrievalPlan,
    this.usage,
  });
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  StreamSubscription<List<AiChat>>? _chatsSub;
  StreamSubscription<List<AiChatMessage>>? _messagesSub;

  final List<SearchResultItem> _searchResults = [];
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  bool _isIndexSearching = false;

  // Search tab state
  bool _isAiSearching = false;
  String? _aiResult;

  // Q&A tab state
  final List<ChatMessage> _chatMessages = [];
  final List<AiChatMessage> _rawChatMessages = [];
  List<AiChat> _chats = [];
  AiChat? _currentChat;
  bool _isChatThinking = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    FirestoreService.instance.preparePagedCollections().catchError((_) {});
    _chatsSub = FirestoreService.instance.watchAiChats().listen((chats) {
      if (!mounted) return;
      setState(() {
        _chats = chats;
        if (_currentChat != null) {
          _currentChat = chats
              .where((chat) => chat.id == _currentChat!.id)
              .firstOrNull;
        }
      });
      if (_currentChat == null && chats.isNotEmpty) {
        _selectChat(chats.first);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    _searchDebounce?.cancel();
    _chatsSub?.cancel();
    _messagesSub?.cancel();
    super.dispose();
  }

  List<SearchResultItem> get _filteredItems =>
      List<SearchResultItem>.unmodifiable(_searchResults);

  SearchResultItem _fromIndex(ContentIndexEntry entry) => SearchResultItem(
    id: entry.sourceId,
    title: entry.isColdArchived ? '${entry.title}（冷归档）' : entry.title,
    subtitle: entry.summary,
    type: switch (entry.type) {
      IndexedContentType.task => 'Task',
      IndexedContentType.note => 'Note',
      IndexedContentType.memo => 'Memo',
      IndexedContentType.diary => 'Diary',
    },
    rawText: '${entry.title} ${entry.summary}',
    originalObject: entry,
  );

  void _scheduleIndexSearch(String value) {
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _searchResults.clear();
        _isIndexSearching = false;
      });
      return;
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 280),
      () => _runIndexSearch(value),
    );
  }

  Future<void> _runIndexSearch(String value) async {
    final generation = ++_searchGeneration;
    if (mounted) setState(() => _isIndexSearching = true);
    try {
      await FirestoreService.instance.preparePagedCollections();
      final entries = await FirestoreService.instance.searchContentIndex(value);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchResults
          ..clear()
          ..addAll(entries.map(_fromIndex));
        _isIndexSearching = false;
      });
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() => _isIndexSearching = false);
    }
  }

  Future<void> _openResult(SearchResultItem item) async {
    try {
      final value = item.originalObject;
      if (value is ContentIndexEntry) {
        if (value.isColdArchived) {
          final collection = switch (value.type) {
            IndexedContentType.task => 'tasks',
            IndexedContentType.note => 'notes',
            IndexedContentType.memo => 'memos',
            IndexedContentType.diary => 'diary',
          };
          final record = await ColdArchiveService.instance.getArchivedRecord(
            collection,
            value.sourceId,
          );
          if (record == null) return _showUnavailable();
          if (!mounted) return;
          final restore = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('该内容已冷归档'),
              content: const Text('完整正文位于坚果云。恢复后可继续查看和编辑，标题、标签和关系不会改变。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('恢复并打开'),
                ),
              ],
            ),
          );
          if (restore != true) return;
          await ColdArchiveService.instance.restoreRecord(record);
        }
        switch (value.type) {
          case IndexedContentType.task:
            final latest = await FirestoreService.instance.getTask(
              value.sourceId,
            );
            if (latest == null || latest.isDeleted) return _showUnavailable();
            if (!mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => TaskEditorScreen(task: latest)),
            );
            return;
          case IndexedContentType.note:
            final latest = await FirestoreService.instance.getNoteById(
              value.sourceId,
            );
            if (latest == null || latest.isDeleted) return _showUnavailable();
            if (!mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => NoteEditorScreen(note: latest)),
            );
            return;
          case IndexedContentType.memo:
            final latest = await FirestoreService.instance.getMemo(
              value.sourceId,
            );
            if (latest == null || latest.isDeleted) return _showUnavailable();
            if (!mounted) return;
            await showAddMemoDialog(context, latest);
            return;
          case IndexedContentType.diary:
            final latest = await FirestoreService.instance.getDiaryEntryById(
              value.sourceId,
            );
            if (latest == null || latest.isDeleted) return _showUnavailable();
            if (!mounted) return;
            await showDiaryEntrySheet(context, latest.date, latest);
            return;
        }
      }
      if (value is Task) {
        final latest = await FirestoreService.instance.getTask(value.id);
        if (latest == null || latest.isDeleted) return _showUnavailable();
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => TaskEditorScreen(task: latest)),
        );
        return;
      }
      if (value is Note) {
        final latest = await FirestoreService.instance.getNoteById(value.id);
        if (latest == null || latest.isDeleted) return _showUnavailable();
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => NoteEditorScreen(note: latest)),
        );
        return;
      }
      if (value is Memo) {
        final latest = await FirestoreService.instance.getMemo(value.id);
        if (latest == null || latest.isDeleted) return _showUnavailable();
        if (!mounted) return;
        await showAddMemoDialog(context, latest);
        return;
      }
      if (value is DiaryEntry) {
        final latest = await FirestoreService.instance.getDiaryEntryById(
          value.id,
        );
        if (latest == null || latest.isDeleted) return _showUnavailable();
        if (!mounted) return;
        await showDiaryEntrySheet(context, latest.date, latest);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法读取云端内容，请检查网络后重试')));
    }
  }

  void _showUnavailable() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('该内容已删除或不存在')));
  }

  Future<void> _performAiSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isAiSearching = true;
      _aiResult = null;
    });

    await _runIndexSearch(query);
    final allItems = _filteredItems;
    final contents = allItems
        .map((e) => '[${e.type}] ${e.title}: ${e.subtitle}')
        .toList();

    final result = await AIService.instance.smartSearch(query, contents);

    if (mounted) {
      setState(() {
        _isAiSearching = false;
        _aiResult = result ?? '未找到相关内容。';
      });
    }
  }

  void _selectChat(AiChat chat) {
    _messagesSub?.cancel();
    _currentChat = chat;
    _messagesSub = FirestoreService.instance
        .watchAiChatMessages(chat.id)
        .listen((messages) {
          if (!mounted) return;
          setState(() {
            _rawChatMessages
              ..clear()
              ..addAll(messages);
            _chatMessages
              ..clear()
              ..addAll(
                messages.map(
                  (message) => ChatMessage(
                    text: message.content,
                    isUser: message.role == 'user',
                    timestamp: message.createdAt,
                    sourceRefs: message.sourceRefs,
                    retrievalPlan: message.retrievalPlan,
                    usage: message.usage,
                  ),
                ),
              );
          });
          _scrollToBottom();
        });
  }

  Future<void> _newChat() async {
    final chat = await FirestoreService.instance.createAiChat();
    _selectChat(chat);
  }

  Future<void> _deleteCurrentChat() async {
    final chat = _currentChat;
    if (chat == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除该 AI 对话？'),
        content: const Text('云端消息和对应子集合将被永久删除，且不会保留本地副本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _messagesSub?.cancel();
    await FirestoreService.instance.deleteAiChat(chat.id);
    if (!mounted) return;
    setState(() {
      _currentChat = null;
      _chatMessages.clear();
      _rawChatMessages.clear();
    });
  }

  Future<void> _renameCurrentChat() async {
    final chat = _currentChat;
    if (chat == null) return;
    final controller = TextEditingController(text: chat.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          contextMenuBuilder:
              AiContextMenuHelper.editableTextContextMenuBuilder,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title != null && title.isNotEmpty) {
      await FirestoreService.instance.renameAiChat(chat.id, title);
    }
  }

  Future<void> _clearChats() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部 AI 对话？'),
        content: const Text('所有云端对话和消息将被永久删除，不会残留本地文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _messagesSub?.cancel();
      await FirestoreService.instance.clearAiChats();
      if (mounted) {
        setState(() {
          _currentChat = null;
          _chatMessages.clear();
          _rawChatMessages.clear();
        });
      }
    }
  }

  Future<void> _sendChatMessage() async {
    final query = _chatController.text.trim();
    if (query.isEmpty || _isChatThinking) return;

    setState(() => _isChatThinking = true);
    try {
      if (!await AiAssistantService.instance.isAutomaticBudgetAvailable()) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('本月 AI 提醒额度已达到'),
            content: const Text('自动 AI 已暂停。此次是手动提问，是否仍继续调用？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('继续本次'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
      _chatController.clear();
      var chat = _currentChat;
      if (chat == null) {
        chat = await FirestoreService.instance.createAiChat(
          query.length > 18 ? '${query.substring(0, 18)}…' : query,
        );
        _selectChat(chat);
      }
      final enabledSources = chat.enabledSources;
      final plan = await AiAssistantService.instance.createRetrievalPlan(
        query,
        enabledSources: enabledSources,
      );
      final personalContext = await AiAssistantService.instance
          .retrievePersonalContext(plan);
      final memories = plan.sources.contains('memories')
          ? await AiAssistantService.instance.getEnabledMemories()
          : const <AiMemory>[];
      final resources = plan.sources.contains('resources')
          ? await AiAssistantService.instance.getResources(chat.id)
          : const <AiChatResource>[];
      final earlier = plan.sources.contains('chat_history')
          ? await AiAssistantService.instance.findEarlierChatSnippets(
              chat.id,
              query,
            )
          : const <AiChatMessage>[];
      final recent = _rawChatMessages.length > 80
          ? _rawChatMessages.sublist(_rawChatMessages.length - 80)
          : List<AiChatMessage>.from(_rawChatMessages);
      await FirestoreService.instance.addAiChatMessage(
        chat.id,
        AiChatMessage(
          id: const Uuid().v4(),
          role: 'user',
          content: query,
          createdAt: DateTime.now(),
        ),
      );
      _scrollToBottom();

      final answer = await AiAssistantService.instance.answer(
        question: query,
        plan: plan,
        personalContext: personalContext,
        recentMessages: recent,
        earlierSnippets: earlier
            .where((item) => !recent.any((recent) => recent.id == item.id))
            .toList(growable: false),
        memories: memories,
        resources: resources,
        conversationSummary: chat.memorySummary,
      );
      await FirestoreService.instance.addAiChatMessage(
        chat.id,
        AiChatMessage(
          id: const Uuid().v4(),
          role: 'assistant',
          content: answer.content,
          createdAt: DateTime.now(),
          sourceRefs: answer.sources,
          retrievalPlan: answer.plan.toJson(),
          usage: answer.usage,
        ),
      );

      final messageCount = _rawChatMessages.length + 2;
      if (messageCount >= 40 && messageCount % 20 < 2) {
        final summaryInput = [...recent]
            .map(
              (message) => {'role': message.role, 'content': message.content},
            )
            .toList(growable: false);
        summaryInput.add({'role': 'user', 'content': query});
        summaryInput.add({'role': 'assistant', 'content': answer.content});
        final memory = await AIService.instance.summarizeConversationMemory(
          chat.memorySummary,
          summaryInput,
        );
        if (memory != null) {
          await FirestoreService.instance.updateAiChatMemory(chat.id, memory);
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('AI 请求失败：$error')));
      }
    } finally {
      if (mounted) {
        setState(() => _isChatThinking = false);
        _scrollToBottom();
      }
    }
  }

  static const Map<String, String> _sourceLabels = {
    'tasks': '任务',
    'diary': '日记与心情',
    'notes': '笔记',
    'memos': '备忘录',
    'literature': '文献',
    'stocks': '股票报告',
    'memories': '长期记忆',
    'chat_history': '历史对话',
    'resources': '本对话资料',
  };

  Future<void> _showSourceSettings() async {
    final chat = _currentChat;
    if (chat == null) return;
    var selected = Set<String>.from(chat.enabledSources);
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('本对话可用资料'),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _sourceLabels.entries
                    .map(
                      (entry) => CheckboxListTile(
                        dense: true,
                        value: selected.contains(entry.key),
                        title: Text(entry.value),
                        onChanged: (value) => setDialogState(() {
                          if (value == true) {
                            selected.add(entry.key);
                          } else {
                            selected.remove(entry.key);
                          }
                        }),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await AiAssistantService.instance.updateEnabledSources(chat.id, result);
    }
  }

  Future<void> _editMemory([AiMemory? memory]) async {
    final controller = TextEditingController(text: memory?.content ?? '');
    final content = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(memory == null ? '添加长期记忆' : '修改长期记忆'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '例如：我正在长期开发 SyncNote；界面不要堆叠过多按钮。',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (content != null && content.isNotEmpty) {
      await AiAssistantService.instance.saveMemory(
        id: memory?.id,
        content: content,
        enabled: memory?.enabled ?? true,
      );
    }
  }

  Future<void> _showMemoryManager() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('长期记忆'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: StreamBuilder<List<AiMemory>>(
          stream: AiAssistantService.instance.watchMemories(),
          builder: (context, snapshot) {
            final items = snapshot.data ?? const [];
            if (items.isEmpty) {
              return const Center(child: Text('暂无长期记忆；所有内容都由您管理。'));
            }
            return ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  leading: Switch(
                    value: item.enabled,
                    onChanged: (value) => AiAssistantService.instance
                        .setMemoryEnabled(item.id, value),
                  ),
                  title: Text(item.content),
                  subtitle: Text(
                    '最后确认 ${item.lastConfirmedAt.toLocal().toString().split('.').first}',
                  ),
                  trailing: Wrap(
                    spacing: 0,
                    children: [
                      IconButton(
                        tooltip: '修改',
                        onPressed: () => _editMemory(item),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: '删除',
                        onPressed: () =>
                            AiAssistantService.instance.deleteMemory(item.id),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _editMemory,
          icon: const Icon(Icons.add),
          label: const Text('添加'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('完成'),
        ),
      ],
    ),
  );

  Future<void> _addResource(String chatId) async {
    final titleController = TextEditingController();
    final contentController = TextEditingController();
    final value = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加本对话专属资料'),
        content: SizedBox(
          width: 580,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: '资料名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                minLines: 6,
                maxLines: 14,
                decoration: const InputDecoration(
                  labelText: '资料正文',
                  helperText: '只需添加一次；后续由系统按问题选择相关片段。',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (value == true && contentController.text.trim().isNotEmpty) {
      await AiAssistantService.instance.addResource(
        chatId,
        title: titleController.text,
        content: contentController.text,
      );
    }
    titleController.dispose();
    contentController.dispose();
  }

  Future<void> _showResourceManager() async {
    var chat = _currentChat;
    if (chat == null) {
      chat = await FirestoreService.instance.createAiChat();
      _selectChat(chat);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('本对话专属资料'),
        content: SizedBox(
          width: 560,
          height: 380,
          child: StreamBuilder<List<AiChatResource>>(
            stream: AiAssistantService.instance.watchResources(chat!.id),
            builder: (context, snapshot) {
              final items = snapshot.data ?? const [];
              if (items.isEmpty) {
                return const Center(child: Text('暂无资料；添加后可跨设备继续本对话。'));
              }
              return ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(item.title),
                    subtitle: Text(
                      '${item.content.length} 字 · ${item.contentHash.substring(0, 8)}',
                    ),
                    trailing: IconButton(
                      tooltip: '删除专属副本',
                      onPressed: () => AiAssistantService.instance
                          .deleteResource(chat!.id, item.id),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _addResource(chat!.id),
            icon: const Icon(Icons.add),
            label: const Text('添加资料'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAiUsage() async {
    final currentBudget = await AiAssistantService.instance
        .getMonthlyBudgetCny();
    final budgetController = TextEditingController(
      text: currentBudget.toStringAsFixed(0),
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('AI 用量与预算'),
        content: SizedBox(
          width: 460,
          child: StreamBuilder<AiMonthlyUsage>(
            stream: AiAssistantService.instance.watchMonthlyUsage(),
            builder: (context, snapshot) {
              final usage =
                  snapshot.data ??
                  const AiMonthlyUsage(
                    promptTokens: 0,
                    completionTokens: 0,
                    cacheHitTokens: 0,
                    estimatedCostUsd: 0,
                    requestCount: 0,
                  );
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本月 ${usage.requestCount} 次调用'),
                  Text(
                    '输入 ${usage.promptTokens} · 输出 ${usage.completionTokens} Token',
                  ),
                  Text('缓存命中 ${usage.cacheHitTokens} Token'),
                  Text('估算费用 ¥${usage.estimatedCostCny.toStringAsFixed(3)}'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: budgetController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '每月自动调用提醒额度（元）',
                      helperText: '达到后暂停自动晨晚报；手动提问会再次确认。',
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final value = double.tryParse(budgetController.text);
              if (value != null) {
                await AiAssistantService.instance.setMonthlyBudgetCny(value);
              }
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    budgetController.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('智能中心'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '回收站',
            onPressed: () {
              context.push('/trash');
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorSize: TabBarIndicatorSize.tab,
          tabs: const [
            Tab(icon: Icon(Icons.search_rounded), text: '全局搜索'),
            Tab(icon: Icon(Icons.forum_rounded), text: 'AI 问答助手'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildSearchTab(), _buildChatTab()],
      ),
    );
  }

  Widget _buildSearchTab() {
    final items = _filteredItems;

    return Column(
      children: [
        // Search Bar
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  contextMenuBuilder:
                      AiContextMenuHelper.editableTextContextMenuBuilder,
                  decoration: InputDecoration(
                    hintText: '搜索任务、笔记、备忘录、日记...',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _aiResult = null;
                                _searchResults.clear();
                              });
                            },
                          )
                        : null,
                  ),
                  onChanged: _scheduleIndexSearch,
                  onSubmitted: (_) => _performAiSearch(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _isAiSearching ? null : _performAiSearch,
                icon: _isAiSearching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: const Text('AI智能'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),

        // AI Result Card
        if (_aiResult != null || _isAiSearching)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.purple.shade50, Colors.blue.shade50],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.purple.shade100),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome, color: Colors.purple),
                      const SizedBox(width: 8),
                      Text(
                        'AI 语义搜索结果',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.purple.shade800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_isAiSearching)
                    const Text('思考中...')
                  else
                    Text(
                      _aiResult!,
                      style: const TextStyle(fontSize: 14, height: 1.5),
                    ),
                ],
              ),
            ),
          ),

        // Results List
        Expanded(
          child: _isIndexSearching
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
              ? Center(
                  child: Text(
                    _searchController.text.trim().isEmpty
                        ? '输入关键词后只读取轻量索引，不会加载全部正文。'
                        : '没有找到任何结果。',
                  ),
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: _buildLeadingIcon(item.type),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: item.subtitle.isNotEmpty
                          ? Text(
                              item.subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      trailing: Text(
                        item.type,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      onTap: () => _openResult(item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildChatTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey(_currentChat?.id),
                  initialValue: _currentChat?.id,
                  decoration: const InputDecoration(
                    labelText: '云端对话',
                    border: OutlineInputBorder(),
                  ),
                  items: _chats
                      .map(
                        (chat) => DropdownMenuItem(
                          value: chat.id,
                          child: Text(
                            chat.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (id) {
                    final chat = _chats
                        .where((item) => item.id == id)
                        .firstOrNull;
                    if (chat != null) _selectChat(chat);
                  },
                ),
              ),
              IconButton(
                tooltip: '新建对话',
                icon: const Icon(Icons.add_comment_outlined),
                onPressed: _newChat,
              ),
              IconButton(
                tooltip: '删除对话',
                icon: const Icon(Icons.delete_outline),
                onPressed: _currentChat == null ? null : _deleteCurrentChat,
              ),
              PopupMenuButton<String>(
                onSelected: (action) {
                  switch (action) {
                    case 'sources':
                      _showSourceSettings();
                      break;
                    case 'memories':
                      _showMemoryManager();
                      break;
                    case 'resources':
                      _showResourceManager();
                      break;
                    case 'usage':
                      _showAiUsage();
                      break;
                    case 'rename':
                      _renameCurrentChat();
                      break;
                    case 'clear':
                      _clearChats();
                      break;
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'sources', child: Text('本对话资料范围')),
                  PopupMenuItem(value: 'memories', child: Text('长期记忆')),
                  PopupMenuItem(value: 'resources', child: Text('对话专属资料')),
                  PopupMenuItem(value: 'usage', child: Text('AI 用量与预算')),
                  PopupMenuItem(value: 'rename', child: Text('重命名当前对话')),
                  PopupMenuItem(value: 'clear', child: Text('清空全部对话')),
                ],
              ),
            ],
          ),
        ),
        // Messages Box
        Expanded(
          child: ListView.builder(
            controller: _chatScrollController,
            padding: const EdgeInsets.all(16),
            itemCount: _chatMessages.length + (_isChatThinking ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == _chatMessages.length) {
                return _buildThinkingBubble();
              }
              final message = _chatMessages[index];
              return _buildChatBubble(message);
            },
          ),
        ),

        // Input Box
        Padding(
          padding: const EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: 20,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  contextMenuBuilder:
                      AiContextMenuHelper.editableTextContextMenuBuilder,
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(
                    hintText: '向 AI 助理提问您的笔记和日程...',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  onSubmitted: (_) => _sendChatMessage(),
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                radius: 24,
                backgroundColor: Theme.of(context).primaryColor,
                child: IconButton(
                  icon: const Icon(Icons.send_rounded, color: Colors.white),
                  onPressed: _sendChatMessage,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChatBubble(ChatMessage message) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: message.isUser
              ? Theme.of(context).primaryColor.withValues(alpha: 0.1)
              : Colors.grey.shade100,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: message.isUser
                ? const Radius.circular(16)
                : Radius.zero,
            bottomRight: message.isUser
                ? Radius.zero
                : const Radius.circular(16),
          ),
          border: message.isUser
              ? Border.all(
                  color: Theme.of(context).primaryColor.withValues(alpha: 0.2),
                )
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AiSelectionArea(
              child: message.isUser
                  ? Text(message.text, style: const TextStyle(fontSize: 15))
                  : MarkdownBody(
                      data: message.text,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(fontSize: 14, height: 1.5),
                        code: const TextStyle(
                          backgroundColor: Colors.transparent,
                          fontSize: 13,
                        ),
                      ),
                    ),
            ),
            if (!message.isUser && message.sourceRefs.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  const Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(Icons.source_outlined, size: 16),
                    label: Text('本轮来源'),
                  ),
                  ...message.sourceRefs
                      .take(8)
                      .map(
                        (source) => Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(source, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                ],
              ),
            ],
            if (!message.isUser && message.usage != null) ...[
              const SizedBox(height: 6),
              Text(
                '${message.usage!.model} · 输入 ${message.usage!.promptTokens} / 输出 ${message.usage!.completionTokens} Token · 约 ¥${(message.usage!.estimatedCostUsd * 7.2).toStringAsFixed(4)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildThinkingBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              '正在检索知识库并思考...',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeadingIcon(String type) {
    switch (type) {
      case 'Task':
        return const Icon(Icons.check_box_outlined, color: Colors.blue);
      case 'Note':
        return const Icon(Icons.note_alt_outlined, color: Colors.orange);
      case 'Memo':
        return const Icon(Icons.sticky_note_2_outlined, color: Colors.yellow);
      case 'Diary':
        return const Icon(Icons.book_outlined, color: Colors.green);
      default:
        return const Icon(Icons.insert_drive_file_outlined);
    }
  }
}
