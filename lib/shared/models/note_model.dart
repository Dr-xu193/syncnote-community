import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum NoteContentType { richText, markdown }

// ---------------------------------------------------------------------------
// Note model
// ---------------------------------------------------------------------------

class Note {
  const Note({
    required this.id,
    required this.title,
    this.content = '',
    this.contentType = NoteContentType.richText,
    this.tags = const [],
    this.category = '',
    this.linkedNoteIds = const [],
    this.images = const [],
    this.voiceUrl,
    this.voiceUrls = const [],
    this.isArchived = false,
    this.isDeleted = false,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.userId,
    this.aiKeywords = const [],
    this.revision = 0,
  });

  final String id;

  /// Display title of the note.
  final String title;

  /// The note body; may contain rich-text JSON or markdown depending on
  /// [contentType].
  final String content;

  /// Encoding format of [content].
  final NoteContentType contentType;

  final List<String> tags;

  /// Optional free-form category/folder label.
  final String category;

  /// IDs of other notes that are linked (bi-directional links).
  final List<String> linkedNoteIds;

  final List<String> images;
  final String? voiceUrl;
  final List<String> voiceUrls;

  final bool isArchived;
  final bool isDeleted;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String userId;

  /// Semantic tags/keywords extracted by AI for wiki recommendations.
  final List<String> aiKeywords;

  /// Monotonic cloud revision used to detect multi-device save conflicts.
  final int revision;

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

  factory Note.fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      contentType: NoteContentType.values.firstWhere(
        (e) => e.name == json['contentType'],
        orElse: () => NoteContentType.richText,
      ),
      tags: List<String>.from(json['tags'] as List<dynamic>? ?? []),
      category: json['category'] as String? ?? '',
      linkedNoteIds: List<String>.from(
        json['linkedNoteIds'] as List<dynamic>? ?? [],
      ),
      images: List<String>.from(json['images'] as List<dynamic>? ?? []),
      voiceUrl: json['voiceUrl'] as String?,
      voiceUrls: List<String>.from(json['voiceUrls'] as List<dynamic>? ?? []),
      isArchived: json['isArchived'] as bool? ?? false,
      isDeleted: json['isDeleted'] as bool? ?? false,
      deletedAt: _fromTsNullable(json['deletedAt']),
      createdAt: _fromTs(json['createdAt']),
      updatedAt: _fromTs(json['updatedAt']),
      userId: json['userId'] as String? ?? '',
      aiKeywords: List<String>.from(json['aiKeywords'] as List<dynamic>? ?? []),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'contentType': contentType.name,
      'tags': tags,
      'category': category,
      'linkedNoteIds': linkedNoteIds,
      'images': images,
      'voiceUrl': voiceUrl,
      'voiceUrls': voiceUrls,
      'isArchived': isArchived,
      'isDeleted': isDeleted,
      'deletedAt': deletedAt != null ? Timestamp.fromDate(deletedAt!) : null,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'userId': userId,
      'aiKeywords': aiKeywords,
      'revision': revision,
    };
  }

  // ---------------------------------------------------------------------------
  // copyWith
  // ---------------------------------------------------------------------------

  Note copyWith({
    String? id,
    String? title,
    String? content,
    NoteContentType? contentType,
    List<String>? tags,
    String? category,
    List<String>? linkedNoteIds,
    List<String>? images,
    String? voiceUrl,
    List<String>? voiceUrls,
    bool? isArchived,
    bool? isDeleted,
    DateTime? deletedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? userId,
    List<String>? aiKeywords,
    int? revision,
    bool clearDeletedAt = false,
    bool clearVoiceUrl = false,
  }) {
    return Note(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      contentType: contentType ?? this.contentType,
      tags: tags ?? this.tags,
      category: category ?? this.category,
      linkedNoteIds: linkedNoteIds ?? this.linkedNoteIds,
      images: images ?? this.images,
      voiceUrl: clearVoiceUrl ? null : (voiceUrl ?? this.voiceUrl),
      voiceUrls: voiceUrls ?? this.voiceUrls,
      isArchived: isArchived ?? this.isArchived,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: clearDeletedAt ? null : (deletedAt ?? this.deletedAt),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      userId: userId ?? this.userId,
      aiKeywords: aiKeywords ?? this.aiKeywords,
      revision: revision ?? this.revision,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Note && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Note(id: $id, title: $title)';
}

// ---------------------------------------------------------------------------
// PositionedImage and VisualNoteContent models and serialization helpers
// ---------------------------------------------------------------------------

class PositionedImage {
  String url;
  double x;
  double y;
  double width;
  double height;

  PositionedImage({
    required this.url,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory PositionedImage.fromJson(Map<String, dynamic> json) {
    return PositionedImage(
      url: json['url'] as String? ?? '',
      x: (json['x'] as num?)?.toDouble() ?? 20.0,
      y: (json['y'] as num?)?.toDouble() ?? 100.0,
      width: (json['width'] as num?)?.toDouble() ?? 200.0,
      height: (json['height'] as num?)?.toDouble() ?? 200.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {'url': url, 'x': x, 'y': y, 'width': width, 'height': height};
  }
}

class PositionedText {
  String text;
  double x;
  double y;
  double width;
  double height;

  PositionedText({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory PositionedText.fromJson(Map<String, dynamic> json) {
    return PositionedText(
      text: json['text'] as String? ?? '',
      x: (json['x'] as num?)?.toDouble() ?? 20.0,
      y: (json['y'] as num?)?.toDouble() ?? 100.0,
      width: (json['width'] as num?)?.toDouble() ?? 200.0,
      height: (json['height'] as num?)?.toDouble() ?? 100.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {'text': text, 'x': x, 'y': y, 'width': width, 'height': height};
  }
}

class VisualNoteContent {
  String text;
  double canvasWidth;
  List<PositionedImage> images;
  List<PositionedText> texts;

  VisualNoteContent({
    required this.text,
    this.canvasWidth = 400.0,
    required this.images,
    required this.texts,
  });

  factory VisualNoteContent.fromJson(Map<String, dynamic> json) {
    final List<dynamic>? imgsJson = json['images'] as List<dynamic>?;
    final List<PositionedImage> imgs = imgsJson != null
        ? imgsJson
              .map(
                (item) =>
                    PositionedImage.fromJson(item as Map<String, dynamic>),
              )
              .toList()
        : [];
    final List<dynamic>? txtsJson = json['texts'] as List<dynamic>?;
    final List<PositionedText> txts = txtsJson != null
        ? txtsJson
              .map(
                (item) => PositionedText.fromJson(item as Map<String, dynamic>),
              )
              .toList()
        : [];
    return VisualNoteContent(
      text: json['text'] as String? ?? '',
      canvasWidth: (json['canvasWidth'] as num?)?.toDouble() ?? 400.0,
      images: imgs,
      texts: txts,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'canvasWidth': canvasWidth,
      'images': images.map((i) => i.toJson()).toList(),
      'texts': texts.map((t) => t.toJson()).toList(),
    };
  }
}

VisualNoteContent parseVisualNoteContent(
  String content,
  List<String> legacyImages,
) {
  final trimmed = content.trim();
  if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic> && decoded.containsKey('text')) {
        return VisualNoteContent.fromJson(decoded);
      }
    } catch (_) {}
  }

  // Backward compatibility: If content is JSON blocks (from our previous block-editor),
  // we can convert it to VisualNoteContent!
  if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
    try {
      final List<dynamic> parsed = jsonDecode(trimmed);
      final buffer = StringBuffer();
      final List<PositionedImage> imgs = [];
      double currentY = 100.0;
      for (final item in parsed) {
        final blockType = item['type'] as String? ?? 'text';
        if (blockType == 'text') {
          buffer.writeln(item['text'] as String? ?? '');
        } else if (blockType == 'image') {
          final url = item['url'] as String? ?? '';
          final blockWidthScale = (item['width'] as num?)?.toDouble() ?? 1.0;
          imgs.add(
            PositionedImage(
              url: url,
              x: 20.0,
              y: currentY,
              width: 300.0 * blockWidthScale,
              height: 300.0 * blockWidthScale,
            ),
          );
          currentY += 320.0;
        }
      }
      return VisualNoteContent(
        text: buffer.toString(),
        images: imgs,
        texts: [],
      );
    } catch (_) {}
  }

  // Fallback: treat the entire content as plain text. If there were legacyImages, position them.
  final List<PositionedImage> imgs = [];
  double currentY = 100.0;
  for (final imgUrl in legacyImages) {
    imgs.add(
      PositionedImage(
        url: imgUrl,
        x: 20.0,
        y: currentY,
        width: 200.0,
        height: 200.0,
      ),
    );
    currentY += 220.0;
  }
  return VisualNoteContent(text: content, images: imgs, texts: []);
}

String serializeVisualNoteContent(VisualNoteContent visualContent) {
  if (visualContent.images.isEmpty && visualContent.texts.isEmpty) {
    return visualContent.text;
  }
  return jsonEncode(visualContent.toJson());
}
