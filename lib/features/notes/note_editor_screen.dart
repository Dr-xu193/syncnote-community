import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/ai_service.dart';
import 'package:syncnote/shared/services/audio_record_service.dart';
import 'package:syncnote/shared/services/export_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:syncnote/shared/widgets/voice_player_widget.dart';
import 'package:syncnote/shared/widgets/webdav_image_widget.dart';
import 'package:syncnote/shared/screens/doodle_screen.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';
import 'package:syncnote/features/notes/note_history_screen.dart';
import 'package:uuid/uuid.dart';

enum _NoteConflictAction { keepCloud, overwriteCloud, keepBoth, manualMerge }

class NoteEditorScreen extends StatefulWidget {
  final Note? note;

  const NoteEditorScreen({super.key, this.note});

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _FenceHighlighter extends SyntaxHighlighter {
  @override
  TextSpan format(String source) {
    final pattern = RegExp(
      r"""("[^"\n]*"|'[^'\n]*'|\b(?:class|void|final|const|var|if|else|for|while|return|async|await|import|true|false|null)\b|//[^\n]*)""",
    );
    final spans = <TextSpan>[];
    var offset = 0;
    for (final match in pattern.allMatches(source)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: source.substring(offset, match.start)));
      }
      final token = match.group(0)!;
      final color = token.startsWith('//')
          ? Colors.green
          : token.startsWith('"') || token.startsWith("'")
          ? Colors.orange
          : Colors.lightBlue;
      spans.add(
        TextSpan(
          text: token,
          style: TextStyle(color: color),
        ),
      );
      offset = match.end;
    }
    if (offset < source.length) {
      spans.add(TextSpan(text: source.substring(offset)));
    }
    return TextSpan(
      style: const TextStyle(
        fontFamily: 'monospace',
        color: Colors.white,
        backgroundColor: Color(0xFF202124),
      ),
      children: spans,
    );
  }
}

class SaveIntent extends Intent {
  const SaveIntent();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late TextEditingController _titleController;
  late TextEditingController _bodyController;
  late TextEditingController _categoryController;
  late TextEditingController _tagsController;
  bool _isArchived = false;
  bool _isSaving = false;
  bool _isExtracting = false;
  bool _isListening = false;
  bool _isTranscribing = false;
  List<String> _noteVoiceUrls = [];
  bool _isPreview = false;

  // Visual Canvas variables
  List<PositionedImage> _noteImages = [];
  List<PositionedText> _noteTexts = [];
  double _canvasWidth = 400.0;
  int? _focusedTextIndex;

  List<Map<String, String>> _recommendedLinks = [];
  bool _isLoadingRecommendations = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note?.title ?? '');
    _categoryController = TextEditingController(
      text: widget.note?.category ?? '',
    );
    _tagsController = TextEditingController(
      text: widget.note?.tags.join(', ') ?? '',
    );
    _isArchived = widget.note?.isArchived ?? false;

    // Parse visual layout or legacy content
    final visualContent = parseVisualNoteContent(
      widget.note?.content ?? '',
      widget.note?.images ?? [],
    );
    _bodyController = TextEditingController(text: visualContent.text);
    _noteImages = visualContent.images;
    _noteTexts = visualContent.texts;
    _canvasWidth = visualContent.canvasWidth;

    // Initialize list states (handles backwards compatibility with single voiceUrl)
    _noteVoiceUrls =
        widget.note?.voiceUrls != null && widget.note!.voiceUrls.isNotEmpty
        ? List<String>.from(widget.note!.voiceUrls)
        : (widget.note?.voiceUrl != null ? [widget.note!.voiceUrl!] : []);

    _isPreview = widget.note != null;

    // Automatically upload local attachments in background when note is loaded
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncLocalAttachmentsToCloud();
      if (widget.note != null) {
        _fetchWikiRecommendations();
      }
    });
  }

  Future<void> _fetchWikiRecommendations() async {
    setState(() {
      _isLoadingRecommendations = true;
    });

    try {
      final allNotes = await FirestoreService.instance.getNotesOnce();
      final candidates = allNotes
          .where((n) => n.id != widget.note?.id && n.title.trim().isNotEmpty)
          .map(
            (n) => {'id': n.id, 'title': n.title, 'aiKeywords': n.aiKeywords},
          )
          .toList();

      if (candidates.isEmpty) {
        setState(() {
          _recommendedLinks = [];
          _isLoadingRecommendations = false;
        });
        return;
      }

      final text = _bodyController.text.trim();
      final title = _titleController.text.trim();
      final currentKeywords = widget.note?.aiKeywords ?? const <String>[];

      final matchedIds = await AIService.instance.recommendRelatedNotes(
        currentId: widget.note?.id ?? 'temp_new_note',
        currentTitle: title,
        currentContent: text,
        currentKeywords: currentKeywords,
        candidateNotes: candidates,
      );

      final List<Map<String, String>> matches = [];
      for (final id in matchedIds) {
        final matchNote = allNotes.firstWhere((n) => n.id == id);
        matches.add({'id': matchNote.id, 'title': matchNote.title});
      }

      setState(() {
        _recommendedLinks = matches;
        _isLoadingRecommendations = false;
      });
    } catch (e) {
      debugPrint('Error getting wiki recommendations: $e');
      setState(() {
        _isLoadingRecommendations = false;
      });
    }
  }

  void _insertDoubleLink(String noteTitle) {
    final linkText = '[[$noteTitle]]';
    final text = _bodyController.text;
    final selection = _bodyController.selection;

    setState(() {
      if (selection.isValid && selection.start >= 0) {
        final newText = text.replaceRange(
          selection.start,
          selection.end,
          linkText,
        );
        _bodyController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(
            offset: selection.start + linkText.length,
          ),
        );
      } else {
        _bodyController.text = text + linkText;
      }
    });
  }

  Widget _buildWikiRecommendationBar() {
    final theme = Theme.of(context);
    if (_isLoadingRecommendations) {
      return Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              'AI 正在语义匹配相关笔记...',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    if (_recommendedLinks.isEmpty) {
      return InkWell(
        onTap: _fetchWikiRecommendations,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.2),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                '🪄 智能关联推荐：点击扫描并分析关联笔记',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            '推荐关联：',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface,
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _recommendedLinks.length + 1,
              itemBuilder: (context, index) {
                if (index == _recommendedLinks.length) {
                  return Padding(
                    padding: const EdgeInsets.only(left: 4.0),
                    child: IconButton(
                      icon: const Icon(Icons.refresh, size: 16),
                      tooltip: '重新扫描',
                      onPressed: _fetchWikiRecommendations,
                    ),
                  );
                }
                final item = _recommendedLinks[index];
                final title = item['title'] ?? '';
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: ActionChip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    side: BorderSide.none,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    label: Text(
                      '＋ $title',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () => _insertDoubleLink(title),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _syncLocalAttachmentsToCloud() async {
    bool updated = false;

    // 1. Sync images
    for (var i = 0; i < _noteImages.length; i++) {
      final img = _noteImages[i];
      if (!img.url.startsWith('http://') &&
          !img.url.startsWith('https://') &&
          !img.url.startsWith('webdav://')) {
        final localFile = File(_normalizeLocalPath(img.url));
        if (await localFile.exists()) {
          final cloudUrl = await UploadService.instance.uploadFile(
            localFile,
            'notes',
          );
          if (cloudUrl != null && cloudUrl.startsWith('webdav://')) {
            if (mounted) {
              setState(() {
                img.url = cloudUrl;
              });
            }
            updated = true;
          }
        }
      }
    }

    // 2. Sync voice recordings
    for (var i = 0; i < _noteVoiceUrls.length; i++) {
      final url = _noteVoiceUrls[i];
      if (!url.startsWith('http://') &&
          !url.startsWith('https://') &&
          !url.startsWith('webdav://')) {
        final localFile = File(url);
        if (await localFile.exists()) {
          final cloudUrl = await UploadService.instance.uploadFile(
            localFile,
            'notes',
          );
          if (cloudUrl != null && cloudUrl.startsWith('webdav://')) {
            if (mounted) {
              setState(() {
                _noteVoiceUrls[i] = cloudUrl;
              });
            }
            updated = true;
          }
        }
      }
    }

    if (updated && widget.note != null && mounted) {
      await _saveNote();
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _categoryController.dispose();
    _tagsController.dispose();
    if (_isListening) {
      AudioRecordService.instance.stopRecording();
    }
    super.dispose();
  }

  void _insertTextToDocument(String text) {
    final currentText = _bodyController.text;
    final selection = _bodyController.selection;
    setState(() {
      if (selection.isValid && selection.start >= 0) {
        final start = selection.start;
        final end = selection.end;
        final newText = currentText.replaceRange(start, end, text);
        _bodyController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start + text.length),
        );
      } else {
        final newText = currentText.isEmpty ? text : '$currentText\n$text';
        _bodyController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: newText.length),
        );
      }
    });
  }

  Future<void> _saveNote() async {
    final title = _titleController.text.trim();
    if (title.isEmpty &&
        _bodyController.text.trim().isEmpty &&
        _noteImages.isEmpty &&
        _noteTexts.isEmpty) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        throw Exception('User not logged in');
      }

      // 1. Upload local images to cloud
      for (var i = 0; i < _noteImages.length; i++) {
        final img = _noteImages[i];
        final url = img.url;
        if (!url.startsWith('webdav://') &&
            !url.startsWith('http://') &&
            !url.startsWith('https://')) {
          final cleanPath = _normalizeLocalPath(url);
          final file = File(cleanPath);
          if (await file.exists()) {
            final cloudUrl = await UploadService.instance.uploadFile(
              file,
              'notes',
            );
            if (cloudUrl != null) {
              img.url = cloudUrl;
            }
          }
        }
      }

      // 2. Upload local voice recordings to cloud
      final List<String> finalVoiceUrls = [];
      for (final url in _noteVoiceUrls) {
        if (url.startsWith('webdav://') ||
            url.startsWith('http://') ||
            url.startsWith('https://')) {
          finalVoiceUrls.add(url);
        } else {
          final cleanPath = _normalizeLocalPath(url);
          final file = File(cleanPath);
          if (await file.exists()) {
            final cloudUrl = await UploadService.instance.uploadFile(
              file,
              'notes',
            );
            if (cloudUrl != null) {
              finalVoiceUrls.add(cloudUrl);
            } else {
              finalVoiceUrls.add(url);
            }
          } else {
            finalVoiceUrls.add(url);
          }
        }
      }
      _noteVoiceUrls = finalVoiceUrls;

      // 3. Serialize visual note content
      final content = serializeVisualNoteContent(
        VisualNoteContent(
          text: _bodyController.text,
          canvasWidth: _canvasWidth,
          images: _noteImages,
          texts: _noteTexts,
        ),
      );

      final now = DateTime.now();
      final imagePaths = _noteImages.map((i) => i.url).toList();
      final noteId = widget.note?.id ?? const Uuid().v4();
      final bool contentChanged =
          widget.note == null ||
          widget.note!.title != title ||
          widget.note!.content != content;
      final tags = _tagsController.text
          .split(RegExp(r'[,，]'))
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toSet()
          .toList();
      final historyChanged =
          widget.note == null ||
          contentChanged ||
          !listEquals(widget.note!.images, imagePaths) ||
          !listEquals(widget.note!.voiceUrls, _noteVoiceUrls) ||
          widget.note!.category != _categoryController.text.trim() ||
          !setEquals(widget.note!.tags.toSet(), tags.toSet()) ||
          widget.note!.isArchived != _isArchived;

      if (widget.note == null) {
        // Create new note
        final newNote = Note(
          id: noteId,
          title: title,
          content: content,
          contentType: NoteContentType.markdown,
          voiceUrl: _noteVoiceUrls.isNotEmpty ? _noteVoiceUrls.first : null,
          voiceUrls: _noteVoiceUrls,
          images: imagePaths,
          createdAt: now,
          updatedAt: now,
          userId: currentUser.uid,
          aiKeywords: const [],
          category: _categoryController.text.trim(),
          tags: tags,
          isArchived: _isArchived,
        );
        final linkedIds = await FirestoreService.instance.resolveLinkedNoteIds(
          content,
          currentId: noteId,
        );
        await FirestoreService.instance.addNote(
          newNote.copyWith(linkedNoteIds: linkedIds.toList()),
        );
      } else {
        // Update existing note
        final updatedNote = widget.note!.copyWith(
          title: title,
          content: content,
          contentType: NoteContentType.markdown,
          voiceUrl: _noteVoiceUrls.isNotEmpty ? _noteVoiceUrls.first : null,
          clearVoiceUrl: _noteVoiceUrls.isEmpty,
          voiceUrls: _noteVoiceUrls,
          images: imagePaths,
          category: _categoryController.text.trim(),
          tags: tags,
          isArchived: _isArchived,
          updatedAt: now,
        );
        if (historyChanged) {
          await FirestoreService.instance.updateNoteWithHistory(
            widget.note!,
            updatedNote,
          );
        } else {
          await FirestoreService.instance.updateNote(updatedNote);
        }
        await _deleteRemovedAttachments(updatedNote);
      }

      if (contentChanged) {
        _triggerBackgroundKeywordsGeneration(noteId, title, content);
      }

      if (mounted) {
        Navigator.of(context).pop();
      }
    } on NoteSaveConflictException catch (e) {
      if (mounted) {
        await _handleNoteSaveConflict(e);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存笔记失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _deleteRemovedAttachments(Note updatedNote) async {
    final old = widget.note;
    if (old == null) return;
    final deletedImages = old.images
        .where(
          (url) =>
              !updatedNote.images.contains(url) && url.startsWith('webdav://'),
        )
        .toList();
    final deletedVoices = old.voiceUrls
        .where(
          (url) =>
              !updatedNote.voiceUrls.contains(url) &&
              url.startsWith('webdav://'),
        )
        .toList();

    await FirestoreService.instance.deleteAttachmentsIfUnreferenced([
      ...deletedImages,
      ...deletedVoices,
    ]);
  }

  Future<void> _handleNoteSaveConflict(
    NoteSaveConflictException conflict,
  ) async {
    final action = await showDialog<_NoteConflictAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('检测到笔记保存冲突'),
        content: const Text('这篇笔记已经在另一台设备上更新。请选择如何处理本机未保存内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(_NoteConflictAction.manualMerge),
            child: const Text('手动合并'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_NoteConflictAction.keepBoth),
            child: const Text('两份保留'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_NoteConflictAction.keepCloud),
            child: const Text('保留云端'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(_NoteConflictAction.overwriteCloud),
            child: const Text('覆盖云端'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _NoteConflictAction.keepCloud:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已保留云端版本，本机修改未写入')));
        Navigator.of(context).pop();
      case _NoteConflictAction.overwriteCloud:
        await FirestoreService.instance.updateNoteWithHistory(
          conflict.cloudNote,
          conflict.localNote,
          force: true,
        );
        await _deleteRemovedAttachments(conflict.localNote);
        if (mounted) Navigator.of(context).pop();
      case _NoteConflictAction.keepBoth:
        final currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser == null) return;
        final now = DateTime.now();
        final copyId = const Uuid().v4();
        final linkedIds = await FirestoreService.instance.resolveLinkedNoteIds(
          conflict.localNote.content,
          currentId: copyId,
        );
        final copy = conflict.localNote.copyWith(
          id: copyId,
          title: '${conflict.localNote.title}（冲突副本）',
          userId: currentUser.uid,
          createdAt: now,
          updatedAt: now,
          linkedNoteIds: linkedIds.toList(),
          revision: 0,
        );
        await FirestoreService.instance.addNote(copy);
        if (mounted) Navigator.of(context).pop();
      case _NoteConflictAction.manualMerge:
        final cloudText = parseVisualNoteContent(
          conflict.cloudNote.content,
          conflict.cloudNote.images,
        ).text;
        final localText = parseVisualNoteContent(
          conflict.localNote.content,
          conflict.localNote.images,
        ).text;
        setState(() {
          _bodyController.text =
              '$cloudText\n\n--- 本机未保存版本，请手动合并 ---\n\n$localText';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已把云端和本机内容放入编辑器，请确认后再次保存')),
        );
    }
  }

  void _triggerBackgroundKeywordsGeneration(
    String noteId,
    String title,
    String content,
  ) {
    Future.microtask(() async {
      try {
        final keywords = await AIService.instance.generateKeywordsForNote(
          title,
          content,
        );
        if (keywords.isNotEmpty) {
          final current = await FirestoreService.instance.getNoteById(noteId);
          if (current != null) {
            final updated = current.copyWith(aiKeywords: keywords);
            await FirestoreService.instance.updateNote(updated);
            debugPrint(
              'Successfully updated keywords for note $noteId: $keywords',
            );
          }
        }
      } catch (e) {
        debugPrint('Error generating background note keywords: $e');
      }
    });
  }

  Future<void> _extractTextFromImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile == null) return;

    setState(() {
      _isExtracting = true;
    });

    try {
      final bytes = await pickedFile.readAsBytes();
      final text = await AIService.instance.extractTextFromImage(bytes);

      if (text != null && text.isNotEmpty) {
        if (mounted) {
          _insertTextToDocument(text);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error extracting text: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExtracting = false;
        });
      }
    }
  }

  void _toggleListening() async {
    if (_isListening) {
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
      setState(() => _isListening = false);
      final path = await AudioRecordService.instance.stopRecording();

      if (path != null) {
        setState(() => _isTranscribing = true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⏳ AI 正在将语音转为文字...'),
              duration: Duration(seconds: 3),
            ),
          );
        }

        try {
          final file = File(path);
          final bytes = await file.readAsBytes();
          final text = await AIService.instance.transcribeAudio(bytes);

          if (mounted) {
            if (text != null && text.isNotEmpty) {
              _handleVoiceTranscription(text, path);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('未能识别到有效语音内容，可能是杂音或声音太小。')),
              );
              try {
                await file.delete();
              } catch (_) {}
            }
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('语音转写出错: $e')));
          }
        } finally {
          if (mounted) setState(() => _isTranscribing = false);
        }
      }
    } else {
      bool success = await AudioRecordService.instance.startRecording();
      if (success) {
        setState(() => _isListening = true);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('无法启动录音，请检查设备麦克风权限')));
        }
      }
    }
  }

  Future<void> _handleVoiceTranscription(
    String rawText,
    String localFilePath,
  ) async {
    bool isPolishing = false;
    String? polishedText;
    bool saveAudioAttachment = false;

    final insertText = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.mic_none, color: Colors.blue),
                  SizedBox(width: 8),
                  Text('语音输入确认'),
                ],
              ),
              content: SizedBox(
                width: 500,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '原始识别文字：',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          rawText,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ),
                    if (polishedText != null) ...[
                      const SizedBox(height: 16),
                      const Text(
                        '✨ AI 智能润色后：',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.purple,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 120),
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.purple.withValues(alpha: 0.05),
                          border: Border.all(
                            color: Colors.purple.withValues(alpha: 0.2),
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            polishedText!,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                    if (isPolishing) ...[
                      const SizedBox(height: 16),
                      const Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('AI 正在润色段落...'),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Checkbox(
                          value: saveAudioAttachment,
                          onChanged: (val) {
                            setDialogState(() {
                              saveAudioAttachment = val ?? false;
                            });
                          },
                        ),
                        const Expanded(
                          child: Text(
                            '同时保存录音原文件（作为笔记音频附件）',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                if (polishedText == null && !isPolishing)
                  TextButton.icon(
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('AI 润色文本'),
                    style: TextButton.styleFrom(foregroundColor: Colors.purple),
                    onPressed: () async {
                      setDialogState(() {
                        isPolishing = true;
                      });
                      try {
                        final polished = await AIService.instance
                            .polishVoiceDraft(rawText);
                        setDialogState(() {
                          polishedText = polished;
                        });
                      } finally {
                        setDialogState(() {
                          isPolishing = false;
                        });
                      }
                    },
                  ),
                const Spacer(),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context, polishedText ?? rawText);
                  },
                  child: Text(polishedText != null ? '插入润色版' : '直接插入'),
                ),
              ],
            );
          },
        );
      },
    );

    if (insertText != null && insertText.isNotEmpty && mounted) {
      if (saveAudioAttachment) {
        setState(() {
          _noteVoiceUrls.add(localFilePath);
        });
      } else {
        try {
          await File(localFilePath).delete();
        } catch (_) {}
      }

      _insertTextToDocument(insertText);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('✅ 语音内容已成功插入')));
    } else {
      try {
        await File(localFilePath).delete();
      } catch (_) {}
    }
  }

  Future<void> _importWebLink() async {
    final TextEditingController urlCtrl = TextEditingController();
    SummaryStyle selectedStyle = SummaryStyle.insight;

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '导入网页/视频链接总结',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: urlCtrl,
                    decoration: InputDecoration(
                      labelText: '网页或视频链接 (YouTube/B站/新闻)',
                      hintText: 'https://...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '选择总结倾向和风格：',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<SummaryStyle>(
                    initialValue: selectedStyle,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: SummaryStyle.outline,
                        child: Text('📊 极简大纲 (结构简练, 150字内)'),
                      ),
                      DropdownMenuItem(
                        value: SummaryStyle.insight,
                        child: Text('🧠 深度解析 (多维细节, 时间线分拆)'),
                      ),
                      DropdownMenuItem(
                        value: SummaryStyle.actionable,
                        child: Text('🎯 行动指南 (提炼步骤为待办列表)'),
                      ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setModalState(() {
                          selectedStyle = val;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context, {
                            'url': urlCtrl.text,
                            'style': selectedStyle,
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('提取并总结'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (result != null) {
      final url = result['url'] as String? ?? '';
      final style = result['style'] as SummaryStyle? ?? SummaryStyle.insight;
      if (url.trim().isEmpty) return;

      setState(() => _isExtracting = true);
      try {
        final summary = await AIService.instance.summarizeWebPage(
          url,
          style: style,
        );
        if (summary != null) {
          final headerText = style == SummaryStyle.actionable
              ? '🎯 **行动指南**'
              : '🔗 **网页总结 (${style == SummaryStyle.outline ? "大纲" : "深度"})**';
          _insertTextToDocument('$headerText: $url\n$summary');
        } else {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('提取失败，请检查网址')));
          }
        }
      } finally {
        if (mounted) setState(() => _isExtracting = false);
      }
    }
  }

  Future<void> _insertPhotoAttachment() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (pickedFile == null) return;

    // Estimate aspect ratio to prevent squishing
    double imgWidth = 250.0;
    double imgHeight = 250.0;
    try {
      final bytes = await File(pickedFile.path).readAsBytes();
      final imageObj = await decodeImageFromList(bytes);
      final double aspect = imageObj.width / imageObj.height;
      if (aspect > 1.0) {
        imgWidth = 250.0;
        imgHeight = 250.0 / aspect;
      } else {
        imgHeight = 250.0;
        imgWidth = 250.0 * aspect;
      }
    } catch (e) {
      debugPrint('Error getting image aspect ratio: $e');
    }

    var downloadUrl = pickedFile.path.replaceAll('\\', '/');
    if (!downloadUrl.startsWith('http://') &&
        !downloadUrl.startsWith('https://') &&
        !downloadUrl.startsWith('file:///') &&
        !downloadUrl.startsWith('webdav://')) {
      downloadUrl = 'file:///$downloadUrl';
    }

    setState(() {
      double insertY = 100.0;
      if (_noteImages.isNotEmpty) {
        insertY = _noteImages.last.y + _noteImages.last.height + 20.0;
      }
      _noteImages.add(
        PositionedImage(
          url: downloadUrl,
          x: 20.0,
          y: insertY,
          width: imgWidth,
          height: imgHeight,
        ),
      );
    });

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('✅ 照片已成功添加至笔记中。')));
    }
  }

  Future<void> _generateMixedSummary() async {
    final title = _titleController.text.trim();
    final content = serializeVisualNoteContent(
      VisualNoteContent(
        text: _bodyController.text,
        canvasWidth: _canvasWidth,
        images: _noteImages,
        texts: _noteTexts,
      ),
    );
    if (title.isEmpty && content.isEmpty) return;

    setState(() => _isExtracting = true);
    try {
      final imageBytes = <Uint8List>[];
      var failedImages = 0;
      for (final url in _noteImages.map((image) => image.url).toSet().take(8)) {
        try {
          imageBytes.add(await _readImageBytes(url));
        } catch (_) {
          failedImages++;
        }
      }
      if (_noteImages.isNotEmpty && imageBytes.isEmpty) {
        throw Exception('笔记图片均无法读取，请检查网络后重试');
      }

      final summary = await AIService.instance.summarizeMixedNote(
        title,
        content,
        imageBytes,
      );
      if (summary != null && mounted) {
        _insertTextToDocument('\n\n📌 **AI 全媒体总结**:\n$summary');
        if (failedImages > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$failedImages 张图片读取失败，其余内容已参与总结')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('智能总结失败')));
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('全媒体总结失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _isExtracting = false);
    }
  }

  Future<Uint8List> _readImageBytes(String source) async {
    if (source.startsWith('webdav://')) {
      final path = await WebdavCacheManager.instance.resolveLocalPath(source);
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) throw Exception('图片文件为空');
      return bytes;
    }
    if (source.startsWith('http://') || source.startsWith('https://')) {
      final response = await http
          .get(Uri.parse(source))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('图片下载失败（HTTP ${response.statusCode}）');
      }
      if (response.bodyBytes.isEmpty) throw Exception('图片文件为空');
      return response.bodyBytes;
    }

    var path = source;
    if (path.startsWith('file:///')) path = path.substring(8);
    if (path.startsWith('/') && path.length > 2 && path[2] == ':') {
      path = path.substring(1);
    }
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) throw Exception('图片文件为空');
    return bytes;
  }

  Future<void> _handleWikiLinkTap(String targetTitle) async {
    final firestore = FirestoreService.instance;
    final notes = await firestore.getNotesOnce();

    final existingIndex = notes.indexWhere(
      (n) => n.title.toLowerCase() == targetTitle.toLowerCase(),
    );

    if (!mounted) return;

    if (existingIndex != -1) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => NoteEditorScreen(note: notes[existingIndex]),
        ),
      );
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('新建关联笔记'),
          content: Text('笔记《$targetTitle》不存在。是否立即创建并打开它？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('创建'),
            ),
          ],
        ),
      );

      if (confirm == true && mounted) {
        final currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser == null) return;

        final newNote = Note(
          id: const Uuid().v4(),
          title: targetTitle,
          content: '',
          contentType: NoteContentType.markdown,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          userId: currentUser.uid,
        );

        await firestore.addNote(newNote);

        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => NoteEditorScreen(note: newNote),
            ),
          );
        }
      }
    }
  }

  String _processWikiLinks(String text) {
    return text.replaceAllMapped(RegExp(r'\[\[(.*?)\]\]'), (match) {
      final title = match.group(1)!.trim();
      final encodedTitle = Uri.encodeComponent(title);
      return '[$title](wiki://$encodedTitle)';
    });
  }

  Widget _buildBacklinks() {
    final note = widget.note;
    if (note == null) return const SizedBox.shrink();
    return StreamBuilder<List<Note>>(
      stream: FirestoreService.instance.watchNoteBacklinks(note.id),
      builder: (context, snapshot) {
        final backlinks = snapshot.data ?? const <Note>[];
        if (backlinks.isEmpty) return const SizedBox.shrink();
        return Wrap(
          spacing: 6,
          children: [
            const Chip(label: Text('反向链接')),
            ...backlinks.map(
              (linked) => ActionChip(
                label: Text(linked.title),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => NoteEditorScreen(note: linked),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  double _calculateStackHeight(double scale) {
    double maxY = 400.0 * scale;
    for (final img in _noteImages) {
      final bottomY = (img.y + img.height) * scale;
      if (bottomY > maxY) {
        maxY = bottomY;
      }
    }
    for (final txt in _noteTexts) {
      final bottomY = (txt.y + txt.height) * scale;
      if (bottomY > maxY) {
        maxY = bottomY;
      }
    }
    return maxY + 150.0;
  }

  /// Safely normalize a local file path (supports Windows drive letters and percent-encoded URIs)
  String _normalizeLocalPath(String url) {
    var cleanPath = url;
    // Strip file:// prefix
    if (cleanPath.startsWith('file:///')) {
      cleanPath = cleanPath.substring(8);
    } else if (cleanPath.startsWith('file://')) {
      cleanPath = cleanPath.substring(7);
    }
    // Percent-decode safely
    try {
      cleanPath = Uri.decodeComponent(cleanPath);
    } catch (_) {}
    // Strip leading slash before Windows drive letter (e.g. /D:/... -> D:/...)
    if (cleanPath.startsWith('/') &&
        cleanPath.length > 2 &&
        cleanPath[2] == ':') {
      cleanPath = cleanPath.substring(1);
    }
    return cleanPath;
  }

  Widget _buildEditableImage(PositionedImage image, int index) {
    final url = image.url;
    final double currentCanvasWidth = (MediaQuery.of(context).size.width - 32)
        .clamp(200.0, double.infinity);
    final double scale = currentCanvasWidth / _canvasWidth;
    final double x = image.x * scale;
    final double y = image.y * scale;
    final double width = image.width * scale;
    final double height = image.height * scale;

    return Positioned(
      left: x,
      top: y,
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                image.x = (image.x + details.delta.dx / scale).clamp(
                  0.0,
                  _canvasWidth - image.width,
                );
                // Clamp y >= 0 so image cannot be dragged above the content area
                image.y = (image.y + details.delta.dy / scale).clamp(
                  0.0,
                  double.infinity,
                );
              });
            },
            onTap: () {
              showPhotoPreviewDialog(context, url, (newUrl) {
                setState(() {
                  image.url = newUrl;
                });
              }, 'notes');
            },
            child: SizedBox(
              width: width,
              height: height,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: WebdavImageWidget(url: url, fit: BoxFit.cover),
                ),
              ),
            ),
          ),
          Positioned(
            top: -10,
            right: -10,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _noteImages.removeAt(index);
                });
              },
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(4),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            bottom: -10,
            right: -10,
            child: GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  image.width = (image.width + details.delta.dx / scale).clamp(
                    50.0,
                    800.0,
                  );
                  image.height = (image.height + details.delta.dy / scale)
                      .clamp(50.0, 800.0);
                });
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeUpLeftDownRight,
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: const Icon(
                    Icons.open_in_full,
                    size: 12,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewImage(PositionedImage image) {
    final url = image.url;
    final double currentCanvasWidth = (MediaQuery.of(context).size.width - 32)
        .clamp(200.0, double.infinity);
    final double scale = currentCanvasWidth / _canvasWidth;
    final double x = image.x * scale;
    final double y = image.y * scale;
    final double width = image.width * scale;
    final double height = image.height * scale;

    return Positioned(
      left: x,
      top: y,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: () {
          showPhotoPreviewDialog(
            context,
            url,
            null, // Disables doodle editing button in preview mode
            'notes',
          );
        },
        child: SizedBox(
          width: width,
          height: height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: WebdavImageWidget(url: url, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }

  Widget _buildEditableText(PositionedText textObj, int index) {
    final double currentCanvasWidth = (MediaQuery.of(context).size.width - 32)
        .clamp(200.0, double.infinity);
    final double scale = currentCanvasWidth / _canvasWidth;
    final double x = textObj.x * scale;
    final double y = textObj.y * scale;
    final double width = textObj.width * scale;
    final double height = textObj.height * scale;
    final bool isFocused = _focusedTextIndex == index;

    return Positioned(
      left: x,
      top: y,
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                textObj.x = (textObj.x + details.delta.dx / scale).clamp(
                  0.0,
                  _canvasWidth - textObj.width,
                );
                textObj.y = (textObj.y + details.delta.dy / scale).clamp(
                  0.0,
                  double.infinity,
                );
              });
            },
            onTap: () {
              setState(() {
                _focusedTextIndex = index;
              });
            },
            child: SizedBox(
              width: width,
              height: height,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isFocused
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.3),
                    width: isFocused ? 2 : 1,
                    style: BorderStyle.solid,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  color: isFocused
                      ? Theme.of(context).colorScheme.surface
                      : Theme.of(
                          context,
                        ).colorScheme.surface.withValues(alpha: 0.8),
                ),
                padding: const EdgeInsets.all(8),
                child: isFocused
                    ? TextField(
                        controller: TextEditingController(text: textObj.text)
                          ..selection = TextSelection.fromPosition(
                            TextPosition(offset: textObj.text.length),
                          ),
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontSize: 14.0 * scale,
                        ),
                        onChanged: (val) {
                          textObj.text = val;
                        },
                        contextMenuBuilder: (context, editableTextState) {
                          return AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: editableTextState.contextMenuAnchors,
                            buttonItems: AiContextMenuHelper.buildButtonItems(
                              context,
                              editableTextState,
                            ),
                          );
                        },
                      )
                    : SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: Text(
                          textObj.text.isEmpty ? '双击编辑文本' : textObj.text,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontSize: 14.0 * scale),
                        ),
                      ),
              ),
            ),
          ),
          if (isFocused) ...[
            Positioned(
              top: -10,
              right: -10,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _noteTexts.removeAt(index);
                    _focusedTextIndex = null;
                  });
                },
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(4),
                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              bottom: -10,
              right: -10,
              child: GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    textObj.width = (textObj.width + details.delta.dx / scale)
                        .clamp(50.0, 800.0);
                    textObj.height = (textObj.height + details.delta.dy / scale)
                        .clamp(30.0, 800.0);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpLeftDownRight,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const Icon(
                      Icons.open_in_full,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPreviewText(PositionedText textObj) {
    final double currentCanvasWidth = (MediaQuery.of(context).size.width - 32)
        .clamp(200.0, double.infinity);
    final double scale = currentCanvasWidth / _canvasWidth;
    final double x = textObj.x * scale;
    final double y = textObj.y * scale;
    final double width = textObj.width * scale;
    final double height = textObj.height * scale;

    return Positioned(
      left: x,
      top: y,
      width: width,
      height: height,
      child: SizedBox(
        width: width,
        height: height,
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Text(
            textObj.text,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontSize: 14.0 * scale),
          ),
        ),
      ),
    );
  }

  Future<void> _showExportDialog() async {
    if (widget.note == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先保存笔记再进行导出')));
      return;
    }

    final hasImages = _noteImages.isNotEmpty;
    final recommendedType = hasImages ? 'pdf' : 'md';

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出笔记'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              hasImages
                  ? '📋 检测到笔记中包含图片与排版，推荐导出为 PDF 格式。'
                  : '📝 检测到笔记为纯文本，推荐导出为 Markdown 格式。',
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
              title: const Text('导出为 PDF 文件'),
              trailing: recommendedType == 'pdf'
                  ? const Chip(
                      label: Text(
                        '推荐',
                        style: TextStyle(color: Colors.white, fontSize: 10),
                      ),
                      backgroundColor: Colors.green,
                    )
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                ExportService.instance.exportNoteToPdf(context, widget.note!);
              },
            ),
            ListTile(
              leading: const Icon(Icons.text_snippet, color: Colors.blue),
              title: const Text('导出为 Markdown 文件'),
              trailing: recommendedType == 'md'
                  ? const Chip(
                      label: Text(
                        '推荐',
                        style: TextStyle(color: Colors.white, fontSize: 10),
                      ),
                      backgroundColor: Colors.green,
                    )
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                ExportService.instance.exportNoteToMarkdown(
                  context,
                  widget.note!,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyS):
            const SaveIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyS):
            const SaveIntent(),
      },
      child: Actions(
        actions: {
          SaveIntent: CallbackAction<SaveIntent>(
            onInvoke: (intent) => _saveNote(),
          ),
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.note == null ? '新建笔记' : '编辑笔记'),
            actions: [
              IconButton(
                icon: const Icon(Icons.auto_awesome),
                tooltip: '智能全媒体总结',
                onPressed: _isExtracting ? null : _generateMixedSummary,
              ),
              IconButton(
                icon: const Icon(Icons.file_download_outlined),
                tooltip: '导出笔记',
                onPressed: _showExportDialog,
              ),
              IconButton(
                icon: Icon(_isPreview ? Icons.edit : Icons.menu_book),
                tooltip: _isPreview ? '编辑模式' : '预览模式',
                onPressed: () {
                  setState(() {
                    _isPreview = !_isPreview;
                  });
                },
              ),
              if (widget.note != null)
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) {
                    if (value == 'history') {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => NoteHistoryScreen(note: widget.note!),
                        ),
                      );
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'history', child: Text('历史版本')),
                  ],
                ),
              if (_isSaving)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
                IconButton(icon: const Icon(Icons.check), onPressed: _saveNote),
            ],
          ),
          bottomNavigationBar: BottomAppBar(
            child: _isListening
                ? Row(
                    children: [
                      const SizedBox(width: 16),
                      const Icon(Icons.mic, color: Colors.red),
                      const SizedBox(width: 8),
                      const Text(
                        '🎙️ 录音中...',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                      const Expanded(child: _RecordingWaveWidget()),
                      IconButton(
                        icon: const Icon(
                          Icons.stop_circle,
                          color: Colors.red,
                          size: 28,
                        ),
                        tooltip: '停止录音',
                        onPressed: _toggleListening,
                      ),
                      const SizedBox(width: 16),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        tooltip: '语音输入',
                        icon: _isTranscribing
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.mic_none),
                        onPressed: _isTranscribing ? null : _toggleListening,
                      ),
                      IconButton(
                        tooltip: '插入照片',
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        onPressed: _isExtracting
                            ? null
                            : _insertPhotoAttachment,
                      ),
                      IconButton(
                        tooltip: '照片转文字 (OCR)',
                        icon: const Icon(Icons.document_scanner),
                        onPressed: _isExtracting ? null : _extractTextFromImage,
                      ),
                      IconButton(
                        tooltip: '添加悬浮文本块',
                        icon: const Icon(Icons.text_fields),
                        onPressed: () {
                          setState(() {
                            double insertY = 100.0;
                            if (_noteImages.isNotEmpty) {
                              insertY = math.max(
                                insertY,
                                _noteImages.last.y + 50.0,
                              );
                            }
                            if (_noteTexts.isNotEmpty) {
                              insertY = math.max(
                                insertY,
                                _noteTexts.last.y + 50.0,
                              );
                            }
                            _noteTexts.add(
                              PositionedText(
                                text: '',
                                x: 20.0,
                                y: insertY,
                                width: 200.0,
                                height: 100.0,
                              ),
                            );
                            _focusedTextIndex =
                                _noteTexts.length - 1; // Focus the new text box
                          });
                        },
                      ),
                      IconButton(
                        tooltip: '网页链接总结',
                        icon: const Icon(Icons.link),
                        onPressed: _isExtracting ? null : _importWebLink,
                      ),
                    ],
                  ),
          ),
          body: Stack(
            children: [
              SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!_isPreview) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  '💡 提示：使用 [[其它笔记标题]]（如 [[ssss]]）在正文中创建内链与在图谱中连线。图片可随意左右移动和拖拽，按住右下角图标可直接放大或缩小图片。',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        _buildWikiRecommendationBar(),
                        _buildBacklinks(),
                        const SizedBox(height: 8),
                      ],
                      if (_noteVoiceUrls.isNotEmpty)
                        Column(
                          children: _noteVoiceUrls.map((url) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8.0),
                              child: Row(
                                children: [
                                  Expanded(child: VoicePlayerWidget(url: url)),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                    ),
                                    onPressed: () async {
                                      setState(() {
                                        _noteVoiceUrls.remove(url);
                                      });
                                      if (!url.startsWith('webdav://') &&
                                          !url.startsWith('http://') &&
                                          !url.startsWith('https://')) {
                                        try {
                                          final f = File(url);
                                          if (await f.exists()) {
                                            await f.delete();
                                          }
                                        } catch (_) {}
                                      }
                                    },
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      TextField(
                        controller: _titleController,
                        decoration: const InputDecoration(
                          hintText: '标题',
                          border: InputBorder.none,
                        ),
                        style: Theme.of(context).textTheme.headlineSmall,
                        contextMenuBuilder: (context, editableTextState) {
                          return AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: editableTextState.contextMenuAnchors,
                            buttonItems: AiContextMenuHelper.buildButtonItems(
                              context,
                              editableTextState,
                            ),
                          );
                        },
                      ),
                      if (!_isPreview) ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _categoryController,
                                decoration: const InputDecoration(
                                  prefixIcon: Icon(Icons.folder_outlined),
                                  hintText: '分类',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                controller: _tagsController,
                                decoration: const InputDecoration(
                                  prefixIcon: Icon(Icons.sell_outlined),
                                  hintText: '标签（逗号分隔）',
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: _isArchived ? '取消归档' : '归档',
                              icon: Icon(
                                _isArchived
                                    ? Icons.unarchive_outlined
                                    : Icons.archive_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => _isArchived = !_isArchived),
                            ),
                          ],
                        ),
                      ],
                      const Divider(),
                      const SizedBox(height: 8),
                      // Visual canvas area: explicit dynamic minHeight so SingleChildScrollView knows
                      // the full scroll extent and scrollbar updates in real-time.
                      Builder(
                        builder: (context) {
                          final double currentCanvasWidth =
                              (MediaQuery.of(context).size.width - 32).clamp(
                                200.0,
                                double.infinity,
                              );
                          if (_canvasWidth == 400.0) {
                            _canvasWidth = currentCanvasWidth;
                          }
                          final double scale =
                              currentCanvasWidth / _canvasWidth;
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: currentCanvasWidth,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  setState(() {
                                    _focusedTextIndex = null;
                                  });
                                },
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: _calculateStackHeight(scale),
                                  ),
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      // 1. Text Layer (non-positioned child to naturally size Stack height if taller)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 100,
                                        ), // padding at bottom of text for readability
                                        child: _isPreview
                                            ? MarkdownBody(
                                                data: _processWikiLinks(
                                                  _bodyController.text,
                                                ),
                                                syntaxHighlighter:
                                                    _FenceHighlighter(),
                                                onTapLink: (text, href, title) {
                                                  if (href != null &&
                                                      href.startsWith(
                                                        'wiki://',
                                                      )) {
                                                    final targetTitle =
                                                        Uri.decodeComponent(
                                                          href.replaceFirst(
                                                            'wiki://',
                                                            '',
                                                          ),
                                                        );
                                                    _handleWikiLinkTap(
                                                      targetTitle,
                                                    );
                                                  }
                                                },
                                                styleSheet:
                                                    MarkdownStyleSheet.fromTheme(
                                                      Theme.of(context),
                                                    ).copyWith(
                                                      p: Theme.of(context)
                                                          .textTheme
                                                          .bodyLarge
                                                          ?.copyWith(
                                                            height: 1.6,
                                                            fontSize:
                                                                14.0 * scale,
                                                          ),
                                                    ),
                                              )
                                            : TextField(
                                                controller: _bodyController,
                                                maxLines: null,
                                                keyboardType:
                                                    TextInputType.multiline,
                                                decoration:
                                                    const InputDecoration(
                                                      hintText: '开始在这里编写内容...',
                                                      border: InputBorder.none,
                                                    ),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyLarge
                                                    ?.copyWith(
                                                      height: 1.6,
                                                      fontSize: 14.0 * scale,
                                                    ),
                                                contextMenuBuilder:
                                                    (
                                                      context,
                                                      editableTextState,
                                                    ) {
                                                      return AdaptiveTextSelectionToolbar.buttonItems(
                                                        anchors: editableTextState
                                                            .contextMenuAnchors,
                                                        buttonItems:
                                                            AiContextMenuHelper.buildButtonItems(
                                                              context,
                                                              editableTextState,
                                                            ),
                                                      );
                                                    },
                                              ),
                                      ),
                                      // 2. Draggable and Resizable Images and Texts Layer (floats on top of text)
                                      if (_isPreview) ...[
                                        ..._noteImages.map(
                                          (img) => _buildPreviewImage(img),
                                        ),
                                        ..._noteTexts.map(
                                          (txt) => _buildPreviewText(txt),
                                        ),
                                      ] else ...[
                                        ..._noteImages.asMap().entries.map(
                                          (entry) => _buildEditableImage(
                                            entry.value,
                                            entry.key,
                                          ),
                                        ),
                                        ..._noteTexts.asMap().entries.map(
                                          (entry) => _buildEditableText(
                                            entry.value,
                                            entry.key,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              if (_isExtracting)
                const Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('正在处理媒体数据...'),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordingWaveWidget extends StatefulWidget {
  const _RecordingWaveWidget();

  @override
  State<_RecordingWaveWidget> createState() => _RecordingWaveWidgetState();
}

class _RecordingWaveWidgetState extends State<_RecordingWaveWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(8, (index) {
            final double phase = (index * 0.5);
            final double amp = math
                .sin((_controller.value * 2 * math.pi) + phase)
                .abs();
            final double height = 8 + (24 * amp);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 4,
              height: height,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}
