import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/features/exploration/services/news_exploration_service.dart';
import 'package:url_launcher/url_launcher.dart';

class NewsExplorationScreen extends StatefulWidget {
  const NewsExplorationScreen({super.key});

  @override
  State<NewsExplorationScreen> createState() => _NewsExplorationScreenState();
}

class _NewsExplorationScreenState extends State<NewsExplorationScreen> {
  final _service = NewsExplorationService();
  List<ExplorationNewsArticle> _articles = const [];
  ExplorationNewsArticle? _selected;
  String _topic = '今日综合';
  bool _loading = true;
  String _status = '正在读取今日缓存…';
  List<String> _errors = const [];

  static const _topics = ['今日综合', '经济金融', '人工智能', '战争与地缘', '中国大陆'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _status = force ? '正在准备手动刷新…' : '正在读取今日云端快照…';
    });
    try {
      final result = await _service.load(
        force: force,
        onStage: (stage) {
          if (!mounted) return;
          setState(
            () => _status = switch (stage) {
              NewsLoadStage.readingSnapshot => '正在读取今日云端快照…',
              NewsLoadStage.waitingForSharedRefresh => '另一台设备正在刷新，正在等待今日快照…',
              NewsLoadStage.fetchingSources => '正在从权威来源聚合新闻…',
              NewsLoadStage.cleaningContent => '正在筛选并清理新闻正文…',
              NewsLoadStage.savingSnapshot => '正在保存今日云端快照…',
            },
          );
        },
      );
      if (!mounted) return;
      setState(() {
        _articles = result.articles;
        _selected = result.articles.firstOrNull;
        _errors = result.errors;
        _loading = false;
        _status = result.cached
            ? '今日云端快照 · ${result.articles.length} 条 · 同日不重复抓取'
            : '${result.successfulSources}/${result.totalSources} 个来源成功 · '
                  '${result.articles.length} 条已验证新闻';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = '新闻更新失败：$error';
      });
    }
  }

  List<ExplorationNewsArticle> get _filtered {
    if (_topic == '今日综合') return _articles;
    return _articles.where((item) => item.topic == _topic).toList();
  }

  void _selectTopic(String topic) {
    final filtered = topic == '今日综合'
        ? _articles
        : _articles.where((item) => item.topic == topic).toList();
    setState(() {
      _topic = topic;
      _selected = filtered.firstOrNull;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日新闻'),
        actions: [
          IconButton(
            tooltip: '手动刷新',
            onPressed: _loading ? null : () => _load(force: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildTopicBar(context),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (_loading && _articles.isEmpty) {
                  return Center(child: Text(_status));
                }
                if (_articles.isEmpty) {
                  return _EmptyNews(
                    status: _status,
                    onRefresh: () => _load(force: true),
                  );
                }
                if (constraints.maxWidth < 760) {
                  return _buildMobileList(context);
                }
                return _buildDesktop(context);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopicBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _topics
                    .map(
                      (topic) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(topic),
                          selected: _topic == topic,
                          onSelected: (_) => _selectTopic(topic),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _status,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (_errors.isNotEmpty)
                  Tooltip(
                    message: _errors.join('\n'),
                    child: Text(
                      '${_errors.length} 个来源暂不可用',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 390,
          child: _NewsList(
            articles: _filtered,
            selected: _selected,
            onSelected: (value) => setState(() => _selected = value),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _selected == null
              ? const Center(child: Text('这个栏目今天暂无完整正文'))
              : _NewsDetail(article: _selected!),
        ),
      ],
    );
  }

  Widget _buildMobileList(BuildContext context) {
    return _NewsList(
      articles: _filtered,
      selected: null,
      onSelected: (value) => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('新闻正文')),
            body: _NewsDetail(article: value),
          ),
        ),
      ),
    );
  }
}

class _NewsList extends StatelessWidget {
  const _NewsList({
    required this.articles,
    required this.selected,
    required this.onSelected,
  });

  final List<ExplorationNewsArticle> articles;
  final ExplorationNewsArticle? selected;
  final ValueChanged<ExplorationNewsArticle> onSelected;

  @override
  Widget build(BuildContext context) {
    if (articles.isEmpty) return const Center(child: Text('这个栏目今天暂无新闻'));
    return ListView.separated(
      padding: const EdgeInsets.all(10),
      itemCount: articles.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final article = articles[index];
        return Card(
          margin: EdgeInsets.zero,
          color: selected?.id == article.id
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onSelected(article),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${article.sourceName} · ${_formatTime(article.publishedAt)} · '
                    '${article.historicalSupplement ? '历史补充' : '实时优先'} · '
                    '${_sourceLabel(article)} · ${_contentLabel(article)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NewsDetail extends StatelessWidget {
  const _NewsDetail({required this.article});

  final ExplorationNewsArticle article;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  article.title,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${article.sourceName} · ${_formatTime(article.publishedAt)} · '
                  '${article.topic} · '
                  '${article.historicalSupplement ? '历史补充' : '实时优先'} · '
                  '${_sourceLabel(article)} · ${_contentLabel(article)}',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(article.url),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('打开权威原文'),
                ),
                const Divider(height: 32),
                if (article.contentComplete)
                  SelectableText(
                    article.fullContent,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(height: 1.75),
                  )
                else if (article.fullContent.trim().length >= 120) ...[
                  Text(
                    '该来源只提供了可验证的正文节选，下面内容已经清理，但不冒充完整全文。',
                    style: TextStyle(
                      color: colors.tertiary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    article.fullContent,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(height: 1.75),
                  ),
                ] else ...[
                  Text(
                    '该来源未能提供可可靠提取的正文，下面仅显示来源摘要，不会把摘要冒充全文。',
                    style: TextStyle(
                      color: colors.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    article.summary.isEmpty
                        ? '来源没有提供摘要，请打开权威原文。'
                        : article.summary,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(height: 1.75),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyNews extends StatelessWidget {
  const _EmptyNews({required this.status, required this.onRefresh});

  final String status;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.newspaper_outlined, size: 52),
            const SizedBox(height: 12),
            Text(status, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新抓取'),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatTime(DateTime? value) {
  if (value == null) return '时间未知';
  return DateFormat('MM-dd HH:mm').format(value.toLocal());
}

String _sourceLabel(ExplorationNewsArticle article) {
  final type = article.sourceClass == 'first_party' ? '一手官方' : '专业媒体';
  return article.language == 'en' ? '$type · 英文原文' : type;
}

String _contentLabel(ExplorationNewsArticle article) {
  if (article.contentComplete) {
    final origin = switch (article.contentOrigin) {
      'feed' => 'RSS 正文',
      'json_ld' => '结构化正文',
      _ => '网页正文',
    };
    return '$origin · 质量 ${article.contentQuality}';
  }
  if (article.fullContent.trim().length >= 120) {
    return '正文节选 · 质量 ${article.contentQuality}';
  }
  return '仅可靠摘要';
}
