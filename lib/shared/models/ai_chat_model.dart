import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:syncnote/shared/models/ai_assistant_model.dart';

class AiChat {
  const AiChat({
    required this.id,
    required this.title,
    this.memorySummary = '',
    this.sourceRefs = const [],
    this.enabledSources = aiContextSourceNames,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String memorySummary;
  final List<String> sourceRefs;
  final Set<String> enabledSources;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory AiChat.fromJson(Map<String, dynamic> json) => AiChat(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '新对话',
    memorySummary: json['memorySummary'] as String? ?? '',
    sourceRefs: List<String>.from(json['sourceRefs'] as List? ?? const []),
    enabledSources: Set<String>.from(
      json['enabledSources'] as List? ?? aiContextSourceNames,
    ).intersection(aiContextSourceNames),
    createdAt: (json['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    updatedAt: (json['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
  );
}

class AiChatMessage {
  const AiChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.sourceRefs = const [],
    this.retrievalPlan,
    this.usage,
  });

  final String id;
  final String role;
  final String content;
  final DateTime createdAt;
  final List<String> sourceRefs;
  final Map<String, dynamic>? retrievalPlan;
  final AiUsageRecord? usage;

  factory AiChatMessage.fromJson(Map<String, dynamic> json) => AiChatMessage(
    id: json['id'] as String? ?? '',
    role: json['role'] as String? ?? 'user',
    content: json['content'] as String? ?? '',
    createdAt: (json['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    sourceRefs: List<String>.from(json['sourceRefs'] as List? ?? const []),
    retrievalPlan: json['retrievalPlan'] is Map
        ? Map<String, dynamic>.from(json['retrievalPlan'] as Map)
        : null,
    usage: json['usage'] is Map
        ? AiUsageRecord.fromJson(
            Map<String, dynamic>.from(json['usage'] as Map),
          )
        : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'content': content,
    'createdAt': Timestamp.fromDate(createdAt),
    'sourceRefs': sourceRefs,
    'searchTerms': _messageSearchTerms(content),
    if (retrievalPlan != null) 'retrievalPlan': retrievalPlan,
    if (usage != null) 'usage': usage!.toJson(),
  };
}

List<String> _messageSearchTerms(String value) {
  final compact = value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  final terms = <String>{};
  for (final word in compact.split(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'))) {
    if (word.isEmpty) continue;
    if (RegExp(r'^[a-z0-9]+$').hasMatch(word)) {
      terms.add(word.length > 40 ? word.substring(0, 40) : word);
      continue;
    }
    final chars = word.runes.map(String.fromCharCode).toList();
    terms.addAll(chars);
    for (var index = 0; index + 1 < chars.length; index++) {
      terms.add('${chars[index]}${chars[index + 1]}');
    }
    if (terms.length >= 120) break;
  }
  return terms.take(120).toList(growable: false);
}
