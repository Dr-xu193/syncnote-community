import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:syncnote/core/theme/app_theme.dart';

void main() {
  testWidgets('app light theme renders a stable smoke scaffold', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: const Scaffold(
          body: Center(child: Text('SyncNote widget smoke')),
        ),
      ),
    );

    expect(find.text('SyncNote widget smoke'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
