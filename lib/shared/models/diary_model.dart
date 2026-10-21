import 'package:cloud_firestore/cloud_firestore.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum Mood { great, good, neutral, bad, awful }

// ---------------------------------------------------------------------------
// DiaryEntry model
// ---------------------------------------------------------------------------

class DiaryEntry {
  const DiaryEntry({
    required this.id,
    required this.date,
    this.content = '',
    this.mood = Mood.neutral,
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

  /// The calendar day this entry belongs to (time component ignored for display
  /// but preserved for ordering).
  final DateTime date;

  /// Diary body text (may be markdown or plain text).
  final String content;

  /// User-selected mood for the day.
  final Mood mood;

  final List<String> images;
  final String? voiceUrl;
  final List<String> voiceUrls;

  final bool isDeleted;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String userId;

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

  factory DiaryEntry.fromJson(Map<String, dynamic> json) {
    return DiaryEntry(
      id: json['id'] as String? ?? '',
      date: _fromTs(json['date']),
      content: json['content'] as String? ?? '',
      mood: Mood.values.firstWhere(
        (e) => e.name == json['mood'],
        orElse: () => Mood.neutral,
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
      'date': Timestamp.fromDate(date),
      'content': content,
      'mood': mood.name,
      'images': images,
      'voiceUrl': voiceUrl,
      'voiceUrls': voiceUrls,
      'isDeleted': isDeleted,
      'deletedAt': deletedAt != null ? Timestamp.fromDate(deletedAt!) : null,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'userId': userId,
    };
  }

  // ---------------------------------------------------------------------------
  // copyWith
  // ---------------------------------------------------------------------------

  DiaryEntry copyWith({
    String? id,
    DateTime? date,
    String? content,
    Mood? mood,
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
    return DiaryEntry(
      id: id ?? this.id,
      date: date ?? this.date,
      content: content ?? this.content,
      mood: mood ?? this.mood,
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
      identical(this, other) || (other is DiaryEntry && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'DiaryEntry(id: $id, date: ${date.toIso8601String()}, mood: ${mood.name})';
}
