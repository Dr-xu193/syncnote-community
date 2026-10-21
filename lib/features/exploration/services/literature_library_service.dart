import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/shared/models/cloud_file_item.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:uuid/uuid.dart';

abstract interface class LiteratureLibraryBackend {
  String? get currentUserId;

  Stream<List<LiteratureLibraryItem>> watch();

  Future<LiteratureLibraryItem?> load(String id);

  Future<void> save(LiteratureLibraryItem item);

  Future<void> delete(String id);

  Future<void> addNote(Note note);
}

class _ProductionLiteratureLibraryBackend implements LiteratureLibraryBackend {
  @override
  String? get currentUserId => FirebaseAuth.instance.currentUser?.uid;

  @override
  Stream<List<LiteratureLibraryItem>> watch() {
    return FirestoreService.instance.watchLiteratureLibrary();
  }

  @override
  Future<LiteratureLibraryItem?> load(String id) {
    return FirestoreService.instance.getLiteratureLibraryItem(id);
  }

  @override
  Future<void> save(LiteratureLibraryItem item) {
    return FirestoreService.instance.saveLiteratureLibraryItem(item);
  }

  @override
  Future<void> delete(String id) {
    return FirestoreService.instance.deleteLiteratureLibraryItem(id);
  }

  @override
  Future<void> addNote(Note note) {
    return FirestoreService.instance.addNote(note);
  }
}

class LiteratureLibraryService {
  LiteratureLibraryService._(this._backend);

  static final LiteratureLibraryService instance = LiteratureLibraryService._(
    _ProductionLiteratureLibraryBackend(),
  );

  @visibleForTesting
  LiteratureLibraryService.forTesting(LiteratureLibraryBackend backend)
    : _backend = backend;

  final LiteratureLibraryBackend _backend;

  Stream<List<LiteratureLibraryItem>> watch() => _backend.watch();

  Future<LiteratureLibraryItem?> load(LiteraturePaper paper) {
    return _backend.load(LiteratureLibraryItem.idForPaper(paper));
  }

  Future<LiteratureLibraryItem> setFavorite(
    LiteratureRecommendation recommendation,
    bool favorite,
  ) async {
    final id = LiteratureLibraryItem.idForPaper(recommendation.paper);
    final current = await _backend.load(id);
    if (!favorite &&
        current != null &&
        !current.hasSavedDeepAnalysis &&
        !current.hasCloudPdf &&
        current.note.trim().isEmpty &&
        current.tags.isEmpty &&
        current.annotations.isEmpty) {
      await _backend.delete(id);
      return current.copyWith(isFavorite: false, updatedAt: DateTime.now());
    }
    final now = DateTime.now();
    final updated =
        (current ??
                LiteratureLibraryItem(
                  id: id,
                  recommendation: recommendation,
                  createdAt: now,
                  updatedAt: now,
                ))
            .copyWith(
              recommendation: recommendation,
              isFavorite: favorite,
              updatedAt: now,
            );
    await _backend.save(updated);
    return updated;
  }

  Future<LiteratureLibraryItem> updateMetadata({
    required LiteratureRecommendation recommendation,
    required LiteratureReadingStatus status,
    required List<String> tags,
    required String note,
  }) async {
    final current = await _ensure(recommendation);
    final updated = current.copyWith(
      readingStatus: status,
      tags: tags
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .take(12)
          .toList(),
      note: note.trim(),
      updatedAt: DateTime.now(),
    );
    await _backend.save(updated);
    return updated;
  }

  Future<LiteratureLibraryItem> saveDeepAnalysis(
    LiteratureRecommendation recommendation,
    Map<String, dynamic> analysis,
  ) async {
    final current = await _ensure(recommendation);
    final updated = current.copyWith(
      isFavorite: true,
      deepAnalysis: Map<String, dynamic>.from(analysis),
      updatedAt: DateTime.now(),
    );
    await _backend.save(updated);
    return updated;
  }

  Future<LiteratureLibraryItem> attachPdf(
    LiteratureRecommendation recommendation,
    CloudFileItem file,
  ) async {
    final current = await _ensure(recommendation);
    final updated = current.copyWith(
      isFavorite: true,
      cloudPdfId: file.id,
      cloudPdfUrl: file.webdavUrl,
      updatedAt: DateTime.now(),
    );
    await _backend.save(updated);
    return updated;
  }

  Future<LiteratureLibraryItem> markOpened(
    LiteratureRecommendation recommendation,
  ) async {
    final current = await _ensure(recommendation);
    final now = DateTime.now();
    final updated = current.copyWith(lastOpenedAt: now, updatedAt: now);
    await _backend.save(updated);
    return updated;
  }

  Future<LiteratureLibraryItem> addAnnotation({
    required LiteratureRecommendation recommendation,
    required String quote,
    int? page,
    String note = '',
  }) async {
    final cleanQuote = quote.replaceAll(RegExp(r'\s+'), ' ').trim();
    final cleanNote = note.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleanQuote.length < 6) throw ArgumentError('摘录至少需要 6 个字符');
    final current = await _ensure(recommendation);
    if (current.annotations.length >= 80) {
      throw StateError('单篇文献最多保存 80 条摘录，请先整理到笔记。');
    }
    final now = DateTime.now();
    final annotation = LiteratureAnnotation(
      id: const Uuid().v4(),
      quote: cleanQuote.length > 1200
          ? cleanQuote.substring(0, 1200)
          : cleanQuote,
      page: page != null && page > 0 ? page : null,
      note: cleanNote.length > 800 ? cleanNote.substring(0, 800) : cleanNote,
      createdAt: now,
    );
    final updated = current.copyWith(
      isFavorite: true,
      readingStatus: current.readingStatus == LiteratureReadingStatus.unread
          ? LiteratureReadingStatus.reading
          : current.readingStatus,
      annotations: [...current.annotations, annotation],
      updatedAt: now,
      lastOpenedAt: now,
    );
    await _backend.save(updated);
    return updated;
  }

  Future<LiteratureLibraryItem> removeAnnotation({
    required LiteratureRecommendation recommendation,
    required String annotationId,
  }) async {
    final current = await _ensure(recommendation);
    final updated = current.copyWith(
      annotations: current.annotations
          .where((item) => item.id != annotationId)
          .toList(),
      updatedAt: DateTime.now(),
    );
    await _backend.save(updated);
    return updated;
  }

  Future<Note> saveAsNote(
    LiteratureRecommendation recommendation, {
    Map<String, dynamic>? deepAnalysis,
  }) async {
    final uid = _backend.currentUserId;
    if (uid == null) throw StateError('请先登录后再保存到笔记。');
    final paper = recommendation.paper;
    final now = DateTime.now();
    final buffer = StringBuffer()
      ..writeln('# ${paper.title}')
      ..writeln()
      ..writeln(
        '来源：${paper.venue.isEmpty ? paper.sourceNames.join('、') : paper.venue}',
      )
      ..writeln(
        '日期：${paper.publishedOn?.toIso8601String().split('T').first ?? '未知'}',
      )
      ..writeln('DOI：${paper.doi.isEmpty ? '无' : paper.doi}')
      ..writeln('原文：${paper.url}')
      ..writeln()
      ..writeln('## 核心解读')
      ..writeln(recommendation.coreSummary)
      ..writeln()
      ..writeln('## 原始摘要')
      ..writeln(paper.abstractText);
    final stored = await _backend.load(
      LiteratureLibraryItem.idForPaper(recommendation.paper),
    );
    if (stored != null && stored.annotations.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 研究摘录');
      for (final annotation in stored.annotations) {
        buffer
          ..writeln()
          ..writeln(
            '> ${annotation.quote}${annotation.page == null ? '' : '（第 ${annotation.page} 页）'}',
          );
        if (annotation.note.isNotEmpty) {
          buffer.writeln('个人理解：${annotation.note}');
        }
      }
    }
    if (deepAnalysis != null && deepAnalysis.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## AI 深度解读')
        ..writeln(const JsonEncoder.withIndent('  ').convert(deepAnalysis));
    }
    final note = Note(
      id: const Uuid().v4(),
      title: paper.title,
      content: buffer.toString(),
      contentType: NoteContentType.markdown,
      tags: const ['文献'],
      category: '文献研究',
      createdAt: now,
      updatedAt: now,
      userId: uid,
      aiKeywords: paper.keywords.take(12).toList(),
    );
    await _backend.addNote(note);
    return note;
  }

  Future<LiteratureLibraryItem> _ensure(
    LiteratureRecommendation recommendation,
  ) async {
    final id = LiteratureLibraryItem.idForPaper(recommendation.paper);
    final current = await _backend.load(id);
    if (current != null) return current;
    final now = DateTime.now();
    return LiteratureLibraryItem(
      id: id,
      recommendation: recommendation,
      createdAt: now,
      updatedAt: now,
    );
  }
}
