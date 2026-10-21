import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/features/exploration/services/exploration_ai_service.dart';
import 'package:syncnote/features/exploration/services/exploration_repository.dart';
import 'package:xml/xml.dart';

class LiteratureDiscoveryService {
  LiteratureDiscoveryService({
    http.Client? client,
    ExplorationAiService? ai,
    ExplorationStateStore? state,
  }) : _client = client ?? http.Client(),
       _ai = ai ?? ExplorationAiService(),
       _state = state ?? ExplorationStateStore.instance;

  static const _userAgent =
      'SyncNote-Literature/1.0 (personal research assistant)';

  final http.Client _client;
  final ExplorationAiService _ai;
  final ExplorationStateStore _state;

  Future<LiteratureDiscoveryReport> discover(
    String query, {
    int sourceLimit = 30,
    int candidateLimit = 30,
    int recommendationLimit = 8,
    int years = 10,
    bool force = false,
    DateTime? now,
    List<String> fallbackTerms = const [],
  }) async {
    final cleaned = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length < 2 || cleaned.length > 120) {
      throw ArgumentError('文献主题需要 2 到 120 个字符');
    }
    final today = now ?? DateTime.now();
    final cleanedFallback = fallbackTerms
        .map((value) => value.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .take(12)
        .toList();
    if (!force) {
      final cached = await _state.loadLiteratureReport(cleaned, today);
      if (cached != null &&
          cached.pipelineVersion >= 9 &&
          cached.query.fallbackTerms.join('\n') == cleanedFallback.join('\n')) {
        return cached;
      }
    }

    var expansionCost = 0.0;
    ExpandedLiteratureQuery expanded;
    try {
      final result = await _ai.expandLiteratureQuery(
        cleaned,
        fallbackTerms: cleanedFallback,
      );
      expansionCost = result.estimatedCostUsd;
      final data = result.data;
      final queries = <String>{
        cleaned,
        ...List<String>.from(
          data['strict_queries'] as List? ??
              data['search_queries'] as List? ??
              const [],
        ).map((value) => value.replaceAll(RegExp(r'\s+'), ' ').trim()),
      }.where((value) => value.isNotEmpty).take(3).toList();
      final conceptGroups =
          (data['required_concept_groups'] as List? ?? const [])
              .map(
                (group) => List<String>.from(group as List? ?? const [])
                    .map((value) => value.trim())
                    .where((value) => value.isNotEmpty)
                    .take(12)
                    .toList(),
              )
              .where((group) => group.isNotEmpty)
              .take(4)
              .toList();
      expanded = ExpandedLiteratureQuery(
        original: cleaned,
        searchQueries: queries.isEmpty ? [cleaned] : queries,
        preferredTerms: List<String>.from(
          data['preferred_terms'] as List? ?? const [],
        ).where((value) => value.trim().isNotEmpty).take(16).toList(),
        excludedTerms: List<String>.from(
          data['excluded_terms'] as List? ?? const [],
        ).where((value) => value.trim().isNotEmpty).take(12).toList(),
        fallbackTerms: cleanedFallback,
        requiredConceptGroups: conceptGroups,
        expansionQueries: List<String>.from(
          data['expansion_queries'] as List? ?? const [],
        ).where((value) => value.trim().isNotEmpty).take(2).toList(),
        intentSummary: '${data['intent_summary'] ?? cleaned}'.trim(),
      );
    } catch (_) {
      expanded = ExpandedLiteratureQuery(
        original: cleaned,
        searchQueries: [cleaned],
        preferredTerms: [cleaned],
        fallbackTerms: cleanedFallback,
        intentSummary: cleaned,
      );
    }

    final fromDate = DateTime(
      today.year - years.clamp(1, 10),
      today.month,
      today.day,
    );
    final strictRuns = await _runProviders(
      _sourceQueries(expanded),
      sourceLimit,
      fromDate,
    );
    final strictPapers = strictRuns.expand((item) => item.papers).toList();
    final strictRanked = _rankLocally(
      _mergePapers(strictPapers),
      expanded,
      today,
    );
    final expansionRuns =
        strictRanked.length < recommendationLimit &&
            expanded.expansionQueries.isNotEmpty
        ? await _runProviders(
            expanded.expansionQueries,
            math.min(16, sourceLimit),
            fromDate,
            tier: 'expanded',
            nameSuffix: '·拓展',
          )
        : const <_SourceRun>[];
    final foundationalRun = await _runSource(
      'openalex_foundational',
      'OpenAlex·奠基文献',
      [_providerSafeQuery(expanded.searchQueries.first)],
      (value) => _searchOpenAlex(
        value,
        math.min(12, sourceLimit),
        fromDate,
        foundational: true,
      ),
    );
    final foundationalPapers = foundationalRun.papers
        .map((paper) => paper.copyWith(discoveryTier: 'foundational'))
        .toList();
    final sourceRuns = [...strictRuns, ...expansionRuns, foundationalRun];
    final allPapers = [
      ...strictPapers,
      ...expansionRuns.expand((item) => item.papers),
      ...foundationalPapers,
    ];
    final statuses = sourceRuns.map((item) => item.status).toList();
    final locallyRanked = _rankLocally(
      _mergePapers(allPapers),
      expanded,
      today,
    );
    final directQuota = math.max(1, candidateLimit - 8);
    final candidates = <LiteraturePaper>[
      ...locallyRanked
          .where((paper) => paper.discoveryTier == 'direct')
          .take(directQuota),
      ...locallyRanked
          .where((paper) => paper.discoveryTier == 'foundational')
          .take(5),
      ...locallyRanked
          .where((paper) => paper.discoveryTier == 'expanded')
          .take(3),
    ].take(candidateLimit).toList();

    if (candidates.isEmpty) {
      return LiteratureDiscoveryReport(
        query: expanded,
        candidates: const [],
        recommendations: const [],
        sourceStatuses: statuses,
        usedAi: expansionCost > 0,
        estimatedCostUsd: expansionCost,
      );
    }

    LiteratureDiscoveryReport report;
    try {
      final aiResult = await _ai.rankLiterature(
        expanded,
        candidates,
        limit: recommendationLimit,
      );
      final byId = {for (final paper in candidates) paper.id: paper};
      final recommendations = <LiteratureRecommendation>[];
      final seen = <String>{};
      final rawRecommendations =
          aiResult.data['recommendations'] as List? ?? const [];
      for (final raw in rawRecommendations) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = '${row['paper_id'] ?? ''}';
        final paper = byId[id];
        final relevance = (row['relevance_score'] as num?)?.toDouble() ?? 0;
        final primarySubjectEvidence =
            '${row['primary_subject_evidence'] ?? ''}'
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
        final primarySubjectVerified =
            paper != null &&
            row['primary_subject_matches'] == true &&
            _containsVerifiedQuote(paper.title, primarySubjectEvidence);
        final researchProblemEvidence =
            '${row['research_problem_evidence'] ?? ''}'
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
        final researchProblemVerified =
            paper != null &&
            row['research_problem_matches'] == true &&
            _containsVerifiedQuote(
              '${paper.title} ${paper.abstractText}',
              researchProblemEvidence,
            );
        final conceptEvidence = paper == null
            ? (matched: const <String>[], missing: const <String>[])
            : _verifiedConceptEvidence(paper, expanded, row);
        final requestedTier = '${row['match_tier'] ?? ''}';
        final semanticBoundaryVerified = _semanticBoundaryVerified(
          requestedTier: requestedTier,
          primarySubjectVerified: primarySubjectVerified,
          researchProblemVerified: researchProblemVerified,
        );
        final matchTier =
            conceptEvidence.missing.isNotEmpty || requestedTier == 'expanded'
            ? 'expanded'
            : (requestedTier == 'foundational' &&
                      paper?.discoveryTier == 'foundational'
                  ? 'foundational'
                  : 'high_relevance');
        final normalizedRelevance = matchTier == 'expanded'
            ? math.min(relevance, 84).toDouble()
            : relevance;
        final minimumRelevance = matchTier == 'expanded' ? 65 : 75;
        if (paper == null ||
            !semanticBoundaryVerified ||
            normalizedRelevance < minimumRelevance ||
            !seen.add(id)) {
          continue;
        }
        recommendations.add(
          LiteratureRecommendation(
            paper: paper,
            rank: recommendations.length + 1,
            relevanceScore: normalizedRelevance,
            qualityScore: (row['quality_score'] as num?)?.toDouble() ?? 0,
            freshnessScore: (row['freshness_score'] as num?)?.toDouble() ?? 0,
            overallScore: (row['overall_score'] as num?)?.toDouble() ?? 0,
            coreSummary: '${row['core_summary'] ?? ''}'.trim(),
            researchQuestion: '${row['research_question'] ?? ''}'.trim(),
            method: '${row['method'] ?? ''}'.trim(),
            keyFindings: List<String>.from(
              row['key_findings'] as List? ?? const [],
            ),
            limitations: List<String>.from(
              row['limitations'] as List? ?? const [],
            ),
            recommendationReason: '${row['recommendation_reason'] ?? ''}'
                .trim(),
            worthDeepReading: row['worth_deep_reading'] == true,
            model: aiResult.model,
            matchTier: matchTier,
            // The visible match evidence is recomputed from the actual title,
            // abstract and keywords. It is never accepted on the model's word.
            matchedConcepts: conceptEvidence.matched,
            missingConcepts: conceptEvidence.missing,
          ),
        );
        if (recommendations.length >= recommendationLimit) break;
      }
      report = LiteratureDiscoveryReport(
        query: expanded,
        candidates: candidates,
        recommendations: recommendations,
        sourceStatuses: [
          ...statuses,
          LiteratureSourceStatus(
            sourceId: 'deepseek_rank',
            sourceName: 'DeepSeek Flash·严格复核',
            success: true,
            paperCount: recommendations.length,
            error: recommendations.isEmpty
                ? '模型返回 ${rawRecommendations.length} 篇，证据核验后没有保留结果'
                : rawRecommendations.length > recommendations.length
                ? '模型返回 ${rawRecommendations.length} 篇，证据核验后保留 ${recommendations.length} 篇'
                : '',
          ),
        ],
        usedAi: true,
        estimatedCostUsd: expansionCost + aiResult.estimatedCostUsd,
      );
    } catch (error) {
      final fallback = _fallbackRecommendations(
        candidates,
        expanded,
        recommendationLimit,
      );
      report = LiteratureDiscoveryReport(
        query: expanded,
        candidates: candidates,
        recommendations: fallback,
        sourceStatuses: [
          ...statuses,
          LiteratureSourceStatus(
            sourceId: 'deepseek_rank',
            sourceName: 'DeepSeek Flash·严格复核',
            success: false,
            paperCount: fallback.length,
            error: '$error',
          ),
        ],
        usedAi: expansionCost > 0,
        estimatedCostUsd: expansionCost,
      );
    }
    await _state.saveLiteratureReport(report, today);
    return report;
  }

  Future<_SourceRun> _runSource(
    String sourceId,
    String sourceName,
    List<String> queries,
    Future<List<LiteraturePaper>> Function(String query) search, {
    Duration throttle = Duration.zero,
  }) async {
    final papers = <LiteraturePaper>[];
    final errors = <String>[];
    for (var index = 0; index < queries.length; index++) {
      if (index > 0 && throttle > Duration.zero) {
        await Future<void>.delayed(throttle);
      }
      final query = queries[index];
      try {
        papers.addAll(await search(query));
      } catch (error) {
        errors.add('$error');
      }
    }
    return _SourceRun(
      papers: papers,
      status: LiteratureSourceStatus(
        sourceId: sourceId,
        sourceName: sourceName,
        success: papers.isNotEmpty,
        paperCount: papers.length,
        error: errors.join('；'),
      ),
    );
  }

  Future<List<_SourceRun>> _runProviders(
    List<String> queries,
    int sourceLimit,
    DateTime fromDate, {
    String tier = 'direct',
    String nameSuffix = '',
  }) async {
    final providerQueries = queries
        .map(_providerSafeQuery)
        .where((value) => value.isNotEmpty)
        .toSet()
        .take(3)
        .toList();
    final runs = await Future.wait([
      _runSource(
        'openalex${tier == 'direct' ? '' : '_$tier'}',
        'OpenAlex$nameSuffix',
        providerQueries,
        (value) => _searchOpenAlex(value, sourceLimit, fromDate),
      ),
      _runSource(
        'semantic_scholar${tier == 'direct' ? '' : '_$tier'}',
        'Semantic Scholar$nameSuffix',
        providerQueries,
        (value) => _searchSemanticScholar(value, sourceLimit, fromDate),
        throttle: const Duration(milliseconds: 1100),
      ),
      _runSource(
        'crossref${tier == 'direct' ? '' : '_$tier'}',
        'Crossref$nameSuffix',
        providerQueries,
        (value) => _searchCrossref(value, sourceLimit, fromDate),
      ),
      _runSource(
        'arxiv${tier == 'direct' ? '' : '_$tier'}',
        'arXiv$nameSuffix',
        providerQueries,
        (value) => _searchArxiv(value, sourceLimit, fromDate),
        throttle: const Duration(seconds: 3),
      ),
      _runSource(
        'europe_pmc${tier == 'direct' ? '' : '_$tier'}',
        'Europe PMC$nameSuffix',
        providerQueries,
        (value) => _searchEuropePmc(value, sourceLimit, fromDate),
        throttle: const Duration(milliseconds: 350),
      ),
    ]);
    if (tier == 'direct') return runs;
    return runs
        .map(
          (run) => _SourceRun(
            papers: run.papers
                .map((paper) => paper.copyWith(discoveryTier: tier))
                .toList(),
            status: run.status,
          ),
        )
        .toList();
  }

  Future<List<LiteraturePaper>> _searchOpenAlex(
    String query,
    int limit,
    DateTime fromDate, {
    bool foundational = false,
  }) async {
    final parameters = <String, String>{
      'search': query,
      'per_page': '${limit.clamp(1, 100)}',
    };
    if (foundational) {
      parameters['sort'] = 'cited_by_count:desc';
    } else {
      parameters['filter'] = 'from_publication_date:${_date(fromDate)}';
    }
    final uri = Uri.https('api.openalex.org', '/works', parameters);
    final data = await _getJson(uri);
    final papers = <LiteraturePaper>[];
    for (final raw in data['results'] as List? ?? const []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final title = _clean(item['title']);
      final abstractText = _openAlexAbstract(
        item['abstract_inverted_index'] as Map?,
      );
      if (title.isEmpty || abstractText.isEmpty) continue;
      final bestOa = Map<String, dynamic>.from(
        item['best_oa_location'] as Map? ?? const {},
      );
      final primary = Map<String, dynamic>.from(
        item['primary_location'] as Map? ?? const {},
      );
      final openAccess = Map<String, dynamic>.from(
        item['open_access'] as Map? ?? const {},
      );
      final source = Map<String, dynamic>.from(
        primary['source'] as Map? ?? const {},
      );
      final providerId = '${item['id'] ?? ''}'.split('/').last;
      final pdfUrl = '${bestOa['pdf_url'] ?? primary['pdf_url'] ?? ''}'.trim();
      papers.add(
        LiteraturePaper(
          id: 'openalex_$providerId',
          title: title,
          abstractText: abstractText,
          authors: (item['authorships'] as List? ?? const [])
              .map((row) {
                final author = Map<String, dynamic>.from(
                  Map<String, dynamic>.from(row as Map)['author'] as Map? ??
                      const {},
                );
                return _clean(author['display_name']);
              })
              .where((value) => value.isNotEmpty)
              .toList(),
          publishedOn: DateTime.tryParse('${item['publication_date'] ?? ''}'),
          venue: _clean(source['display_name']),
          doi: normalizeDoi('${item['doi'] ?? ''}'),
          url:
              '${bestOa['landing_page_url'] ?? primary['landing_page_url'] ?? item['doi'] ?? ''}',
          pdfUrl: pdfUrl,
          keywords: (item['topics'] as List? ?? const [])
              .take(10)
              .map(
                (row) => _clean(
                  Map<String, dynamic>.from(row as Map)['display_name'],
                ),
              )
              .where((value) => value.isNotEmpty)
              .toList(),
          citationCount: (item['cited_by_count'] as num?)?.toInt() ?? 0,
          sourceNames: const ['OpenAlex'],
          isOpenAccess: openAccess['is_oa'] == true || pdfUrl.isNotEmpty,
          openAlexId: providerId,
          referenceCount:
              (item['referenced_works_count'] as num?)?.toInt() ?? 0,
          publicationType: _clean(item['type']),
          openAccessStatus: _clean(openAccess['oa_status']),
          isRetracted: item['is_retracted'] == true,
        ),
      );
    }
    return papers;
  }

  Future<List<LiteraturePaper>> _searchSemanticScholar(
    String query,
    int limit,
    DateTime fromDate,
  ) async {
    final uri = Uri.https('api.semanticscholar.org', '/graph/v1/paper/search', {
      'query': query,
      'limit': '${limit.clamp(1, 100)}',
      'year': '${fromDate.year}-',
      'fields':
          'title,abstract,authors,publicationDate,venue,externalIds,url,'
          'citationCount,influentialCitationCount,referenceCount,'
          'openAccessPdf,isOpenAccess,fieldsOfStudy,publicationTypes',
    });
    final data = await _getJson(uri);
    final papers = <LiteraturePaper>[];
    for (final raw in data['data'] as List? ?? const []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final title = _clean(item['title']);
      final abstractText = _clean(item['abstract']);
      if (title.isEmpty || abstractText.isEmpty) continue;
      final external = Map<String, dynamic>.from(
        item['externalIds'] as Map? ?? const {},
      );
      final openPdf = Map<String, dynamic>.from(
        item['openAccessPdf'] as Map? ?? const {},
      );
      final providerId = '${item['paperId'] ?? _stableId('s2', title)}';
      papers.add(
        LiteraturePaper(
          id: 's2_$providerId',
          title: title,
          abstractText: abstractText,
          authors: (item['authors'] as List? ?? const [])
              .map(
                (row) => _clean(Map<String, dynamic>.from(row as Map)['name']),
              )
              .where((value) => value.isNotEmpty)
              .toList(),
          publishedOn: DateTime.tryParse('${item['publicationDate'] ?? ''}'),
          venue: _clean(item['venue']),
          doi: normalizeDoi('${external['DOI'] ?? ''}'),
          url: '${item['url'] ?? ''}',
          pdfUrl: '${openPdf['url'] ?? ''}',
          keywords: List<String>.from(
            item['fieldsOfStudy'] as List? ?? const [],
          ),
          citationCount: (item['citationCount'] as num?)?.toInt() ?? 0,
          sourceNames: const ['Semantic Scholar'],
          isOpenAccess:
              item['isOpenAccess'] == true ||
              '${openPdf['url'] ?? ''}'.isNotEmpty,
          arxivId: '${external['ArXiv'] ?? ''}',
          semanticScholarId: providerId,
          referenceCount: (item['referenceCount'] as num?)?.toInt() ?? 0,
          influentialCitationCount:
              (item['influentialCitationCount'] as num?)?.toInt() ?? 0,
          publicationType: (item['publicationTypes'] as List? ?? const [])
              .map(_clean)
              .where((value) => value.isNotEmpty)
              .join(' / '),
          openAccessStatus: _clean(openPdf['status']),
        ),
      );
    }
    return papers;
  }

  Future<List<LiteraturePaper>> _searchCrossref(
    String query,
    int limit,
    DateTime fromDate,
  ) async {
    final uri = Uri.https('api.crossref.org', '/works', {
      'query.bibliographic': query,
      'filter': 'from-pub-date:${_date(fromDate)},type:journal-article',
      'sort': 'relevance',
      'order': 'desc',
      'rows': '${limit.clamp(1, 50)}',
      'select':
          'DOI,title,author,published-online,published-print,published,'
          'issued,abstract,URL,container-title,subject,link,'
          'is-referenced-by-count,license',
    });
    final data = await _getJson(uri);
    final message = Map<String, dynamic>.from(
      data['message'] as Map? ?? const {},
    );
    final papers = <LiteraturePaper>[];
    for (final raw in message['items'] as List? ?? const []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final titles = item['title'] as List? ?? const [];
      final title = _clean(titles.isEmpty ? '' : titles.first);
      final abstractText = _clean(item['abstract']);
      if (title.isEmpty || abstractText.isEmpty) continue;
      final doi = normalizeDoi('${item['DOI'] ?? ''}');
      final links = item['link'] as List? ?? const [];
      final pdfUrl = links
          .map((row) => Map<String, dynamic>.from(row as Map))
          .where(
            (row) =>
                '${row['content-type'] ?? ''}'.toLowerCase().contains('pdf'),
          )
          .map((row) => '${row['URL'] ?? ''}')
          .firstOrNull;
      final containers = item['container-title'] as List? ?? const [];
      papers.add(
        LiteraturePaper(
          id: _stableId('crossref', doi.isEmpty ? title : doi),
          title: title,
          abstractText: abstractText,
          authors: (item['author'] as List? ?? const [])
              .map((row) {
                final author = Map<String, dynamic>.from(row as Map);
                return '${author['given'] ?? ''} ${author['family'] ?? ''}'
                    .trim();
              })
              .where((value) => value.isNotEmpty)
              .toList(),
          publishedOn: _crossrefDate(item),
          venue: _clean(containers.isEmpty ? '' : containers.first),
          doi: doi,
          url: '${item['URL'] ?? ''}',
          pdfUrl: pdfUrl ?? '',
          keywords: (item['subject'] as List? ?? const [])
              .map(_clean)
              .where((value) => value.isNotEmpty)
              .toList(),
          citationCount: (item['is-referenced-by-count'] as num?)?.toInt() ?? 0,
          sourceNames: const ['Crossref'],
          isOpenAccess:
              (pdfUrl ?? '').isNotEmpty ||
              (item['license'] as List? ?? const []).isNotEmpty,
          publicationType: 'journal-article',
          openAccessStatus: (item['license'] as List? ?? const []).isNotEmpty
              ? 'licensed'
              : '',
        ),
      );
    }
    return papers;
  }

  Future<List<LiteraturePaper>> _searchArxiv(
    String query,
    int limit,
    DateTime fromDate,
  ) async {
    final uri = Uri.https('export.arxiv.org', '/api/query', {
      'search_query': 'all:"$query"',
      'start': '0',
      'max_results': '${limit.clamp(1, 50)}',
      'sortBy': 'relevance',
      'sortOrder': 'descending',
    });
    final response = await _client
        .get(uri, headers: const {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('arXiv ${response.statusCode}');
    }
    final document = XmlDocument.parse(utf8.decode(response.bodyBytes));
    final papers = <LiteraturePaper>[];
    for (final entry in document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'entry',
    )) {
      String childText(String name) =>
          entry.children
              .whereType<XmlElement>()
              .where((element) => element.name.local == name)
              .map((element) => element.innerText)
              .firstOrNull ??
          '';
      final title = _clean(childText('title'));
      final abstractText = _clean(childText('summary'));
      final published = DateTime.tryParse(childText('published'));
      if (title.isEmpty ||
          abstractText.isEmpty ||
          (published != null && published.isBefore(fromDate))) {
        continue;
      }
      final entryUrl = childText('id');
      final arxivId = entryUrl.replaceAll(RegExp(r'/$'), '').split('/').last;
      final links = entry.children.whereType<XmlElement>().where(
        (element) => element.name.local == 'link',
      );
      final pdfUrl =
          links
              .where(
                (element) =>
                    element.getAttribute('title') == 'pdf' ||
                    element.getAttribute('type') == 'application/pdf',
              )
              .map((element) => element.getAttribute('href') ?? '')
              .firstOrNull ??
          'https://arxiv.org/pdf/$arxivId';
      papers.add(
        LiteraturePaper(
          id: 'arxiv_$arxivId',
          title: title,
          abstractText: abstractText,
          authors: entry.children
              .whereType<XmlElement>()
              .where((element) => element.name.local == 'author')
              .expand(
                (author) => author.children.whereType<XmlElement>().where(
                  (element) => element.name.local == 'name',
                ),
              )
              .map((element) => _clean(element.innerText))
              .where((value) => value.isNotEmpty)
              .toList(),
          publishedOn: published,
          venue: 'arXiv',
          url: entryUrl,
          pdfUrl: pdfUrl,
          keywords: entry.children
              .whereType<XmlElement>()
              .where((element) => element.name.local == 'category')
              .map((element) => element.getAttribute('term') ?? '')
              .where((value) => value.isNotEmpty)
              .toList(),
          sourceNames: const ['arXiv'],
          isOpenAccess: true,
          arxivId: arxivId,
          publicationType: 'preprint',
          openAccessStatus: 'green',
        ),
      );
    }
    return papers;
  }

  Future<List<LiteraturePaper>> _searchEuropePmc(
    String query,
    int limit,
    DateTime fromDate,
  ) async {
    final uri =
        Uri.https('www.ebi.ac.uk', '/europepmc/webservices/rest/search', {
          'query': query,
          'format': 'json',
          'resultType': 'core',
          'pageSize': '${limit.clamp(1, 50)}',
        });
    final data = await _getJson(uri);
    final resultList = Map<String, dynamic>.from(
      data['resultList'] as Map? ?? const {},
    );
    final papers = <LiteraturePaper>[];
    for (final raw in resultList['result'] as List? ?? const []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final title = _clean(item['title']);
      final abstractText = _clean(item['abstractText']);
      final published = DateTime.tryParse(
        '${item['firstPublicationDate'] ?? item['firstIndexDate'] ?? ''}',
      );
      if (title.isEmpty ||
          abstractText.isEmpty ||
          (published != null && published.isBefore(fromDate))) {
        continue;
      }
      final source = '${item['source'] ?? 'MED'}';
      final providerId = '${item['id'] ?? item['pmid'] ?? ''}';
      final fullTextList = Map<String, dynamic>.from(
        item['fullTextUrlList'] as Map? ?? const {},
      );
      final fullTextRows = (fullTextList['fullTextUrl'] as List? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      final pdfUrl = fullTextRows
          .where(
            (row) =>
                '${row['documentStyle'] ?? ''}'.toLowerCase() == 'pdf' &&
                '${row['url'] ?? ''}'.startsWith('https://'),
          )
          .map((row) => '${row['url'] ?? ''}')
          .firstOrNull;
      final keywordList = Map<String, dynamic>.from(
        item['keywordList'] as Map? ?? const {},
      );
      final pubTypes = Map<String, dynamic>.from(
        item['pubTypeList'] as Map? ?? const {},
      );
      papers.add(
        LiteraturePaper(
          id: _stableId('epmc', '$source:$providerId'),
          title: title,
          abstractText: abstractText,
          authors: '${item['authorString'] ?? ''}'
              .split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(),
          publishedOn: published,
          venue: _clean(item['journalTitle']),
          doi: normalizeDoi('${item['doi'] ?? ''}'),
          url: 'https://europepmc.org/article/$source/$providerId',
          pdfUrl: pdfUrl ?? '',
          keywords: (keywordList['keyword'] as List? ?? const [])
              .map(_clean)
              .where((value) => value.isNotEmpty)
              .take(16)
              .toList(),
          citationCount: (item['citedByCount'] as num?)?.toInt() ?? 0,
          sourceNames: const ['Europe PMC'],
          isOpenAccess: item['isOpenAccess'] == 'Y' || pdfUrl != null,
          publicationType: (pubTypes['pubType'] as List? ?? const [])
              .map(_clean)
              .where((value) => value.isNotEmpty)
              .join(' / '),
          openAccessStatus: item['isOpenAccess'] == 'Y' ? 'open' : '',
        ),
      );
    }
    return papers;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    http.Response? response;
    for (var attempt = 0; attempt < 2; attempt++) {
      response = await _client
          .get(uri, headers: const {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 429 || attempt > 0) break;
      final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
      await Future<void>.delayed(
        Duration(seconds: (retryAfter ?? 2).clamp(1, 8)),
      );
    }
    if (response!.statusCode != 200) {
      throw StateError('${uri.host} ${response.statusCode}');
    }
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map,
    );
  }

  static List<LiteraturePaper> _mergePapers(List<LiteraturePaper> papers) {
    final merged = <String, LiteraturePaper>{};
    for (final paper in papers) {
      final current = merged[paper.canonicalKey];
      if (current == null) {
        merged[paper.canonicalKey] = paper;
        continue;
      }
      final better = paper.abstractText.length > current.abstractText.length
          ? paper
          : current;
      final other = identical(better, paper) ? current : paper;
      merged[paper.canonicalKey] = better.copyWith(
        id: current.id,
        authors: better.authors.isEmpty ? other.authors : better.authors,
        publishedOn: better.publishedOn ?? other.publishedOn,
        venue: better.venue.isEmpty ? other.venue : better.venue,
        doi: better.doi.isEmpty ? other.doi : better.doi,
        url: better.url.isEmpty ? other.url : better.url,
        pdfUrl: better.pdfUrl.isEmpty ? other.pdfUrl : better.pdfUrl,
        keywords: {...better.keywords, ...other.keywords}.toList(),
        citationCount: math.max(better.citationCount, other.citationCount),
        sourceNames: {...better.sourceNames, ...other.sourceNames}.toList()
          ..sort(),
        isOpenAccess: better.isOpenAccess || other.isOpenAccess,
        arxivId: better.arxivId.isEmpty ? other.arxivId : better.arxivId,
        openAlexId: better.openAlexId.isEmpty
            ? other.openAlexId
            : better.openAlexId,
        semanticScholarId: better.semanticScholarId.isEmpty
            ? other.semanticScholarId
            : better.semanticScholarId,
        referenceCount: math.max(better.referenceCount, other.referenceCount),
        influentialCitationCount: math.max(
          better.influentialCitationCount,
          other.influentialCitationCount,
        ),
        publicationType: better.publicationType.isEmpty
            ? other.publicationType
            : better.publicationType,
        openAccessStatus: better.openAccessStatus.isEmpty
            ? other.openAccessStatus
            : better.openAccessStatus,
        isRetracted: better.isRetracted || other.isRetracted,
        discoveryTier:
            _tierPriority(better.discoveryTier) <=
                _tierPriority(other.discoveryTier)
            ? better.discoveryTier
            : other.discoveryTier,
      );
    }
    return merged.values.toList();
  }

  static List<LiteraturePaper> _rankLocally(
    List<LiteraturePaper> papers,
    ExpandedLiteratureQuery query,
    DateTime today,
  ) {
    final queryTerms = _terms(
      [
        query.original,
        ...query.searchQueries,
        ...query.preferredTerms,
      ].join(' '),
    );
    final meaningfulQueryTerms = _meaningfulTerms(queryTerms);
    final excludedPhrases = query.excludedTerms
        .map(
          (value) => value
              .replaceAll(RegExp(r'''^[\s"']+|[\s"']+$'''), '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim()
              .toLowerCase(),
        )
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final anchors = _specificPhrases(query).map((item) => item.toLowerCase());
    final ranked = <LiteraturePaper>[];
    for (final paper in papers) {
      if (paper.isRetracted) continue;
      final titleTerms = _terms(paper.title);
      final bodyTerms = _terms(
        '${paper.abstractText} ${paper.keywords.join(' ')}',
      );
      final searchableText =
          '${paper.title} ${paper.abstractText} ${paper.keywords.join(' ')}'
              .toLowerCase()
              .replaceAll(RegExp(r'\s+'), ' ');
      final searchableTerms = {...titleTerms, ...bodyTerms};
      // Exclusions describe unwanted concepts (for example "医疗废物"), not
      // individual words.  Token intersection was far too broad: an excluded
      // phrase sharing only "废物" with the user's "核废物处理" query removed
      // every otherwise relevant provider result.
      if (excludedPhrases.any(
        (phrase) => _phraseMatches(phrase, searchableText, searchableTerms),
      )) {
        continue;
      }
      final conceptGroups = query.requiredConceptGroups
          .where((group) => group.isNotEmpty)
          .toList();
      final evidence = _conceptEvidenceFromText(
        searchableText,
        searchableTerms,
        conceptGroups,
      );
      final matchedConceptGroups = evidence.matched.length;
      final coreMatched =
          conceptGroups.isEmpty ||
          _conceptGroupMatch(
                conceptGroups.first,
                searchableText,
                searchableTerms,
              ) !=
              null;
      final meaningfulHits = meaningfulQueryTerms
          .intersection(searchableTerms)
          .length;
      // Retrieval must preserve recall. Exact aliases improve local ranking,
      // but are not admission tickets: papers using another scholarly phrase
      // still reach the semantic AI review when they share substantive query
      // terms. Hard subject/problem decisions happen only after AI supplies
      // source-verifiable evidence.
      if (!coreMatched && matchedConceptGroups == 0 && meaningfulHits < 2) {
        continue;
      }
      final conceptCoverage = conceptGroups.isEmpty
          ? 1.0
          : matchedConceptGroups / conceptGroups.length;
      final anchorHits = anchors
          .where(
            (phrase) => _phraseMatches(phrase, searchableText, searchableTerms),
          )
          .length;
      if (anchors.isNotEmpty && anchorHits == 0 && meaningfulHits < 2) {
        continue;
      }
      final titleOverlap =
          queryTerms.intersection(titleTerms).length /
          math.max(1, queryTerms.length);
      final bodyOverlap =
          queryTerms.intersection(bodyTerms).length /
          math.max(1, queryTerms.length);
      if (titleOverlap == 0 && bodyOverlap == 0) continue;
      final freshness = paper.publishedOn == null
          ? 0.2
          : math
                .pow(
                  0.5,
                  math.max(0, today.difference(paper.publishedOn!).inDays) /
                      365,
                )
                .toDouble();
      final citations = math
          .min(
            1,
            math.log(math.max(0, paper.citationCount) + 1) / math.log(501),
          )
          .toDouble();
      final score =
          conceptCoverage * 0.48 +
          titleOverlap * 0.24 +
          bodyOverlap * 0.12 +
          freshness * 0.06 +
          citations * 0.04 +
          (paper.isOpenAccess ? 0.02 : 0) +
          math.min(0.02, math.max(0, paper.sourceNames.length - 1) * 0.01) +
          math.min(0.04, anchorHits * 0.02) -
          (paper.discoveryTier == 'expanded' ? 0.18 : 0);
      ranked.add(paper.copyWith(localScore: score * 100));
    }
    ranked.sort((a, b) {
      final byScore = b.localScore.compareTo(a.localScore);
      if (byScore != 0) return byScore;
      return (b.publishedOn ?? DateTime(1900)).compareTo(
        a.publishedOn ?? DateTime(1900),
      );
    });
    return ranked;
  }

  static List<LiteratureRecommendation> _fallbackRecommendations(
    List<LiteraturePaper> candidates,
    ExpandedLiteratureQuery query,
    int limit,
  ) {
    final verified = candidates
        .where((paper) {
          return _conceptEvidence(paper, query).missing.isEmpty;
        })
        .take(limit);
    return verified.indexed.map((entry) {
      final (index, paper) = entry;
      final evidence = _conceptEvidence(paper, query);
      final summary = paper.abstractText.length > 420
          ? '${paper.abstractText.substring(0, 420)}…'
          : paper.abstractText;
      return LiteratureRecommendation(
        paper: paper,
        rank: index + 1,
        relevanceScore: math.min(paper.localScore, 84).toDouble(),
        qualityScore: 0,
        freshnessScore: 0,
        overallScore: paper.localScore,
        coreSummary: summary,
        recommendationReason: 'AI 暂时不可用；这是按标题、摘要、时效性和开放获取状态排列的待复核候选。',
        matchTier: 'expanded',
        matchedConcepts: evidence.matched,
        missingConcepts: evidence.missing,
      );
    }).toList();
  }

  static ({List<String> matched, List<String> missing}) _conceptEvidence(
    LiteraturePaper paper,
    ExpandedLiteratureQuery query,
  ) {
    final titleText = paper.title.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final searchableText =
        '${paper.title} ${paper.abstractText} ${paper.keywords.join(' ')}'
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ');
    final groups = query.requiredConceptGroups
        .where((group) => group.isNotEmpty)
        .toList();
    final matched = <String>[];
    final missing = <String>[];
    for (var index = 0; index < groups.length; index++) {
      final evidenceText = index == 0 ? titleText : searchableText;
      final hit = _conceptGroupMatch(
        groups[index],
        evidenceText,
        _terms(evidenceText),
      );
      if (hit == null) {
        missing.add(groups[index].take(3).join(' / '));
      } else {
        matched.add(hit);
      }
    }
    return (matched: matched, missing: missing);
  }

  static ({List<String> matched, List<String> missing})
  _verifiedConceptEvidence(
    LiteraturePaper paper,
    ExpandedLiteratureQuery query,
    Map<String, dynamic> aiRow,
  ) {
    final searchableText =
        '${paper.title} ${paper.abstractText} ${paper.keywords.join(' ')}'
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), ' ');
    final titleText = paper.title.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final groups = query.requiredConceptGroups
        .where((group) => group.isNotEmpty)
        .toList();
    final rawEvidence = (aiRow['concept_evidence'] as List? ?? const [])
        .map((value) => Map<String, dynamic>.from(value as Map? ?? const {}))
        .toList();
    final matched = <String>[];
    final missing = <String>[];
    for (var index = 0; index < groups.length; index++) {
      final evidenceText = index == 0 ? titleText : searchableText;
      final row = rawEvidence.where((item) {
        return (item['group_index'] as num?)?.toInt() == index;
      }).firstOrNull;
      final quote = '${row?['evidence_quote'] ?? ''}'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final normalizedQuote = quote
          .replaceAll(RegExp(r'''^[\s"'“”‘’…]+|[\s"'“”‘’…]+$'''), '')
          .toLowerCase();
      if (row?['covered'] == true &&
          normalizedQuote.length >= 4 &&
          normalizedQuote.length <= 120 &&
          evidenceText.contains(normalizedQuote)) {
        matched.add(quote);
      } else {
        missing.add(groups[index].take(3).join(' / '));
      }
    }
    return (matched: matched, missing: missing);
  }

  static bool _containsVerifiedQuote(String source, String quote) {
    final normalizedQuote = quote
        .replaceAll(RegExp(r'''^[\s"'“”‘’…]+|[\s"'“”‘’…]+$'''), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
    if (normalizedQuote.length < 4 || normalizedQuote.length > 160) {
      return false;
    }
    final normalizedSource = source
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();
    return normalizedSource.contains(normalizedQuote);
  }

  static bool _semanticBoundaryVerified({
    required String requestedTier,
    required bool primarySubjectVerified,
    required bool researchProblemVerified,
  }) {
    final relatedReading =
        requestedTier == 'expanded' || requestedTier == 'foundational';
    return relatedReading
        ? primarySubjectVerified || researchProblemVerified
        : primarySubjectVerified && researchProblemVerified;
  }

  static ({List<String> matched, List<String> missing})
  _conceptEvidenceFromText(
    String searchableText,
    Set<String> searchableTerms,
    List<List<String>> conceptGroups,
  ) {
    final matched = <String>[];
    final missing = <String>[];
    for (final group in conceptGroups) {
      final hit = _conceptGroupMatch(group, searchableText, searchableTerms);
      if (hit == null) {
        missing.add(group.take(3).join(' / '));
      } else {
        matched.add(hit);
      }
    }
    return (matched: matched, missing: missing);
  }

  static String? _conceptGroupMatch(
    List<String> group,
    String searchableText,
    Set<String> searchableTerms,
  ) {
    for (final concept in group) {
      final normalized = concept.trim().toLowerCase();
      if (normalized.isNotEmpty &&
          (_phraseMatches(normalized, searchableText, searchableTerms) ||
              searchableText.contains(normalized))) {
        return concept;
      }
    }
    return null;
  }

  static List<String> _sourceQueries(ExpandedLiteratureQuery query) {
    return <String>{
      query.original,
      ...query.searchQueries,
    }.where((value) => value.trim().isNotEmpty).take(3).toList();
  }

  static String _providerSafeQuery(String value) {
    return value
        .replaceAll(RegExp(r'\b(?:AND|OR|NOT)\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'[()\[\]{}|+"]'), ' ')
        // Semantic Scholar's relevance endpoint explicitly does not support
        // special query syntax and rejects hyphenated terms as matches.
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static List<String> _specificPhrases(ExpandedLiteratureQuery query) {
    const generic = {
      '研究',
      '技术',
      '方法',
      '处理',
      '处置',
      '管理',
      'research',
      'technology',
      'method',
      'treatment',
      'disposal',
      'management',
    };
    final raw = <String>[
      query.original,
      ...query.preferredTerms,
      ...query.searchQueries.expand(
        (value) => value.split(RegExp(r'\s+OR\s+|\|', caseSensitive: false)),
      ),
    ];
    return raw
        .map(
          (value) => value
              .replaceAll(RegExp(r'''^[\s"']+|[\s"']+$'''), '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
        )
        .where((value) {
          if (value.isEmpty || generic.contains(value.toLowerCase())) {
            return false;
          }
          final chineseLength = RegExp(
            r'[\u4e00-\u9fff]',
          ).allMatches(value).length;
          final latinWords = RegExp(
            r'[A-Za-z][A-Za-z0-9-]+',
          ).allMatches(value).length;
          return chineseLength >= 3 || latinWords >= 2;
        })
        .toSet()
        .take(12)
        .toList();
  }

  static bool _phraseMatches(
    String phrase,
    String searchableText,
    Set<String> searchableTerms,
  ) {
    const genericEnglish = {
      'research',
      'technology',
      'method',
      'treatment',
      'disposal',
      'management',
    };
    final latinWords = RegExp(r'[A-Za-z][A-Za-z0-9-]+')
        .allMatches(phrase)
        .map((match) => match.group(0)!.toLowerCase())
        .where((value) => !genericEnglish.contains(value))
        .toSet();
    if (latinWords.length >= 2) {
      return searchableTerms.containsAll(latinWords);
    }
    if (latinWords.length == 1) {
      return searchableTerms.contains(latinWords.first);
    }
    final chinese = RegExp(
      r'[\u4e00-\u9fff]',
    ).allMatches(phrase).map((match) => match.group(0)).join();
    if (chinese.length >= 3) {
      if (searchableText.contains(chinese)) return true;
      final bigrams = {
        for (var index = 0; index < chinese.length - 1; index++)
          chinese.substring(index, index + 2),
      };
      return bigrams.isNotEmpty &&
          bigrams.intersection(searchableTerms).length / bigrams.length >= 0.67;
    }
    return false;
  }

  static int _tierPriority(String value) => switch (value) {
    'direct' => 0,
    'foundational' => 1,
    'expanded' => 2,
    _ => 3,
  };

  static Set<String> _terms(String text) {
    final lowered = text.toLowerCase();
    final terms = RegExp(
      r'[a-z0-9][a-z0-9.+-]{1,}',
    ).allMatches(lowered).map((match) => match.group(0)!).toSet();
    for (final match in RegExp(r'[\u4e00-\u9fff]+').allMatches(lowered)) {
      final segment = match.group(0)!;
      terms.add(segment);
      for (var index = 0; index < segment.length - 1; index++) {
        terms.add(segment.substring(index, index + 2));
      }
    }
    return terms;
  }

  static Set<String> _meaningfulTerms(Set<String> terms) {
    const generic = {
      'research',
      'study',
      'analysis',
      'method',
      'methods',
      'technology',
      'management',
      'treatment',
      '研究',
      '分析',
      '方法',
      '技术',
      '管理',
      '处理',
    };
    return terms
        .where((term) => !generic.contains(term) && term.length >= 2)
        .toSet();
  }

  static List<LiteraturePaper> rankLocallyForTesting(
    List<LiteraturePaper> papers,
    ExpandedLiteratureQuery query,
    DateTime today,
  ) => _rankLocally(papers, query, today);

  static ({List<String> matched, List<String> missing})
  verifyConceptEvidenceForTesting(
    LiteraturePaper paper,
    ExpandedLiteratureQuery query,
    Map<String, dynamic> aiRow,
  ) => _verifiedConceptEvidence(paper, query, aiRow);

  static bool semanticBoundaryForTesting({
    required String requestedTier,
    required bool primarySubjectVerified,
    required bool researchProblemVerified,
  }) => _semanticBoundaryVerified(
    requestedTier: requestedTier,
    primarySubjectVerified: primarySubjectVerified,
    researchProblemVerified: researchProblemVerified,
  );

  static String _openAlexAbstract(Map? raw) {
    if (raw == null) return '';
    final positioned = <(int, String)>[];
    for (final entry in raw.entries) {
      for (final offset in entry.value as List? ?? const []) {
        positioned.add(((offset as num).toInt(), '${entry.key}'));
      }
    }
    positioned.sort((a, b) => a.$1.compareTo(b.$1));
    return positioned.map((item) => item.$2).join(' ');
  }

  static DateTime? _crossrefDate(Map<String, dynamic> item) {
    for (final key in [
      'published-online',
      'published-print',
      'published',
      'issued',
    ]) {
      final row = Map<String, dynamic>.from(item[key] as Map? ?? const {});
      final parts = row['date-parts'] as List? ?? const [];
      if (parts.isEmpty || parts.first is! List) continue;
      final values = List<num>.from(parts.first as List);
      if (values.isEmpty) continue;
      try {
        return DateTime(
          values[0].toInt(),
          values.length > 1 ? values[1].toInt() : 1,
          values.length > 2 ? values[2].toInt() : 1,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static String _clean(Object? value) {
    var decoded = html_parser
        .parseFragment('${value ?? ''}')
        .text!
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Crossref sometimes returns escaped JATS tags. The first parse decodes
    // entities such as &lt;bold&gt;; a second pass removes the decoded markup.
    if (RegExp(r'</?[A-Za-z][^>]*>').hasMatch(decoded)) {
      decoded = html_parser
          .parseFragment(decoded)
          .text!
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    return decoded;
  }

  static String _stableId(String prefix, String value) {
    final digest = sha256
        .convert(utf8.encode(value))
        .toString()
        .substring(0, 24);
    return '${prefix}_$digest';
  }

  static String _date(DateTime value) {
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  void dispose() {
    _client.close();
    _ai.dispose();
  }
}

class _SourceRun {
  const _SourceRun({required this.papers, required this.status});

  final List<LiteraturePaper> papers;
  final LiteratureSourceStatus status;
}
