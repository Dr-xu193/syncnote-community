import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncnote/features/cloud_files/cloud_file_preview_screen.dart';
import 'package:syncnote/shared/models/cloud_file_item.dart';
import 'package:syncnote/shared/services/cloud_file_preview_service.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:uuid/uuid.dart';

class CloudFilesScreen extends StatefulWidget {
  const CloudFilesScreen({super.key});

  @override
  State<CloudFilesScreen> createState() => _CloudFilesScreenState();
}

class _CloudFilesScreenState extends State<CloudFilesScreen> {
  final _searchController = TextEditingController();
  bool _isTransferring = false;
  double _progress = 0;
  String _transferLabel = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('云文件'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonalIcon(
              onPressed: _isTransferring ? null : _upload,
              icon: const Icon(Icons.cloud_upload_outlined, size: 19),
              label: const Text('上传文件'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isTransferring)
            Material(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$_transferLabel ${(_progress * 100).round()}%',
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _progress),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索云文件',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<CloudFileItem>>(
              stream: FirestoreService.instance.watchCloudFiles(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _MessageState(
                    icon: Icons.cloud_off_outlined,
                    title: '云文件加载失败',
                    message: '${snapshot.error}',
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final query = _searchController.text.trim().toLowerCase();
                final files = snapshot.data!
                    .where(
                      (file) =>
                          query.isEmpty ||
                          file.name.toLowerCase().contains(query),
                    )
                    .toList(growable: false);
                if (files.isEmpty) {
                  return _MessageState(
                    icon: query.isEmpty
                        ? Icons.cloud_queue_rounded
                        : Icons.search_off_rounded,
                    title: query.isEmpty ? '还没有云文件' : '没有找到文件',
                    message: query.isEmpty
                        ? '文件将直接上传到坚果云，不会保存在应用本地。'
                        : '换一个名称再试试。',
                  );
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final horizontal = constraints.maxWidth >= 800
                        ? 32.0
                        : 12.0;
                    return ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                        horizontal,
                        8,
                        horizontal,
                        24,
                      ),
                      itemCount: files.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) => _CloudFileTile(
                        file: files[index],
                        disabled: _isTransferring,
                        onPreview: () => _preview(files[index]),
                        onDownload: () => _download(files[index]),
                        onRename: () => _rename(files[index]),
                        onDelete: () => _delete(files[index]),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: MediaQuery.sizeOf(context).width < 600
          ? FloatingActionButton.extended(
              onPressed: _isTransferring ? null : _upload,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('上传'),
            )
          : null,
    );
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.any,
      withData: false,
      withReadStream: true,
      dialogTitle: '选择要上传到坚果云的文件',
    );
    if (result == null || result.files.isEmpty || !mounted) return;

    final picked = result.files.single;
    final sourceStream =
        picked.readStream ??
        (picked.path == null ? null : File(picked.path!).openRead());
    if (sourceStream == null) {
      _showMessage('无法读取这个文件，请重新选择。', error: true);
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showMessage('请先登录后再上传文件。', error: true);
      return;
    }

    final id = const Uuid().v4();
    final remoteName = '$id${CloudFileRules.safeRemoteExtension(picked.name)}';
    String? uploadedUrl;
    _startTransfer('正在上传 ${picked.name}');
    try {
      uploadedUrl = await UploadService.instance.uploadCloudFile(
        stream: sourceStream,
        contentLength: picked.size,
        remoteFileName: remoteName,
        contentType: CloudFileRules.mimeTypeForName(picked.name),
        onProgress: _setProgress,
      );
      final now = DateTime.now();
      await FirestoreService.instance.addCloudFile(
        CloudFileItem(
          id: id,
          name: picked.name,
          webdavUrl: uploadedUrl,
          size: picked.size,
          mimeType: CloudFileRules.mimeTypeForName(picked.name),
          createdAt: now,
          updatedAt: now,
          userId: user.uid,
        ),
      );
      _showMessage('${picked.name} 已上传到坚果云');
    } catch (error) {
      if (uploadedUrl != null) {
        await UploadService.instance.deleteFile(uploadedUrl);
      }
      _showMessage('上传失败：$error', error: true);
    } finally {
      _finishTransfer();
    }
  }

  Future<void> _download(CloudFileItem file) async {
    if (Platform.isAndroid) {
      _startTransfer('正在读取 ${file.name}');
      try {
        final bytes = await UploadService.instance.downloadCloudFileBytes(
          file.webdavUrl,
        );
        _setProgress(0.8);
        final saved = await FilePicker.platform.saveFile(
          dialogTitle: '选择保存位置',
          fileName: file.name,
          type: FileType.any,
          bytes: bytes,
        );
        if (saved != null) _showMessage('${file.name} 已保存到你选择的位置');
      } catch (error) {
        _showMessage('下载失败：$error', error: true);
      } finally {
        _finishTransfer();
      }
      return;
    }

    final path = await FilePicker.platform.saveFile(
      dialogTitle: '选择保存位置',
      fileName: file.name,
      type: FileType.any,
    );
    if (path == null || !mounted) return;
    _startTransfer('正在下载 ${file.name}');
    try {
      await UploadService.instance.downloadCloudFileTo(
        file.webdavUrl,
        File(path),
        onProgress: _setProgress,
      );
      _showMessage('${file.name} 已保存到你选择的位置');
    } catch (error) {
      _showMessage('下载失败：$error', error: true);
    } finally {
      _finishTransfer();
    }
  }

  Future<void> _preview(CloudFileItem file) async {
    _startTransfer('正在读取 ${file.name}');
    try {
      final preview = await CloudFilePreviewService.instance.load(
        file,
        onProgress: _setProgress,
      );
      _finishTransfer();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CloudFilePreviewScreen(file: file, preview: preview),
        ),
      );
    } catch (error) {
      _showMessage('预览失败：$error', error: true);
      _finishTransfer();
    }
  }

  Future<void> _rename(CloudFileItem file) async {
    final controller = TextEditingController(text: file.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名云文件'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 180,
          decoration: const InputDecoration(labelText: '文件名'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == file.name) return;
    try {
      await FirestoreService.instance.renameCloudFile(file.id, trimmed);
    } catch (error) {
      _showMessage('重命名失败：$error', error: true);
    }
  }

  Future<void> _delete(CloudFileItem file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除云文件？'),
        content: Text('“${file.name}”将从坚果云和所有设备中永久删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _startTransfer('正在删除 ${file.name}');
    try {
      final deleted = await UploadService.instance.deleteFile(file.webdavUrl);
      if (!deleted) throw const WebdavUploadException('坚果云文件删除失败');
      await FirestoreService.instance.deleteCloudFile(file.id);
      _showMessage('${file.name} 已删除');
    } catch (error) {
      _showMessage('删除失败：$error', error: true);
    } finally {
      _finishTransfer();
    }
  }

  void _startTransfer(String label) {
    if (!mounted) return;
    setState(() {
      _isTransferring = true;
      _progress = 0;
      _transferLabel = label;
    });
  }

  void _setProgress(double value) {
    if (!mounted) return;
    setState(() => _progress = value);
  }

  void _finishTransfer() {
    if (!mounted) return;
    setState(() {
      _isTransferring = false;
      _progress = 0;
      _transferLabel = '';
    });
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

class _CloudFileTile extends StatelessWidget {
  const _CloudFileTile({
    required this.file,
    required this.disabled,
    required this.onPreview,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
  });

  final CloudFileItem file;
  final bool disabled;
  final VoidCallback onPreview;
  final VoidCallback onDownload;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        enabled: !disabled,
        onTap: onPreview,
        minTileHeight: 76,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
          child: Icon(_iconFor(file.extension)),
        ),
        title: Text(
          file.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${_formatBytes(file.size)}  ·  '
          '${DateFormat('yyyy-MM-dd HH:mm').format(file.createdAt)}',
        ),
        trailing: PopupMenuButton<String>(
          enabled: !disabled,
          tooltip: '文件操作',
          onSelected: (value) {
            switch (value) {
              case 'preview':
                onPreview();
              case 'download':
                onDownload();
              case 'rename':
                onRename();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'preview',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.preview_outlined),
                title: Text('预览'),
              ),
            ),
            PopupMenuItem(
              value: 'download',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.download_outlined),
                title: Text('保存到本地'),
              ),
            ),
            PopupMenuItem(
              value: 'rename',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.drive_file_rename_outline),
                title: Text('重命名'),
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.delete_outline),
                title: Text('永久删除'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(String extension) {
    if ({'jpg', 'jpeg', 'png', 'gif', 'webp', 'svg'}.contains(extension)) {
      return Icons.image_outlined;
    }
    if ({'mp3', 'm4a', 'wav', 'flac'}.contains(extension)) {
      return Icons.audio_file_outlined;
    }
    if ({'mp4', 'mkv', 'mov', 'avi'}.contains(extension)) {
      return Icons.video_file_outlined;
    }
    if (extension == 'pdf') return Icons.picture_as_pdf_outlined;
    if ({'zip', 'rar', '7z', 'tar', 'gz'}.contains(extension)) {
      return Icons.folder_zip_outlined;
    }
    if ({'doc', 'docx', 'txt', 'md'}.contains(extension)) {
      return Icons.description_outlined;
    }
    if ({'xls', 'xlsx', 'csv'}.contains(extension)) {
      return Icons.table_chart_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 58, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
