import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/models/cloud_file_item.dart';

void main() {
  group('cloud file rules', () {
    test('keeps only safe extensions for remote object names', () {
      expect(CloudFileRules.safeRemoteExtension('report.PDF'), '.pdf');
      expect(CloudFileRules.safeRemoteExtension('archive.tar.gz'), '.gz');
      expect(CloudFileRules.safeRemoteExtension('README'), isEmpty);
      expect(CloudFileRules.safeRemoteExtension('unsafe.超长格式'), isEmpty);
    });

    test('maps common types and accepts unknown binary files', () {
      expect(CloudFileRules.mimeTypeForName('photo.jpg'), 'image/jpeg');
      expect(CloudFileRules.mimeTypeForName('notes.md'), 'text/markdown');
      expect(
        CloudFileRules.mimeTypeForName('anything.custom'),
        'application/octet-stream',
      );
    });
  });
}
