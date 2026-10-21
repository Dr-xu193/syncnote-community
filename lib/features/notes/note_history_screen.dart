import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/models/note_version_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';

class NoteHistoryScreen extends StatelessWidget {
  const NoteHistoryScreen({super.key, required this.note});

  final Note note;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史版本'),
        actions: [
          IconButton(
            tooltip: '清空历史',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('清空全部历史？'),
                  content: const Text('这会永久删除该笔记的全部云端历史版本，无法恢复。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('清空'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await FirestoreService.instance.clearNoteVersions(note.id);
              }
            },
          ),
        ],
      ),
      body: StreamBuilder<List<NoteVersion>>(
        stream: FirestoreService.instance.watchNoteVersions(note.id),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('历史加载失败：${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final versions = snapshot.data!;
          if (versions.isEmpty) {
            return const Center(child: Text('暂无历史版本'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: versions.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final version = versions[index];
              return Card(
                child: ListTile(
                  title: Text(
                    DateFormat('yyyy-MM-dd HH:mm:ss').format(version.createdAt),
                  ),
                  subtitle: Text(
                    version.note.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: Text(version.note.title),
                      content: SingleChildScrollView(
                        child: SelectableText(version.note.content),
                      ),
                    ),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'restore') {
                        await FirestoreService.instance.restoreNoteVersion(
                          note,
                          version,
                        );
                        if (context.mounted) Navigator.pop(context);
                      } else {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('删除该历史版本？'),
                            content: const Text('此操作无法撤销。'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          await FirestoreService.instance.deleteNoteVersion(
                            note.id,
                            version,
                          );
                        }
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'restore', child: Text('恢复')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
