import 'package:cloud_firestore/cloud_firestore.dart';

const Set<String> aiContextSourceNames = {
  'tasks',
  'diary',
  'notes',
  'memos',
  'literature',
  'stocks',
  'memories',
  'chat_history',
  'resources',
};

class AiRetrievalPlan {
  const AiRetrievalPlan({
    required this.from,
    required this.to,
    required this.sources,
    required this.statuses,
    required this.concepts,
    required this.includeColdArchive,
    required this.maxItems,
    required this.reason,
  });

  final DateTime? from;
  final DateTime? to;
  final Set<String> sources;
  final Set<String> statuses;
  final List<String> concepts;
  final bool includeColdArchive;
  final int maxItems;
  final String reason;

  factory AiRetrievalPlan.fromJson(
    Map<String, dynamic> json, {
    required DateTime now,
    Set<String> allowedSources = aiContextSourceNames,
  }) {
    DateTime? parseDate(Object? value) {
      if (value is! String || value.trim().isEmpty) return null;
      return DateTime.tryParse(value)?.toLocal();
    }

    final range = Map<String, dynamic>.from(
      json['timeRange'] as Map? ?? const {},
    );
    final rawSources = (json['sources'] as List? ?? const [])
        .map((value) => '$value')
        .where(allowedSources.contains)
        .toSet();
    final rawMax = (json['maxItems'] as num?)?.toInt() ?? 12;
    final concepts = (json['concepts'] as List? ?? const [])
        .map((value) => '$value'.trim())
        .where((value) => value.isNotEmpty)
        .take(12)
        .toList(growable: false);
    var from = parseDate(range['from']);
    var to = parseDate(range['to']);
    if (to != null && from != null && to.isBefore(from)) {
      final swap = from;
      from = to;
      to = swap;
    }
    final earliest = DateTime(now.year - 30);
    if (from != null && from.isBefore(earliest)) from = earliest;
    final latest = now.add(const Duration(days: 366));
    if (to != null && to.isAfter(latest)) to = latest;
    return AiRetrievalPlan(
      from: from,
      to: to,
      sources: rawSources,
      statuses: (json['statuses'] as List? ?? const [])
          .map((value) => '$value'.toLowerCase())
          .where((value) => value.length <= 30)
          .take(8)
          .toSet(),
      concepts: concepts,
      includeColdArchive: json['includeColdArchive'] as bool? ?? false,
      maxItems: rawMax.clamp(1, 25),
      reason: '${json['reason'] ?? ''}'.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'timeRange': {'from': from?.toIso8601String(), 'to': to?.toIso8601String()},
    'sources': sources.toList()..sort(),
    'statuses': statuses.toList()..sort(),
    'concepts': concepts,
    'includeColdArchive': includeColdArchive,
    'maxItems': maxItems,
    'reason': reason,
  };
}

class AiMemory {
  const AiMemory({
    required this.id,
    required this.content,
    required this.source,
    required this.createdAt,
    required this.lastConfirmedAt,
    this.enabled = true,
  });

  final String id;
  final String content;
  final String source;
  final DateTime createdAt;
  final DateTime lastConfirmedAt;
  final bool enabled;

  factory AiMemory.fromJson(Map<String, dynamic> json) => AiMemory(
    id: '${json['id'] ?? ''}',
    content: '${json['content'] ?? ''}',
    source: '${json['source'] ?? 'manual'}',
    createdAt: (json['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    lastConfirmedAt:
        (json['lastConfirmedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    enabled: json['enabled'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'source': source,
    'createdAt': Timestamp.fromDate(createdAt),
    'lastConfirmedAt': Timestamp.fromDate(lastConfirmedAt),
    'enabled': enabled,
  };
}

class AiChatResource {
  const AiChatResource({
    required this.id,
    required this.title,
    required this.content,
    required this.contentHash,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String content;
  final String contentHash;
  final DateTime createdAt;

  factory AiChatResource.fromJson(Map<String, dynamic> json) => AiChatResource(
    id: '${json['id'] ?? ''}',
    title: '${json['title'] ?? '对话资料'}',
    content: '${json['content'] ?? ''}',
    contentHash: '${json['contentHash'] ?? ''}',
    createdAt: (json['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'contentHash': contentHash,
    'createdAt': Timestamp.fromDate(createdAt),
  };
}

class AiUsageRecord {
  const AiUsageRecord({
    required this.model,
    required this.promptTokens,
    required this.completionTokens,
    required this.cacheHitTokens,
    required this.estimatedCostUsd,
  });

  final String model;
  final int promptTokens;
  final int completionTokens;
  final int cacheHitTokens;
  final double estimatedCostUsd;

  factory AiUsageRecord.fromJson(Map<String, dynamic> json) => AiUsageRecord(
    model: '${json['model'] ?? ''}',
    promptTokens: (json['promptTokens'] as num?)?.toInt() ?? 0,
    completionTokens: (json['completionTokens'] as num?)?.toInt() ?? 0,
    cacheHitTokens: (json['cacheHitTokens'] as num?)?.toInt() ?? 0,
    estimatedCostUsd: (json['estimatedCostUsd'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'model': model,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'cacheHitTokens': cacheHitTokens,
    'estimatedCostUsd': estimatedCostUsd,
  };
}
