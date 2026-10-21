import 'dart:convert';

bool _containsRawMarketBulk(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      if ({
        'bars',
        'candles',
        'minute_data',
        'factor_matrix',
        'full_news_text',
      }.contains('${entry.key}'.toLowerCase())) {
        return true;
      }
      if (_containsRawMarketBulk(entry.value)) return true;
    }
  } else if (value is List) {
    return value.any(_containsRawMarketBulk);
  }
  return false;
}

/// A statement is never promoted from hypothesis to fact by rewriting it.
/// Later evidence creates another entry linked to the original event.
class StockAgentMemoryEntry {
  const StockAgentMemoryEntry({
    required this.id,
    required this.kind,
    required this.content,
    required this.sourceEventIds,
    required this.updatedAt,
    this.status = 'active',
  });

  final String id;
  final String kind;
  final String content;
  final List<String> sourceEventIds;
  final DateTime updatedAt;
  final String status;

  static const kinds = {'observation', 'hypothesis', 'outcome', 'lesson'};

  void validate() {
    if (id.trim().isEmpty ||
        !kinds.contains(kind) ||
        content.trim().isEmpty ||
        sourceEventIds.isEmpty ||
        sourceEventIds.any((id) => id.trim().isEmpty) ||
        !{'active', 'resolved', 'retracted'}.contains(status)) {
      throw StateError('股票长期记忆必须区分事实、猜测、结果并引用原始事件');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'content': content,
    'sourceEventIds': sourceEventIds,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'status': status,
  };

  factory StockAgentMemoryEntry.fromJson(Map<String, dynamic> json) =>
      StockAgentMemoryEntry(
        id: '${json['id'] ?? ''}',
        kind: '${json['kind'] ?? ''}',
        content: '${json['content'] ?? ''}',
        sourceEventIds: List<String>.from(
          json['sourceEventIds'] as List? ?? const [],
        ),
        updatedAt: DateTime.parse('${json['updatedAt']}'),
        status: '${json['status'] ?? 'active'}',
      );
}

/// Compact authoritative account pointer; detailed daily material lives in WebDAV.
class StockAgentExperiment {
  const StockAgentExperiment({
    required this.id,
    required this.startedAt,
    required this.endsAt,
    required this.version,
    required this.account,
    required this.memory,
    required this.updatedAt,
    this.status = 'active',
  });

  final String id;
  final DateTime startedAt;
  final DateTime endsAt;
  final int version;
  final Map<String, dynamic> account;
  final Map<String, dynamic> memory;
  final DateTime updatedAt;
  final String status;

  static const double initialCash = 1000;

  StockAgentExperiment copyWith({
    int? version,
    Map<String, dynamic>? account,
    Map<String, dynamic>? memory,
    DateTime? updatedAt,
    String? status,
  }) => StockAgentExperiment(
    id: id,
    startedAt: startedAt,
    endsAt: endsAt,
    version: version ?? this.version,
    account: account ?? this.account,
    memory: memory ?? this.memory,
    updatedAt: updatedAt ?? this.updatedAt,
    status: status ?? this.status,
  );

  void validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id) ||
        version < 0 ||
        !endsAt.isAfter(startedAt) ||
        !{'active', 'paused', 'completed'}.contains(status)) {
      throw StateError('股票实验状态无效');
    }
    final startBeijing = startedAt.toUtc().add(const Duration(hours: 8));
    final expectedEndUtc = DateTime.utc(
      startBeijing.year,
      startBeijing.month,
      startBeijing.day + 30,
    ).subtract(const Duration(hours: 8));
    if (endsAt.toUtc() != expectedEndUtc) {
      throw StateError('股票实验必须覆盖 30 个北京时间自然日');
    }
    final cash = (account['initialCash'] as num?)?.toDouble();
    if (cash != initialCash) {
      throw StateError('本轮股票实验初始资金必须为 1000 元');
    }
    final entries = memory['entries'] as List? ?? const [];
    for (final raw in entries) {
      StockAgentMemoryEntry.fromJson(
        Map<String, dynamic>.from(raw as Map),
      ).validate();
    }
    if (utf8.encode(jsonEncode(toJson())).length > 128 * 1024) {
      throw StateError('股票实验当前状态过大，禁止写入 Firestore');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endsAt': endsAt.toUtc().toIso8601String(),
    'version': version,
    'account': account,
    'memory': memory,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'status': status,
  };

  factory StockAgentExperiment.fromJson(Map<String, dynamic> json) =>
      StockAgentExperiment(
        id: '${json['id'] ?? ''}',
        startedAt: DateTime.parse('${json['startedAt']}'),
        endsAt: DateTime.parse('${json['endsAt']}'),
        version: (json['version'] as num?)?.toInt() ?? 0,
        account: Map<String, dynamic>.from(json['account'] as Map? ?? const {}),
        memory: Map<String, dynamic>.from(json['memory'] as Map? ?? const {}),
        updatedAt:
            DateTime.tryParse('${json['updatedAt'] ?? ''}') ?? DateTime.now(),
        status: '${json['status'] ?? 'active'}',
      );
}

class StockAgentEvent {
  const StockAgentEvent({
    required this.id,
    required this.experimentId,
    required this.logicalDay,
    required this.kind,
    required this.occurredAt,
    required this.recordedAt,
    required this.detail,
    required this.codes,
    this.tags = const [],
    this.sourceObservedAt,
  });

  final String id;
  final String experimentId;
  final String logicalDay;
  final String kind;
  final DateTime occurredAt;
  final DateTime recordedAt;
  final DateTime? sourceObservedAt;
  final Map<String, dynamic> detail;
  final List<String> codes;
  final List<String> tags;

  void validate() {
    if (id.trim().isEmpty ||
        experimentId.trim().isEmpty ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(logicalDay) ||
        DateTime.tryParse('${logicalDay}T00:00:00Z') == null) {
      throw StateError('股票实验事件 ID 或日期无效');
    }
    final beijingDay = recordedAt.toUtc().add(const Duration(hours: 8));
    final recordedDay = beijingDay.toIso8601String().split('T').first;
    final delayedMissedDay =
        kind == 'missed_cycle' &&
        detail['delayedRecovery'] == true &&
        recordedDay.compareTo(logicalDay) > 0;
    if (recordedDay != logicalDay && !delayedMissedDay) {
      throw StateError('事件日期与北京时间不一致');
    }
    if (sourceObservedAt != null && sourceObservedAt!.isAfter(recordedAt)) {
      throw StateError('事件引用了尚未出现的行情');
    }
    if (occurredAt.isAfter(recordedAt)) {
      throw StateError('事件发生时间不能晚于记录时间');
    }
    if (_containsRawMarketBulk(detail)) {
      throw StateError('股票事件禁止写入原始全市场行情或新闻全文');
    }
    if (utf8.encode(jsonEncode(toJson())).length > 32 * 1024) {
      throw StateError('股票实验单个事件过大，禁止写入 Firestore');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'experimentId': experimentId,
    'logicalDay': logicalDay,
    'kind': kind,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'sourceObservedAt': sourceObservedAt?.toUtc().toIso8601String(),
    'detail': detail,
    'codes': codes,
    'tags': tags,
  };

  factory StockAgentEvent.fromJson(Map<String, dynamic> json) =>
      StockAgentEvent(
        id: '${json['id'] ?? ''}',
        experimentId: '${json['experimentId'] ?? ''}',
        logicalDay: '${json['logicalDay'] ?? ''}',
        kind: '${json['kind'] ?? ''}',
        occurredAt: DateTime.parse('${json['occurredAt']}'),
        recordedAt: DateTime.parse('${json['recordedAt']}'),
        sourceObservedAt: DateTime.tryParse(
          '${json['sourceObservedAt'] ?? ''}',
        ),
        detail: Map<String, dynamic>.from(json['detail'] as Map? ?? const {}),
        codes: List<String>.from(json['codes'] as List? ?? const []),
        tags: List<String>.from(json['tags'] as List? ?? const []),
      );
}

class StockAgentDayIndex {
  const StockAgentDayIndex({
    required this.experimentId,
    required this.logicalDay,
    required this.archiveUrl,
    required this.sha256,
    required this.byteLength,
    required this.sealed,
    required this.codes,
    required this.tags,
    required this.eventIds,
    required this.updatedAt,
    this.staleArchiveUrls = const [],
  });

  final String experimentId;
  final String logicalDay;
  final String archiveUrl;
  final String sha256;
  final int byteLength;
  final bool sealed;
  final List<String> codes;
  final List<String> tags;
  final List<String> eventIds;
  final DateTime updatedAt;
  final List<String> staleArchiveUrls;

  void validate() {
    if (experimentId.trim().isEmpty ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(logicalDay) ||
        archiveUrl.isEmpty ||
        sha256.length != 64 ||
        byteLength <= 0 ||
        byteLength > 4 * 1024 * 1024 ||
        eventIds.length != eventIds.toSet().length ||
        utf8.encode(jsonEncode(toJson())).length > 64 * 1024) {
      throw StateError('股票日记索引无效或超出 Firestore 体积预算');
    }
  }

  StockAgentDayIndex copyWith({List<String>? staleArchiveUrls}) =>
      StockAgentDayIndex(
        experimentId: experimentId,
        logicalDay: logicalDay,
        archiveUrl: archiveUrl,
        sha256: sha256,
        byteLength: byteLength,
        sealed: sealed,
        codes: codes,
        tags: tags,
        eventIds: eventIds,
        updatedAt: updatedAt,
        staleArchiveUrls: staleArchiveUrls ?? this.staleArchiveUrls,
      );

  Map<String, dynamic> toJson() => {
    'experimentId': experimentId,
    'logicalDay': logicalDay,
    'archiveUrl': archiveUrl,
    'sha256': sha256,
    'byteLength': byteLength,
    'sealed': sealed,
    'codes': codes,
    'tags': tags,
    'eventIds': eventIds,
    'eventCount': eventIds.length,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'staleArchiveUrls': staleArchiveUrls,
  };

  factory StockAgentDayIndex.fromJson(Map<String, dynamic> json) =>
      StockAgentDayIndex(
        experimentId: '${json['experimentId'] ?? ''}',
        logicalDay: '${json['logicalDay'] ?? ''}',
        archiveUrl: '${json['archiveUrl'] ?? ''}',
        sha256: '${json['sha256'] ?? ''}',
        byteLength: (json['byteLength'] as num?)?.toInt() ?? 0,
        sealed: json['sealed'] == true,
        codes: List<String>.from(json['codes'] as List? ?? const []),
        tags: List<String>.from(json['tags'] as List? ?? const []),
        eventIds: List<String>.from(json['eventIds'] as List? ?? const []),
        updatedAt:
            DateTime.tryParse('${json['updatedAt'] ?? ''}') ?? DateTime.now(),
        staleArchiveUrls: List<String>.from(
          json['staleArchiveUrls'] as List? ?? const [],
        ),
      );
}

class StockAgentMemoryContext {
  const StockAgentMemoryContext({
    required this.experiment,
    required this.recent,
    required this.relevant,
    required this.sourceEventIds,
  });

  final StockAgentExperiment experiment;
  final List<StockAgentEvent> recent;
  final List<StockAgentEvent> relevant;
  final List<String> sourceEventIds;
}
