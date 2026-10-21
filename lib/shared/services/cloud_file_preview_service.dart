import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' show parseFragment;
import 'package:syncnote/shared/models/cloud_file_item.dart';
import 'package:syncnote/shared/services/upload_service.dart';

enum CloudPreviewKind {
  image,
  pdf,
  docx,
  markdown,
  text,
  spreadsheet,
  presentation,
  archive,
  audio,
  info,
}

class CloudFilePreviewData {
  const CloudFilePreviewData({
    required this.kind,
    this.bytes,
    this.text,
    this.message,
  });

  final CloudPreviewKind kind;
  final Uint8List? bytes;
  final String? text;
  final String? message;
}

class CloudFilePreviewService {
  CloudFilePreviewService._();

  static final CloudFilePreviewService instance = CloudFilePreviewService._();
  static const int maxPreviewBytes = 40 * 1024 * 1024;

  Future<CloudFilePreviewData> load(
    CloudFileItem file, {
    ValueChanged<double>? onProgress,
  }) async {
    final kind = CloudFilePreviewParser.kindFor(file.extension);
    if (kind == CloudPreviewKind.info) {
      return const CloudFilePreviewData(
        kind: CloudPreviewKind.info,
        message: '此格式暂时无法在完全不生成本地文件的情况下直接渲染。',
      );
    }
    if (file.size > maxPreviewBytes) {
      return const CloudFilePreviewData(
        kind: CloudPreviewKind.info,
        message: '文件超过40 MB纯内存预览上限。你仍然可以选择“保存到本地”。',
      );
    }

    final bytes = await UploadService.instance.downloadCloudFileBytes(
      file.webdavUrl,
      maxBytes: maxPreviewBytes,
      onProgress: onProgress,
    );
    return switch (kind) {
      CloudPreviewKind.image ||
      CloudPreviewKind.audio ||
      CloudPreviewKind.pdf ||
      CloudPreviewKind.docx ||
      CloudPreviewKind.spreadsheet ||
      CloudPreviewKind.presentation => CloudFilePreviewData(
        kind: kind,
        bytes: bytes,
      ),
      CloudPreviewKind.markdown ||
      CloudPreviewKind.text => CloudFilePreviewData(
        kind: kind,
        text: CloudFilePreviewParser.decodeText(bytes),
      ),
      CloudPreviewKind.archive => CloudFilePreviewData(
        kind: kind,
        text: CloudFilePreviewParser.listZipEntries(bytes),
      ),
      CloudPreviewKind.info => const CloudFilePreviewData(
        kind: CloudPreviewKind.info,
      ),
    };
  }
}

abstract final class CloudFilePreviewParser {
  static const _images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};
  static const _texts = {
    'txt',
    'log',
    'json',
    'csv',
    'xml',
    'html',
    'htm',
    'yaml',
    'yml',
    'dart',
    'js',
    'ts',
    'py',
    'java',
    'kt',
    'swift',
    'c',
    'cpp',
    'h',
    'css',
    'sql',
    'svg',
  };
  static const _audio = {'mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'};

  static CloudPreviewKind kindFor(String extension) {
    final ext = extension.toLowerCase();
    if (_images.contains(ext)) return CloudPreviewKind.image;
    if (ext == 'pdf') return CloudPreviewKind.pdf;
    if (ext == 'docx') return CloudPreviewKind.docx;
    if (ext == 'md') return CloudPreviewKind.markdown;
    if (_texts.contains(ext)) return CloudPreviewKind.text;
    if (ext == 'xlsx') return CloudPreviewKind.spreadsheet;
    if (ext == 'pptx') return CloudPreviewKind.presentation;
    if (ext == 'zip') return CloudPreviewKind.archive;
    if (_audio.contains(ext)) return CloudPreviewKind.audio;
    return CloudPreviewKind.info;
  }

  static String decodeText(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(units);
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    final offset =
        bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf
        ? 3
        : 0;
    return utf8.decode(bytes.sublist(offset), allowMalformed: true);
  }

  static String extractOfficeText(Uint8List bytes, String extension) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final ext = extension.toLowerCase();
    final files = archive.files.where((file) {
      if (!file.isFile) return false;
      final name = file.name.toLowerCase();
      return switch (ext) {
        'docx' =>
          name == 'word/document.xml' ||
              name.startsWith('word/header') ||
              name.startsWith('word/footer'),
        'xlsx' =>
          name == 'xl/sharedstrings.xml' ||
              name.startsWith('xl/worksheets/sheet'),
        'pptx' => name.startsWith('ppt/slides/slide') && name.endsWith('.xml'),
        _ => false,
      };
    }).toList()..sort((a, b) => a.name.compareTo(b.name));

    final output = StringBuffer();
    for (final file in files) {
      final xml = decodeText(
        file.content,
      ).replaceAll(RegExp(r'</(?:w:p|a:p|row|si)>'), '<t>\n</t>');
      final matches = RegExp(
        r'<(?:w:t|a:t|t|v)(?:\s[^>]*)?>(.*?)</(?:w:t|a:t|t|v)>',
        dotAll: true,
      ).allMatches(xml);
      final section = StringBuffer();
      for (final match in matches) {
        final value = parseFragment(match.group(1) ?? '').text ?? '';
        if (value == '\n') {
          section.writeln();
        } else if (value.isNotEmpty) {
          section.write(value);
          section.write(' ');
        }
      }
      final text = section.toString().trim();
      if (text.isEmpty) continue;
      if (output.isNotEmpty) output.write('\n\n');
      if (files.length > 1) output.writeln('【${file.name}】');
      output.write(text);
    }
    return output.isEmpty ? '没有提取到可显示的文字内容。' : output.toString();
  }

  static String extractPdfText(Uint8List bytes) {
    final source = latin1.decode(bytes, allowInvalid: true);
    final output = <String>[];

    void collect(String content) {
      for (final match in RegExp(
        r'\((?:\\.|[^\\)])*\)\s*Tj',
        dotAll: true,
      ).allMatches(content)) {
        final token = match.group(0)!;
        output.add(
          _decodePdfLiteral(token.substring(1, token.lastIndexOf(')'))),
        );
      }
      for (final array in RegExp(
        r'\[(.*?)\]\s*TJ',
        dotAll: true,
      ).allMatches(content)) {
        final body = array.group(1) ?? '';
        final line = RegExp(r'\((?:\\.|[^\\)])*\)', dotAll: true)
            .allMatches(body)
            .map((match) {
              final token = match.group(0)!;
              return _decodePdfLiteral(token.substring(1, token.length - 1));
            })
            .join();
        if (line.isNotEmpty) output.add(line);
      }
    }

    collect(source);
    final cleaned = output
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet()
        .join('\n');
    return cleaned.isEmpty
        ? '该PDF没有可直接提取的文字，可能是扫描件或使用了嵌入字体编码。为了不创建临时文件，本次不进行页面栅格化。'
        : cleaned;
  }

  static String _decodePdfLiteral(String value) {
    final buffer = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final current = value[i];
      if (current != '\\' || i + 1 >= value.length) {
        buffer.write(current);
        continue;
      }
      final next = value[++i];
      switch (next) {
        case 'n':
          buffer.write('\n');
        case 'r':
          buffer.write('\r');
        case 't':
          buffer.write('\t');
        case 'b':
          buffer.write('\b');
        case 'f':
          buffer.write('\f');
        case '(' || ')' || '\\':
          buffer.write(next);
        default:
          if (RegExp(r'[0-7]').hasMatch(next)) {
            var octal = next;
            while (octal.length < 3 &&
                i + 1 < value.length &&
                RegExp(r'[0-7]').hasMatch(value[i + 1])) {
              octal += value[++i];
            }
            buffer.writeCharCode(int.parse(octal, radix: 8));
          } else {
            buffer.write(next);
          }
      }
    }
    return buffer.toString();
  }

  static String listZipEntries(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.files.isEmpty) return '压缩包为空。';
    return archive.files
        .map((file) {
          final suffix = file.isFile ? _formatBytes(file.size) : '文件夹';
          return '${file.name}    $suffix';
        })
        .join('\n');
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
