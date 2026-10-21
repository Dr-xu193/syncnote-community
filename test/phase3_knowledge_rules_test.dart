import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/services/firestore_service.dart';

void main() {
  test('extracts and normalizes both wiki link syntaxes', () {
    expect(
      FirestoreService.extractWikiTitles(
        '关联 [[项目计划]]、[[ 项目计划 ]] 和 [任务](wiki://%E4%BB%BB%E5%8A%A1)',
      ),
      {'项目计划', '任务'},
    );
  });

  test('note history uses a ten minute merge window', () {
    final now = DateTime(2026, 7, 9, 12);
    expect(
      FirestoreService.shouldCreateNoteVersion(
        now.subtract(const Duration(minutes: 9)),
        now,
      ),
      isFalse,
    );
    expect(
      FirestoreService.shouldCreateNoteVersion(
        now.subtract(const Duration(minutes: 10)),
        now,
      ),
      isTrue,
    );
    expect(FirestoreService.shouldCreateNoteVersion(null, now), isTrue);
  });
}
