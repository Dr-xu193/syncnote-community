import 'package:flutter/material.dart';
import 'package:syncnote/features/exploration/screens/knowledge_cards_screen.dart';
import 'package:syncnote/features/exploration/screens/literature_exploration_screen.dart';
import 'package:syncnote/features/exploration/screens/news_exploration_screen.dart';
import 'package:syncnote/features/exploration/screens/puzzle_exploration_screen.dart';
import 'package:syncnote/features/exploration/screens/stock_research_screen.dart';
import 'package:syncnote/features/notes/knowledge_exploration_hub.dart';
import 'package:syncnote/features/notes/note_editor_screen.dart';
import 'package:syncnote/features/notes/notes_graph_screen.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/controllers/cursor_paged_controller.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/utils/list_preview_text.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';
import 'package:syncnote/shared/widgets/nullable_string_filter_menu.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  static const int _pageSize = 40;

  final _searchController = TextEditingController();
  _KnowledgeWorkspace _workspace = _KnowledgeWorkspace.library;
  String? _category;
  String? _tag;
  bool _showArchived = false;
  late final CursorPagedController<Note> _notesController;

  @override
  void initState() {
    super.initState();
    _notesController = CursorPagedController<Note>(idOf: (note) => note.id);
    _prepareList();
  }

  Future<void> _prepareList() async {
    try {
      await FirestoreService.instance.preparePagedCollections();
      if (!mounted) return;
      _notesController.start(
        firstPage: FirestoreService.instance.watchNotesPage(limit: _pageSize),
        loadPage: (cursor) => FirestoreService.instance.getNotesPage(
          limit: _pageSize,
          startAfter: cursor,
        ),
      );
      FirestoreService.instance.migrateWikiLinks().catchError((_) {});
    } catch (error) {
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Widget _highlight(
    String text, {
    int? maxLines,
    TextOverflow overflow = TextOverflow.clip,
    TextStyle? style,
  }) {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: overflow, style: style);
    }
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    final needle = query.toLowerCase();
    var start = 0;
    while (true) {
      final index = lower.indexOf(needle, start);
      if (index < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: const TextStyle(
            backgroundColor: Colors.amber,
            color: Colors.black,
          ),
        ),
      );
      start = index + query.length;
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  void _resetVisibleLimit() {}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('知识库'),
        actions: _workspace == _KnowledgeWorkspace.library
            ? [
                IconButton(
                  icon: const Icon(Icons.hub_outlined),
                  tooltip: '关系图谱',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const NotesGraphScreen()),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: '新建笔记',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const NoteEditorScreen()),
                  ),
                ),
              ]
            : null,
      ),
      body: Column(
        children: [
          _KnowledgeWorkspaceSelector(
            selected: _workspace,
            onSelected: (value) => setState(() => _workspace = value),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _workspace == _KnowledgeWorkspace.library
                  ? _buildLibrary()
                  : KnowledgeExplorationHub(
                      onModuleSelected: _openExplorationModule,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _openExplorationModule(ExplorationModule module) {
    final Widget screen = switch (module) {
      ExplorationModule.news => const NewsExplorationScreen(),
      ExplorationModule.literature => const LiteratureExplorationScreen(),
      ExplorationModule.knowledge => const KnowledgeCardsScreen(),
      ExplorationModule.puzzles => const PuzzleExplorationScreen(),
      ExplorationModule.stocks => const StockResearchScreen(),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  Widget _buildLibrary() {
    return AnimatedBuilder(
      animation: _notesController,
      builder: (context, _) {
        if (_notesController.error != null && !_notesController.ready) {
          return Center(child: Text('云端笔记加载失败：${_notesController.error}'));
        }
        if (!_notesController.ready) {
          return const Center(child: CircularProgressIndicator());
        }
        final all = _notesController.items;
        final categories =
            all
                .map((note) => note.category)
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList()
              ..sort();
        final tags = all.expand((note) => note.tags).toSet().toList()..sort();
        final query = _searchController.text.trim().toLowerCase();
        final notes = all.where((note) {
          if (note.isArchived != _showArchived) return false;
          if (_category != null && note.category != _category) return false;
          if (_tag != null && !note.tags.contains(_tag)) return false;
          return query.isEmpty ||
              '${note.title} ${note.content}'.toLowerCase().contains(query);
        }).toList();
        final visibleNotes = notes;
        final hasMore = _notesController.hasMore;

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _searchController,
                contextMenuBuilder:
                    AiContextMenuHelper.editableTextContextMenuBuilder,
                onChanged: (_) => setState(_resetVisibleLimit),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索笔记',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  FilterChip(
                    label: Text(_showArchived ? '归档' : '当前'),
                    selected: _showArchived,
                    onSelected: (value) => setState(() {
                      _showArchived = value;
                      _resetVisibleLimit();
                    }),
                  ),
                  const SizedBox(width: 8),
                  _FilterMenu(
                    label: _category ?? '分类',
                    selectedValue: _category,
                    values: categories,
                    onSelected: (value) => setState(() {
                      _category = value;
                      _resetVisibleLimit();
                    }),
                  ),
                  const SizedBox(width: 8),
                  _FilterMenu(
                    label: _tag ?? '标签',
                    selectedValue: _tag,
                    values: tags,
                    onSelected: (value) => setState(() {
                      _tag = value;
                      _resetVisibleLimit();
                    }),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: notes.isEmpty
                  ? const Center(child: Text('当前筛选下没有笔记'))
                  : ListView.builder(
                      itemCount: visibleNotes.length + (hasMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == visibleNotes.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                            child: OutlinedButton.icon(
                              onPressed: _notesController.loadingMore
                                  ? null
                                  : _notesController.loadMore,
                              icon: _notesController.loadingMore
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.expand_more_rounded),
                              label: Text('加载更多（已显示 ${visibleNotes.length}）'),
                            ),
                          );
                        }
                        final note = visibleNotes[index];
                        final visualContent = parseVisualNoteContent(
                          note.content,
                          note.images,
                        );
                        final previewText = compactListPreviewText(
                          [
                            visualContent.text,
                            ...visualContent.texts.map((item) => item.text),
                          ].where((value) => value.trim().isNotEmpty).join(' '),
                        );
                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          child: ListTile(
                            title: _highlight(
                              note.title.isEmpty ? '无标题' : note.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (previewText.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: _highlight(
                                      previewText,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(height: 1.4),
                                    ),
                                  ),
                                if (note.category.isNotEmpty ||
                                    note.tags.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 5),
                                    child: Text(
                                      [
                                        if (note.category.isNotEmpty)
                                          note.category,
                                        ...note.tags,
                                      ].join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                              ],
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (action) async {
                                if (action == 'archive') {
                                  await FirestoreService.instance.updateNote(
                                    note.copyWith(
                                      isArchived: !note.isArchived,
                                      updatedAt: DateTime.now(),
                                    ),
                                  );
                                } else {
                                  await FirestoreService.instance.deleteNote(
                                    note.id,
                                  );
                                }
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'archive',
                                  child: Text(note.isArchived ? '取消归档' : '归档'),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('移入回收站'),
                                ),
                              ],
                            ),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => NoteEditorScreen(note: note),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

enum _KnowledgeWorkspace { library, explore }

class _KnowledgeWorkspaceSelector extends StatelessWidget {
  const _KnowledgeWorkspaceSelector({
    required this.selected,
    required this.onSelected,
  });

  final _KnowledgeWorkspace selected;
  final ValueChanged<_KnowledgeWorkspace> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<_KnowledgeWorkspace>(
              segments: const [
                ButtonSegment(
                  value: _KnowledgeWorkspace.library,
                  icon: Icon(Icons.menu_book_rounded),
                  label: Text('我的知识库'),
                ),
                ButtonSegment(
                  value: _KnowledgeWorkspace.explore,
                  icon: Icon(Icons.explore_rounded),
                  label: Text('探索中心'),
                ),
              ],
              selected: {selected},
              showSelectedIcon: false,
              onSelectionChanged: (value) => onSelected(value.first),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterMenu extends StatelessWidget {
  const _FilterMenu({
    required this.label,
    required this.selectedValue,
    required this.values,
    required this.onSelected,
  });

  final String label;
  final String? selectedValue;
  final List<String> values;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return NullableStringFilterMenu(
      values: values,
      selectedValue: selectedValue,
      allLabel: '全部',
      onSelected: onSelected,
      child: Chip(label: Text(label)),
    );
  }
}
