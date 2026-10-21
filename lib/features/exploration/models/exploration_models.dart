import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

String normalizeDoi(String? value) {
  var text = (value ?? '').trim().toLowerCase();
  text = text.replaceFirst(
    RegExp(r'^https?://(?:dx\.)?doi\.org/', caseSensitive: false),
    '',
  );
  return text.startsWith('doi:') ? text.substring(4) : text;
}

String normalizePaperTitle(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[^\w\u4e00-\u9fff]'), '');
}

@immutable
class NewsSourceDefinition {
  const NewsSourceDefinition({
    required this.id,
    required this.name,
    required this.authority,
    required this.region,
    required this.topic,
    required this.kind,
    required this.url,
    required this.limit,
    this.sourceClass = 'media',
    this.language = 'zh',
    this.pathPrefixes = const [],
  });

  final String id;
  final String name;
  final double authority;
  final String region;
  final String topic;
  final String kind;
  final String url;
  final int limit;
  final String sourceClass;
  final String language;
  final List<String> pathPrefixes;

  factory NewsSourceDefinition.fromJson(Map<String, dynamic> json) {
    return NewsSourceDefinition(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      authority: (json['authority'] as num?)?.toDouble() ?? 0,
      region: '${json['region'] ?? ''}',
      topic: '${json['topic'] ?? ''}',
      kind: '${json['kind'] ?? ''}',
      url: '${json['url'] ?? ''}',
      limit: (json['limit'] as num?)?.toInt() ?? 12,
      sourceClass: '${json['source_class'] ?? 'media'}',
      language: '${json['language'] ?? 'zh'}',
      pathPrefixes: List<String>.from(
        json['path_prefixes'] as List? ?? const [],
      ),
    );
  }
}

@immutable
class ExplorationNewsArticle {
  const ExplorationNewsArticle({
    required this.id,
    required this.title,
    required this.url,
    required this.sourceId,
    required this.sourceName,
    required this.sourceAuthority,
    required this.region,
    required this.topic,
    this.publishedAt,
    this.summary = '',
    this.fullContent = '',
    this.keywords = const [],
    this.score = 0,
    this.contentComplete = false,
    this.historicalSupplement = false,
    this.contentOrigin = 'none',
    this.contentQuality = 0,
    this.sourceClass = 'media',
    this.language = 'zh',
  });

  final String id;
  final String title;
  final String url;
  final String sourceId;
  final String sourceName;
  final double sourceAuthority;
  final String region;
  final String topic;
  final DateTime? publishedAt;
  final String summary;
  final String fullContent;
  final List<String> keywords;
  final double score;
  final bool contentComplete;
  final bool historicalSupplement;
  final String contentOrigin;
  final int contentQuality;
  final String sourceClass;
  final String language;

  ExplorationNewsArticle copyWith({
    String? title,
    String? url,
    String? topic,
    String? summary,
    String? fullContent,
    List<String>? keywords,
    double? score,
    bool? contentComplete,
    bool? historicalSupplement,
    String? contentOrigin,
    int? contentQuality,
    String? sourceClass,
    String? language,
  }) {
    return ExplorationNewsArticle(
      id: id,
      title: title ?? this.title,
      url: url ?? this.url,
      sourceId: sourceId,
      sourceName: sourceName,
      sourceAuthority: sourceAuthority,
      region: region,
      topic: topic ?? this.topic,
      publishedAt: publishedAt,
      summary: summary ?? this.summary,
      fullContent: fullContent ?? this.fullContent,
      keywords: keywords ?? this.keywords,
      score: score ?? this.score,
      contentComplete: contentComplete ?? this.contentComplete,
      historicalSupplement: historicalSupplement ?? this.historicalSupplement,
      contentOrigin: contentOrigin ?? this.contentOrigin,
      contentQuality: contentQuality ?? this.contentQuality,
      sourceClass: sourceClass ?? this.sourceClass,
      language: language ?? this.language,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'sourceId': sourceId,
    'sourceName': sourceName,
    'sourceAuthority': sourceAuthority,
    'region': region,
    'topic': topic,
    'publishedAt': publishedAt?.toIso8601String(),
    'summary': summary,
    'fullContent': fullContent,
    'keywords': keywords,
    'score': score,
    'contentComplete': contentComplete,
    'historicalSupplement': historicalSupplement,
    'contentOrigin': contentOrigin,
    'contentQuality': contentQuality,
    'sourceClass': sourceClass,
    'language': language,
  };

  factory ExplorationNewsArticle.fromJson(Map<String, dynamic> json) {
    return ExplorationNewsArticle(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? ''}',
      url: '${json['url'] ?? ''}',
      sourceId: '${json['sourceId'] ?? ''}',
      sourceName: '${json['sourceName'] ?? ''}',
      sourceAuthority: (json['sourceAuthority'] as num?)?.toDouble() ?? 0,
      region: '${json['region'] ?? ''}',
      topic: '${json['topic'] ?? ''}',
      publishedAt: DateTime.tryParse('${json['publishedAt'] ?? ''}'),
      summary: '${json['summary'] ?? ''}',
      fullContent: '${json['fullContent'] ?? ''}',
      keywords: List<String>.from(json['keywords'] as List? ?? const []),
      score: (json['score'] as num?)?.toDouble() ?? 0,
      contentComplete: json['contentComplete'] == true,
      historicalSupplement: json['historicalSupplement'] == true,
      contentOrigin: '${json['contentOrigin'] ?? 'none'}',
      contentQuality: (json['contentQuality'] as num?)?.toInt() ?? 0,
      sourceClass: '${json['sourceClass'] ?? 'media'}',
      language: '${json['language'] ?? 'zh'}',
    );
  }
}

@immutable
class ExpandedLiteratureQuery {
  const ExpandedLiteratureQuery({
    required this.original,
    required this.searchQueries,
    this.preferredTerms = const [],
    this.excludedTerms = const [],
    this.fallbackTerms = const [],
    this.requiredConceptGroups = const [],
    this.expansionQueries = const [],
    this.intentSummary = '',
  });

  final String original;
  final List<String> searchQueries;
  final List<String> preferredTerms;
  final List<String> excludedTerms;
  final List<String> fallbackTerms;
  final List<List<String>> requiredConceptGroups;
  final List<String> expansionQueries;
  final String intentSummary;

  factory ExpandedLiteratureQuery.fallback(String query) {
    return ExpandedLiteratureQuery(
      original: query,
      searchQueries: [query],
      preferredTerms: [query],
      intentSummary: query,
    );
  }

  Map<String, dynamic> toJson() => {
    'original': original,
    'searchQueries': searchQueries,
    'preferredTerms': preferredTerms,
    'excludedTerms': excludedTerms,
    'fallbackTerms': fallbackTerms,
    // Firestore rejects arrays nested directly inside arrays. Represent every
    // concept group as a map so the same report is safe on Windows Firebase,
    // Android Firebase and ordinary JSON backups.
    'requiredConceptGroups': requiredConceptGroups
        .map((group) => <String, dynamic>{'terms': group})
        .toList(),
    'expansionQueries': expansionQueries,
    'intentSummary': intentSummary,
  };

  factory ExpandedLiteratureQuery.fromJson(Map<String, dynamic> json) {
    return ExpandedLiteratureQuery(
      original: '${json['original'] ?? ''}',
      searchQueries: List<String>.from(
        json['searchQueries'] as List? ?? const [],
      ),
      preferredTerms: List<String>.from(
        json['preferredTerms'] as List? ?? const [],
      ),
      excludedTerms: List<String>.from(
        json['excludedTerms'] as List? ?? const [],
      ),
      fallbackTerms: List<String>.from(
        json['fallbackTerms'] as List? ?? const [],
      ),
      requiredConceptGroups: (json['requiredConceptGroups'] as List? ?? const [])
          .map((group) {
            // Read both the Firestore-safe v3 shape and any in-memory/legacy
            // JSON that used a direct list of terms.
            if (group is Map) {
              return List<String>.from(group['terms'] as List? ?? const []);
            }
            return List<String>.from(group as List? ?? const []);
          })
          .where((group) => group.isNotEmpty)
          .toList(),
      expansionQueries: List<String>.from(
        json['expansionQueries'] as List? ?? const [],
      ),
      intentSummary: '${json['intentSummary'] ?? ''}',
    );
  }
}

@immutable
class LiteraturePaper {
  const LiteraturePaper({
    required this.id,
    required this.title,
    required this.abstractText,
    this.authors = const [],
    this.publishedOn,
    this.venue = '',
    this.doi = '',
    this.url = '',
    this.pdfUrl = '',
    this.keywords = const [],
    this.citationCount = 0,
    this.sourceNames = const [],
    this.isOpenAccess = false,
    this.localScore = 0,
    this.arxivId = '',
    this.openAlexId = '',
    this.semanticScholarId = '',
    this.referenceCount = 0,
    this.influentialCitationCount = 0,
    this.publicationType = '',
    this.openAccessStatus = '',
    this.isRetracted = false,
    this.discoveryTier = 'direct',
  });

  final String id;
  final String title;
  final String abstractText;
  final List<String> authors;
  final DateTime? publishedOn;
  final String venue;
  final String doi;
  final String url;
  final String pdfUrl;
  final List<String> keywords;
  final int citationCount;
  final List<String> sourceNames;
  final bool isOpenAccess;
  final double localScore;
  final String arxivId;
  final String openAlexId;
  final String semanticScholarId;
  final int referenceCount;
  final int influentialCitationCount;
  final String publicationType;
  final String openAccessStatus;
  final bool isRetracted;
  final String discoveryTier;

  String get canonicalKey {
    final normalizedDoi = normalizeDoi(doi);
    if (normalizedDoi.isNotEmpty) return 'doi:$normalizedDoi';
    if (arxivId.trim().isNotEmpty) return 'arxiv:${arxivId.toLowerCase()}';
    final digest = sha256
        .convert(utf8.encode(normalizePaperTitle(title)))
        .toString()
        .substring(0, 24);
    return 'title:$digest';
  }

  LiteraturePaper copyWith({
    String? id,
    String? abstractText,
    List<String>? authors,
    DateTime? publishedOn,
    String? venue,
    String? doi,
    String? url,
    String? pdfUrl,
    List<String>? keywords,
    int? citationCount,
    List<String>? sourceNames,
    bool? isOpenAccess,
    double? localScore,
    String? arxivId,
    String? openAlexId,
    String? semanticScholarId,
    int? referenceCount,
    int? influentialCitationCount,
    String? publicationType,
    String? openAccessStatus,
    bool? isRetracted,
    String? discoveryTier,
  }) {
    return LiteraturePaper(
      id: id ?? this.id,
      title: title,
      abstractText: abstractText ?? this.abstractText,
      authors: authors ?? this.authors,
      publishedOn: publishedOn ?? this.publishedOn,
      venue: venue ?? this.venue,
      doi: doi ?? this.doi,
      url: url ?? this.url,
      pdfUrl: pdfUrl ?? this.pdfUrl,
      keywords: keywords ?? this.keywords,
      citationCount: citationCount ?? this.citationCount,
      sourceNames: sourceNames ?? this.sourceNames,
      isOpenAccess: isOpenAccess ?? this.isOpenAccess,
      localScore: localScore ?? this.localScore,
      arxivId: arxivId ?? this.arxivId,
      openAlexId: openAlexId ?? this.openAlexId,
      semanticScholarId: semanticScholarId ?? this.semanticScholarId,
      referenceCount: referenceCount ?? this.referenceCount,
      influentialCitationCount:
          influentialCitationCount ?? this.influentialCitationCount,
      publicationType: publicationType ?? this.publicationType,
      openAccessStatus: openAccessStatus ?? this.openAccessStatus,
      isRetracted: isRetracted ?? this.isRetracted,
      discoveryTier: discoveryTier ?? this.discoveryTier,
    );
  }

  Map<String, dynamic> toAiJson({int abstractLimit = 8000}) => {
    'paper_id': id,
    'title': title,
    'abstract': abstractText.length > abstractLimit.clamp(200, 8000)
        ? abstractText.substring(0, abstractLimit.clamp(200, 8000))
        : abstractText,
    'authors': authors.take(12).toList(),
    'published_on': publishedOn?.toIso8601String().split('T').first,
    'venue': venue,
    'doi': normalizeDoi(doi),
    'keywords': keywords.take(16).toList(),
    'citation_count': citationCount,
    'sources': sourceNames,
    'open_access': isOpenAccess,
    'open_access_status': openAccessStatus,
    'publication_type': publicationType,
    'reference_count': referenceCount,
    'influential_citation_count': influentialCitationCount,
    'is_retracted': isRetracted,
    'discovery_tier': discoveryTier,
    'local_score': localScore,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'abstractText': abstractText,
    'authors': authors,
    'publishedOn': publishedOn?.toIso8601String(),
    'venue': venue,
    'doi': doi,
    'url': url,
    'pdfUrl': pdfUrl,
    'keywords': keywords,
    'citationCount': citationCount,
    'sourceNames': sourceNames,
    'isOpenAccess': isOpenAccess,
    'localScore': localScore,
    'arxivId': arxivId,
    'openAlexId': openAlexId,
    'semanticScholarId': semanticScholarId,
    'referenceCount': referenceCount,
    'influentialCitationCount': influentialCitationCount,
    'publicationType': publicationType,
    'openAccessStatus': openAccessStatus,
    'isRetracted': isRetracted,
    'discoveryTier': discoveryTier,
  };

  factory LiteraturePaper.fromJson(Map<String, dynamic> json) {
    return LiteraturePaper(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? ''}',
      abstractText: '${json['abstractText'] ?? ''}',
      authors: List<String>.from(json['authors'] as List? ?? const []),
      publishedOn: DateTime.tryParse('${json['publishedOn'] ?? ''}'),
      venue: '${json['venue'] ?? ''}',
      doi: '${json['doi'] ?? ''}',
      url: '${json['url'] ?? ''}',
      pdfUrl: '${json['pdfUrl'] ?? ''}',
      keywords: List<String>.from(json['keywords'] as List? ?? const []),
      citationCount: (json['citationCount'] as num?)?.toInt() ?? 0,
      sourceNames: List<String>.from(json['sourceNames'] as List? ?? const []),
      isOpenAccess: json['isOpenAccess'] == true,
      localScore: (json['localScore'] as num?)?.toDouble() ?? 0,
      arxivId: '${json['arxivId'] ?? ''}',
      openAlexId: '${json['openAlexId'] ?? ''}',
      semanticScholarId: '${json['semanticScholarId'] ?? ''}',
      referenceCount: (json['referenceCount'] as num?)?.toInt() ?? 0,
      influentialCitationCount:
          (json['influentialCitationCount'] as num?)?.toInt() ?? 0,
      publicationType: '${json['publicationType'] ?? ''}',
      openAccessStatus: '${json['openAccessStatus'] ?? ''}',
      isRetracted: json['isRetracted'] == true,
      discoveryTier: '${json['discoveryTier'] ?? 'direct'}',
    );
  }
}

@immutable
class LiteratureRecommendation {
  const LiteratureRecommendation({
    required this.paper,
    required this.rank,
    required this.relevanceScore,
    required this.qualityScore,
    required this.freshnessScore,
    required this.overallScore,
    required this.coreSummary,
    this.researchQuestion = '',
    this.method = '',
    this.keyFindings = const [],
    this.limitations = const [],
    this.recommendationReason = '',
    this.worthDeepReading = false,
    this.model = 'deterministic',
    this.matchTier = 'high_relevance',
    this.matchedConcepts = const [],
    this.missingConcepts = const [],
  });

  final LiteraturePaper paper;
  final int rank;
  final double relevanceScore;
  final double qualityScore;
  final double freshnessScore;
  final double overallScore;
  final String coreSummary;
  final String researchQuestion;
  final String method;
  final List<String> keyFindings;
  final List<String> limitations;
  final String recommendationReason;
  final bool worthDeepReading;
  final String model;
  final String matchTier;
  final List<String> matchedConcepts;
  final List<String> missingConcepts;

  Map<String, dynamic> toJson() => {
    'paper': paper.toJson(),
    'rank': rank,
    'relevanceScore': relevanceScore,
    'qualityScore': qualityScore,
    'freshnessScore': freshnessScore,
    'overallScore': overallScore,
    'coreSummary': coreSummary,
    'researchQuestion': researchQuestion,
    'method': method,
    'keyFindings': keyFindings,
    'limitations': limitations,
    'recommendationReason': recommendationReason,
    'worthDeepReading': worthDeepReading,
    'model': model,
    'matchTier': matchTier,
    'matchedConcepts': matchedConcepts,
    'missingConcepts': missingConcepts,
  };

  factory LiteratureRecommendation.fromJson(Map<String, dynamic> json) {
    return LiteratureRecommendation(
      paper: LiteraturePaper.fromJson(
        Map<String, dynamic>.from(json['paper'] as Map? ?? const {}),
      ),
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      relevanceScore: (json['relevanceScore'] as num?)?.toDouble() ?? 0,
      qualityScore: (json['qualityScore'] as num?)?.toDouble() ?? 0,
      freshnessScore: (json['freshnessScore'] as num?)?.toDouble() ?? 0,
      overallScore: (json['overallScore'] as num?)?.toDouble() ?? 0,
      coreSummary: '${json['coreSummary'] ?? ''}',
      researchQuestion: '${json['researchQuestion'] ?? ''}',
      method: '${json['method'] ?? ''}',
      keyFindings: List<String>.from(json['keyFindings'] as List? ?? const []),
      limitations: List<String>.from(json['limitations'] as List? ?? const []),
      recommendationReason: '${json['recommendationReason'] ?? ''}',
      worthDeepReading: json['worthDeepReading'] == true,
      model: '${json['model'] ?? 'deterministic'}',
      matchTier: '${json['matchTier'] ?? 'high_relevance'}',
      matchedConcepts: List<String>.from(
        json['matchedConcepts'] as List? ?? const [],
      ),
      missingConcepts: List<String>.from(
        json['missingConcepts'] as List? ?? const [],
      ),
    );
  }
}

@immutable
class LiteratureSourceStatus {
  const LiteratureSourceStatus({
    required this.sourceId,
    required this.sourceName,
    required this.success,
    required this.paperCount,
    this.error = '',
  });

  final String sourceId;
  final String sourceName;
  final bool success;
  final int paperCount;
  final String error;

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceName': sourceName,
    'success': success,
    'paperCount': paperCount,
    'error': error,
  };

  factory LiteratureSourceStatus.fromJson(Map<String, dynamic> json) {
    return LiteratureSourceStatus(
      sourceId: '${json['sourceId'] ?? ''}',
      sourceName: '${json['sourceName'] ?? ''}',
      success: json['success'] == true,
      paperCount: (json['paperCount'] as num?)?.toInt() ?? 0,
      error: '${json['error'] ?? ''}',
    );
  }
}

@immutable
class LiteratureDiscoveryReport {
  const LiteratureDiscoveryReport({
    required this.query,
    required this.candidates,
    required this.recommendations,
    required this.sourceStatuses,
    required this.usedAi,
    required this.estimatedCostUsd,
    this.reportCached = false,
    this.pipelineVersion = 9,
  });

  final ExpandedLiteratureQuery query;
  final List<LiteraturePaper> candidates;
  final List<LiteratureRecommendation> recommendations;
  final List<LiteratureSourceStatus> sourceStatuses;
  final bool usedAi;
  final double estimatedCostUsd;
  final bool reportCached;
  final int pipelineVersion;

  LiteratureDiscoveryReport copyWith({bool? reportCached}) {
    return LiteratureDiscoveryReport(
      query: query,
      candidates: candidates,
      recommendations: recommendations,
      sourceStatuses: sourceStatuses,
      usedAi: usedAi,
      estimatedCostUsd: estimatedCostUsd,
      reportCached: reportCached ?? this.reportCached,
      pipelineVersion: pipelineVersion,
    );
  }

  Map<String, dynamic> toJson() => {
    'query': query.toJson(),
    'candidates': candidates.map((item) => item.toJson()).toList(),
    'recommendations': recommendations.map((item) => item.toJson()).toList(),
    'sourceStatuses': sourceStatuses.map((item) => item.toJson()).toList(),
    'usedAi': usedAi,
    'estimatedCostUsd': estimatedCostUsd,
    'pipelineVersion': pipelineVersion,
  };

  factory LiteratureDiscoveryReport.fromJson(Map<String, dynamic> json) {
    return LiteratureDiscoveryReport(
      query: ExpandedLiteratureQuery.fromJson(
        Map<String, dynamic>.from(json['query'] as Map? ?? const {}),
      ),
      candidates: (json['candidates'] as List? ?? const [])
          .map(
            (item) => LiteraturePaper.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      recommendations: (json['recommendations'] as List? ?? const [])
          .map(
            (item) => LiteratureRecommendation.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      sourceStatuses: (json['sourceStatuses'] as List? ?? const [])
          .map(
            (item) => LiteratureSourceStatus.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      usedAi: json['usedAi'] == true,
      estimatedCostUsd: (json['estimatedCostUsd'] as num?)?.toDouble() ?? 0,
      pipelineVersion: (json['pipelineVersion'] as num?)?.toInt() ?? 1,
    );
  }
}

enum LiteratureReadingStatus { unread, reading, read }

@immutable
class LiteratureAnnotation {
  const LiteratureAnnotation({
    required this.id,
    required this.quote,
    required this.createdAt,
    this.page,
    this.note = '',
  });

  final String id;
  final String quote;
  final int? page;
  final String note;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'quote': quote,
    'page': page,
    'note': note,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory LiteratureAnnotation.fromJson(Map<String, dynamic> json) {
    return LiteratureAnnotation(
      id: '${json['id'] ?? ''}',
      quote: '${json['quote'] ?? ''}',
      page: (json['page'] as num?)?.toInt(),
      note: '${json['note'] ?? ''}',
      createdAt:
          DateTime.tryParse('${json['createdAt'] ?? ''}') ?? DateTime.now(),
    );
  }
}

@immutable
class LiteratureLibraryItem {
  const LiteratureLibraryItem({
    required this.id,
    required this.recommendation,
    required this.createdAt,
    required this.updatedAt,
    this.isFavorite = true,
    this.readingStatus = LiteratureReadingStatus.unread,
    this.tags = const [],
    this.note = '',
    this.deepAnalysis = const {},
    this.cloudPdfId = '',
    this.cloudPdfUrl = '',
    this.annotations = const [],
    this.lastOpenedAt,
  });

  final String id;
  final LiteratureRecommendation recommendation;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isFavorite;
  final LiteratureReadingStatus readingStatus;
  final List<String> tags;
  final String note;
  final Map<String, dynamic> deepAnalysis;
  final String cloudPdfId;
  final String cloudPdfUrl;
  final List<LiteratureAnnotation> annotations;
  final DateTime? lastOpenedAt;

  bool get hasSavedDeepAnalysis => deepAnalysis.isNotEmpty;
  bool get hasCloudPdf => cloudPdfUrl.startsWith('webdav://');

  LiteratureLibraryItem copyWith({
    LiteratureRecommendation? recommendation,
    DateTime? updatedAt,
    bool? isFavorite,
    LiteratureReadingStatus? readingStatus,
    List<String>? tags,
    String? note,
    Map<String, dynamic>? deepAnalysis,
    String? cloudPdfId,
    String? cloudPdfUrl,
    List<LiteratureAnnotation>? annotations,
    DateTime? lastOpenedAt,
  }) {
    return LiteratureLibraryItem(
      id: id,
      recommendation: recommendation ?? this.recommendation,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isFavorite: isFavorite ?? this.isFavorite,
      readingStatus: readingStatus ?? this.readingStatus,
      tags: tags ?? this.tags,
      note: note ?? this.note,
      deepAnalysis: deepAnalysis ?? this.deepAnalysis,
      cloudPdfId: cloudPdfId ?? this.cloudPdfId,
      cloudPdfUrl: cloudPdfUrl ?? this.cloudPdfUrl,
      annotations: annotations ?? this.annotations,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'recommendation': recommendation.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'isFavorite': isFavorite,
    'readingStatus': readingStatus.name,
    'tags': tags,
    'note': note,
    'deepAnalysis': deepAnalysis,
    'cloudPdfId': cloudPdfId,
    'cloudPdfUrl': cloudPdfUrl,
    'annotations': annotations.map((item) => item.toJson()).toList(),
    'lastOpenedAt': lastOpenedAt?.toUtc().toIso8601String(),
  };

  factory LiteratureLibraryItem.fromJson(Map<String, dynamic> json) {
    DateTime date(String key) =>
        DateTime.tryParse('${json[key] ?? ''}') ?? DateTime.now();
    return LiteratureLibraryItem(
      id: '${json['id'] ?? ''}',
      recommendation: LiteratureRecommendation.fromJson(
        Map<String, dynamic>.from(json['recommendation'] as Map? ?? const {}),
      ),
      createdAt: date('createdAt'),
      updatedAt: date('updatedAt'),
      isFavorite: json['isFavorite'] != false,
      readingStatus: LiteratureReadingStatus.values.firstWhere(
        (value) => value.name == json['readingStatus'],
        orElse: () => LiteratureReadingStatus.unread,
      ),
      tags: List<String>.from(json['tags'] as List? ?? const []),
      note: '${json['note'] ?? ''}',
      deepAnalysis: Map<String, dynamic>.from(
        json['deepAnalysis'] as Map? ?? const {},
      ),
      cloudPdfId: '${json['cloudPdfId'] ?? ''}',
      cloudPdfUrl: '${json['cloudPdfUrl'] ?? ''}',
      annotations: (json['annotations'] as List? ?? const [])
          .map(
            (item) => LiteratureAnnotation.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      lastOpenedAt: DateTime.tryParse('${json['lastOpenedAt'] ?? ''}'),
    );
  }

  static String idForPaper(LiteraturePaper paper) => sha256
      .convert(utf8.encode(paper.canonicalKey))
      .toString()
      .substring(0, 24);
}

@immutable
class KnowledgeCardItem {
  const KnowledgeCardItem({required this.term, required this.content});

  final String term;
  final String content;
}

@immutable
class PuzzleStage {
  const PuzzleStage({
    required this.index,
    required this.task,
    required this.answerKeywords,
    required this.truth,
    this.knownClues = const [],
    this.mustPoints = const [],
    this.optionalPoints = const [],
    this.contradictions = const [],
  });

  final int index;
  final String task;
  final List<String> answerKeywords;
  final String truth;
  final List<String> knownClues;
  final List<String> mustPoints;
  final List<String> optionalPoints;
  final List<String> contradictions;

  factory PuzzleStage.fromJson(Map<String, dynamic> json) {
    return PuzzleStage(
      index: (json['stage_idx'] as num?)?.toInt() ?? 0,
      task: '${json['task'] ?? ''}',
      answerKeywords: List<String>.from(
        json['answer_keywords'] as List? ?? const [],
      ),
      truth: '${json['stage_truth'] ?? ''}',
      knownClues: List<String>.from(json['known_clues'] as List? ?? const []),
      mustPoints: List<String>.from(json['must_points'] as List? ?? const []),
      optionalPoints: List<String>.from(
        json['optional_points'] as List? ?? const [],
      ),
      contradictions: List<String>.from(
        json['contradictions'] as List? ?? const [],
      ),
    );
  }
}

@immutable
class PuzzleCase {
  const PuzzleCase({
    required this.id,
    required this.title,
    required this.type,
    required this.background,
    required this.stages,
  });

  final String id;
  final String title;
  final String type;
  final String background;
  final List<PuzzleStage> stages;

  factory PuzzleCase.fromJson(String id, Map<String, dynamic> json) {
    return PuzzleCase(
      id: id,
      title: '${json['title'] ?? '未知卷宗'}',
      type: '${json['type'] ?? 'multi_stage'}',
      background: '${json['background'] ?? ''}',
      stages: (json['stages'] as List? ?? const [])
          .map(
            (item) =>
                PuzzleStage.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(),
    );
  }
}

@immutable
class PuzzleProgress {
  const PuzzleProgress({
    this.currentStage = 0,
    this.attempts = 0,
    this.cleared = false,
  });

  final int currentStage;
  final int attempts;
  final bool cleared;

  Map<String, dynamic> toJson() => {
    'currentStage': currentStage,
    'attempts': attempts,
    'cleared': cleared,
  };

  factory PuzzleProgress.fromJson(Map<String, dynamic> json) {
    return PuzzleProgress(
      currentStage: (json['currentStage'] as num?)?.toInt() ?? 0,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      cleared: json['cleared'] == true,
    );
  }
}

enum PuzzleVerdict {
  correct,
  plausibleAlternative,
  partial,
  needsClarification,
  incorrect,
}

@immutable
class PuzzleDimensionScore {
  const PuzzleDimensionScore({
    required this.label,
    required this.score,
    required this.maximum,
    required this.explanation,
  });

  final String label;
  final int score;
  final int maximum;
  final String explanation;
}

@immutable
class PuzzleJudgeDecision {
  const PuzzleJudgeDecision({
    required this.verdict,
    required this.score,
    required this.confidence,
    required this.feedback,
    required this.dimensions,
    required this.passed,
    required this.nextAction,
    this.matchedPoints = const [],
    this.missingPoints = const [],
    this.contradictions = const [],
    this.model = 'local',
  });

  final PuzzleVerdict verdict;
  final int score;
  final double confidence;
  final String feedback;
  final List<PuzzleDimensionScore> dimensions;
  final bool passed;
  final String nextAction;
  final List<String> matchedPoints;
  final List<String> missingPoints;
  final List<String> contradictions;
  final String model;
}
