import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/widgets/nullable_string_filter_menu.dart';

void main() {
  testWidgets(
    'explicit all option reports null instead of popup cancellation',
    (tester) async {
      var callbackCalled = false;
      String? selected = '早餐';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NullableStringFilterMenu(
              values: const ['早餐', '学习'],
              selectedValue: selected,
              allLabel: '全部标签',
              onSelected: (value) {
                callbackCalled = true;
                selected = value;
              },
              child: const Chip(key: ValueKey('tag-filter'), label: Text('早餐')),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('tag-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部标签'));
      await tester.pumpAndSettle();

      expect(callbackCalled, isTrue);
      expect(selected, isNull);
    },
  );

  testWidgets('specific option still reports its string value', (tester) async {
    String? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NullableStringFilterMenu(
            values: const ['早餐', '学习'],
            selectedValue: null,
            allLabel: '全部',
            onSelected: (value) => selected = value,
            child: const Chip(
              key: ValueKey('note-tag-filter'),
              label: Text('标签'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('note-tag-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习'));
    await tester.pumpAndSettle();

    expect(selected, '学习');
  });
}
