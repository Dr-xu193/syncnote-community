import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/models/diary_model.dart';
import 'package:syncnote/shared/models/memo_model.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/services/ai_context_filter.dart';

void main() {
  test('release version and smoke documents stay aligned', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final changelog = File('CHANGELOG.md').readAsStringSync();
    final smoke = File('RELEASE_SMOKE_TESTS.md').readAsStringSync();

    expect(
      pubspec,
      contains(RegExp(r'^version:\s*0\.1\.0\+1$', multiLine: true)),
    );
    expect(changelog, contains('0.1.0+1'));
    expect(changelog, contains('首次启动'));
    expect(smoke, contains('flutter build windows --release'));
    expect(smoke, contains('flutter build apk --release'));
    expect(smoke, contains('服务配置'));
    expect(smoke, contains('不部署 Cloud Functions'));
  });

  test('scratch tooling is excluded from the formal analyzer baseline', () {
    final analysisOptions = File('analysis_options.yaml').readAsStringSync();
    expect(analysisOptions, contains('scratch/**'));
  });

  test('AI knowledge context excludes archived, done, and deleted records', () {
    final now = DateTime.utc(2026, 7, 10);
    final context = AiContextFilter.buildRelevantKnowledgeContext(
      query: '项目',
      notes: [
        Note(
          id: 'active-note',
          title: '项目笔记',
          content: '项目资料',
          createdAt: now,
          updatedAt: now,
          userId: 'u1',
        ),
        Note(
          id: 'archived-note',
          title: '项目归档',
          content: '不应该发送',
          isArchived: true,
          createdAt: now,
          updatedAt: now,
          userId: 'u1',
        ),
      ],
      diaries: [
        DiaryEntry(
          id: 'diary',
          date: now,
          content: '项目当天记录',
          mood: Mood.good,
          createdAt: now,
          updatedAt: now,
          userId: 'u1',
        ),
      ],
      tasks: [
        Task(
          id: 'active-task',
          title: '项目待办',
          createdAt: now,
          updatedAt: now,
          userId: 'u1',
        ),
        Task(
          id: 'done-task',
          title: '项目已完成',
          status: TaskStatus.done,
          createdAt: now,
          updatedAt: now,
          userId: 'u1',
        ),
        Task(
          id: 'archived-task',
          title: '项目归档任务',
          isArchived: true,
          createdAt: now,
          updatedAt: now,
          userId: 'u1',
        ),
      ],
      memos: [
        Memo(
          id: 'active-memo',
          content: '项目备忘',
          createdAt: now,
          updatedAt: now,
          userId: 'u1',
        ),
        Memo(
          id: 'deleted-memo',
          content: '项目已删除备忘',
          isDeleted: true,
          createdAt: now,
          updatedAt: now,
          userId: 'u1',
        ),
      ],
    );

    final serialized = context
        .map((item) => '${item['title']} ${item['content']}')
        .join('\n');
    expect(serialized, contains('项目笔记'));
    expect(serialized, contains('项目当天记录'));
    expect(serialized, contains('项目待办'));
    expect(serialized, contains('项目备忘'));
    expect(serialized, isNot(contains('项目归档')));
    expect(serialized, isNot(contains('项目已完成')));
    expect(serialized, isNot(contains('项目归档任务')));
    expect(serialized, isNot(contains('项目已删除备忘')));
  });

  test('AI context respects the configured size and item limits', () {
    final now = DateTime.utc(2026, 7, 10);
    final memos = List.generate(
      40,
      (index) => Memo(
        id: 'memo-$index',
        content: '项目 ${'x' * 200}',
        createdAt: now,
        updatedAt: now,
        userId: 'u1',
      ),
    );

    final context = AiContextFilter.buildRelevantKnowledgeContext(
      query: '项目',
      notes: const [],
      diaries: const [],
      tasks: const [],
      memos: memos,
    );
    final totalChars = context.fold<int>(
      0,
      (sum, item) =>
          sum + (item['title'] ?? '').length + (item['content'] ?? '').length,
    );

    expect(context.length, lessThanOrEqualTo(AiContextFilter.maxContextItems));
    expect(totalChars, lessThanOrEqualTo(AiContextFilter.maxContextChars));
  });
}
