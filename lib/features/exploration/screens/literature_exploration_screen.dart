import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/features/exploration/services/exploration_ai_service.dart';
import 'package:syncnote/features/exploration/services/literature_cloud_save_service.dart';
import 'package:syncnote/features/exploration/services/literature_connections_service.dart';
import 'package:syncnote/features/exploration/services/literature_discovery_service.dart';
import 'package:syncnote/features/exploration/services/literature_library_service.dart';
import 'package:syncnote/features/exploration/services/literature_pdf_service.dart';
import 'package:syncnote/features/exploration/services/exploration_repository.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';
import 'package:url_launcher/url_launcher.dart';

class LiteratureExplorationScreen extends StatefulWidget {
  const LiteratureExplorationScreen({super.key});

  @override
  State<LiteratureExplorationScreen> createState() =>
      _LiteratureExplorationScreenState();
}

class _LiteratureExplorationScreenState
    extends State<LiteratureExplorationScreen> {
  final _queryController = TextEditingController();
  final _fallbackController = TextEditingController();
  final _librarySearchController = TextEditingController();
  final _discovery = LiteratureDiscoveryService();
  final _pdfService = LiteraturePdfService();
  final _ai = ExplorationAiService();
  final _library = LiteratureLibraryService.instance;
  StreamSubscription<List<LiteratureLibraryItem>>? _librarySubscription;

  LiteratureDiscoveryReport? _report;
  LiteratureRecommendation? _selected;
  ParsedLiteraturePdf? _parsedPdf;
  Map<String, dynamic>? _deepAnalysis;
  bool _searching = false;
  bool _readingPdf = false;
  bool _savingPdf = false;
  bool _savedToCloud = false;
  String? _error;
  double _pdfProgress = 0;
  double _saveProgress = 0;
  Map<String, LiteratureLibraryItem> _libraryById = const {};
  bool _showLibrary = false;
  String _libraryFilter = 'all';

  @override
  void initState() {
    super.initState();
    _restoreTodayReport();
    _librarySubscription = _library.watch().listen((items) {
      if (!mounted) return;
      setState(() {
        _libraryById = {for (final item in items) item.id: item};
      });
    });
  }

  Future<void> _restoreTodayReport() async {
    final today = DateTime.now();
    await ExplorationStateStore.instance.clearExpiredLiteratureReport(today);
    final report = await ExplorationStateStore.instance
        .loadCurrentLiteratureReport(today);
    if (!mounted || report == null) return;
    _queryController.text = report.query.original;
    _fallbackController.text = report.query.fallbackTerms.join('，');
    if (report.pipelineVersion < 9) return;
    setState(() {
      _report = report;
      _selected = report.recommendations.firstOrNull;
    });
  }

  @override
  void dispose() {
    _queryController.dispose();
    _fallbackController.dispose();
    _librarySearchController.dispose();
    _librarySubscription?.cancel();
    _discovery.dispose();
    _pdfService.dispose();
    _ai.dispose();
    super.dispose();
  }

  Future<void> _search({bool force = false}) async {
    final query = _queryController.text.trim();
    if (query.length < 2 || query.length > 120) {
      setState(() => _error = '请输入 2 到 120 个字符的文献方向。');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
      _deepAnalysis = null;
      _parsedPdf = null;
    });
    try {
      final report = await _discovery.discover(
        query,
        force: force,
        fallbackTerms: _fallbackTerms,
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _selected = report.recommendations.firstOrNull;
        _searching = false;
        _showLibrary = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '$error';
      });
    }
  }

  List<String> get _fallbackTerms => _fallbackController.text
      .split(RegExp(r'[,，;；\n]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  LiteratureLibraryItem? _libraryItem(LiteratureRecommendation row) {
    return _libraryById[LiteratureLibraryItem.idForPaper(row.paper)];
  }

  void _select(LiteratureRecommendation value) {
    setState(() {
      _selected = value;
      _parsedPdf = null;
      _deepAnalysis = null;
      _error = null;
      _pdfProgress = 0;
      _saveProgress = 0;
      final stored = _libraryItem(value);
      _savedToCloud = stored?.hasCloudPdf ?? false;
      _deepAnalysis = stored?.deepAnalysis.isEmpty == false
          ? stored!.deepAnalysis
          : null;
    });
  }

  Future<ParsedLiteraturePdf> _ensurePdf() async {
    if (_parsedPdf != null) return _parsedPdf!;
    final selected = _selected;
    if (selected == null) throw StateError('请先选择一篇文献');
    final parsed = await _pdfService.fetchAndParse(
      selected.paper,
      onProgress: (value) {
        if (mounted) setState(() => _pdfProgress = value);
      },
    );
    _parsedPdf = parsed;
    return parsed;
  }

  Future<void> _previewPdf() async {
    setState(() {
      _readingPdf = true;
      _error = null;
    });
    try {
      final parsed = await _ensurePdf();
      if (!mounted) return;
      setState(() => _readingPdf = false);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _MemoryPdfScreen(
            title: _selected!.paper.title,
            bytes: parsed.bytes,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _readingPdf = false;
        _error = '$error';
      });
    }
  }

  Future<void> _deepRead() async {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      _readingPdf = true;
      _error = null;
      _deepAnalysis = null;
    });
    try {
      final parsed = await _ensurePdf();
      final result = await _ai.analyzeLiteraturePdf(
        paper: selected.paper,
        pages: parsed.pages,
      );
      if (!mounted || _selected?.paper.id != selected.paper.id) return;
      setState(() {
        _readingPdf = false;
        _deepAnalysis = result.data;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _readingPdf = false;
        _error = '$error';
      });
    }
  }

  Future<void> _savePdfToCloud() async {
    final selected = _selected;
    if (selected == null || _savedToCloud) return;
    setState(() {
      _savingPdf = true;
      _error = null;
      _saveProgress = 0;
    });
    try {
      final parsed = await _ensurePdf();
      final file = await LiteratureCloudSaveService.instance.savePdf(
        paper: selected.paper,
        bytes: parsed.bytes,
        onProgress: (value) {
          if (mounted) setState(() => _saveProgress = value);
        },
      );
      await _library.attachPdf(selected, file);
      if (!mounted || _selected?.paper.id != selected.paper.id) return;
      setState(() {
        _savingPdf = false;
        _savedToCloud = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PDF 已保存到坚果云，并加入“云文件”。')));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _savingPdf = false;
        _error = '保存失败：$error';
      });
    }
  }

  Future<void> _toggleFavorite(LiteratureRecommendation row) async {
    final current = _libraryItem(row);
    try {
      await _library.setFavorite(row, !(current?.isFavorite ?? false));
    } catch (error) {
      if (mounted) setState(() => _error = '收藏失败：$error');
    }
  }

  Future<void> _saveDeepAnalysis() async {
    final selected = _selected;
    final deep = _deepAnalysis;
    if (selected == null || deep == null) return;
    try {
      await _library.saveDeepAnalysis(selected, deep);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('深度解读已永久保存到文献收藏。')));
    } catch (error) {
      if (mounted) setState(() => _error = '保存解读失败：$error');
    }
  }

  Future<void> _saveAsNote(LiteratureRecommendation row) async {
    try {
      await _library.saveAsNote(row, deepAnalysis: _deepAnalysis);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存为“文献研究”分类的 Markdown 笔记。')),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '保存到笔记失败：$error');
    }
  }

  Future<void> _editMetadata(LiteratureRecommendation row) async {
    final current = _libraryItem(row);
    var status = current?.readingStatus ?? LiteratureReadingStatus.unread;
    final tags = TextEditingController(text: current?.tags.join('，') ?? '');
    final note = TextEditingController(text: current?.note ?? '');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('文献状态与备注'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<LiteratureReadingStatus>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: '阅读状态'),
                  items: const [
                    DropdownMenuItem(
                      value: LiteratureReadingStatus.unread,
                      child: Text('未读'),
                    ),
                    DropdownMenuItem(
                      value: LiteratureReadingStatus.reading,
                      child: Text('阅读中'),
                    ),
                    DropdownMenuItem(
                      value: LiteratureReadingStatus.read,
                      child: Text('已读'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => status = value);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tags,
                  decoration: const InputDecoration(labelText: '标签（逗号分隔）'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '个人备注'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      try {
        await _library.updateMetadata(
          recommendation: row,
          status: status,
          tags: tags.text.split(RegExp(r'[,，;；]+')),
          note: note.text,
        );
      } catch (error) {
        if (mounted) setState(() => _error = '保存状态失败：$error');
      }
    }
    tags.dispose();
    note.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _showLibrary
        ? _filteredLibraryRows
        : _sortedRecommendations(
            _report?.recommendations ?? const <LiteratureRecommendation>[],
          );
    return Scaffold(
      appBar: AppBar(title: const Text('今日文献')),
      body: Column(
        children: [
          _buildSearchBar(context),
          if (_searching || _readingPdf)
            LinearProgressIndicator(
              value: _readingPdf && _pdfProgress > 0 && _pdfProgress < 1
                  ? _pdfProgress
                  : null,
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (!_showLibrary && _searching) {
                  return _buildSearching(context);
                }
                if (!_showLibrary && _report == null) {
                  return _buildEmpty(context);
                }
                if (rows.isEmpty) {
                  return const Center(child: Text('这里还没有内容。可先生成今日推荐，或收藏一篇文献。'));
                }
                if (constraints.maxWidth < 820) {
                  return _buildMobile(context, rows);
                }
                return _buildDesktop(context, rows);
              },
            ),
          ),
        ],
      ),
    );
  }

  List<LiteratureRecommendation> get _filteredLibraryRows {
    final query = _librarySearchController.text.trim().toLowerCase();
    final items =
        _libraryById.values.where((item) {
          final statusMatches = switch (_libraryFilter) {
            'unread' => item.readingStatus == LiteratureReadingStatus.unread,
            'reading' => item.readingStatus == LiteratureReadingStatus.reading,
            'read' => item.readingStatus == LiteratureReadingStatus.read,
            'annotations' => item.annotations.isNotEmpty,
            'deep' => item.hasSavedDeepAnalysis,
            'pdf' => item.hasCloudPdf,
            _ => true,
          };
          if (!statusMatches) return false;
          if (query.isEmpty) return true;
          final paper = item.recommendation.paper;
          final searchable = [
            paper.title,
            paper.authors.join(' '),
            paper.venue,
            paper.keywords.join(' '),
            item.tags.join(' '),
            item.note,
          ].join(' ').toLowerCase();
          return searchable.contains(query);
        }).toList()..sort(
          (left, right) => right.updatedAt.compareTo(left.updatedAt),
        );
    return items.map((item) => item.recommendation).toList();
  }

  Widget _buildSearchBar(BuildContext context) {
    final report = _searching && !_showLibrary ? null : _report;
    final successful =
        report?.sourceStatuses.where((item) => item.success).length ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        children: [
          Row(
            children: [
              ChoiceChip(
                label: const Text('今日推荐'),
                selected: !_showLibrary,
                onSelected: (_) => setState(() => _showLibrary = false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text('研究库 ${_libraryById.length}'),
                selected: _showLibrary,
                onSelected: (_) => setState(() => _showLibrary = true),
              ),
            ],
          ),
          if (_showLibrary) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _librarySearchController,
              contextMenuBuilder:
                  AiContextMenuHelper.editableTextContextMenuBuilder,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: '检索标题、作者、期刊、标签或备注',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final entry in const [
                    ('all', '全部'),
                    ('unread', '待读'),
                    ('reading', '阅读中'),
                    ('read', '已读'),
                    ('annotations', '有摘录'),
                    ('deep', '有深读'),
                    ('pdf', '有 PDF'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 7),
                      child: ChoiceChip(
                        label: Text(entry.$2),
                        selected: _libraryFilter == entry.$1,
                        onSelected: (_) =>
                            setState(() => _libraryFilter = entry.$1),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryController,
                  contextMenuBuilder:
                      AiContextMenuHelper.editableTextContextMenuBuilder,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.science_rounded),
                    hintText: '准确写出研究对象＋问题/机制，例如：核废物玻璃固化的长期浸出稳定性',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _searching ? null : _search,
                icon: const Icon(Icons.manage_search_rounded),
                label: const Text('生成今日推荐'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _fallbackController,
            contextMenuBuilder:
                AiContextMenuHelper.editableTextContextMenuBuilder,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.tune_rounded),
              labelText: '可选兜底关键词',
              hintText: '只有当天主题过宽或难以检索时才补充使用；用逗号分隔',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (report != null || _error != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _error ??
                        '${report!.reportCached ? '今日缓存' : '本次生成'} · '
                            '$successful/${report.sourceStatuses.length} 个检索环节 · '
                            '候选 ${report.candidates.length} · 推荐 ${report.recommendations.length} · '
                            '本次 Flash 约 \$${report.reportCached ? '0.0000' : report.estimatedCostUsd.toStringAsFixed(4)}',
                    style: TextStyle(
                      color: _error == null
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                if (report != null)
                  TextButton(
                    onPressed: _searching ? null : () => _search(force: true),
                    child: const Text('强制重查'),
                  ),
              ],
            ),
            if (report != null) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: report.sourceStatuses
                      .map((source) {
                        final color = source.success
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error;
                        final detail = source.error.trim().isEmpty
                            ? '${source.sourceName} 未返回含摘要的结果'
                            : '${source.sourceName}：${source.error}';
                        return Tooltip(
                          message: source.success ? '本次可用摘要数量' : detail,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.09),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: color.withValues(alpha: 0.24),
                              ),
                            ),
                            child: Text(
                              '${source.sourceName} ${source.paperCount} 篇',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: color,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                        );
                      })
                      .toList(growable: false),
                ),
              ),
              if (!_showLibrary) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '检索意图：${report.query.intentSummary.isEmpty ? report.query.original : report.query.intentSummary}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '高度相关文献必须同时命中：${report.query.requiredConceptGroups.map((group) => '〔${group.take(4).join(' / ')}〕').join(' ＋ ')}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (report.query.expansionQueries.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          '严格结果不足时才启用拓展：${report.query.expansionQueries.join('；')}。拓展结果会单独标记。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.biotech_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 14),
            Text(
              '今天想研究什么？',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            const Text(
              '系统会理解研究主体与问题，同时寻找直接研究、相关方法/机制和奠基文献，再从 OpenAlex、'
              'Semantic Scholar、Crossref、arXiv 和 Europe PMC 检索，最后由 DeepSeek Flash 排序与解读。\n'
              '同一天相同方向会直接读取缓存，不重复收费。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearching(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.travel_explore_rounded,
              size: 58,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '正在为新方向检索与复核',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              '当前方向：${_queryController.text.trim()}\n完成前不会把上一份报告冒充为本次结果。',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktop(
    BuildContext context,
    List<LiteratureRecommendation> rows,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 400,
          child: _LiteratureList(
            rows: rows,
            selected: _selected,
            onSelected: _select,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _selected == null
              ? const Center(child: Text('请选择一篇文献'))
              : _buildDetail(context, _selected!),
        ),
      ],
    );
  }

  Widget _buildMobile(
    BuildContext context,
    List<LiteratureRecommendation> rows,
  ) {
    return _LiteratureList(
      rows: rows,
      selected: null,
      onSelected: (value) {
        _select(value);
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => _MobileLiteratureDetail(
              row: value,
              initialLibraryItem: _libraryItem(value),
              onOpenOriginal: () => _openOriginal(value.paper.url),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetail(BuildContext context, LiteratureRecommendation row) {
    final colors = Theme.of(context).colorScheme;
    final deep = _deepAnalysis;
    final parsed = _parsedPdf;
    final stored = _libraryItem(row);
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
        children: [
          Text(
            row.paper.title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${row.paper.authors.take(5).join('、')} · '
            '${row.paper.venue.isEmpty ? '来源未注明' : row.paper.venue} · '
            '${row.paper.publishedOn?.toIso8601String().split('T').first ?? '日期未知'}\n'
            '${_matchTierLabel(row.matchTier)} · 匹配 ${row.relevanceScore.toStringAsFixed(0)}% · '
            '引用 ${row.paper.citationCount} · 参考 ${row.paper.referenceCount} · '
            '${row.paper.publicationType.isEmpty ? '类型未知' : row.paper.publicationType} · '
            '${row.paper.isOpenAccess ? '开放获取 ${row.paper.openAccessStatus}' : '未确认开放全文'}',
            style: TextStyle(
              color: colors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (stored != null) ...[
            const SizedBox(height: 8),
            Text(
              '收藏状态：${_readingStatusLabel(stored.readingStatus)}'
              '${stored.tags.isEmpty ? '' : ' · ${stored.tags.join('、')}'}'
              '${stored.note.isEmpty ? '' : ' · 已有个人备注'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (row.paper.isRetracted) ...[
            const SizedBox(height: 10),
            Text(
              '警告：学术索引将该记录标记为已撤稿，系统不会把它作为正常推荐依据。',
              style: TextStyle(
                color: colors.error,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _toggleFavorite(row),
                icon: Icon(
                  stored?.isFavorite == true
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                ),
                label: Text(stored?.isFavorite == true ? '已收藏' : '收藏'),
              ),
              OutlinedButton.icon(
                onPressed: () => _editMetadata(row),
                icon: const Icon(Icons.bookmark_added_outlined),
                label: const Text('状态、标签与备注'),
              ),
              OutlinedButton.icon(
                onPressed: () => _saveAsNote(row),
                icon: const Icon(Icons.note_add_outlined),
                label: const Text('保存到笔记'),
              ),
              OutlinedButton.icon(
                onPressed: () => _showLiteratureConnections(context, row),
                icon: const Icon(Icons.hub_outlined),
                label: const Text('研究脉络'),
              ),
              OutlinedButton.icon(
                onPressed: () => _showAnnotationDialog(context, row),
                icon: const Icon(Icons.format_quote_rounded),
                label: const Text('添加研究摘录'),
              ),
              if (row.paper.url.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _openOriginal(row.paper.url),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('打开原文'),
                ),
              if (row.paper.pdfUrl.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _readingPdf || _savingPdf ? null : _previewPdf,
                  icon: const Icon(Icons.picture_as_pdf_rounded),
                  label: const Text('内存预览 PDF'),
                ),
              if (row.paper.pdfUrl.isNotEmpty)
                FilledButton.icon(
                  onPressed: _readingPdf || _savingPdf ? null : _deepRead,
                  icon: const Icon(Icons.psychology_alt_rounded),
                  label: const Text('深度解读 · Flash'),
                ),
              if (row.paper.pdfUrl.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _readingPdf || _savingPdf || _savedToCloud
                      ? null
                      : _savePdfToCloud,
                  icon: Icon(
                    _savedToCloud
                        ? Icons.cloud_done_rounded
                        : Icons.cloud_upload_rounded,
                  ),
                  label: Text(
                    _savedToCloud
                        ? '已保存到坚果云'
                        : (_savingPdf ? '正在保存' : '保存 PDF 到云文件'),
                  ),
                ),
              if (deep != null)
                FilledButton.tonalIcon(
                  onPressed: _saveDeepAnalysis,
                  icon: Icon(
                    stored?.hasSavedDeepAnalysis == true
                        ? Icons.cloud_done_rounded
                        : Icons.save_rounded,
                  ),
                  label: Text(
                    stored?.hasSavedDeepAnalysis == true ? '解读已保存' : '永久保存解读',
                  ),
                ),
            ],
          ),
          if (_readingPdf) ...[
            const SizedBox(height: 10),
            Text(
              _pdfProgress > 0 && _pdfProgress < 1
                  ? '正在将开放 PDF 读取到内存…'
                  : '正在逐页提取正文、清理页眉页脚并交给 Flash 全文分析…',
            ),
          ],
          if (_savingPdf) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _saveProgress > 0 && _saveProgress < 1
                  ? _saveProgress
                  : null,
            ),
            const SizedBox(height: 6),
            const Text('正在从内存直接上传到坚果云，不创建本地文件…'),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: colors.error)),
          ],
          const Divider(height: 30),
          if (stored != null && stored.annotations.isNotEmpty) ...[
            _LiteratureAnnotations(
              item: stored,
              onDelete: (id) => _library.removeAnnotation(
                recommendation: row,
                annotationId: id,
              ),
            ),
            const Divider(height: 30),
          ],
          if (deep != null)
            _DeepLiteratureReport(data: deep, parsed: parsed)
          else
            _AbstractLiteratureReport(row: row),
        ],
      ),
    );
  }

  Future<void> _openOriginal(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class _LiteratureList extends StatelessWidget {
  const _LiteratureList({
    required this.rows,
    required this.selected,
    required this.onSelected,
  });

  final List<LiteratureRecommendation> rows;
  final LiteratureRecommendation? selected;
  final ValueChanged<LiteratureRecommendation> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(10),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final row = rows[index];
        return Card(
          margin: EdgeInsets.zero,
          color: selected?.paper.id == row.paper.id
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onSelected(row),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${index + 1}. ${row.paper.title}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 7,
                    runSpacing: 5,
                    children: [
                      _SmallBadge(
                        label: _matchTierLabel(row.matchTier),
                        emphasized: row.matchTier == 'high_relevance',
                      ),
                      _SmallBadge(
                        label: '匹配 ${row.relevanceScore.toStringAsFixed(0)}',
                      ),
                      _SmallBadge(
                        label: row.paper.pdfUrl.isNotEmpty ? '开放 PDF' : '仅摘要',
                      ),
                      if (row.paper.isRetracted)
                        const _SmallBadge(label: '已撤稿', danger: true),
                    ],
                  ),
                  if (row.matchedConcepts.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      '命中：${row.matchedConcepts.take(4).join('、')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AbstractLiteratureReport extends StatelessWidget {
  const _AbstractLiteratureReport({required this.row});

  final LiteratureRecommendation row;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          row.model == explorationFlashModel || row.model == 'deepseek-v4-pro'
              ? 'AI 核心解读（仅依据摘要）'
              : '本地候选摘要（AI 暂时不可用）',
        ),
        Text(row.coreSummary.isEmpty ? '摘要信息不足' : row.coreSummary),
        const _SectionTitle('研究问题'),
        Text(row.researchQuestion.isEmpty ? '摘要未说明' : row.researchQuestion),
        const _SectionTitle('方法'),
        Text(row.method.isEmpty ? '摘要未说明' : row.method),
        const _SectionTitle('主要发现'),
        _BulletList(
          values: row.keyFindings.isEmpty ? const ['摘要未说明'] : row.keyFindings,
        ),
        const _SectionTitle('局限'),
        _BulletList(
          values: row.limitations.isEmpty ? const ['摘要未说明'] : row.limitations,
        ),
        const _SectionTitle('推荐理由'),
        Text(row.recommendationReason),
        const _SectionTitle('原始摘要'),
        SelectableText(row.paper.abstractText),
      ],
    );
  }
}

class _DeepLiteratureReport extends StatelessWidget {
  const _DeepLiteratureReport({required this.data, required this.parsed});

  final Map<String, dynamic> data;
  final ParsedLiteraturePdf? parsed;

  @override
  Widget build(BuildContext context) {
    List<String> values(String key) =>
        List<String>.from(data[key] as List? ?? const []);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          parsed == null
              ? '已保存的 AI 深度解读'
              : '已分析开放 PDF · ${parsed!.totalPages} 页 · '
                    '${parsed!.extractedCharacters} 字符'
                    '${parsed!.truncated ? ' · 超长部分按上限截取' : ''}',
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
        const _SectionTitle('一句话结论'),
        Text('${data['one_sentence'] ?? '全文未说明'}'),
        const _SectionTitle('研究背景'),
        Text('${data['background'] ?? '全文未说明'}'),
        const _SectionTitle('方法设计'),
        _BulletList(values: values('methods')),
        const _SectionTitle('主要结果'),
        _BulletList(values: values('results')),
        const _SectionTitle('创新点'),
        _BulletList(values: values('innovations')),
        const _SectionTitle('作者承认的局限'),
        _BulletList(values: values('author_limitations')),
        const _SectionTitle('审慎评价'),
        _BulletList(values: values('critical_assessment')),
        const _SectionTitle('后续问题'),
        _BulletList(values: values('follow_up_questions')),
        const _SectionTitle('证据位置'),
        ...((data['evidence'] as List? ?? const []).map((raw) {
          final row = Map<String, dynamic>.from(raw as Map);
          final pages = List<Object?>.from(
            row['pages'] as List? ?? const [],
          ).join('、');
          return Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Text(
              '• ${row['claim'] ?? ''}（第 ${pages.isEmpty ? '?' : pages} 页）',
            ),
          );
        })),
        const SizedBox(height: 12),
        Text(
          '置信度：${ExplorationAiService.confidencePercent(data['confidence']).toStringAsFixed(0)}%',
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 7),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _BulletList extends StatelessWidget {
  const _BulletList({required this.values});

  final List<String> values;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const Text('未提供');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: values
          .map(
            (value) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('• $value'),
            ),
          )
          .toList(),
    );
  }
}

class _MemoryPdfScreen extends StatefulWidget {
  const _MemoryPdfScreen({required this.title, required this.bytes});

  final String title;
  final Uint8List bytes;

  @override
  State<_MemoryPdfScreen> createState() => _MemoryPdfScreenState();
}

class _MemoryPdfScreenState extends State<_MemoryPdfScreen> {
  late final PdfDocumentRefData _documentRef;

  @override
  void initState() {
    super.initState();
    _documentRef = PdfDocumentRefData(
      widget.bytes,
      sourceName: 'literature-${widget.title.hashCode}-${widget.bytes.length}',
      useProgressiveLoading: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: PdfDocumentViewBuilder(
        documentRef: _documentRef,
        loadingBuilder: (_) => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('正在从内存渲染 PDF…'),
            ],
          ),
        ),
        errorBuilder: (_, error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('PDF 渲染失败：$error', textAlign: TextAlign.center),
          ),
        ),
        builder: (context, document) {
          if (document == null) return const SizedBox.shrink();
          return ColoredBox(
            color: const Color(0xff303030),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: document.pages.length,
              itemBuilder: (context, index) {
                final page = document.pages[index];
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  child: Column(
                    children: [
                      InteractiveViewer(
                        minScale: 1,
                        maxScale: 4,
                        child: AspectRatio(
                          aspectRatio: page.width / page.height,
                          child: PdfPageView(
                            document: document,
                            pageNumber: index + 1,
                            maximumDpi: 180,
                            backgroundColor: Colors.white,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black45,
                                  blurRadius: 6,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${index + 1} / ${document.pages.length}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _MobileLiteratureDetail extends StatefulWidget {
  const _MobileLiteratureDetail({
    required this.row,
    required this.initialLibraryItem,
    required this.onOpenOriginal,
  });

  final LiteratureRecommendation row;
  final LiteratureLibraryItem? initialLibraryItem;
  final VoidCallback onOpenOriginal;

  @override
  State<_MobileLiteratureDetail> createState() =>
      _MobileLiteratureDetailState();
}

class _MobileLiteratureDetailState extends State<_MobileLiteratureDetail> {
  final _pdfService = LiteraturePdfService();
  final _ai = ExplorationAiService();
  final _library = LiteratureLibraryService.instance;
  ParsedLiteraturePdf? _parsed;
  Map<String, dynamic>? _deep;
  bool _busy = false;
  bool _saving = false;
  bool _savedToCloud = false;
  double _progress = 0;
  double _saveProgress = 0;
  String? _error;
  LiteratureLibraryItem? _stored;

  @override
  void initState() {
    super.initState();
    _stored = widget.initialLibraryItem;
    if (_stored?.hasSavedDeepAnalysis == true) {
      _deep = _stored!.deepAnalysis;
    }
    _savedToCloud = _stored?.hasCloudPdf ?? false;
  }

  @override
  void dispose() {
    _pdfService.dispose();
    _ai.dispose();
    super.dispose();
  }

  Future<ParsedLiteraturePdf> _ensurePdf() async {
    if (_parsed != null) return _parsed!;
    final parsed = await _pdfService.fetchAndParse(
      widget.row.paper,
      onProgress: (value) {
        if (mounted) setState(() => _progress = value);
      },
    );
    _parsed = parsed;
    return parsed;
  }

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final parsed = await _ensurePdf();
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _MemoryPdfScreen(
            title: widget.row.paper.title,
            bytes: parsed.bytes,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  Future<void> _deepRead() async {
    setState(() {
      _busy = true;
      _error = null;
      _deep = null;
    });
    try {
      final parsed = await _ensurePdf();
      final result = await _ai.analyzeLiteraturePdf(
        paper: widget.row.paper,
        pages: parsed.pages,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _deep = result.data;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  Future<void> _savePdfToCloud() async {
    if (_savedToCloud) return;
    setState(() {
      _saving = true;
      _error = null;
      _saveProgress = 0;
    });
    try {
      final parsed = await _ensurePdf();
      final file = await LiteratureCloudSaveService.instance.savePdf(
        paper: widget.row.paper,
        bytes: parsed.bytes,
        onProgress: (value) {
          if (mounted) setState(() => _saveProgress = value);
        },
      );
      final stored = await _library.attachPdf(widget.row, file);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _savedToCloud = true;
        _stored = stored;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PDF 已保存到坚果云，并加入“云文件”。')));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$error';
      });
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      final stored = await _library.setFavorite(
        widget.row,
        !(_stored?.isFavorite ?? false),
      );
      if (mounted) setState(() => _stored = stored);
    } catch (error) {
      if (mounted) setState(() => _error = '收藏失败：$error');
    }
  }

  Future<void> _saveDeep() async {
    final deep = _deep;
    if (deep == null) return;
    try {
      final stored = await _library.saveDeepAnalysis(widget.row, deep);
      if (!mounted) return;
      setState(() => _stored = stored);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('深度解读已永久保存。')));
    } catch (error) {
      if (mounted) setState(() => _error = '保存解读失败：$error');
    }
  }

  Future<void> _saveNote() async {
    try {
      await _library.saveAsNote(widget.row, deepAnalysis: _deep);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存到笔记。')));
    } catch (error) {
      if (mounted) setState(() => _error = '保存到笔记失败：$error');
    }
  }

  Future<void> _editMetadata() async {
    var status = _stored?.readingStatus ?? LiteratureReadingStatus.unread;
    final tags = TextEditingController(text: _stored?.tags.join('，') ?? '');
    final note = TextEditingController(text: _stored?.note ?? '');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('阅读状态与备注'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<LiteratureReadingStatus>(
                initialValue: status,
                items: const [
                  DropdownMenuItem(
                    value: LiteratureReadingStatus.unread,
                    child: Text('未读'),
                  ),
                  DropdownMenuItem(
                    value: LiteratureReadingStatus.reading,
                    child: Text('阅读中'),
                  ),
                  DropdownMenuItem(
                    value: LiteratureReadingStatus.read,
                    child: Text('已读'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setDialogState(() => status = value);
                },
              ),
              TextField(
                controller: tags,
                decoration: const InputDecoration(labelText: '标签（逗号分隔）'),
              ),
              TextField(
                controller: note,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '个人备注'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      try {
        final stored = await _library.updateMetadata(
          recommendation: widget.row,
          status: status,
          tags: tags.text.split(RegExp(r'[,，;；]+')),
          note: note.text,
        );
        if (mounted) setState(() => _stored = stored);
      } catch (error) {
        if (mounted) setState(() => _error = '保存状态失败：$error');
      }
    }
    tags.dispose();
    note.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    return Scaffold(
      appBar: AppBar(title: const Text('文献详情')),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              row.paper.title,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 10),
            Text(
              '${_matchTierLabel(row.matchTier)} · 匹配 ${row.relevanceScore.toStringAsFixed(0)}% · '
              '引用 ${row.paper.citationCount} · 参考 ${row.paper.referenceCount} · '
              '${row.paper.isOpenAccess ? '开放获取' : '未确认开放全文'}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (row.paper.isRetracted) ...[
              const SizedBox(height: 8),
              Text(
                '警告：该记录已被学术索引标记为撤稿。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _toggleFavorite,
                  icon: Icon(
                    _stored?.isFavorite == true
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                  ),
                  label: Text(_stored?.isFavorite == true ? '已收藏' : '收藏'),
                ),
                OutlinedButton.icon(
                  onPressed: _saveNote,
                  icon: const Icon(Icons.note_add_outlined),
                  label: const Text('保存到笔记'),
                ),
                OutlinedButton.icon(
                  onPressed: _editMetadata,
                  icon: const Icon(Icons.bookmark_added_outlined),
                  label: const Text('状态与备注'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showLiteratureConnections(context, row),
                  icon: const Icon(Icons.hub_outlined),
                  label: const Text('研究脉络'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final stored = await _showAnnotationDialog(context, row);
                    if (mounted && stored != null) {
                      setState(() => _stored = stored);
                    }
                  },
                  icon: const Icon(Icons.format_quote_rounded),
                  label: const Text('添加研究摘录'),
                ),
                if (row.paper.url.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: widget.onOpenOriginal,
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('打开原文'),
                  ),
                if (row.paper.pdfUrl.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: _busy || _saving ? null : _preview,
                    icon: const Icon(Icons.picture_as_pdf_rounded),
                    label: const Text('内存预览 PDF'),
                  ),
                if (row.paper.pdfUrl.isNotEmpty)
                  FilledButton.icon(
                    onPressed: _busy || _saving ? null : _deepRead,
                    icon: const Icon(Icons.psychology_alt_rounded),
                    label: const Text('深度解读 · Flash'),
                  ),
                if (row.paper.pdfUrl.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: _busy || _saving || _savedToCloud
                        ? null
                        : _savePdfToCloud,
                    icon: Icon(
                      _savedToCloud
                          ? Icons.cloud_done_rounded
                          : Icons.cloud_upload_rounded,
                    ),
                    label: Text(
                      _savedToCloud
                          ? '已保存到坚果云'
                          : (_saving ? '正在保存' : '保存 PDF 到云文件'),
                    ),
                  ),
                if (_deep != null)
                  FilledButton.tonalIcon(
                    onPressed: _saveDeep,
                    icon: Icon(
                      _stored?.hasSavedDeepAnalysis == true
                          ? Icons.cloud_done_rounded
                          : Icons.save_rounded,
                    ),
                    label: Text(
                      _stored?.hasSavedDeepAnalysis == true
                          ? '解读已保存'
                          : '永久保存解读',
                    ),
                  ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: _progress > 0 && _progress < 1 ? _progress : null,
              ),
              const SizedBox(height: 7),
              Text(
                _progress > 0 && _progress < 1
                    ? '正在将开放 PDF 读取到内存…'
                    : '正在逐页提取并使用 Flash 深度解读…',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_saving) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: _saveProgress > 0 && _saveProgress < 1
                    ? _saveProgress
                    : null,
              ),
              const SizedBox(height: 6),
              const Text('正在从内存直接上传到坚果云，不创建本地文件…'),
            ],
            const Divider(height: 28),
            if (_stored != null && _stored!.annotations.isNotEmpty) ...[
              _LiteratureAnnotations(
                item: _stored!,
                onDelete: (id) async {
                  final stored = await _library.removeAnnotation(
                    recommendation: row,
                    annotationId: id,
                  );
                  if (mounted) setState(() => _stored = stored);
                },
              ),
              const Divider(height: 28),
            ],
            if (_deep != null)
              _DeepLiteratureReport(data: _deep!, parsed: _parsed)
            else
              _AbstractLiteratureReport(row: row),
          ],
        ),
      ),
    );
  }
}

String _readingStatusLabel(LiteratureReadingStatus status) => switch (status) {
  LiteratureReadingStatus.unread => '未读',
  LiteratureReadingStatus.reading => '阅读中',
  LiteratureReadingStatus.read => '已读',
};

String _matchTierLabel(String value) => switch (value) {
  'foundational' => '奠基文献',
  'expanded' => '拓展阅读',
  _ => '高度相关',
};

int _matchTierPriority(String value) => switch (value) {
  'high_relevance' => 0,
  'foundational' => 1,
  'expanded' => 2,
  _ => 3,
};

List<LiteratureRecommendation> _sortedRecommendations(
  List<LiteratureRecommendation> values,
) {
  final rows = List<LiteratureRecommendation>.from(values);
  rows.sort((left, right) {
    final byTier = _matchTierPriority(
      left.matchTier,
    ).compareTo(_matchTierPriority(right.matchTier));
    if (byTier != 0) return byTier;
    final byRelevance = right.relevanceScore.compareTo(left.relevanceScore);
    if (byRelevance != 0) return byRelevance;
    return left.rank.compareTo(right.rank);
  });
  return rows;
}

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({
    required this.label,
    this.emphasized = false,
    this.danger = false,
  });

  final String label;
  final bool emphasized;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = danger
        ? colors.error
        : (emphasized ? colors.primary : colors.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

Future<LiteratureLibraryItem?> _showAnnotationDialog(
  BuildContext context,
  LiteratureRecommendation row,
) async {
  final quote = TextEditingController();
  final page = TextEditingController();
  final note = TextEditingController();
  String? error;
  LiteratureLibraryItem? result;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('添加研究摘录'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: quote,
                  contextMenuBuilder:
                      AiContextMenuHelper.editableTextContextMenuBuilder,
                  minLines: 3,
                  maxLines: 7,
                  decoration: const InputDecoration(
                    labelText: '原文摘录',
                    hintText: '粘贴真正支持判断的原文，不要只记录结论',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: page,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'PDF 页码（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  contextMenuBuilder:
                      AiContextMenuHelper.editableTextContextMenuBuilder,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '你的理解或用途（可选）',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                result = await LiteratureLibraryService.instance.addAnnotation(
                  recommendation: row,
                  quote: quote.text,
                  page: int.tryParse(page.text.trim()),
                  note: note.text,
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (value) {
                setDialogState(() => error = '$value');
              }
            },
            child: const Text('保存摘录'),
          ),
        ],
      ),
    ),
  );
  quote.dispose();
  page.dispose();
  note.dispose();
  return result;
}

Future<void> _showLiteratureConnections(
  BuildContext context,
  LiteratureRecommendation row,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1050, maxHeight: 760),
        child: _LiteratureConnectionsDialog(row: row),
      ),
    ),
  );
}

class _LiteratureConnectionsDialog extends StatefulWidget {
  const _LiteratureConnectionsDialog({required this.row});

  final LiteratureRecommendation row;

  @override
  State<_LiteratureConnectionsDialog> createState() =>
      _LiteratureConnectionsDialogState();
}

class _LiteratureConnectionsDialogState
    extends State<_LiteratureConnectionsDialog> {
  final _service = LiteratureConnectionsService();
  late final Future<LiteratureConnectionsReport> _future;
  final _saved = <String>{};

  @override
  void initState() {
    super.initState();
    _future = _service.load(widget.row.paper);
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _save(LiteraturePaper paper) async {
    final recommendation = LiteratureRecommendation(
      paper: paper,
      rank: 0,
      relevanceScore: 0,
      qualityScore: 0,
      freshnessScore: 0,
      overallScore: 0,
      coreSummary: paper.abstractText,
      recommendationReason: '从“${widget.row.paper.title}”的引用脉络加入研究库。',
      matchTier: 'expanded',
    );
    await LiteratureLibraryService.instance.setFavorite(recommendation, true);
    if (mounted) setState(() => _saved.add(paper.id));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LiteratureConnectionsReport>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在核验参考、后续引用与相似研究…'),
              ],
            ),
          );
        }
        if (snapshot.hasError) {
          return _ConnectionError(error: '${snapshot.error}');
        }
        final report = snapshot.data!;
        return DefaultTabController(
          length: 3,
          child: Column(
            children: [
              ListTile(
                title: const Text(
                  '研究脉络',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text(
                  '${report.provider} 按需读取 · 不自动保存网络数据'
                  '${report.errors.isEmpty ? '' : ' · ${report.errors.length} 项暂不可用'}',
                ),
                trailing: IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: '它引用了什么'),
                  Tab(text: '后来谁引用它'),
                  Tab(text: '相似研究'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _ConnectionList(
                      rows: report.references,
                      emptyText: '索引没有返回可核验的参考文献',
                      saved: _saved,
                      onSave: _save,
                    ),
                    _ConnectionList(
                      rows: report.citations,
                      emptyText: '目前没有取得后续引用记录',
                      saved: _saved,
                      onSave: _save,
                    ),
                    _ConnectionList(
                      rows: report.related,
                      emptyText: '目前没有取得高可信相似研究',
                      saved: _saved,
                      onSave: _save,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectionList extends StatelessWidget {
  const _ConnectionList({
    required this.rows,
    required this.emptyText,
    required this.saved,
    required this.onSave,
  });

  final List<LiteraturePaper> rows;
  final String emptyText;
  final Set<String> saved;
  final Future<void> Function(LiteraturePaper) onSave;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return Center(child: Text(emptyText));
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final paper = rows[index];
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        paper.title,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${paper.publishedOn?.year ?? '年份未知'} · '
                        '引用 ${paper.citationCount} · '
                        '${paper.isOpenAccess ? '开放获取' : '原文页'}'
                        '${paper.isRetracted ? ' · 已撤稿' : ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (paper.abstractText.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          paper.abstractText,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: saved.contains(paper.id) ? '已加入研究库' : '加入研究库',
                  onPressed: saved.contains(paper.id) || paper.isRetracted
                      ? null
                      : () => onSave(paper),
                  icon: Icon(
                    saved.contains(paper.id)
                        ? Icons.bookmark_added_rounded
                        : Icons.bookmark_add_outlined,
                  ),
                ),
                if (paper.url.isNotEmpty)
                  IconButton(
                    tooltip: '打开原文',
                    onPressed: () => launchUrl(
                      Uri.parse(paper.url),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new_rounded),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ConnectionError extends StatelessWidget {
  const _ConnectionError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hub_outlined, size: 48),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiteratureAnnotations extends StatelessWidget {
  const _LiteratureAnnotations({required this.item, required this.onDelete});

  final LiteratureLibraryItem item;
  final Future<void> Function(String) onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '研究摘录 ${item.annotations.length}',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        for (final annotation in item.annotations)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '“${annotation.quote}”',
                          style: const TextStyle(height: 1.5),
                        ),
                        if (annotation.page != null ||
                            annotation.note.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            '${annotation.page == null ? '' : '第 ${annotation.page} 页'}'
                            '${annotation.page != null && annotation.note.isNotEmpty ? ' · ' : ''}'
                            '${annotation.note}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '删除摘录',
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('删除这条研究摘录？'),
                          content: const Text('只删除摘录文字，不会删除文献、PDF 或笔记。'),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) await onDelete(annotation.id);
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
