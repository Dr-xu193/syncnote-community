import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:syncnote/shared/models/diary_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/ai_service.dart';
import 'package:syncnote/shared/services/daily_ai_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:syncnote/shared/services/audio_record_service.dart';
import 'package:syncnote/shared/widgets/voice_player_widget.dart';
import 'package:syncnote/shared/screens/doodle_screen.dart';
import 'package:syncnote/shared/widgets/webdav_image_widget.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';

class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
  }

  void _showDiaryEntrySheet(DateTime date, DiaryEntry? existingEntry) {
    showDiaryEntrySheet(context, date, existingEntry);
  }

  List<DiaryEntry> _getEventsForDay(DateTime day, List<DiaryEntry> allEntries) {
    return allEntries.where((entry) => isSameDay(entry.date, day)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visibleFrom = DateTime(_focusedDay.year, _focusedDay.month - 1, 1);
    final visibleTo = DateTime(_focusedDay.year, _focusedDay.month + 2, 1);
    return Scaffold(
      appBar: AppBar(
        title: const Text('日记'),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'AI心灵情绪复盘',
            onPressed: () => _showAiMoodReviewDialog(context),
          ),
        ],
      ),
      body: StreamBuilder<List<DiaryEntry>>(
        stream: FirestoreService.instance.watchDiaryRange(
          visibleFrom,
          visibleTo,
        ),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final entries = snapshot.data ?? [];

          return Column(
            children: [
              TableCalendar<DiaryEntry>(
                firstDay: DateTime.utc(2000, 1, 1),
                lastDay: DateTime.utc(2100, 12, 31),
                focusedDay: _focusedDay,
                selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                onDaySelected: (selectedDay, focusedDay) {
                  setState(() {
                    _selectedDay = selectedDay;
                    _focusedDay = focusedDay;
                  });
                  final entriesForDay = _getEventsForDay(selectedDay, entries);
                  _showDiaryEntrySheet(
                    selectedDay,
                    entriesForDay.isNotEmpty ? entriesForDay.first : null,
                  );
                },
                onPageChanged: (focusedDay) {
                  setState(() => _focusedDay = focusedDay);
                },
                locale: 'zh_CN',
                eventLoader: (day) => _getEventsForDay(day, entries),
                calendarStyle: const CalendarStyle(
                  markerDecoration: BoxDecoration(
                    color: Colors.blueAccent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('选择日期以查看或添加日记。'),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () {
                          if (_selectedDay != null) {
                            final entriesForDay = _getEventsForDay(
                              _selectedDay!,
                              entries,
                            );
                            _showDiaryEntrySheet(
                              _selectedDay!,
                              entriesForDay.isNotEmpty
                                  ? entriesForDay.first
                                  : null,
                            );
                          }
                        },
                        child: const Text('添加 / 编辑该日期的日记'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAiMoodReviewDialog(BuildContext context) {
    showAiReportSheet(context);
  }
}

bool _aiReportSheetVisible = false;

Future<bool> showAiReportSheet(
  BuildContext context, {
  String? initialType,
  String? initialReport,
  bool automatic = false,
  Future<void> Function()? onPresented,
}) async {
  if (_aiReportSheetVisible || !context.mounted) return false;
  _aiReportSheetVisible = true;
  try {
    final firstFrame = Completer<void>();
    final sheetClosed = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        if (!firstFrame.isCompleted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!firstFrame.isCompleted) firstFrame.complete();
          });
        }
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: _AiMoodReviewSheet(
            initialType: initialType,
            initialReport: initialReport,
            automatic: automatic,
          ),
        );
      },
    );
    // Persist the once-per-day state only after the sheet has rendered at
    // least one frame. A route that failed before rendering must stay retryable.
    await firstFrame.future.timeout(const Duration(seconds: 5));
    Object? presentationError;
    StackTrace? presentationStack;
    try {
      await onPresented?.call();
    } catch (error, stackTrace) {
      presentationError = error;
      presentationStack = stackTrace;
    }
    await sheetClosed;
    if (presentationError != null) {
      Error.throwWithStackTrace(presentationError, presentationStack!);
    }
    return true;
  } finally {
    _aiReportSheetVisible = false;
  }
}

Future<void> showDiaryEntrySheet(
  BuildContext context,
  DateTime date,
  DiaryEntry? existingEntry,
) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) {
      return DiaryEntrySheet(date: date, entry: existingEntry);
    },
  );
}

class DiaryEntrySheet extends StatefulWidget {
  final DateTime date;
  final DiaryEntry? entry;

  const DiaryEntrySheet({super.key, required this.date, this.entry});

  @override
  State<DiaryEntrySheet> createState() => DiaryEntrySheetState();
}

class DiaryEntrySheetState extends State<DiaryEntrySheet> {
  late TextEditingController _contentController;
  Mood _selectedMood = Mood.neutral;
  List<String> _imageUrls = [];
  List<String> _voiceUrls = [];
  bool _isRecording = false;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(
      text: widget.entry?.content ?? '',
    );
    _selectedMood = widget.entry?.mood ?? Mood.neutral;
    _imageUrls = List<String>.from(widget.entry?.images ?? []);
    _voiceUrls =
        widget.entry?.voiceUrls != null && widget.entry!.voiceUrls.isNotEmpty
        ? List<String>.from(widget.entry!.voiceUrls)
        : (widget.entry?.voiceUrl != null ? [widget.entry!.voiceUrl!] : []);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncLocalAttachmentsToCloud();
    });
  }

  Future<void> _syncLocalAttachmentsToCloud() async {
    bool updated = false;
    for (var i = 0; i < _imageUrls.length; i++) {
      final url = _imageUrls[i];
      if (!url.startsWith('http://') &&
          !url.startsWith('https://') &&
          !url.startsWith('webdav://')) {
        final localFile = File(url);
        if (await localFile.exists()) {
          final cloudUrl = await UploadService.instance.uploadFile(
            localFile,
            'diaries',
          );
          if (cloudUrl != null && cloudUrl.startsWith('webdav://')) {
            _imageUrls[i] = cloudUrl;
            updated = true;
          }
        }
      }
    }
    for (var i = 0; i < _voiceUrls.length; i++) {
      final url = _voiceUrls[i];
      if (!url.startsWith('http://') &&
          !url.startsWith('https://') &&
          !url.startsWith('webdav://')) {
        final localFile = File(url);
        if (await localFile.exists()) {
          final cloudUrl = await UploadService.instance.uploadFile(
            localFile,
            'diaries',
          );
          if (cloudUrl != null && cloudUrl.startsWith('webdav://')) {
            _voiceUrls[i] = cloudUrl;
            updated = true;
          }
        }
      }
    }
    if (updated && widget.entry != null && mounted) {
      setState(() {});
      final updatedEntry = widget.entry!.copyWith(
        images: _imageUrls,
        voiceUrl: _voiceUrls.isNotEmpty ? _voiceUrls.first : null,
        voiceUrls: _voiceUrls,
        updatedAt: DateTime.now(),
      );
      await FirestoreService.instance.saveDiaryEntry(updatedEntry);
    }
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  String _moodEmoji(Mood mood) {
    switch (mood) {
      case Mood.great:
        return '🤩 极好';
      case Mood.good:
        return '😊 不错';
      case Mood.neutral:
        return '😐 平静';
      case Mood.bad:
        return '😔 糟糕';
      case Mood.awful:
        return '😭 极差';
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (pickedFile == null) return;

    setState(() {
      _imageUrls.add(pickedFile.path);
    });
  }

  Future<void> _startRecording() async {
    final success = await AudioRecordService.instance.startRecording();
    if (success) {
      setState(() => _isRecording = true);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法启动录音，请检查设备麦克风权限')));
      }
    }
  }

  Future<void> _stopRecording() async {
    final path = await AudioRecordService.instance.stopRecording();
    setState(() => _isRecording = false);

    if (path != null) {
      setState(() {
        _voiceUrls.add(path);
      });
    }
  }

  void _saveEntry() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error: User not logged in.')),
      );
      return;
    }

    setState(() => _isUploading = true);
    try {
      final List<String> finalImageUrls = [];
      for (final url in _imageUrls) {
        if (url.startsWith('webdav://') ||
            url.startsWith('http://') ||
            url.startsWith('https://')) {
          finalImageUrls.add(url);
        } else {
          final file = File(url);
          if (await file.exists()) {
            final cloudUrl = await UploadService.instance.uploadFile(
              file,
              'diaries',
            );
            if (cloudUrl != null) {
              finalImageUrls.add(cloudUrl);
            } else {
              finalImageUrls.add(url);
            }
          }
        }
      }

      final List<String> finalVoiceUrls = [];
      for (final url in _voiceUrls) {
        if (url.startsWith('webdav://') ||
            url.startsWith('http://') ||
            url.startsWith('https://')) {
          finalVoiceUrls.add(url);
        } else {
          final file = File(url);
          if (await file.exists()) {
            final cloudUrl = await UploadService.instance.uploadFile(
              file,
              'diaries',
            );
            if (cloudUrl != null) {
              finalVoiceUrls.add(cloudUrl);
            } else {
              finalVoiceUrls.add(url);
            }
          }
        }
      }

      final entry = DiaryEntry(
        id: widget.entry?.id ?? const Uuid().v4(),
        date: widget.date,
        content: _contentController.text,
        mood: _selectedMood,
        images: finalImageUrls,
        voiceUrl: finalVoiceUrls.isNotEmpty ? finalVoiceUrls.first : null,
        voiceUrls: finalVoiceUrls,
        createdAt: widget.entry?.createdAt ?? DateTime.now(),
        updatedAt: DateTime.now(),
        userId: user.uid,
      );

      await FirestoreService.instance.saveDiaryEntry(entry);

      // Clean up deleted WebDAV attachments
      if (widget.entry != null) {
        final oldImages = widget.entry!.images;
        final deletedImages = oldImages
            .where(
              (url) =>
                  !finalImageUrls.contains(url) && url.startsWith('webdav://'),
            )
            .toList();

        final oldVoices = widget.entry!.voiceUrls;
        final deletedVoices = oldVoices
            .where(
              (url) =>
                  !finalVoiceUrls.contains(url) && url.startsWith('webdav://'),
            )
            .toList();

        await FirestoreService.instance.deleteAttachmentsIfUnreferenced([
          ...deletedImages,
          ...deletedVoices,
        ]);
      }

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存日记失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      padding: EdgeInsets.only(
        left: 16.0,
        right: 16.0,
        top: 24.0,
        bottom: bottomInset + 24.0,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.entry == null ? '新建日记' : '编辑日记',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              '${widget.date.year}-${widget.date.month.toString().padLeft(2, '0')}-${widget.date.day.toString().padLeft(2, '0')}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<Mood>(
              initialValue: _selectedMood,
              decoration: const InputDecoration(
                labelText: '心情',
                border: OutlineInputBorder(),
              ),
              items: Mood.values.map((mood) {
                return DropdownMenuItem(
                  value: mood,
                  child: Text(_moodEmoji(mood)),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _selectedMood = val;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _contentController,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '正文',
                border: OutlineInputBorder(),
              ),
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
            const SizedBox(height: 16),
            const Text('照片附件：', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _buildImagesSection(),
            const SizedBox(height: 16),
            const Text('语音记录：', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _buildVoiceSection(),
            if (_isUploading) ...[
              const SizedBox(height: 8),
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
                    Text(
                      '正在上传媒体文件...',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                if (widget.entry != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                      onPressed: () async {
                        await FirestoreService.instance.deleteDiaryEntry(
                          widget.entry!.id,
                        );
                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                      icon: const Icon(Icons.delete),
                      label: const Text('删除'),
                    ),
                  ),
                if (widget.entry != null) const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saveEntry,
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentImage(
    String url, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.cover,
  }) {
    if (url.startsWith('webdav://')) {
      return WebdavImageWidget(
        url: url,
        width: width,
        height: height,
        fit: fit,
      );
    } else if (url.startsWith('http://') || url.startsWith('https://')) {
      return Image.network(
        url,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => Container(
          width: width,
          height: height,
          color: Colors.grey.withValues(alpha: 0.1),
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      );
    } else {
      return Image.file(
        File(url),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => Container(
          width: width,
          height: height,
          color: Colors.grey.withValues(alpha: 0.1),
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      );
    }
  }

  Widget _buildImagesSection() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ..._imageUrls.map((url) {
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: GestureDetector(
                  onTap: () {
                    showPhotoPreviewDialog(context, url, (newUrl) {
                      setState(() {
                        final idx = _imageUrls.indexOf(url);
                        if (idx != -1) {
                          _imageUrls[idx] = newUrl;
                        }
                      });
                    }, 'diaries');
                  },
                  child: _buildAttachmentImage(url, width: 80, height: 80),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _imageUrls.remove(url);
                    });
                  },
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: const Icon(
                      Icons.close,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          );
        }),
        GestureDetector(
          onTap: _isUploading ? null : _pickImage,
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
            ),
            child: const Icon(Icons.add_photo_alternate, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_voiceUrls.isNotEmpty)
          ..._voiceUrls.map((url) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  Expanded(child: VoicePlayerWidget(url: url)),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      setState(() {
                        _voiceUrls.remove(url);
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
          }),
        if (_isRecording)
          Card(
            color: Colors.red.withValues(alpha: 0.05),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: Colors.redAccent, width: 0.5),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.mic, color: Colors.red),
                  const SizedBox(width: 8),
                  const Text(
                    '🎙️ 录制中...',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: _stopRecording,
                    icon: const Icon(Icons.stop),
                    label: const Text('停止'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: _isUploading ? null : _startRecording,
            icon: const Icon(Icons.mic_none),
            label: const Text('录制一段声音日记'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
      ],
    );
  }
}

class _AiMoodReviewSheet extends StatefulWidget {
  final String? initialType;
  final String? initialReport;
  final bool automatic;
  const _AiMoodReviewSheet({
    this.initialType,
    this.initialReport,
    this.automatic = false,
  });

  @override
  State<_AiMoodReviewSheet> createState() => _AiMoodReviewSheetState();
}

class _AiMoodReviewSheetState extends State<_AiMoodReviewSheet> {
  String? _analysisReport;
  bool _isLoading = false;
  String? _error;
  int _selectedDaysRange = 7; // default to 7 days
  bool _showRangeConfig = false;
  String _currentReportTitle = 'AI 心灵情绪复盘报告';

  @override
  void initState() {
    super.initState();
    if (widget.initialReport != null) {
      _analysisReport = widget.initialReport;
      _currentReportTitle = widget.initialType == 'evening_reflection'
          ? 'AI 今日心灵暮省'
          : 'AI 今日日程晨报';
      return;
    }
    if (widget.initialType != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (widget.initialType == 'daily_briefing') {
          _generateDailyBriefing(automatic: widget.automatic);
        } else if (widget.initialType == 'evening_reflection') {
          _generateEveningReflection(automatic: widget.automatic);
        }
      });
    }
  }

  Future<void> _generateReport() async {
    setState(() {
      _isLoading = true;
      _analysisReport = null;
      _error = null;
      _currentReportTitle = 'AI 心灵情绪复盘报告';
    });

    try {
      final entries = await FirestoreService.instance.watchDiaryEntries().first;
      final thresholdDate = DateTime.now().subtract(
        Duration(days: _selectedDaysRange),
      );
      final filteredEntries = entries
          .where((d) => d.date.isAfter(thresholdDate))
          .toList();

      if (filteredEntries.isEmpty) {
        if (mounted) {
          setState(() {
            _analysisReport = '所选时间段内没有记录任何日记，无法进行心灵复盘。建议多写写日记再来体验哦！';
            _isLoading = false;
          });
        }
        return;
      }

      final report = await AIService.instance.analyzeMoodAndLife(
        filteredEntries,
      );

      if (mounted) {
        setState(() {
          _analysisReport = report ?? '生成分析失败，请稍后重试。';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '生成分析失败: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _generateDailyBriefing({bool automatic = false}) async {
    setState(() {
      _isLoading = true;
      _analysisReport = null;
      _error = null;
      _currentReportTitle = 'AI 今日日程晨报';
    });

    try {
      final result = await DailyAiService.instance.checkAndGenerate(
        automatic: automatic,
        forceWindow: DailyAiWindow.morning,
      );

      if (mounted) {
        setState(() {
          _analysisReport = result?.content ?? '今日晨报正在另一台设备生成，请稍后重试。';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '生成今日晨报失败: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _generateEveningReflection({bool automatic = false}) async {
    setState(() {
      _isLoading = true;
      _analysisReport = null;
      _error = null;
      _currentReportTitle = 'AI 今日心灵暮省';
    });

    try {
      final result = await DailyAiService.instance.checkAndGenerate(
        automatic: automatic,
        forceWindow: DailyAiWindow.evening,
      );

      if (mounted) {
        setState(() {
          _analysisReport = result?.content ?? '今日暮省正在另一台设备生成，请稍后重试。';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '生成今日暮省失败: $e';
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildOptionCard(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.12),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('🪄 SyncNote AI 助理'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_analysisReport == null && !_isLoading && _error == null) ...[
              if (!_showRangeConfig) ...[
                Text(
                  'AI 导师每日分析与建议',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'AI 导师将提炼您的任务清单并深度关联日记心情，为您生成量身定制的心灵简报与行程建议。',
                  style: TextStyle(color: Colors.grey, height: 1.5),
                ),
                const SizedBox(height: 8),
                StreamBuilder<Map<String, bool>>(
                  stream: DailyAiService.instance.watchAutoSettings(),
                  builder: (context, snapshot) {
                    final settings =
                        snapshot.data ??
                        const {'morning': true, 'evening': true};
                    return Column(
                      children: [
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('每天首次打开自动晨报'),
                          subtitle: const Text('07:00～22:59，每个逻辑日一次'),
                          value: settings['morning'] ?? true,
                          onChanged: (value) =>
                              DailyAiService.instance.setAutoEnabled(
                                window: DailyAiWindow.morning,
                                enabled: value,
                              ),
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('每天首次打开自动晚间复盘'),
                          subtitle: const Text('23:00～次日 06:59，凌晨归属前一日'),
                          value: settings['evening'] ?? true,
                          onChanged: (value) =>
                              DailyAiService.instance.setAutoEnabled(
                                window: DailyAiWindow.evening,
                                enabled: value,
                              ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                _buildOptionCard(
                  context,
                  icon: Icons.light_mode,
                  iconColor: Colors.orange,
                  title: '生成今日行程晨报',
                  description: '提取今日待办清单与近期情绪，给您最合理的精力与心情排程建议。',
                  onTap: _generateDailyBriefing,
                ),
                const SizedBox(height: 12),
                _buildOptionCard(
                  context,
                  icon: Icons.dark_mode,
                  iconColor: Colors.indigo,
                  title: '生成晚间暮省报告',
                  description: '梳理今日任务成果并深度复盘晚间情绪，给您温和的释怀关怀与晚安。',
                  onTap: _generateEveningReflection,
                ),
                const SizedBox(height: 12),
                _buildOptionCard(
                  context,
                  icon: Icons.analytics_outlined,
                  iconColor: Colors.purple,
                  title: '生成心灵情绪复盘报告',
                  description: '回顾最近 7 / 14 / 30 天的所有日记和心情趋势，建立长期的情绪走势与减压建议。',
                  onTap: () {
                    setState(() {
                      _showRangeConfig = true;
                    });
                  },
                ),
              ] else ...[
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () {
                        setState(() {
                          _showRangeConfig = false;
                        });
                      },
                    ),
                    Text(
                      '选择分析时间范围',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: _selectedDaysRange,
                  decoration: InputDecoration(
                    labelText: '分析范围',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(value: 7, child: Text('最近一周 (7天)')),
                    DropdownMenuItem(value: 14, child: Text('最近两周 (14天)')),
                    DropdownMenuItem(value: 30, child: Text('最近一月 (30天)')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedDaysRange = val);
                    }
                  },
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _generateReport,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('生成心灵复盘报告'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ],
            if (_isLoading)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40.0),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text('AI 正在翻阅并建立报告: $_currentReportTitle...'),
                    ],
                  ),
                ),
              ),
            if (_analysisReport != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.1,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      _currentReportTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              MarkdownBody(
                data: _analysisReport!,
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(fontSize: 14, height: 1.6),
                  h3: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    height: 2,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _analysisReport = null;
                    _showRangeConfig = false;
                  });
                },
                child: const Text('返回 AI 主面板'),
              ),
            ],
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  if (widget.initialType == 'daily_briefing') {
                    _generateDailyBriefing();
                  } else if (widget.initialType == 'evening_reflection') {
                    _generateEveningReflection();
                  } else {
                    _generateReport();
                  }
                },
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
