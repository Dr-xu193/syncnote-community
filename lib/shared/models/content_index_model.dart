import 'package:cloud_firestore/cloud_firestore.dart';

enum IndexedContentType { task, note, memo, diary }

class ContentIndexEntry {
  const ContentIndexEntry({
    required this.id,
    required this.sourceId,
    required this.type,
    required this.title,
    required this.summary,
    required this.searchTerms,
    required this.tags,
    required this.category,
    required this.isArchived,
    required this.isDeleted,
    required this.primaryDate,
    required this.updatedAt,
    this.isColdArchived = false,
    this.archiveId,
    this.coldArchiveUrl,
  });

  final String id;
  final String sourceId;
  final IndexedContentType type;
  final String title;
  final String summary;
  final List<String> searchTerms;
  final List<String> tags;
  final String category;
  final bool isArchived;
  final bool isDeleted;
  final DateTime primaryDate;
  final DateTime updatedAt;
  final bool isColdArchived;
  final String? archiveId;
  final String? coldArchiveUrl;

  factory ContentIndexEntry.fromJson(Map<String, dynamic> json) {
    DateTime date(Object? value) {
      if (value is Timestamp) return value.toDate();
      if (value is String) return DateTime.tryParse(value) ?? DateTime(1970);
      return DateTime(1970);
    }

    return ContentIndexEntry(
      id: json['id'] as String? ?? '',
      sourceId: json['sourceId'] as String? ?? '',
      type: IndexedContentType.values.firstWhere(
        (value) => value.name == json['type'],
        orElse: () => IndexedContentType.note,
      ),
      title: json['title'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      searchTerms: List<String>.from(
        json['searchTerms'] as List<dynamic>? ?? const [],
      ),
      tags: List<String>.from(json['tags'] as List<dynamic>? ?? const []),
      category: json['category'] as String? ?? '',
      isArchived: json['isArchived'] as bool? ?? false,
      isDeleted: json['isDeleted'] as bool? ?? false,
      primaryDate: date(json['primaryDate']),
      updatedAt: date(json['updatedAt']),
      isColdArchived: json['isColdArchived'] as bool? ?? false,
      archiveId: json['archiveId'] as String?,
      coldArchiveUrl: json['coldArchiveUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'type': type.name,
    'title': title,
    'summary': summary,
    'searchTerms': searchTerms,
    'tags': tags,
    'category': category,
    'isArchived': isArchived,
    'isDeleted': isDeleted,
    'primaryDate': Timestamp.fromDate(primaryDate),
    'updatedAt': Timestamp.fromDate(updatedAt),
    'isColdArchived': isColdArchived,
    'archiveId': archiveId,
    'coldArchiveUrl': coldArchiveUrl,
  };
}
