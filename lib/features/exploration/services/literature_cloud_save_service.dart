import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/shared/models/cloud_file_item.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:uuid/uuid.dart';

abstract interface class LiteratureCloudBackend {
  String? get currentUserId;

  Future<String> uploadPdf({
    required Stream<List<int>> stream,
    required int contentLength,
    required String remoteFileName,
    ValueChanged<double>? onProgress,
  });

  Future<void> addCloudFile(CloudFileItem item);

  Future<void> deleteUploadedFile(String webdavUrl);
}

class _ProductionLiteratureCloudBackend implements LiteratureCloudBackend {
  @override
  String? get currentUserId => FirebaseAuth.instance.currentUser?.uid;

  @override
  Future<String> uploadPdf({
    required Stream<List<int>> stream,
    required int contentLength,
    required String remoteFileName,
    ValueChanged<double>? onProgress,
  }) {
    return UploadService.instance.uploadCloudFile(
      stream: stream,
      contentLength: contentLength,
      remoteFileName: remoteFileName,
      contentType: 'application/pdf',
      onProgress: onProgress,
    );
  }

  @override
  Future<void> addCloudFile(CloudFileItem item) {
    return FirestoreService.instance.addCloudFile(item);
  }

  @override
  Future<void> deleteUploadedFile(String webdavUrl) {
    return UploadService.instance.deleteFile(webdavUrl);
  }
}

class LiteratureCloudSaveService {
  LiteratureCloudSaveService._(this._backend);

  static final LiteratureCloudSaveService instance =
      LiteratureCloudSaveService._(_ProductionLiteratureCloudBackend());

  @visibleForTesting
  LiteratureCloudSaveService.forTesting(LiteratureCloudBackend backend)
    : _backend = backend;

  final LiteratureCloudBackend _backend;

  Future<CloudFileItem> savePdf({
    required LiteraturePaper paper,
    required Uint8List bytes,
    ValueChanged<double>? onProgress,
  }) async {
    final userId = _backend.currentUserId;
    if (userId == null) throw StateError('请先登录后再保存文献。');
    if (bytes.isEmpty) throw StateError('PDF 内容为空，无法保存。');

    final id = const Uuid().v4();
    final remoteName = '$id.pdf';
    String? uploadedUrl;
    try {
      uploadedUrl = await _backend.uploadPdf(
        stream: Stream<List<int>>.value(bytes),
        contentLength: bytes.length,
        remoteFileName: remoteName,
        onProgress: onProgress,
      );
      final now = DateTime.now();
      final item = CloudFileItem(
        id: id,
        name: '${safeTitle(paper.title)}.pdf',
        webdavUrl: uploadedUrl,
        size: bytes.length,
        mimeType: 'application/pdf',
        createdAt: now,
        updatedAt: now,
        userId: userId,
      );
      await _backend.addCloudFile(item);
      return item;
    } catch (_) {
      if (uploadedUrl != null) {
        await _backend.deleteUploadedFile(uploadedUrl);
      }
      rethrow;
    }
  }

  @visibleForTesting
  static String safeTitle(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '文献';
    return cleaned.length <= 90 ? cleaned : cleaned.substring(0, 90).trim();
  }
}
