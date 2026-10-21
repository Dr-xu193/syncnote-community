import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/models/diary_model.dart';
import 'package:syncnote/shared/services/ai_service.dart';

void main() {
  test('daily briefing diary payload encodes mood as plain JSON text', () {
    final now = DateTime(2026, 7, 10);
    final payload = AIService.buildDailyBriefingDiaryPayload([
      DiaryEntry(
        id: 'diary-1',
        date: now,
        content: 'slept well',
        mood: Mood.good,
        createdAt: now,
        updatedAt: now,
        userId: 'user-1',
      ),
    ]);

    expect(payload.single['mood'], 'good');
    expect(jsonEncode(payload), contains('"mood":"good"'));
  });

  test('evening reflection diary payload encodes mood as plain JSON text', () {
    final now = DateTime(2026, 7, 10);
    final payload = AIService.buildEveningReflectionDiaryPayload([
      DiaryEntry(
        id: 'diary-1',
        date: now,
        content: 'finished the core task',
        mood: Mood.great,
        createdAt: now,
        updatedAt: now,
        userId: 'user-1',
      ),
    ]);

    expect(payload.single['mood'], 'great');
    expect(jsonEncode(payload), contains('"mood":"great"'));
  });
}
