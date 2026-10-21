import 'package:cloud_firestore/cloud_firestore.dart';

class CloudFileItem {
  const CloudFileItem({
    required this.id,
    required this.name,
    required this.webdavUrl,
    required this.size,
    required this.mimeType,
    required this.createdAt,
    required this.updatedAt,
    required this.userId,
  });

  final String id;
  final String name;
  final String webdavUrl;
  final int size;
  final String mimeType;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String userId;

  String get extension {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  factory CloudFileItem.fromJson(Map<String, dynamic> json) {
    DateTime readDate(Object? value) {
      if (value is Timestamp) return value.toDate();
      if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
      return DateTime.now();
    }

    return CloudFileItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名文件',
      webdavUrl: json['webdavUrl'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      createdAt: readDate(json['createdAt']),
      updatedAt: readDate(json['updatedAt']),
      userId: json['userId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'webdavUrl': webdavUrl,
    'size': size,
    'mimeType': mimeType,
    'createdAt': Timestamp.fromDate(createdAt),
    'updatedAt': Timestamp.fromDate(updatedAt),
    'userId': userId,
  };
}

abstract final class CloudFileRules {
  static String safeRemoteExtension(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return '';
    final extension = fileName.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,16}$').hasMatch(extension) ? extension : '';
  }

  static String mimeTypeForName(String fileName) {
    final extension = safeRemoteExtension(fileName);
    return switch (extension) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.svg' => 'image/svg+xml',
      '.pdf' => 'application/pdf',
      '.txt' => 'text/plain',
      '.md' => 'text/markdown',
      '.json' => 'application/json',
      '.mp3' => 'audio/mpeg',
      '.m4a' => 'audio/mp4',
      '.wav' => 'audio/wav',
      '.mp4' => 'video/mp4',
      '.zip' => 'application/zip',
      '.docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      _ => 'application/octet-stream',
    };
  }
}
