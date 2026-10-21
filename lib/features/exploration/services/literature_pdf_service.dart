import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';
import 'package:syncnote/features/exploration/models/exploration_models.dart';

class ParsedLiteraturePdf {
  const ParsedLiteraturePdf({
    required this.bytes,
    required this.pages,
    required this.totalPages,
    required this.extractedCharacters,
    required this.truncated,
  });

  final Uint8List bytes;
  final List<Map<String, dynamic>> pages;
  final int totalPages;
  final int extractedCharacters;
  final bool truncated;
}

class LiteraturePdfService {
  LiteraturePdfService({http.Client? client})
    : _client = client ?? http.Client();

  static const maxBytes = 30 * 1024 * 1024;
  static const maxCharacters = 180000;

  final http.Client _client;

  Future<ParsedLiteraturePdf> fetchAndParse(
    LiteraturePaper paper, {
    ValueChanged<double>? onProgress,
  }) async {
    final uri = Uri.tryParse(paper.pdfUrl);
    if (uri == null || uri.scheme != 'https') {
      throw StateError('这篇文献没有可安全读取的 HTTPS 开放 PDF');
    }
    final request = http.Request('GET', uri)
      ..headers['User-Agent'] =
          'SyncNote-Literature/1.0 (personal research assistant)';
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 45));
    if (response.statusCode != 200) {
      throw StateError('PDF 下载失败（${response.statusCode}）');
    }
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > maxBytes) {
      throw StateError('PDF 超过 30 MB 内存处理上限');
    }
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream) {
      received += chunk.length;
      if (received > maxBytes) throw StateError('PDF 超过 30 MB 内存处理上限');
      builder.add(chunk);
      if (declaredLength != null && declaredLength > 0) {
        onProgress?.call(received / declaredLength);
      }
    }
    final bytes = builder.takeBytes();
    if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
      throw StateError('服务器返回的内容不是有效 PDF');
    }

    final document = await PdfDocument.openData(
      bytes,
      sourceName: paper.pdfUrl,
    );
    try {
      final rawPages = <String>[];
      for (final page in document.pages) {
        final text = await page.loadStructuredText();
        rawPages.add(_cleanPage(text.fullText));
      }
      final cleanedPages = _removeRepeatedMargins(rawPages);
      final usefulCharacters = cleanedPages.fold<int>(
        0,
        (sum, page) => sum + page.length,
      );
      if (usefulCharacters < 280) {
        throw StateError('该 PDF 可能是扫描件，未提取到足够文字，当前版本不进行 OCR');
      }
      var remaining = maxCharacters;
      var truncated = false;
      final payload = <Map<String, dynamic>>[];
      for (var index = 0; index < cleanedPages.length; index++) {
        if (remaining <= 0) {
          truncated = true;
          break;
        }
        final text = cleanedPages[index];
        if (text.isEmpty) continue;
        final selected = text.length > remaining
            ? text.substring(0, remaining)
            : text;
        if (selected.length < text.length) truncated = true;
        payload.add({'page': index + 1, 'text': selected});
        remaining -= selected.length;
      }
      return ParsedLiteraturePdf(
        bytes: bytes,
        pages: payload,
        totalPages: document.pages.length,
        extractedCharacters: usefulCharacters,
        truncated: truncated,
      );
    } finally {
      await document.dispose();
    }
  }

  static String _cleanPage(String value) {
    return value
        .replaceAll('\u0000', '')
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n')
        .trim();
  }

  static List<String> _removeRepeatedMargins(List<String> pages) {
    if (pages.length < 3) return pages;
    final counts = <String, int>{};
    final linesByPage = pages.map((page) => page.split('\n')).toList();
    for (final lines in linesByPage) {
      final candidates = <String>{
        ...lines.take(3).map(_marginSignature),
        ...lines.reversed.take(3).map(_marginSignature),
      }..removeWhere((value) => value.isEmpty);
      for (final candidate in candidates) {
        counts[candidate] = (counts[candidate] ?? 0) + 1;
      }
    }
    final threshold = (pages.length * 0.6).ceil();
    final repeated = counts.entries
        .where((entry) => entry.value >= threshold)
        .map((entry) => entry.key)
        .toSet();
    if (repeated.isEmpty) return pages;
    return linesByPage.map((lines) {
      return lines
          .where((line) => !repeated.contains(_marginSignature(line)))
          .join('\n')
          .trim();
    }).toList();
  }

  static String _marginSignature(String value) {
    final normalized = value
        .toLowerCase()
        .replaceAll(RegExp(r'\d+'), '#')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.length < 4 || normalized.length > 160) return '';
    return normalized;
  }

  void dispose() => _client.close();
}
