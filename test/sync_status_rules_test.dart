import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/services/sync_status_service.dart';

void main() {
  group('sync status rules', () {
    test('physical network loss always reports offline', () {
      final level = SyncStatusService.classifyFirestoreState(
        networkOffline: true,
        isFromCache: false,
        hasPendingWrites: false,
      );

      expect(level, SyncStatusLevel.offline);
    });

    test('cache-only Firestore data is not treated as cloud-confirmed', () {
      final level = SyncStatusService.classifyFirestoreState(
        networkOffline: false,
        isFromCache: true,
        hasPendingWrites: false,
      );

      expect(level, SyncStatusLevel.offline);
    });

    test('server-confirmed pending writes report syncing', () {
      final level = SyncStatusService.classifyFirestoreState(
        networkOffline: false,
        isFromCache: false,
        hasPendingWrites: true,
      );

      expect(level, SyncStatusLevel.syncing);
    });

    test('server-confirmed settled snapshot reports online', () {
      final level = SyncStatusService.classifyFirestoreState(
        networkOffline: false,
        isFromCache: false,
        hasPendingWrites: false,
      );

      expect(level, SyncStatusLevel.online);
    });

    test('restored adapter waits for Firestore confirmation', () {
      final service = SyncStatusService.instance;
      service.setNetworkOffline(true);
      service.setNetworkOffline(false);

      expect(service.status.value.level, SyncStatusLevel.syncing);
      expect(service.status.value.message, contains('确认云端连接'));
    });
  });
}
