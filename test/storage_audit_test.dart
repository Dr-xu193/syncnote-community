import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/services/storage_audit_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';

void main() {
  test('Firestore byte estimate handles timestamps and nested values', () {
    final bytes = StorageAuditService.estimateDocumentBytes('memo-1', {
      'content': '中文内容',
      'nested': {
        'enabled': true,
        'values': [1, 2, 3],
      },
    });
    expect(bytes, greaterThan(40));
  });

  test('WebDAV inventory counts files and groups byte usage', () {
    const xml = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/SyncNote_Attachments/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/SyncNote_Attachments/cloud_files/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/SyncNote_Attachments/cloud_files/a.pdf</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1024</d:getcontentlength></d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/SyncNote_Attachments/images/b.png</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>2048</d:getcontentlength></d:prop></d:propstat></d:response>
</d:multistatus>''';
    final inventory = UploadService.parseWebdavInventory(xml);
    expect(inventory.fileCount, 2);
    expect(inventory.folderCount, 2);
    expect(inventory.totalBytes, 3072);
    expect(inventory.filesByFolder['cloud_files'], 1024);
    expect(inventory.filesByFolder['images'], 2048);
  });
}
