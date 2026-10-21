import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/features/exploration/services/exploration_repository.dart';
import 'package:syncnote/features/exploration/services/news_snapshot_store.dart';
import 'package:xml/xml.dart';

@immutable
class NewsRefreshResult {
  const NewsRefreshResult({
    required this.articles,
    required this.successfulSources,
    required this.totalSources,
    required this.errors,
    required this.cached,
  });

  final List<ExplorationNewsArticle> articles;
  final int successfulSources;
  final int totalSources;
  final List<String> errors;
  final bool cached;
}

enum NewsLoadStage {
  readingSnapshot,
  waitingForSharedRefresh,
  fetchingSources,
  cleaningContent,
  savingSnapshot,
}

class NewsExplorationService {
  NewsExplorationService({
    http.Client? client,
    ExplorationRepository? repository,
    NewsSnapshotStore? snapshots,
  }) : _client = client ?? http.Client(),
       _repository = repository ?? ExplorationRepository.instance,
       _snapshots = snapshots ?? NewsSnapshotStore.instance;

  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 Chrome/126.0 Safari/537.36 SyncNoteNews/1.0',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.6',
  };

  final http.Client _client;
  final ExplorationRepository _repository;
  final NewsSnapshotStore _snapshots;

  Future<NewsRefreshResult> load({
    bool force = false,
    DateTime? now,
    ValueChanged<NewsLoadStage>? onStage,
  }) async {
    final current = now ?? DateTime.now();
    onStage?.call(NewsLoadStage.readingSnapshot);
    List<ExplorationNewsArticle> cached = const [];
    try {
      cached = await _snapshots.load(current);
    } catch (_) {
      // A damaged or temporarily unreachable snapshot must never block a
      // fresh, verified replacement.
    }
    if (!force && cached.isNotEmpty) {
      return _cachedResult(cached);
    }

    String? leaseOwner;
    try {
      leaseOwner = await _snapshots.acquireLease(current, current);
    } catch (_) {
      if (cached.isNotEmpty) return _cachedResult(cached);
      rethrow;
    }
    if (leaseOwner == null) {
      if (cached.isNotEmpty) {
        return _cachedResult(cached, error: '另一台设备正在刷新，当前继续显示已验证快照');
      }
      onStage?.call(NewsLoadStage.waitingForSharedRefresh);
      for (var attempt = 0; attempt < 6; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          final shared = await _snapshots.load(current);
          if (shared.isNotEmpty) return _cachedResult(shared);
        } catch (_) {
          // Keep waiting for the lease holder to finish.
        }
      }
      throw StateError('另一台设备正在刷新今日新闻，请稍后重试');
    }
    try {
      onStage?.call(NewsLoadStage.fetchingSources);
      final sources = await _repository.loadNewsSources();
      final keywordRules = await _repository.loadKeywordRules();
      final rankingRules = await _repository.loadRankingRules();
      final runs = await Future.wait(
        sources.map((source) => _fetchSource(source)),
      );
      final discovered = runs.expand((run) => run.articles).where((article) {
        final published = article.publishedAt;
        if (published == null) return false;
        final age = current.toUtc().difference(published.toUtc());
        return age >= const Duration(hours: -3) &&
            age <= const Duration(days: 30);
      }).toList();
      final unique = _deduplicate(discovered);
      final preliminary = _rank(unique, keywordRules, rankingRules, current);
      final candidates = _selectDailyArticles(
        preliminary,
        current,
        perTopic: 15,
      );
      onStage?.call(NewsLoadStage.cleaningContent);
      final enriched = <ExplorationNewsArticle>[];
      for (var index = 0; index < candidates.length; index += 6) {
        enriched.addAll(
          await Future.wait(
            candidates.skip(index).take(6).map((article) => _enrich(article)),
          ),
        );
      }
      final ranked = _rank(enriched, keywordRules, rankingRules, current);
      final selected = _selectDailyArticles(ranked, current, perTopic: 10);
      if (selected.isEmpty) throw StateError('权威来源没有返回可展示的新闻');
      onStage?.call(NewsLoadStage.savingSnapshot);
      await _snapshots.save(selected, current);
      await _snapshots.releaseLease(leaseOwner, failed: false);
      return NewsRefreshResult(
        articles: selected,
        successfulSources: runs.where((run) => run.articles.isNotEmpty).length,
        totalSources: sources.length,
        errors: runs
            .where((run) => run.error.isNotEmpty)
            .map((run) => '${run.sourceName}：${run.error}')
            .toList(),
        cached: false,
      );
    } catch (error) {
      await _snapshots.releaseLease(leaseOwner, failed: true);
      if (cached.isNotEmpty) {
        return _cachedResult(cached, error: '刷新失败，已保留原快照：$error');
      }
      rethrow;
    }
  }

  static NewsRefreshResult _cachedResult(
    List<ExplorationNewsArticle> articles, {
    String? error,
  }) {
    return NewsRefreshResult(
      articles: articles,
      successfulSources: 0,
      totalSources: 0,
      errors: error == null ? const [] : [error],
      cached: true,
    );
  }

  Future<_NewsSourceRun> _fetchSource(NewsSourceDefinition source) async {
    try {
      final response = await _client
          .get(Uri.parse(source.url), headers: _headers)
          .timeout(const Duration(seconds: 24));
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      final articles = switch (source.kind) {
        'rss' => _parseFeed(source, text),
        'newsnow_json' => _parseNewsNow(source, text),
        'sitemap' => _parseSitemap(source, text),
        _ => throw StateError('不支持的来源类型 ${source.kind}'),
      };
      if (articles.isEmpty) throw StateError('没有返回有效新闻');
      return _NewsSourceRun(sourceName: source.name, articles: articles);
    } catch (error) {
      return _NewsSourceRun(
        sourceName: source.name,
        articles: const [],
        error: '$error',
      );
    }
  }

  List<ExplorationNewsArticle> _parseFeed(
    NewsSourceDefinition source,
    String text,
  ) {
    final document = XmlDocument.parse(text);
    var nodes = document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'item',
    );
    if (nodes.isEmpty) {
      nodes = document.descendants.whereType<XmlElement>().where(
        (element) => element.name.local == 'entry',
      );
    }
    final output = <ExplorationNewsArticle>[];
    for (final node in nodes) {
      String childText(String name) =>
          node.children
              .whereType<XmlElement>()
              .where((element) => element.name.local == name)
              .map((element) => element.innerText)
              .firstOrNull ??
          '';
      final title = _oneLine(childText('title'));
      final linkNode = node.children
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'link')
          .firstOrNull;
      final rawLink = _oneLine(linkNode?.innerText ?? '').isNotEmpty
          ? _oneLine(linkNode!.innerText)
          : linkNode?.getAttribute('href') ?? '';
      final link = Uri.parse(source.url).resolve(rawLink).toString();
      final summary = _cleanMarkup(
        childText('description').isNotEmpty
            ? childText('description')
            : (childText('summary').isNotEmpty
                  ? childText('summary')
                  : childText('content')),
      );
      final published = _parseDate(
        childText('pubDate').isNotEmpty
            ? childText('pubDate')
            : (childText('published').isNotEmpty
                  ? childText('published')
                  : childText('updated')),
      );
      if (title.length >= 6 && link.isNotEmpty) {
        final embeddedHtml = childText('encoded').isNotEmpty
            ? childText('encoded')
            : childText('content');
        final embedded = _extractEmbeddedContent(embeddedHtml);
        output.add(
          _baseArticle(
            source,
            title,
            link,
            published,
            summary,
            fullContent: embedded.text,
            contentOrigin: embedded.text.isEmpty ? 'none' : 'feed',
            contentQuality: embedded.quality,
            contentComplete: embedded.complete,
          ),
        );
      }
      if (output.length >= source.limit) break;
    }
    return output;
  }

  List<ExplorationNewsArticle> _parseSitemap(
    NewsSourceDefinition source,
    String text,
  ) {
    final document = XmlDocument.parse(text);
    final rows = <({String url, DateTime? modified})>[];
    for (final node in document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'url',
    )) {
      String childText(String name) =>
          node.children
              .whereType<XmlElement>()
              .where((element) => element.name.local == name)
              .map((element) => element.innerText.trim())
              .firstOrNull ??
          '';
      final url = _canonicalUrl(childText('loc'));
      final uri = Uri.tryParse(url);
      if (uri == null || url.isEmpty) continue;
      if (source.pathPrefixes.isNotEmpty &&
          !source.pathPrefixes.any(uri.path.startsWith)) {
        continue;
      }
      rows.add((url: url, modified: _parseDate(childText('lastmod'))));
    }
    rows.sort(
      (left, right) => (right.modified ?? DateTime(1900)).compareTo(
        left.modified ?? DateTime(1900),
      ),
    );
    return rows
        .take(source.limit)
        .map((row) {
          final uri = Uri.parse(row.url);
          final slug = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
          final provisionalTitle = slug
              .split('-')
              .where((part) => part.isNotEmpty)
              .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
              .join(' ');
          return _baseArticle(
            source,
            provisionalTitle,
            row.url,
            row.modified,
            '',
          );
        })
        .where((article) => article.title.length >= 6)
        .toList();
  }

  List<ExplorationNewsArticle> _parseNewsNow(
    NewsSourceDefinition source,
    String text,
  ) {
    final payload = Map<String, dynamic>.from(jsonDecode(text) as Map);
    final status = '${payload['status'] ?? ''}'.toLowerCase();
    if (!{'success', 'cache', 'fresh'}.contains(status)) {
      throw StateError('聚合源未返回成功状态');
    }
    final output = <ExplorationNewsArticle>[];
    final seen = <String>{};
    for (final raw in payload['items'] as List? ?? const []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final extra = Map<String, dynamic>.from(
        item['extra'] as Map? ?? const {},
      );
      final title = _oneLine('${item['title'] ?? ''}');
      final url = _canonicalUrl('${item['url'] ?? ''}');
      if (title.length < 6 || url.isEmpty || !seen.add(url)) continue;
      output.add(
        _baseArticle(
          source,
          title,
          url,
          _parseDate(
            '${item['pubDate'] ?? extra['date'] ?? item['publishedAt'] ?? ''}',
          ),
          '${extra['hover'] ?? extra['info'] ?? item['description'] ?? ''}',
        ),
      );
      if (output.length >= source.limit) break;
    }
    return output;
  }

  Future<ExplorationNewsArticle> _enrich(ExplorationNewsArticle article) async {
    try {
      final response = await _client
          .get(Uri.parse(article.url), headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return article;
      final rawHtml = utf8.decode(response.bodyBytes, allowMalformed: true);
      final finalUrl = response.request?.url ?? Uri.parse(article.url);
      final document = html_parser.parse(rawHtml);
      final metadata = _pageMetadata(document);
      final extracted = _extractFromDocument(document, finalUrl);
      final usePage = extracted.quality > article.contentQuality;
      return article.copyWith(
        title: metadata.title.length >= 6 ? metadata.title : article.title,
        summary: metadata.summary.length > article.summary.length
            ? metadata.summary
            : article.summary,
        fullContent: usePage ? extracted.text : article.fullContent,
        contentComplete: usePage ? extracted.complete : article.contentComplete,
        contentOrigin: usePage ? extracted.origin : article.contentOrigin,
        contentQuality: usePage ? extracted.quality : article.contentQuality,
      );
    } catch (_) {
      return article;
    }
  }

  static _ExtractedNewsContent _extractEmbeddedContent(String rawHtml) {
    if (rawHtml.trim().isEmpty) return const _ExtractedNewsContent.empty();
    final document = html_parser.parse('<article>$rawHtml</article>');
    return _extractFromDocument(
      document,
      Uri.parse('https://feed.invalid/article'),
      origin: 'feed',
    );
  }

  static _PageMetadata _pageMetadata(Document document) {
    String meta(String selector) =>
        _oneLine(document.querySelector(selector)?.attributes['content'] ?? '');
    var title = meta('meta[property="og:title"]');
    title = title.isEmpty ? meta('meta[name="twitter:title"]') : title;
    title = title.isEmpty
        ? _oneLine(document.querySelector('h1')?.text ?? '')
        : title;
    title = title.isEmpty
        ? _oneLine(document.querySelector('title')?.text ?? '')
        : title;
    var summary = meta('meta[property="og:description"]');
    summary = summary.isEmpty ? meta('meta[name="description"]') : summary;
    return _PageMetadata(title: title, summary: summary);
  }

  static _ExtractedNewsContent _extractFromDocument(
    Document document,
    Uri url, {
    String origin = 'page',
  }) {
    // Capture structured data before pruning scripts and page chrome. Some DOM
    // implementations do not preserve raw-text script nodes after mutations.
    final structuredBody = _structuredArticleBody(document);
    for (final node in document.querySelectorAll(
      'script,style,noscript,nav,footer,header,aside,form,button,'
      '.ad,.ads,.advertisement,.recommend,.related,.share,.left_time,'
      '.adEditor,.pictext,.copyright,.newsletter,.subscribe,.social-share,'
      '[aria-label="breadcrumb"],[class*="cookie"],[class*="Cookie"]',
    )) {
      if (node.localName == 'script' &&
          node.attributes['type'] == 'application/ld+json') {
        continue;
      }
      node.remove();
    }
    final structuredParagraphs = _plainParagraphs(structuredBody);
    var best = structuredParagraphs;
    var bestScore = _contentQuality(structuredParagraphs);
    var bestOrigin = structuredParagraphs.isEmpty ? origin : 'json_ld';
    const siteSelectors = <String, List<String>>{
      'chinanews.com.cn': ['.left_zw', '.content_desc'],
      'chinanews.com': ['.left_zw', '.content_desc'],
      'news.cn': ['#detailContent', '.main-aticle', '.article', '.content'],
      'xinhuanet.com': ['#detailContent', '.main-aticle', '.article'],
      'ithome.com': ['#paragraph', '.post_content'],
      'cls.cn': ['.detail-content', '.article-content', 'article'],
      'cankaoxiaoxi.com': ['.article-content', '.articleText', 'article'],
      'deepmind.google': ['main article', 'article', 'main'],
      'huggingface.co': ['main article', '.blog-content', 'main'],
      'microsoft.com': ['[itemprop="articleBody"]', '.entry-content', 'main'],
      'anthropic.com': ['main article', 'article', 'main'],
    };
    const generic = [
      'article',
      '[itemprop=articleBody]',
      'main article',
      '.article-content',
      '.article-body',
      '.article__content',
      '.post-content',
      '.post_content',
      '.detail-content',
      '.entry-content',
      '.rich-text',
      '.prose',
      '[class*="articleBody"]',
      '[class*="article-body"]',
      'main',
    ];
    final selectors = <String>[
      for (final entry in siteSelectors.entries)
        if (url.host.toLowerCase().endsWith(entry.key)) ...entry.value,
      ...generic,
    ];
    final visited = <Element>{};
    for (final selector in selectors) {
      for (final root in document.querySelectorAll(selector)) {
        if (!visited.add(root)) continue;
        final paragraphs = _paragraphs(root);
        final score = _contentQuality(paragraphs);
        if (score > bestScore) {
          best = paragraphs;
          bestScore = score;
          bestOrigin = origin;
        }
      }
    }
    final text = best.join('\n\n');
    final assessment = _assessContent(best);
    return _ExtractedNewsContent(
      text: text,
      complete: assessment.complete,
      quality: assessment.quality,
      origin: text.isEmpty ? 'none' : bestOrigin,
    );
  }

  static String _structuredArticleBody(Document document) {
    String find(dynamic value) {
      if (value is Map) {
        final body = value['articleBody'];
        if (body is String && body.trim().isNotEmpty) return body;
        for (final child in value.values) {
          final found = find(child);
          if (found.isNotEmpty) return found;
        }
      } else if (value is List) {
        for (final child in value) {
          final found = find(child);
          if (found.isNotEmpty) return found;
        }
      }
      return '';
    }

    for (final script in document.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      try {
        // `Element.text` intentionally omits raw-text script contents in the
        // html package. Read the text nodes directly so valid JSON-LD is not
        // mistaken for an empty block.
        final raw = script.nodes
            .whereType<Text>()
            .map((node) => node.data)
            .join()
            .trim();
        if (raw.isEmpty) continue;
        final found = find(jsonDecode(raw));
        if (found.isNotEmpty) return found;
      } catch (_) {
        // A malformed analytics/schema block must not invalidate the page.
      }
    }
    return '';
  }

  static List<String> _plainParagraphs(String value) {
    if (value.trim().isEmpty) return const [];
    final parsed = html_parser.parseFragment(value);
    final htmlParagraphs = parsed
        .querySelectorAll('p')
        .map((node) => _oneLine(node.text))
        .where((text) => text.length >= 18)
        .toList();
    if (htmlParagraphs.isNotEmpty) return htmlParagraphs;
    final lines = value
        .split(RegExp(r'\n{2,}|\r\n{2,}'))
        .map((line) => _oneLine(html_parser.parseFragment(line).text ?? ''))
        .where((line) => line.length >= 18)
        .toList();
    if (lines.length > 1) return lines;
    final plain = _oneLine(parsed.text ?? value);
    if (plain.length < 18) return const [];
    return [plain];
  }

  static List<String> _paragraphs(Element root) {
    const noise = [
      '责任编辑',
      '责任校对',
      '值班编辑',
      '编辑：',
      '编辑:',
      '来源：',
      '来源:',
      '版权所有',
      '网站地图',
      '打印',
      '关闭窗口',
      '分享',
      '返回顶部',
      '相关阅读',
      '相关推荐',
      '更多精彩内容',
      '打开客户端',
      '扫码下载',
      '免责声明',
      'sign up',
      'subscribe',
      'related posts',
      'recommended for you',
      'read more',
      'all rights reserved',
      'cookie policy',
    ];
    final output = <String>[];
    final seen = <String>{};
    for (final paragraph in root.querySelectorAll('p')) {
      final text = _oneLine(paragraph.text);
      if (text.length < 18 ||
          text.length > 1800 ||
          noise.any(text.contains) ||
          {'（完）', '(完)', '完'}.contains(text)) {
        continue;
      }
      final linkCharacters = paragraph
          .querySelectorAll('a[href]')
          .fold<int>(0, (sum, item) => sum + item.text.trim().length);
      if (linkCharacters > 0 && linkCharacters / text.length > 0.35) {
        continue;
      }
      final normalized = text.replaceAll(RegExp(r'\W+'), '');
      if (seen.add(normalized)) output.add(text);
    }
    return output;
  }

  static double _contentQuality(List<String> paragraphs) {
    if (paragraphs.isEmpty) return 0;
    final characters = paragraphs.fold<int>(
      0,
      (sum, item) => sum + item.length,
    );
    final useful = paragraphs.where((item) => item.length >= 45).length;
    final punctuation = paragraphs
        .where((item) => RegExp(r'[。！？.!?]$').hasMatch(item))
        .length;
    final short = paragraphs.where((item) => item.length < 28).length;
    return characters + useful * 80 + punctuation * 15 - short * 35;
  }

  static ({bool complete, int quality}) _assessContent(
    List<String> paragraphs,
  ) {
    if (paragraphs.isEmpty) return (complete: false, quality: 0);
    final characters = paragraphs.fold<int>(
      0,
      (sum, item) => sum + item.length,
    );
    final average = characters / paragraphs.length;
    final complete =
        characters >= 320 &&
        ((paragraphs.length >= 3 && average >= 34) || characters >= 900);
    final quality = math
        .min(
          100,
          (characters / 20).round() +
              math.min(24, paragraphs.length * 4) +
              (complete ? 20 : 0),
        )
        .toInt();
    return (complete: complete, quality: quality);
  }

  @visibleForTesting
  static ({String text, bool complete, int quality, String origin})
  extractContentForTesting(String html, Uri url) {
    final value = _extractFromDocument(html_parser.parse(html), url);
    return (
      text: value.text,
      complete: value.complete,
      quality: value.quality,
      origin: value.origin,
    );
  }

  static List<ExplorationNewsArticle> _rank(
    List<ExplorationNewsArticle> articles,
    Map<String, dynamic> keywordRules,
    Map<String, dynamic> rankingRules,
    DateTime now,
  ) {
    final topics = Map<String, dynamic>.from(
      keywordRules['topics'] as Map? ?? const {},
    );
    final impacts = Map<String, dynamic>.from(
      keywordRules['impact_terms'] as Map? ?? const {},
    );
    final weights = Map<String, dynamic>.from(
      rankingRules['weights'] as Map? ?? const {},
    );
    final halfLife =
        (rankingRules['freshness_half_life_hours'] as num?)?.toDouble() ?? 36;
    final ranked = articles.map((article) {
      final text =
          '${article.title} ${article.summary} '
          '${article.fullContent.length > 1200 ? article.fullContent.substring(0, 1200) : article.fullContent}';
      var bestTopic = article.topic;
      var topicScore = 0.0;
      final matched = <String>[];
      for (final entry in topics.entries) {
        final rule = Map<String, dynamic>.from(entry.value as Map);
        final ordinary = List<String>.from(
          rule['must_any'] as List? ?? const [],
        ).where((term) => _containsTerm(text, term)).toList();
        final high = List<String>.from(
          rule['high_weight'] as List? ?? const [],
        ).where((term) => _containsTerm(text, term)).toList();
        final excluded = List<String>.from(
          rule['exclude'] as List? ?? const [],
        ).where((term) => _containsTerm(text, term)).toList();
        final anchored =
            ordinary.isNotEmpty ||
            entry.key == article.topic ||
            (entry.key == '中国大陆' && article.region == '中国大陆');
        var score = math.min(
          1,
          ordinary.length * 0.22 + (anchored ? high.length * 0.36 : 0),
        );
        if (excluded.isNotEmpty) score = math.max(0, score - 0.65);
        if (entry.key == article.topic) score = math.min(1, score + 0.35);
        if (entry.key == '中国大陆' && article.region == '中国大陆') {
          score = math.min(1, score + 0.35);
        }
        if (score > topicScore) {
          topicScore = score.toDouble();
          bestTopic = entry.key;
          matched
            ..clear()
            ..addAll([...ordinary, ...high]);
        }
      }
      final curatedTopic =
          article.topic != '综合' && topics.containsKey(article.topic);
      if (curatedTopic) {
        bestTopic = article.topic;
        final rule = Map<String, dynamic>.from(
          topics[article.topic] as Map? ?? const {},
        );
        final curatedMatches = <String>[
          ...List<String>.from(rule['must_any'] as List? ?? const []),
          ...List<String>.from(rule['high_weight'] as List? ?? const []),
        ].where((term) => _containsTerm(text, term)).toList();
        matched
          ..clear()
          ..addAll(curatedMatches);
        topicScore = math.max(topicScore, 0.72);
      }
      var impact = 0.0;
      for (final entry in impacts.entries) {
        final weight = double.tryParse(entry.key) ?? 0;
        for (final term in List<String>.from(entry.value as List)) {
          if (_containsTerm('${article.title} ${article.summary}', term)) {
            impact += weight;
          }
        }
      }
      final ageHours = article.publishedAt == null
          ? 999.0
          : math.max(
              0,
              now.toUtc().difference(article.publishedAt!.toUtc()).inMinutes /
                  60,
            );
      final freshness = article.publishedAt == null
          ? 0.35
          : math.pow(0.5, ageHours / halfLife).toDouble();
      var score =
          article.sourceAuthority *
              ((weights['authority'] as num?)?.toDouble() ?? 32) +
          freshness * ((weights['freshness'] as num?)?.toDouble() ?? 26) +
          topicScore * ((weights['topic_match'] as num?)?.toDouble() ?? 16) +
          math.min(10, impact) /
              10 *
              ((weights['impact'] as num?)?.toDouble() ?? 12) +
          (article.contentComplete ? 1 : 0) *
              ((weights['complete_content'] as num?)?.toDouble() ?? 4);
      if (article.publishedAt == null) {
        score -=
            (rankingRules['unknown_date_penalty'] as num?)?.toDouble() ?? 8;
      }
      if (!article.contentComplete) {
        score -=
            (rankingRules['incomplete_content_penalty'] as num?)?.toDouble() ??
            5;
      }
      return article.copyWith(
        topic: bestTopic,
        keywords: matched.take(8).toList(),
        score: score,
      );
    }).toList();
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked;
  }

  @visibleForTesting
  static List<ExplorationNewsArticle> rankForTesting(
    List<ExplorationNewsArticle> articles,
    Map<String, dynamic> keywordRules,
    Map<String, dynamic> rankingRules,
    DateTime now,
  ) => _rank(articles, keywordRules, rankingRules, now);

  @visibleForTesting
  static List<ExplorationNewsArticle> selectDailyArticlesForTesting(
    List<ExplorationNewsArticle> articles,
    DateTime now, {
    int perTopic = 10,
  }) => _selectDailyArticles(articles, now, perTopic: perTopic);

  static List<ExplorationNewsArticle> _selectDailyArticles(
    List<ExplorationNewsArticle> articles,
    DateTime now, {
    required int perTopic,
  }) {
    const topics = ['经济金融', '人工智能', '战争与地缘', '中国大陆'];
    final selected = <ExplorationNewsArticle>[];
    final selectedIds = <String>{};
    for (final topic in topics) {
      final candidates = articles.where((item) => item.topic == topic).toList()
        ..sort((left, right) {
          final tier = _ageTier(left, now).compareTo(_ageTier(right, now));
          if (tier != 0) return tier;
          if (left.contentComplete != right.contentComplete) {
            return left.contentComplete ? -1 : 1;
          }
          return right.score.compareTo(left.score);
        });
      final sourceCounts = <String, int>{};
      final topicRows = <ExplorationNewsArticle>[];
      for (final article in candidates) {
        final count = sourceCounts[article.sourceId] ?? 0;
        if (count >= 3) continue;
        sourceCounts[article.sourceId] = count + 1;
        topicRows.add(article);
        if (topicRows.length >= perTopic) break;
      }
      if (topicRows.length < perTopic) {
        for (final article in candidates) {
          if (topicRows.any((item) => item.id == article.id)) continue;
          topicRows.add(article);
          if (topicRows.length >= perTopic) break;
        }
      }
      for (final article in topicRows) {
        if (!selectedIds.add(article.id)) continue;
        selected.add(
          article.copyWith(historicalSupplement: _ageTier(article, now) >= 2),
        );
      }
    }
    selected.sort((left, right) {
      final tier = _ageTier(left, now).compareTo(_ageTier(right, now));
      if (tier != 0) return tier;
      return right.score.compareTo(left.score);
    });
    return selected;
  }

  static int _ageTier(ExplorationNewsArticle article, DateTime now) {
    final published = article.publishedAt;
    if (published == null) return 5;
    final age = now.toUtc().difference(published.toUtc());
    if (age <= const Duration(hours: 2)) return 0;
    if (age <= const Duration(hours: 24)) return 1;
    if (age <= const Duration(days: 3)) return 2;
    if (age <= const Duration(days: 7)) return 3;
    if (age <= const Duration(days: 30)) return 4;
    return 5;
  }

  static List<ExplorationNewsArticle> _deduplicate(
    List<ExplorationNewsArticle> articles,
  ) {
    final byUrl = <String, ExplorationNewsArticle>{};
    final titleSignatures = <String, ExplorationNewsArticle>{};
    for (final article in articles) {
      if (byUrl.containsKey(article.url)) continue;
      final signature = _normalizeTitle(article.title);
      final similar = titleSignatures.entries
          .where((entry) => _titleSimilarity(signature, entry.key) >= 0.62)
          .firstOrNull;
      if (similar != null) continue;
      byUrl[article.url] = article;
      titleSignatures[signature] = article;
    }
    return byUrl.values.toList();
  }

  static double _titleSimilarity(String left, String right) {
    Set<String> grams(String value) => {
      for (var index = 0; index < value.length - 1; index++)
        value.substring(index, index + 2),
    };
    final a = grams(left);
    final b = grams(right);
    if (a.isEmpty || b.isEmpty) return 0;
    return a.intersection(b).length / a.union(b).length;
  }

  static ExplorationNewsArticle _baseArticle(
    NewsSourceDefinition source,
    String title,
    String url,
    DateTime? publishedAt,
    String summary, {
    String fullContent = '',
    String contentOrigin = 'none',
    int contentQuality = 0,
    bool contentComplete = false,
  }) {
    final cleanUrl = _canonicalUrl(url);
    final id = sha256
        .convert(utf8.encode(cleanUrl))
        .toString()
        .substring(0, 24);
    return ExplorationNewsArticle(
      id: id,
      title: _oneLine(title),
      url: cleanUrl,
      sourceId: source.id,
      sourceName: source.name,
      sourceAuthority: source.authority,
      region: source.region,
      topic: source.topic,
      publishedAt: publishedAt,
      summary: _cleanMarkup(summary),
      fullContent: fullContent,
      contentOrigin: contentOrigin,
      contentQuality: contentQuality,
      contentComplete: contentComplete,
      sourceClass: source.sourceClass,
      language: source.language,
    );
  }

  static DateTime? _parseDate(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final integer = int.tryParse(text);
    if (integer != null && (text.length == 10 || text.length == 13)) {
      return DateTime.fromMillisecondsSinceEpoch(
        text.length == 13 ? integer : integer * 1000,
        isUtc: true,
      );
    }
    try {
      return HttpDate.parse(text);
    } catch (_) {
      final parsed = DateTime.tryParse(text);
      if (parsed != null) return parsed;
      final match = RegExp(
        r'(20\d{2})[-/.年](\d{1,2})[-/.月](\d{1,2})',
      ).firstMatch(text);
      if (match == null) return null;
      return DateTime.utc(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      );
    }
  }

  static String _canonicalUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !{'http', 'https'}.contains(uri.scheme)) return '';
    final query = Map<String, String>.from(uri.queryParameters)
      ..removeWhere(
        (key, _) =>
            key.toLowerCase().startsWith('utm_') ||
            {'spm', 'from'}.contains(key.toLowerCase()),
      );
    return uri
        .replace(queryParameters: query.isEmpty ? null : query, fragment: '')
        .toString();
  }

  static String _cleanMarkup(Object? value) {
    return _oneLine(html_parser.parseFragment('${value ?? ''}').text ?? '');
  }

  static String _oneLine(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _normalizeTitle(String value) {
    var text = value
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\u3000]+'), '')
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fff]'), '');
    for (final suffix in ['最新消息', '权威发布', '全文', '快讯', '视频']) {
      text = text.replaceAll(suffix, '');
    }
    return text;
  }

  static bool _containsTerm(String text, String term) {
    if (RegExp(r'^[A-Za-z0-9_.+-]+$').hasMatch(term)) {
      return RegExp(
        '(?<![A-Za-z0-9])${RegExp.escape(term)}(?![A-Za-z0-9])',
        caseSensitive: false,
      ).hasMatch(text);
    }
    return text.toLowerCase().contains(term.toLowerCase());
  }

  void dispose() => _client.close();
}

class _NewsSourceRun {
  const _NewsSourceRun({
    required this.sourceName,
    required this.articles,
    this.error = '',
  });

  final String sourceName;
  final List<ExplorationNewsArticle> articles;
  final String error;
}

class _ExtractedNewsContent {
  const _ExtractedNewsContent({
    required this.text,
    required this.complete,
    required this.quality,
    required this.origin,
  });

  const _ExtractedNewsContent.empty()
    : text = '',
      complete = false,
      quality = 0,
      origin = 'none';

  final String text;
  final bool complete;
  final int quality;
  final String origin;
}

class _PageMetadata {
  const _PageMetadata({required this.title, required this.summary});

  final String title;
  final String summary;
}
