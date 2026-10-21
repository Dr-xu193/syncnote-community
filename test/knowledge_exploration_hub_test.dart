import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/features/notes/knowledge_exploration_hub.dart';

void main() {
  test('exploration grid adapts to phone, tablet, and desktop widths', () {
    expect(explorationColumnCount(420), 1);
    expect(explorationColumnCount(800), 2);
    expect(explorationColumnCount(1280), 4);
  });

  testWidgets('exploration hub exposes all five modules', (tester) async {
    ExplorationModule? selected;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KnowledgeExplorationHub(
            onModuleSelected: (value) => selected = value,
          ),
        ),
      ),
    );

    for (final title in ['今日新闻', '今日文献', '知识卡片', '逻辑推演', '股票研究']) {
      expect(find.text(title), findsOneWidget);
    }

    await tester.tap(find.text('今日文献'));
    await tester.pump();
    expect(selected, ExplorationModule.literature);
  });
}
