import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';
import 'package:syncnote/shared/services/firestore_service.dart';

class ExplorationRepository {
  ExplorationRepository._();

  static final ExplorationRepository instance = ExplorationRepository._();

  List<KnowledgeCardItem>? _knowledge;
  List<PuzzleCase>? _puzzles;
  List<NewsSourceDefinition>? _newsSources;
  Map<String, dynamic>? _keywordRules;
  Map<String, dynamic>? _rankingRules;

  Future<List<KnowledgeCardItem>> loadKnowledge() async {
    if (_knowledge != null) return _knowledge!;
    final data = await _loadObject('assets/exploration/knowledge_v1.json');
    _knowledge = data.entries
        .map(
          (entry) =>
              KnowledgeCardItem(term: entry.key, content: '${entry.value}'),
        )
        .toList(growable: false);
    return _knowledge!;
  }

  Future<List<PuzzleCase>> loadPuzzles() async {
    if (_puzzles != null) return _puzzles!;
    final data = await _loadObject('assets/exploration/puzzles_v1.json');
    _puzzles = data.entries
        .map(
          (entry) => PuzzleCase.fromJson(
            entry.key,
            Map<String, dynamic>.from(entry.value as Map),
          ),
        )
        .toList(growable: false);
    return _puzzles!;
  }

  Future<List<NewsSourceDefinition>> loadNewsSources() async {
    if (_newsSources != null) return _newsSources!;
    final data = await _loadObject('assets/exploration/news_sources.json');
    _newsSources = (data['sources'] as List? ?? const [])
        .map(
          (item) => NewsSourceDefinition.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
    return _newsSources!;
  }

  Future<Map<String, dynamic>> loadKeywordRules() async {
    return _keywordRules ??= await _loadObject(
      'assets/exploration/keyword_rules.json',
    );
  }

  Future<Map<String, dynamic>> loadRankingRules() async {
    return _rankingRules ??= await _loadObject(
      'assets/exploration/ranking_rules.json',
    );
  }

  Future<Map<String, dynamic>> _loadObject(String path) async {
    final raw = await rootBundle.loadString(path);
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }
}

abstract interface class ExplorationCloudBackend {
  Future<Map<String, dynamic>?> load(String id);

  Future<void> save(String id, Map<String, dynamic> data);

  Future<void> delete(String id);
}

class _ProductionExplorationCloudBackend implements ExplorationCloudBackend {
  @override
  Future<Map<String, dynamic>?> load(String id) {
    return FirestoreService.instance.loadExplorationState(id);
  }

  @override
  Future<void> save(String id, Map<String, dynamic> data) {
    return FirestoreService.instance.saveExplorationState(id, data);
  }

  @override
  Future<void> delete(String id) {
    return FirestoreService.instance.deleteExplorationState(id);
  }
}

/// Cloud-first personal exploration state with a process-memory fallback.
///
/// No knowledge progress, puzzle progress, literature report, or news body is
/// written to an app-local file. Firestore holds personal state; public news
/// bodies are cached only for the current process to avoid oversized documents.
class ExplorationStateStore {
  ExplorationStateStore._(this._cloud);

  static final ExplorationStateStore instance = ExplorationStateStore._(
    _ProductionExplorationCloudBackend(),
  );

  @visibleForTesting
  ExplorationStateStore.forTesting(ExplorationCloudBackend cloud)
    : _cloud = cloud;

  final ExplorationCloudBackend _cloud;
  final Set<String> _memorySeen = {};
  final Map<String, PuzzleProgress> _memoryPuzzleProgress = {};
  final Map<String, LiteratureDiscoveryReport> _memoryLiteratureReports = {};
  List<ExplorationNewsArticle> _memoryNews = const [];
  String? _memoryNewsDay;

  Future<Set<String>> loadSeenKnowledge() async {
    try {
      final cloud = await _cloud.load('knowledge');
      final remote = List<String>.from(
        cloud?['seen'] as List? ?? const [],
      ).toSet();
      final hasPendingMemory = _memorySeen.difference(remote).isNotEmpty;
      _memorySeen.addAll(remote);
      if (hasPendingMemory) {
        await _cloud.save('knowledge', {'seen': _memorySeen.toList()..sort()});
      }
    } catch (_) {
      // The current process can continue while temporarily offline.
    }
    return Set<String>.from(_memorySeen);
  }

  Future<void> markKnowledgeSeen(String term) async {
    _memorySeen.add(term);
    final sorted = _memorySeen.toList()..sort();
    try {
      await _cloud.save('knowledge', {'seen': sorted});
    } catch (_) {
      // Keep the pending state in memory for this process.
    }
  }

  Future<Map<String, PuzzleProgress>> loadPuzzleProgress() async {
    try {
      final cloud = await _cloud.load('puzzles');
      final cloudItems = Map<String, dynamic>.from(
        cloud?['items'] as Map? ?? const {},
      );
      var hasPendingMemory = false;
      for (final entry in cloudItems.entries) {
        final remote = PuzzleProgress.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        final local = _memoryPuzzleProgress[entry.key];
        final merged = _newerPuzzleProgress(local, remote);
        if (local != null && !_samePuzzleProgress(merged, remote)) {
          hasPendingMemory = true;
        }
        _memoryPuzzleProgress[entry.key] = merged;
      }
      if (_memoryPuzzleProgress.keys.any(
        (key) => !cloudItems.containsKey(key),
      )) {
        hasPendingMemory = true;
      }
      if (hasPendingMemory) {
        await _cloud.save('puzzles', {
          'items': _memoryPuzzleProgress.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
        });
      }
    } catch (_) {
      // Return only the current process state while offline.
    }
    return Map<String, PuzzleProgress>.from(_memoryPuzzleProgress);
  }

  Future<void> savePuzzleProgress(
    String caseId,
    PuzzleProgress progress,
  ) async {
    _memoryPuzzleProgress[caseId] = progress;
    try {
      await _cloud.save('puzzles', {
        'items': _memoryPuzzleProgress.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      });
    } catch (_) {
      // Keep the pending state in memory for this process.
    }
  }

  Future<LiteratureDiscoveryReport?> loadLiteratureReport(
    String query,
    DateTime day,
  ) async {
    final current = await loadCurrentLiteratureReport(day);
    if (current == null ||
        current.query.original.trim().toLowerCase() !=
            query.trim().toLowerCase()) {
      return null;
    }
    return current;
  }

  Future<LiteratureDiscoveryReport?> loadCurrentLiteratureReport(
    DateTime day,
  ) async {
    const id = 'literature_today';
    try {
      final cloud = await _cloud.load(id);
      if (cloud != null && cloud['day'] != _dayStamp(day)) {
        await _cloud.delete(id);
        _memoryLiteratureReports.remove(id);
        return null;
      }
      final report = Map<String, dynamic>.from(
        cloud?['report'] as Map? ?? const {},
      );
      if (report.isNotEmpty) {
        final parsed = LiteratureDiscoveryReport.fromJson(
          report,
        ).copyWith(reportCached: true);
        _memoryLiteratureReports[id] = parsed;
        return parsed;
      }
      final pending = _memoryLiteratureReports[id];
      if (pending != null) {
        await _cloud.save(id, {
          'day': _dayStamp(day),
          'query': pending.query.original,
          'report': pending.toJson(),
        });
        return pending.copyWith(reportCached: true);
      }
    } catch (_) {
      // Fall through to process memory while offline.
    }
    return _memoryLiteratureReports[id]?.copyWith(reportCached: true);
  }

  Future<void> saveLiteratureReport(
    LiteratureDiscoveryReport report,
    DateTime day,
  ) async {
    const id = 'literature_today';
    _memoryLiteratureReports[id] = report.copyWith(reportCached: true);
    try {
      await _cloud.save(id, {
        'day': _dayStamp(day),
        'query': report.query.original,
        'report': report.toJson(),
      });
    } catch (_) {
      // Keep the report in process memory; no local file is created.
    }
  }

  Future<void> clearExpiredLiteratureReport(DateTime day) async {
    const id = 'literature_today';
    try {
      final cloud = await _cloud.load(id);
      if (cloud != null && cloud['day'] != _dayStamp(day)) {
        await _cloud.delete(id);
        _memoryLiteratureReports.remove(id);
      }
    } catch (_) {
      // Cleanup is idempotent and will retry on the next module entry.
    }
  }

  Future<List<ExplorationNewsArticle>> loadNews(DateTime day) async {
    return _memoryNewsDay == _dayStamp(day)
        ? List<ExplorationNewsArticle>.from(_memoryNews)
        : const [];
  }

  Future<void> saveNews(
    List<ExplorationNewsArticle> articles,
    DateTime day,
  ) async {
    _memoryNewsDay = _dayStamp(day);
    _memoryNews = List<ExplorationNewsArticle>.unmodifiable(articles);
  }

  PuzzleProgress _newerPuzzleProgress(
    PuzzleProgress? local,
    PuzzleProgress remote,
  ) {
    if (local == null) return remote;
    return PuzzleProgress(
      currentStage: local.currentStage > remote.currentStage
          ? local.currentStage
          : remote.currentStage,
      attempts: local.attempts > remote.attempts
          ? local.attempts
          : remote.attempts,
      cleared: local.cleared || remote.cleared,
    );
  }

  bool _samePuzzleProgress(PuzzleProgress a, PuzzleProgress b) {
    return a.currentStage == b.currentStage &&
        a.attempts == b.attempts &&
        a.cleared == b.cleared;
  }

  String _dayStamp(DateTime value) {
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
