import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:syncnote/shared/models/note_model.dart';

class NoteVersion {
  const NoteVersion({
    required this.id,
    required this.note,
    required this.createdAt,
    required this.source,
  });

  final String id;
  final Note note;
  final DateTime createdAt;
  final String source;

  factory NoteVersion.fromJson(Map<String, dynamic> json) {
    final snapshot = Map<String, dynamic>.from(
      json['snapshot'] as Map? ?? const {},
    );
    return NoteVersion(
      id: json['id'] as String? ?? '',
      note: Note.fromJson(snapshot),
      createdAt: (json['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      source: json['source'] as String? ?? 'save',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'snapshot': note.toJson(),
    'createdAt': Timestamp.fromDate(createdAt),
    'source': source,
  };
}
