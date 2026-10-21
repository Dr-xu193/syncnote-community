import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/controllers/cursor_paged_controller.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/utils/content_index_text.dart';

void main() {
  test(
    'first page reads only the configured window from 2000 records',
    () async {
      final source = List<String>.generate(2000, (index) => 'item-$index');
      final firstPage = StreamController<FirestorePage<String>>();
      var offset = 40;
      var pageLoads = 0;
      final controller = CursorPagedController<String>(idOf: (item) => item);
      controller.start(
        firstPage: firstPage.stream,
        loadPage: (_) async {
          pageLoads++;
          final end = (offset + 40).clamp(0, source.length);
          final items = source.sublist(offset, end);
          offset = end;
          return FirestorePage(
            items: items,
            cursor: null,
            hasMore: offset < source.length,
          );
        },
      );

      firstPage.add(
        FirestorePage(
          items: source.take(40).toList(),
          cursor: null,
          hasMore: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.items.length, 40);
      expect(pageLoads, 0);
      await controller.loadMore();
      expect(controller.items.length, 80);
      expect(pageLoads, 1);

      // A live first-page refresh may contain an item already present in the
      // older page; stable-ID merging keeps it exactly once.
      firstPage.add(
        FirestorePage(
          items: ['item-new', ...source.skip(39).take(40)],
          cursor: null,
          hasMore: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.items.where((item) => item == 'item-40').length, 1);
      expect(controller.items.toSet().length, controller.items.length);

      controller.dispose();
      await firstPage.close();
    },
  );

  test('light index is bounded and does not retain the full body', () {
    final body = List.filled(1000, '核废物处理与辐射安全').join(' ');
    final summary = compactIndexSummary(body);
    final terms = buildSearchTerms([body]);

    expect(summary.length, lessThanOrEqualTo(181));
    expect(summary, isNot(body));
    expect(terms.length, lessThanOrEqualTo(400));
    expect(terms, contains('核废'));
    expect(terms, contains('辐射'));
  });
}
