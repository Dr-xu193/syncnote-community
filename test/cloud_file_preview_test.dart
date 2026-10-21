import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/services/cloud_file_preview_service.dart';

void main() {
  group('cloud file preview parser', () {
    test('classifies supported formats without using a local file', () {
      expect(CloudFilePreviewParser.kindFor('png'), CloudPreviewKind.image);
      expect(CloudFilePreviewParser.kindFor('pdf'), CloudPreviewKind.pdf);
      expect(CloudFilePreviewParser.kindFor('docx'), CloudPreviewKind.docx);
      expect(
        CloudFilePreviewParser.kindFor('xlsx'),
        CloudPreviewKind.spreadsheet,
      );
      expect(
        CloudFilePreviewParser.kindFor('pptx'),
        CloudPreviewKind.presentation,
      );
      expect(CloudFilePreviewParser.kindFor('zip'), CloudPreviewKind.archive);
      expect(CloudFilePreviewParser.kindFor('exe'), CloudPreviewKind.info);
    });

    test('decodes UTF-8 and UTF-16 text from memory', () {
      expect(
        CloudFilePreviewParser.decodeText(utf8.encode('你好 SyncNote')),
        '你好 SyncNote',
      );
      expect(
        CloudFilePreviewParser.decodeText(
          Uint8List.fromList([0xff, 0xfe, 0x41, 0, 0x42, 0]),
        ),
        'AB',
      );
    });

    test('extracts docx text directly from zip bytes', () {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'word/document.xml',
            '<w:document><w:p><w:r><w:t>第一段</w:t></w:r></w:p>'
                '<w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:document>',
          ),
        );
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

      final text = CloudFilePreviewParser.extractOfficeText(bytes, 'docx');

      expect(text, contains('第一段'));
      expect(text, contains('第二段'));
    });

    test('extracts simple PDF text operators from memory', () {
      final bytes = Uint8List.fromList(
        latin1.encode('%PDF-1.4\nBT (Hello SyncNote) Tj ET\n%%EOF'),
      );

      final text = CloudFilePreviewParser.extractPdfText(bytes);

      expect(text, contains('Hello SyncNote'));
    });

    test('lists zip entries without extracting them to disk', () {
      final archive = Archive()
        ..addFile(ArchiveFile.string('folder/readme.txt', 'hello'))
        ..addFile(ArchiveFile.bytes('image.png', [1, 2, 3]));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

      final listing = CloudFilePreviewParser.listZipEntries(bytes);

      expect(listing, contains('folder/readme.txt'));
      expect(listing, contains('image.png'));
    });
  });
}
