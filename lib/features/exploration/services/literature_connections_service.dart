import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:syncnote/features/exploration/models/exploration_models.dart';

class LiteratureConnectionsReport {
  const LiteratureConnectionsReport({
    required this.references,
    required this.citations,
    required this.related,
    required this.provider,
    this.errors = const [],
  });

  final List<LiteraturePaper> references;
  final List<LiteraturePaper> citations;
  final List<LiteraturePaper> related;
  final String provider;
  final List<String> errors;
}

/// Loads a small, on-demand citation neighbourhood. Nothing returned by this
/// service is persisted automatically; only papers the user explicitly saves
/// enter the research library.
class LiteratureConnectionsService {
  LiteratureConnectionsService({http.Client? client})
    : _client = client ?? http.Client();

  static const _headers = {
    'User-Agent': 'SyncNoteLiterature/1.0 (personal research client)',
  };

  final http.Client _client;

  Future<LiteratureConnectionsReport> load(
    LiteraturePaper paper, {
    int limit = 10,
  }) async {
    final root = await _resolveOpenAlexWork(paper);
    final openAlexId = _shortOpenAlexId('${root['id'] ?? ''}');
    if (openAlexId.isEmpty) {
      throw StateError('OpenAlex 未能确认该文献，无法生成可靠的引用脉络。');
    }
    final referenceIds = (root['referenced_works'] as List? ?? const [])
        .map((value) => _shortOpenAlexId('$value'))
        .where((value) => value.isNotEmpty)
        .take(limit)
        .toList();
    final relatedIds = (root['related_works'] as List? ?? const [])
        .map((value) => _shortOpenAlexId('$value'))
        .where((value) => value.isNotEmpty)
        .take(limit)
        .toList();
    final errors = <String>[];

    Future<List<LiteraturePaper>> guarded(
      String label,
      Future<List<LiteraturePaper>> Function() action,
    ) async {
      try {
        return await action();
      } catch (error) {
        errors.add('$label：$error');
        return const [];
      }
    }

    final results = await Future.wait([
      guarded('参考文献', () => _fetchByIds(referenceIds)),
      guarded(
        '后续引用',
        () => _fetchList(
          Uri.https('api.openalex.org', '/works', {
            'filter': 'cites:$openAlexId',
            'sort': 'publication_date:desc',
            'per_page': '${limit.clamp(1, 25)}',
          }),
        ),
      ),
      guarded('相似研究', () => _fetchByIds(relatedIds)),
    ]);
    return LiteratureConnectionsReport(
      references: results[0],
      citations: results[1],
      related: results[2],
      provider: 'OpenAlex',
      errors: errors,
    );
  }

  Future<Map<String, dynamic>> _resolveOpenAlexWork(
    LiteraturePaper paper,
  ) async {
    if (paper.openAlexId.trim().isNotEmpty) {
      return _getJson(
        Uri.parse('https://api.openalex.org/works/${paper.openAlexId.trim()}'),
      );
    }
    final doi = normalizeDoi(paper.doi);
    if (doi.isNotEmpty) {
      return _getJson(
        Uri.parse('https://api.openalex.org/works/https://doi.org/$doi'),
      );
    }
    if (paper.arxivId.trim().isNotEmpty) {
      final data = await _getJson(
        Uri.https('api.openalex.org', '/works', {
          'filter':
              'locations.landing_page_url:https://arxiv.org/abs/${paper.arxivId}',
          'per_page': '1',
        }),
      );
      final rows = data['results'] as List? ?? const [];
      if (rows.isNotEmpty) return Map<String, dynamic>.from(rows.first as Map);
    }
    final data = await _getJson(
      Uri.https('api.openalex.org', '/works', {
        'search': paper.title,
        'per_page': '3',
      }),
    );
    final normalized = normalizePaperTitle(paper.title);
    final rows = (data['results'] as List? ?? const [])
        .map((row) => Map<String, dynamic>.from(row as Map))
        .where(
          (row) => normalizePaperTitle('${row['title'] ?? ''}') == normalized,
        )
        .toList();
    if (rows.isEmpty) throw StateError('未找到可核验的 OpenAlex 记录');
    return rows.first;
  }

  Future<List<LiteraturePaper>> _fetchByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    return _fetchList(
      Uri.https('api.openalex.org', '/works', {
        'filter': 'openalex_id:${ids.take(25).join('|')}',
        'per_page': '${ids.length.clamp(1, 25)}',
      }),
    );
  }

  Future<List<LiteraturePaper>> _fetchList(Uri uri) async {
    final data = await _getJson(uri);
    return (data['results'] as List? ?? const [])
        .map((raw) => _paper(Map<String, dynamic>.from(raw as Map)))
        .where((paper) => paper.title.trim().isNotEmpty)
        .toList();
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    http.Response? response;
    for (var attempt = 0; attempt < 2; attempt++) {
      response = await _client
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 429 || attempt == 1) break;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (response == null || response.statusCode != 200) {
      throw StateError('${uri.host} HTTP ${response?.statusCode ?? '未知'}');
    }
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map,
    );
  }

  static LiteraturePaper _paper(Map<String, dynamic> item) {
    final title = _clean(item['title']);
    final primary = Map<String, dynamic>.from(
      item['primary_location'] as Map? ?? const {},
    );
    final bestOa = Map<String, dynamic>.from(
      item['best_oa_location'] as Map? ?? const {},
    );
    final source = Map<String, dynamic>.from(
      primary['source'] as Map? ?? const {},
    );
    final openAccess = Map<String, dynamic>.from(
      item['open_access'] as Map? ?? const {},
    );
    final openAlexId = _shortOpenAlexId('${item['id'] ?? ''}');
    final pdfUrl = '${bestOa['pdf_url'] ?? primary['pdf_url'] ?? ''}';
    return LiteraturePaper(
      id: 'openalex_$openAlexId',
      title: title,
      abstractText: _openAlexAbstract(item['abstract_inverted_index'] as Map?),
      authors: (item['authorships'] as List? ?? const [])
          .map((row) {
            final author = Map<String, dynamic>.from(
              Map<String, dynamic>.from(row as Map)['author'] as Map? ??
                  const {},
            );
            return _clean(author['display_name']);
          })
          .where((value) => value.isNotEmpty)
          .toList(),
      publishedOn: DateTime.tryParse('${item['publication_date'] ?? ''}'),
      venue: _clean(source['display_name']),
      doi: normalizeDoi('${item['doi'] ?? ''}'),
      url:
          '${bestOa['landing_page_url'] ?? primary['landing_page_url'] ?? item['doi'] ?? ''}',
      pdfUrl: pdfUrl,
      keywords: (item['topics'] as List? ?? const [])
          .take(10)
          .map(
            (row) =>
                _clean(Map<String, dynamic>.from(row as Map)['display_name']),
          )
          .where((value) => value.isNotEmpty)
          .toList(),
      citationCount: (item['cited_by_count'] as num?)?.toInt() ?? 0,
      sourceNames: const ['OpenAlex'],
      isOpenAccess: openAccess['is_oa'] == true || pdfUrl.isNotEmpty,
      openAlexId: openAlexId,
      referenceCount: (item['referenced_works_count'] as num?)?.toInt() ?? 0,
      publicationType: _clean(item['type']),
      openAccessStatus: _clean(openAccess['oa_status']),
      isRetracted: item['is_retracted'] == true,
    );
  }

  static String _openAlexAbstract(Map? raw) {
    if (raw == null) return '';
    final positioned = <(int, String)>[];
    for (final entry in raw.entries) {
      for (final offset in entry.value as List? ?? const []) {
        positioned.add(((offset as num).toInt(), '${entry.key}'));
      }
    }
    positioned.sort((left, right) => left.$1.compareTo(right.$1));
    return positioned.map((item) => item.$2).join(' ');
  }

  static String _shortOpenAlexId(String value) {
    return value
        .trim()
        .split('/')
        .lastWhere((part) => part.startsWith('W'), orElse: () => '');
  }

  static String _clean(Object? value) => html_parser
      .parseFragment('${value ?? ''}')
      .text!
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  void dispose() => _client.close();
}
