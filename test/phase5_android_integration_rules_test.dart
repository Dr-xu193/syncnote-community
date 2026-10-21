import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/models/memo_model.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/services/android_integration_service.dart';

void main() {
  test('shared URL detection accepts only http and https links', () {
    expect(
      AndroidIntegrationService.isLikelyUrl('https://example.com/a'),
      true,
    );
    expect(AndroidIntegrationService.isLikelyUrl('http://example.com'), true);
    expect(AndroidIntegrationService.isLikelyUrl('just some text'), false);
    expect(AndroidIntegrationService.isLikelyUrl('ftp://example.com'), false);
  });

  test('widget snapshot shows recent memo and active today tasks only', () {
    final now = DateTime.now();
    final laterToday = DateTime(now.year, now.month, now.day, 23, 59);
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 12);
    final tasks = [
      Task(
        id: 'today',
        title: '今天要做',
        dueDate: laterToday,
        createdAt: now,
        updatedAt: now,
        userId: 'u1',
      ),
      Task(
        id: 'done',
        title: '已完成',
        status: TaskStatus.done,
        dueDate: now,
        createdAt: now,
        updatedAt: now,
        userId: 'u1',
      ),
      Task(
        id: 'tomorrow',
        title: '明天要做',
        dueDate: tomorrow,
        createdAt: now,
        updatedAt: now,
        userId: 'u1',
      ),
    ];
    final memos = [
      Memo(
        id: 'memo',
        content: '最近备忘内容',
        createdAt: now,
        updatedAt: now,
        userId: 'u1',
      ),
    ];

    final snapshot = AndroidIntegrationService.buildWidgetSnapshot(
      tasks,
      memos,
    );

    expect(snapshot.recentMemo, '最近备忘内容');
    expect(snapshot.todayTaskCount, 1);
    expect(snapshot.todayTaskSummary, contains('今天要做'));
    expect(snapshot.todayTaskSummary, isNot(contains('已完成')));
    expect(snapshot.todayTaskSummary, isNot(contains('明天要做')));
  });
}
