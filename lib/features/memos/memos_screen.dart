import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:flutter/material.dart';
import 'package:syncnote/features/settings/community_setup_screen.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:syncnote/core/theme/app_theme.dart';
import 'package:syncnote/core/providers/theme_provider.dart';
import 'package:syncnote/core/providers/auth_provider.dart';
import 'package:syncnote/shared/models/memo_model.dart';
import 'package:syncnote/shared/controllers/cursor_paged_controller.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/ai_service.dart';
import 'package:syncnote/shared/services/export_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:syncnote/shared/services/audio_record_service.dart';
import 'package:syncnote/shared/widgets/voice_player_widget.dart';
import 'package:syncnote/shared/screens/doodle_screen.dart';
import 'package:syncnote/shared/widgets/android_permission_center.dart';
import 'package:syncnote/shared/widgets/app_lock_widgets.dart';
import 'package:syncnote/features/cloud_files/cloud_files_screen.dart';
import 'package:syncnote/features/settings/storage_audit_screen.dart';
import 'package:syncnote/shared/utils/list_preview_text.dart';

import 'package:syncnote/shared/widgets/webdav_image_widget.dart';
import 'package:syncnote/shared/widgets/ai_context_menu.dart';

Widget _buildAttachmentImage(
  String url, {
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
}) {
  return WebdavImageWidget(url: url, width: width, height: height, fit: fit);
}

class MemosScreen extends StatefulWidget {
  const MemosScreen({super.key});

  @override
  State<MemosScreen> createState() => _MemosScreenState();
}

class _MemosScreenState extends State<MemosScreen> {
  static const int _pageSize = 40;

  late final CursorPagedController<Memo> _memosController;

  @override
  void initState() {
    super.initState();
    _memosController = CursorPagedController<Memo>(idOf: (memo) => memo.id);
    _prepareList();
  }

  Future<void> _prepareList() async {
    await FirestoreService.instance.preparePagedCollections();
    if (!mounted) return;
    _memosController.start(
      firstPage: FirestoreService.instance.watchMemosPage(limit: _pageSize),
      loadPage: (cursor) => FirestoreService.instance.getMemosPage(
        limit: _pageSize,
        startAfter: cursor,
      ),
    );
  }

  @override
  void dispose() {
    _memosController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '备忘录',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.symmetric(
                            horizontal: MediaQuery.sizeOf(context).width < 600
                                ? 12
                                : 18,
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const CloudFilesScreen(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.cloud_outlined, size: 19),
                        label: const Text('云文件'),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.settings_outlined),
                        tooltip: '设置与备份',
                        itemBuilder: (ctx) => [
                          const PopupMenuItem(
                            value: 'community_config',
                            child: Text('社区版服务配置'),
                          ),
                          const PopupMenuItem(
                            value: 'storage_audit',
                            child: Row(
                              children: [
                                Icon(Icons.analytics_outlined, size: 20),
                                SizedBox(width: 8),
                                Text('存储与基线审计'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'backup',
                            child: Row(
                              children: [
                                Icon(Icons.backup_outlined, size: 20),
                                SizedBox(width: 8),
                                Text('全量备份 (ZIP)'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'restore_backup',
                            child: Row(
                              children: [
                                Icon(Icons.restore_page_outlined, size: 20),
                                SizedBox(width: 8),
                                Text('从 ZIP 恢复'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'trash',
                            child: Row(
                              children: [
                                Icon(Icons.delete_sweep_outlined, size: 20),
                                SizedBox(width: 8),
                                Text('前往回收站'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'theme',
                            child: Row(
                              children: [
                                Icon(Icons.palette_outlined, size: 20),
                                SizedBox(width: 8),
                                Text('切换主题'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'app_lock',
                            child: Row(
                              children: [
                                Icon(Icons.lock_outline_rounded, size: 20),
                                SizedBox(width: 8),
                                Text('应用锁'),
                              ],
                            ),
                          ),
                          if (Platform.isAndroid)
                            const PopupMenuItem(
                              value: 'android_permissions',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.admin_panel_settings_outlined,
                                    size: 20,
                                  ),
                                  SizedBox(width: 8),
                                  Text('Android 权限中心'),
                                ],
                              ),
                            ),
                          const PopupMenuItem(
                            value: 'logout',
                            child: Row(
                              children: [
                                Icon(Icons.logout_rounded, size: 20),
                                SizedBox(width: 8),
                                Text('退出登录'),
                              ],
                            ),
                          ),
                        ],
                        onSelected: (val) async {
                          if (val == 'community_config') {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const CommunitySetupScreen(),
                              ),
                            );
                          } else if (val == 'storage_audit') {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const StorageAuditScreen(),
                              ),
                            );
                          } else if (val == 'backup') {
                            await ExportService.instance.exportAllDataToZip(
                              context,
                            );
                          } else if (val == 'restore_backup') {
                            await ExportService.instance.importAllDataFromZip(
                              context,
                            );
                          } else if (val == 'trash') {
                            context.pushNamed('trash');
                          } else if (val == 'theme') {
                            final provider = Provider.of<ThemeProvider>(
                              context,
                              listen: false,
                            );
                            provider.toggleTheme();
                          } else if (val == 'app_lock') {
                            await showAppLockSettingsDialog(context);
                          } else if (val == 'android_permissions') {
                            await showAndroidPermissionCenter(context);
                          } else if (val == 'logout') {
                            final provider = Provider.of<AuthProvider>(
                              context,
                              listen: false,
                            );
                            await provider.signOut();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: _memosController,
                builder: (context, _) {
                  if (_memosController.error != null &&
                      !_memosController.ready) {
                    return Center(
                      child: Text('加载出错: ${_memosController.error}'),
                    );
                  }

                  if (!_memosController.ready) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final memos = _memosController.items;
                  final visibleMemos = memos;
                  final hasMore = _memosController.hasMore;

                  if (memos.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.sticky_note_2_rounded,
                            size: 64,
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.2,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '还没有备忘录',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: visibleMemos.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == visibleMemos.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: OutlinedButton.icon(
                            onPressed: _memosController.loadingMore
                                ? null
                                : _memosController.loadMore,
                            icon: _memosController.loadingMore
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.expand_more_rounded),
                            label: Text('加载更多（已显示 ${visibleMemos.length}）'),
                          ),
                        );
                      }
                      final memo = visibleMemos[index];
                      return _MemoCard(memo: memo);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showAddMemoDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }
}

Future<void> showAddMemoDialog(
  BuildContext context, [
  Memo? existingMemo,
]) async {
  await showDialog(
    context: context,
    builder: (context) => AddMemoDialog(existingMemo: existingMemo),
  );
}

class AddMemoDialog extends StatefulWidget {
  final Memo? existingMemo;
  const AddMemoDialog({super.key, this.existingMemo});

  @override
  State<AddMemoDialog> createState() => AddMemoDialogState();
}

class AddMemoDialogState extends State<AddMemoDialog> {
  final _controller = TextEditingController();
  List<String> _imageUrls = [];
  List<String> _voiceUrls = [];
  bool _isRecording = false;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    if (widget.existingMemo != null) {
      _controller.text = widget.existingMemo!.content;
      _imageUrls = List<String>.from(widget.existingMemo!.images);
      _voiceUrls = widget.existingMemo!.voiceUrls.isNotEmpty
          ? List<String>.from(widget.existingMemo!.voiceUrls)
          : (widget.existingMemo!.voiceUrl != null
                ? [widget.existingMemo!.voiceUrl!]
                : []);
      _syncLocalAttachmentsToCloud();
    }
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
            'memos',
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
            'memos',
          );
          if (cloudUrl != null && cloudUrl.startsWith('webdav://')) {
            _voiceUrls[i] = cloudUrl;
            updated = true;
          }
        }
      }
    }
    if (updated && widget.existingMemo != null && mounted) {
      setState(() {});
      final updatedMemo = widget.existingMemo!.copyWith(
        images: _imageUrls,
        voiceUrl: _voiceUrls.isNotEmpty ? _voiceUrls.first : null,
        voiceUrls: _voiceUrls,
        updatedAt: DateTime.now(),
      );
      await FirestoreService.instance.updateMemo(updatedMemo);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existingMemo == null ? '新备忘录' : '编辑备忘录'),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                decoration: const InputDecoration(
                  hintText: '写点什么...',
                  border: InputBorder.none,
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
              const SizedBox(height: 12),
              const Text(
                '照片附件：',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 8),
              _buildImagesSection(),
              const SizedBox(height: 12),
              const Text(
                '语音附件：',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 8),
              _buildVoiceSection(),
              if (_isUploading) ...[
                const SizedBox(height: 8),
                const Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      ),
                      SizedBox(width: 6),
                      Text(
                        '正在上传文件...',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isUploading ? null : _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _buildImagesSection() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        ..._imageUrls.map((url) {
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: GestureDetector(
                  onTap: () {
                    showPhotoPreviewDialog(context, url, (newUrl) {
                      setState(() {
                        final idx = _imageUrls.indexOf(url);
                        if (idx != -1) {
                          _imageUrls[idx] = newUrl;
                        }
                      });
                    }, 'memos');
                  },
                  child: _buildAttachmentImage(url, width: 60, height: 60),
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
                    padding: const EdgeInsets.all(1.5),
                    child: const Icon(
                      Icons.close,
                      size: 12,
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
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
            ),
            child: const Icon(
              Icons.add_photo_alternate_outlined,
              size: 20,
              color: Colors.grey,
            ),
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
              padding: const EdgeInsets.only(bottom: 6.0),
              child: Row(
                children: [
                  Expanded(child: VoicePlayerWidget(url: url)),
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                      size: 20,
                    ),
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
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.mic, color: Colors.red, size: 18),
                const SizedBox(width: 6),
                const Text(
                  '录制中...',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _stopRecording,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(40, 24),
                  ),
                  child: const Text('停止', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: _isUploading ? null : _startRecording,
            icon: const Icon(Icons.mic_none, size: 16),
            label: const Text('录音备忘', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
      ],
    );
  }

  void _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _imageUrls.isEmpty && _voiceUrls.isEmpty) {
      Navigator.pop(context);
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
              'memos',
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
              'memos',
            );
            if (cloudUrl != null) {
              finalVoiceUrls.add(cloudUrl);
            } else {
              finalVoiceUrls.add(url);
            }
          }
        }
      }

      if (widget.existingMemo != null) {
        final updated = widget.existingMemo!.copyWith(
          content: text,
          images: finalImageUrls,
          voiceUrl: finalVoiceUrls.isNotEmpty ? finalVoiceUrls.first : null,
          clearVoiceUrl: finalVoiceUrls.isEmpty,
          voiceUrls: finalVoiceUrls,
          updatedAt: DateTime.now(),
        );
        await FirestoreService.instance.updateMemo(updated);

        // Clean up deleted WebDAV attachments
        final oldImages = widget.existingMemo!.images;
        final deletedImages = oldImages
            .where(
              (url) =>
                  !finalImageUrls.contains(url) && url.startsWith('webdav://'),
            )
            .toList();

        final oldVoices = widget.existingMemo!.voiceUrls;
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
      } else {
        final memo = Memo(
          id: const Uuid().v4(),
          content: text,
          images: finalImageUrls,
          voiceUrl: finalVoiceUrls.isNotEmpty ? finalVoiceUrls.first : null,
          voiceUrls: finalVoiceUrls,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          userId: FirebaseAuth.instance.currentUser!.uid,
        );
        await FirestoreService.instance.addMemo(memo);
      }
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存备忘录失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }
}

class _MemoCard extends StatelessWidget {
  const _MemoCard({required this.memo});

  final Memo memo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = theme.extension<AppColors>();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: memo.isPinned
          ? theme.colorScheme.primaryContainer
          : appColors?.cardColor,
      elevation: memo.isPinned ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.dividerColor.withValues(alpha: 0.1),
          width: 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showAddMemoDialog(context, memo),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (memo.content.isNotEmpty)
                          Text(
                            compactListPreviewText(memo.content),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              height: 1.45,
                            ),
                          ),
                        if (memo.voiceUrls.isNotEmpty)
                          ...memo.voiceUrls.map(
                            (url) => Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: VoicePlayerWidget(url: url),
                            ),
                          )
                        else if (memo.voiceUrl != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: VoicePlayerWidget(url: memo.voiceUrl!),
                          ),
                        if (memo.images.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: memo.images.map((url) {
                                return ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: GestureDetector(
                                    onTap: () {
                                      showPhotoPreviewDialog(context, url, (
                                        newUrl,
                                      ) {
                                        final updatedImages = List<String>.from(
                                          memo.images,
                                        );
                                        final idx = updatedImages.indexOf(url);
                                        if (idx != -1) {
                                          updatedImages[idx] = newUrl;
                                          final updatedMemo = memo.copyWith(
                                            images: updatedImages,
                                          );
                                          FirestoreService.instance.updateMemo(
                                            updatedMemo,
                                          );
                                        }
                                      }, 'memos');
                                    },
                                    child: _buildAttachmentImage(
                                      url,
                                      width: 80,
                                      height: 80,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      FirestoreService.instance.toggleMemoPin(
                        memo.id,
                        !memo.isPinned,
                      );
                    },
                    child: Icon(
                      memo.isPinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      size: 20,
                      color: memo.isPinned
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatDate(memo.createdAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Magic wand button
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: Icon(
                          Icons.auto_awesome,
                          size: 18,
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.8,
                          ),
                        ),
                        onPressed: () => _showAiConversionMenu(context, memo),
                        tooltip: 'AI智能转换',
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () {
                          FirestoreService.instance.deleteMemo(memo.id);
                        },
                        child: Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: theme.colorScheme.error.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAiConversionMenu(BuildContext context, Memo memo) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  '备忘录 AI 智能转化',
                  style: Theme.of(bottomSheetContext).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.playlist_add_check_rounded,
                  color: Colors.blue,
                ),
                title: const Text('转换为待办任务'),
                subtitle: const Text('由 AI 自动解析并创建待办，提取截止时间与优先级'),
                onTap: () {
                  Navigator.of(bottomSheetContext).pop();
                  _handleConvertToTask(context, memo);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.note_add_outlined,
                  color: Colors.orange,
                ),
                title: const Text('扩展为知识库笔记'),
                subtitle: const Text('由 AI 扩写并格式化排版，存入您的个人笔记'),
                onTap: () {
                  Navigator.of(bottomSheetContext).pop();
                  _handleConvertToNote(context, memo);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleConvertToTask(BuildContext context, Memo memo) async {
    BuildContext? dialogContext;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        return const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('AI 正在分析并创建任务...'),
            ],
          ),
        );
      },
    );

    try {
      final result = await AIService.instance.convertMemo(memo.content);

      if (dialogContext != null && dialogContext!.mounted) {
        Navigator.of(dialogContext!).pop();
      }

      if (result == null || result['type'] != 'task') {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('转换失败，请检查网络或内容后重试')));
        }
        return;
      }

      final title = result['title'] ?? '未命名任务';
      final priorityStr = result['priority'] ?? 'normal';
      final dueDateStr = result['dueDate'];

      TaskPriority priority;
      switch (priorityStr) {
        case 'low':
          priority = TaskPriority.low;
          break;
        case 'high':
          priority = TaskPriority.high;
          break;
        case 'urgent':
          priority = TaskPriority.urgent;
          break;
        default:
          priority = TaskPriority.normal;
      }

      DateTime? dueDate;
      if (dueDateStr != null) {
        try {
          dueDate = DateTime.parse(dueDateStr);
        } catch (_) {}
      }

      final newTask = Task(
        id: const Uuid().v4(),
        title: title,
        description: '【由备忘录转化】\n${memo.content}',
        status: TaskStatus.todo,
        priority: priority,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        userId: FirebaseAuth.instance.currentUser?.uid ?? '',
        dueDate: dueDate,
      );

      await FirestoreService.instance.addTask(newTask);

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('成功转化为任务: "$title"')));
      }
    } catch (e) {
      if (dialogContext != null && dialogContext!.mounted) {
        Navigator.of(dialogContext!).pop();
      }
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('转换失败: $e')));
      }
    }
  }

  Future<void> _handleConvertToNote(BuildContext context, Memo memo) async {
    BuildContext? dialogContext;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        return const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('AI 正在扩写并整理笔记...'),
            ],
          ),
        );
      },
    );

    try {
      final result = await AIService.instance.convertMemo(memo.content);

      if (dialogContext != null && dialogContext!.mounted) {
        Navigator.of(dialogContext!).pop();
      }

      if (result == null || result['type'] != 'note') {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('转换失败，请检查网络或内容后重试')));
        }
        return;
      }

      final title = result['title'] ?? '未命名笔记';
      final content = result['content'] ?? '';

      final newNote = Note(
        id: const Uuid().v4(),
        title: title,
        content: content,
        images: List<String>.from(memo.images),
        voiceUrl: memo.voiceUrl,
        voiceUrls: List<String>.from(memo.voiceUrls),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        userId: FirebaseAuth.instance.currentUser?.uid ?? '',
        isArchived: false,
      );

      await FirestoreService.instance.addNote(newNote);

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已扩写并存入笔记: "$title"')));
      }
    } catch (e) {
      if (dialogContext != null && dialogContext!.mounted) {
        Navigator.of(dialogContext!).pop();
      }
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('转换失败: $e')));
      }
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return '今天 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.month}月${date.day}日 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
