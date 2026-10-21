import 'package:flutter/foundation.dart';
import 'package:syncnote/shared/models/diary_model.dart';
import 'package:syncnote/shared/models/memo_model.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/models/task_model.dart';

class AiContextFilter {
  AiContextFilter._();

  static const int maxContextChars = 25000;
  static const int maxContextItems = 25;

  @visibleForTesting
  static List<String> queryTokens(String query) {
    final words = <String>[];
    final rawParts = query.toLowerCase().split(RegExp(r'\s+'));
    for (final part in rawParts) {
      if (part.isEmpty) continue;
      final containsChinese = RegExp(r'[\u4e00-\u9fa5]').hasMatch(part);
      if (!containsChinese) {
        words.add(part);
        continue;
      }
      words.add(part);
      for (int i = 0; i < part.length - 1; i++) {
        words.add(part.substring(i, i + 2));
      }
      for (int i = 0; i < part.length; i++) {
        words.add(part.substring(i, i + 1));
      }
    }
    return words.toSet().toList(growable: false);
  }

  static List<Map<String, String>> buildRelevantKnowledgeContext({
    required String query,
    required List<Note> notes,
    required List<DiaryEntry> diaries,
    required List<Task> tasks,
    required List<Memo> memos,
  }) {
    if (query.trim().isEmpty) return const [];

    final queryWords = queryTokens(query);
    final allContext = <Map<String, String>>[
      for (final note in notes.where(
        (note) => !note.isArchived && !note.isDeleted,
      ))
        {'type': '笔记', 'title': note.title, 'content': note.content},
      for (final diary in diaries.where((diary) => !diary.isDeleted))
        {
          'type': '日记',
          'title': '日记 (${diary.date.toIso8601String().split('T').first})',
          'content': '心情: ${diary.mood.name}\n内容: ${diary.content}',
        },
      for (final task in tasks.where(
        (task) =>
            !task.isArchived &&
            !task.isDeleted &&
            task.status != TaskStatus.done,
      ))
        {
          'type': '待办任务',
          'title': task.title,
          'content':
              '描述: ${task.description}\n状态: ${task.status.name}\n优先级: ${task.priority.name}',
        },
      for (final memo in memos.where((memo) => !memo.isDeleted))
        {'type': '备忘录', 'title': '备忘录', 'content': memo.content},
    ];

    final scoredItems = allContext.map((item) {
      final title = (item['title'] ?? '').toLowerCase();
      final content = (item['content'] ?? '').toLowerCase();

      double score = 0.0;
      for (final word in queryWords) {
        if (title.contains(word)) score += 10.0;
        score += word.allMatches(content).length * 2.0;
      }
      return MapEntry(item, score);
    }).toList();

    scoredItems.sort((a, b) => b.value.compareTo(a.value));

    final selected = <Map<String, String>>[];
    var totalLength = 0;

    for (final entry in scoredItems) {
      if (entry.value <= 0) continue;
      totalLength = _addIfFits(selected, entry.key, totalLength);
    }

    for (final entry in scoredItems) {
      if (entry.value > 0) continue;
      totalLength = _addIfFits(selected, entry.key, totalLength);
    }

    return selected;
  }

  static int _addIfFits(
    List<Map<String, String>> selected,
    Map<String, String> item,
    int currentLength,
  ) {
    if (selected.length >= maxContextItems) return currentLength;
    final textLength =
        (item['title'] ?? '').length + (item['content'] ?? '').length;
    if (currentLength + textLength > maxContextChars) return currentLength;
    selected.add(item);
    return currentLength + textLength;
  }
}
