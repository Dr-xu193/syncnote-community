import 'package:cloud_firestore/cloud_firestore.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum MemoSource { manual, shared }

// ---------------------------------------------------------------------------
// Memo model
// ---------------------------------------------------------------------------

class Memo {
  const Memo({
    required this.id,
    required this.content,
    this.isPinned = false,
    this.source = MemoSource.manual,
    this.images = const [],
    this.voiceUrl,
    this.voiceUrls = const [],
    this.isDeleted = false,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.userId,
  });

  final String id;

  /// Plain-text or markdown memo body.
  final String content;

  /// Whether the memo is pinned to the top of the list.
  final bool isPinned;

  /// How the memo was created: typed manually or shared from another app.
  final MemoSource source;

  final List<String> images;
  final String? voiceUrl;
  final List<String> voiceUrls;

  final bool isDeleted;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String userId;

  /// Single-field Firestore order key: pinned first, then newest first.
  String get displayOrderKey {
    final group = isPinned ? '0' : '1';
    final micros = createdAt.toUtc().microsecondsSinceEpoch.clamp(
      0,
      9999999999999999,
    );
    final descending = 9999999999999999 - micros;
    return '$group|${descending.toString().padLeft(16, '0')}|$id';
  }

  // ---------------------------------------------------------------------------
  // Serialisation helpers
  // ---------------------------------------------------------------------------

  static DateTime _fromTs(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.parse(value);
    return DateTime.now();
  }

  static DateTime? _fromTsNullable(dynamic value) {
    if (value == null) return null;
    return _fromTs(value);
  }

  factory Memo.fromJson(Map<String, dynamic> json) {
    return Memo(
      id: json['id'] as String? ?? '',
      content: json['content'] as String? ?? '',
      isPinned: json['isPinned'] as bool? ?? false,
      source: MemoSource.values.firstWhere(
        (e) => e.name == json['source'],
        orElse: () => MemoSource.manual,
      ),
      images: List<String>.from(json['images'] as List<dynamic>? ?? []),
      voiceUrl: json['voiceUrl'] as String?,
      voiceUrls: List<String>.from(json['voiceUrls'] as List<dynamic>? ?? []),
      isDeleted: json['isDeleted'] as bool? ?? false,
      deletedAt: _fromTsNullable(json['deletedAt']),
      createdAt: _fromTs(json['createdAt']),
      updatedAt: _fromTs(json['updatedAt']),
      userId: json['userId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'content': content,
      'isPinned': isPinned,
      'source': source.name,
      'images': images,
      'voiceUrl': voiceUrl,
      'voiceUrls': voiceUrls,
      'isDeleted': isDeleted,
      'deletedAt': deletedAt != null ? Timestamp.fromDate(deletedAt!) : null,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'userId': userId,
      'displayOrderKey': displayOrderKey,
    };
  }

  // ---------------------------------------------------------------------------
  // copyWith
  // ---------------------------------------------------------------------------

  Memo copyWith({
    String? id,
    String? content,
    bool? isPinned,
    MemoSource? source,
    List<String>? images,
    String? voiceUrl,
    List<String>? voiceUrls,
    bool? isDeleted,
    DateTime? deletedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? userId,
    bool clearDeletedAt = false,
    bool clearVoiceUrl = false,
  }) {
    return Memo(
      id: id ?? this.id,
      content: content ?? this.content,
      isPinned: isPinned ?? this.isPinned,
      source: source ?? this.source,
      images: images ?? this.images,
      voiceUrl: clearVoiceUrl ? null : (voiceUrl ?? this.voiceUrl),
      voiceUrls: voiceUrls ?? this.voiceUrls,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      userId: userId ?? this.userId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Memo && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Memo(id: $id, isPinned: $isPinned, source: ${source.name})';
}
