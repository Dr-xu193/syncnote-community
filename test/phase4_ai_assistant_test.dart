import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/features/diary/diary_screen.dart';
import 'package:syncnote/shared/models/ai_assistant_model.dart';
import 'package:syncnote/shared/models/ai_chat_model.dart';
import 'package:syncnote/shared/services/ai_assistant_service.dart';
import 'package:syncnote/shared/services/daily_ai_service.dart';

void main() {
  group('daily AI logical clock', () {
    test('07:00 through 22:59 is the current-day morning window', () {
      final atSeven = DateTime(2026, 8, 2, 7);
      final at2259 = DateTime(2026, 8, 2, 22, 59);
      expect(DailyAiClock.windowAt(atSeven), DailyAiWindow.morning);
      expect(DailyAiClock.windowAt(at2259), DailyAiWindow.morning);
      expect(DailyAiClock.dayKey(atSeven), '2026-08-02');
      expect(DailyAiClock.dayKey(at2259), '2026-08-02');
    });

    test('23:00 through 06:59 is the previous logical-day evening', () {
      final at2300 = DateTime(2026, 8, 2, 23);
      final at0030 = DateTime(2026, 8, 3, 0, 30);
      final at0659 = DateTime(2026, 8, 3, 6, 59);
      for (final clock in [at2300, at0030, at0659]) {
        expect(DailyAiClock.windowAt(clock), DailyAiWindow.evening);
        expect(DailyAiClock.dayKey(clock), '2026-08-02');
      }
    });

    test('the next foreground boundary is always 07:00 or 23:00', () {
      expect(
        DailyAiClock.nextBoundary(DateTime(2026, 8, 3, 6, 59)),
        DateTime(2026, 8, 3, 7),
      );
      expect(
        DailyAiClock.nextBoundary(DateTime(2026, 8, 3, 22, 59)),
        DateTime(2026, 8, 3, 23),
      );
      expect(
        DailyAiClock.nextBoundary(DateTime(2026, 8, 3, 23, 1)),
        DateTime(2026, 8, 4, 7),
      );
    });

    test('each logical day claims morning and evening independently once', () {
      final state = <String, dynamic>{
        'logicalDay': '2026-08-03',
        'presentationVersion': DailyAiPresentationState.currentVersion,
        'morningPresented': true,
        'eveningPresented': false,
      };
      expect(
        DailyAiPresentationState.shouldClaim(
          state,
          window: DailyAiWindow.morning,
          dayKey: '2026-08-03',
        ),
        isFalse,
      );
      expect(
        DailyAiPresentationState.shouldClaim(
          state,
          window: DailyAiWindow.evening,
          dayKey: '2026-08-03',
        ),
        isTrue,
      );
      expect(
        DailyAiPresentationState.shouldClaim(
          {...state, 'morningPresented': true, 'presentationVersion': 0},
          window: DailyAiWindow.morning,
          dayKey: '2026-08-03',
        ),
        isTrue,
      );
      expect(
        DailyAiPresentationState.shouldClaim(
          state,
          window: DailyAiWindow.morning,
          dayKey: '2026-08-04',
        ),
        isTrue,
      );
    });

    test('presentation reservation is temporary and window-specific', () {
      final now = DateTime.utc(2026, 8, 3, 15);
      final state = <String, dynamic>{
        'logicalDay': '2026-08-03',
        'presentationVersion': DailyAiPresentationState.currentVersion,
        'morningPresented': false,
        'eveningPresented': false,
        DailyAiPresentationState.presentationLeaseOwnerField(
          DailyAiWindow.morning,
        ): 'morning-owner',
        DailyAiPresentationState.presentationLeaseExpiresField(
          DailyAiWindow.morning,
        ): Timestamp.fromDate(
          now.add(const Duration(minutes: 1)),
        ),
      };
      expect(
        DailyAiPresentationState.hasActiveReservation(
          state,
          window: DailyAiWindow.morning,
          dayKey: '2026-08-03',
          now: now,
        ),
        isTrue,
      );
      expect(
        DailyAiPresentationState.hasActiveReservation(
          state,
          window: DailyAiWindow.evening,
          dayKey: '2026-08-03',
          now: now,
        ),
        isFalse,
      );
      expect(
        DailyAiPresentationState.hasActiveReservation(
          state,
          window: DailyAiWindow.morning,
          dayKey: '2026-08-03',
          now: now.add(const Duration(minutes: 2)),
        ),
        isFalse,
      );
    });

    test('morning and evening generation leases never share fields', () {
      expect(
        DailyAiPresentationState.generationLeaseOwnerField(
          DailyAiWindow.morning,
        ),
        isNot(
          DailyAiPresentationState.generationLeaseOwnerField(
            DailyAiWindow.evening,
          ),
        ),
      );
      expect(
        DailyAiPresentationState.generationLeaseExpiresField(
          DailyAiWindow.morning,
        ),
        isNot(
          DailyAiPresentationState.generationLeaseExpiresField(
            DailyAiWindow.evening,
          ),
        ),
      );
    });
  });

  testWidgets('automatic report confirms only after its sheet renders', (
    tester,
  ) async {
    var presented = false;
    Future<bool>? presentation;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () {
                presentation = showAiReportSheet(
                  context,
                  initialType: 'daily_briefing',
                  initialReport: '可见的晨报测试正文',
                  automatic: true,
                  onPresented: () async => presented = true,
                );
              },
              child: const Text('打开晨报'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开晨报'));
    expect(presented, isFalse);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('可见的晨报测试正文'), findsOneWidget);
    expect(presented, isTrue);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(await presentation, isTrue);
  });

  test('retrieval plans enforce source, time and item boundaries', () {
    final now = DateTime(2026, 8, 1, 12);
    final plan = AiRetrievalPlan.fromJson(
      {
        'timeRange': {'from': '1980-01-01', 'to': '2035-01-01'},
        'sources': ['tasks', 'diary', 'secrets'],
        'statuses': ['DONE'],
        'concepts': List.generate(20, (index) => '词$index'),
        'includeColdArchive': true,
        'maxItems': 999,
        'reason': 'test',
      },
      now: now,
      allowedSources: const {'tasks', 'diary'},
    );
    expect(plan.sources, {'tasks', 'diary'});
    expect(plan.from, DateTime(1996));
    expect(plan.to, DateTime(2027, 8, 2, 12));
    expect(plan.maxItems, 25);
    expect(plan.concepts, hasLength(12));
    expect(plan.statuses, {'done'});
  });

  test('fallback planner understands non-template personal questions', () {
    final plan = AiAssistantService.fallbackPlan(
      '回顾本周，我的压力和完成事情之间有什么关系？',
      now: DateTime(2026, 8, 7, 18),
      enabledSources: aiContextSourceNames,
    );
    expect(plan.sources, containsAll({'tasks', 'diary', 'chat_history'}));
    expect(plan.from, DateTime(2026, 8, 3));
    expect(plan.statuses, containsAll({'done', 'active'}));
  });

  test(
    'conversation resources select relevant chunks instead of full files',
    () {
      final resources = [
        AiChatResource(
          id: 'r1',
          title: '项目约束',
          content:
              '${List.filled(500, '无关内容。').join()}Firebase 必须保持免费方案，界面不要堆太多按钮。',
          contentHash: 'hash-one',
          createdAt: DateTime(2026),
        ),
        AiChatResource(
          id: 'r2',
          title: '食谱',
          content: '番茄炒蛋和米饭。',
          contentHash: 'hash-two',
          createdAt: DateTime(2026),
        ),
      ];
      final chunks = AiAssistantService.selectResourceChunks(
        'Firebase 免费方案是什么约束？',
        resources,
        maxChunks: 1,
      );
      expect(chunks, hasLength(1));
      expect(chunks.single['title'], '项目约束');
      expect(chunks.single['content'], contains('Firebase'));
      expect(
        chunks.single['content']!.length,
        lessThan(resources.first.content.length),
      );
    },
  );

  test('50-turn context keeps early constraints through visible summary', () {
    final messages = List.generate(
      120,
      (index) => AiChatMessage(
        id: 'm$index',
        role: index.isEven ? 'user' : 'assistant',
        content: '第 $index 条普通消息',
        createdAt: DateTime(2026, 8, 1).add(Duration(minutes: index)),
      ),
    );
    final plan = AiRetrievalPlan(
      from: null,
      to: null,
      sources: const {'chat_history', 'memories'},
      statuses: const {},
      concepts: const [],
      includeColdArchive: false,
      maxItems: 12,
      reason: 'test',
    );
    final composed = AiAssistantService.composeContextMessages(
      question: '我早期有什么要求？',
      plan: plan,
      personalContext: const [],
      recentMessages: messages,
      earlierSnippets: const [],
      memories: const [],
      resourceChunks: const [],
      conversationSummary: '早期关键约束：Windows 使用 Release；界面按钮不要过多。',
    );
    expect(
      composed.any(
        (message) => '${message['content']}'.contains('Windows 使用 Release'),
      ),
      isTrue,
    );
    expect(
      composed.where((message) => message['role'] != 'system'),
      hasLength(81),
    );
    expect(composed.last['content'], '我早期有什么要求？');
  });
}
