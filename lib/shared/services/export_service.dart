import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/services/backup_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';

class ExportService {
  ExportService._();

  static final ExportService instance = ExportService._();

  /// Exports a single note to a Markdown file.
  Future<void> exportNoteToMarkdown(BuildContext context, Note note) async {
    final title = note.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final filename = '${title.isEmpty ? "untitled" : title}.md';

    final visualContent = parseVisualNoteContent(note.content, note.images);
    final buffer = StringBuffer();
    buffer.writeln('# ${note.title}');
    buffer.writeln();
    buffer.writeln(visualContent.text);
    buffer.writeln();
    for (final img in visualContent.images) {
      buffer.writeln('![图片](${img.url})');
      buffer.writeln();
    }
    final content = '${buffer.toString().trimRight()}\n';

    try {
      if (kIsWeb) {
        // Not implemented for Web in this scope
        return;
      }

      if (Platform.isWindows) {
        // Windows Desktop: Show Save File Picker
        final outputFilePath = await FilePicker.platform.saveFile(
          dialogTitle: '导出为 Markdown',
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: ['md'],
        );

        if (outputFilePath != null) {
          final file = File(outputFilePath);
          await file.writeAsString(content);
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('已成功导出至: $outputFilePath')));
          }
        }
      } else if (Platform.isAndroid) {
        // Android Mobile: Save to temp and trigger Share Sheet
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/$filename');
        await file.writeAsString(content);

        final xFile = XFile(file.path);
        await Share.shareXFiles([xFile], subject: '分享笔记 Markdown');
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出 Markdown 失败: $e')));
      }
    }
  }

  Future<Uint8List?> _loadImageBytes(String path) async {
    try {
      if (path.startsWith('webdav://')) {
        return await UploadService.instance.downloadCloudFileBytes(path);
      } else if (path.startsWith('http://') || path.startsWith('https://')) {
        final client = HttpClient();
        final request = await client.getUrl(Uri.parse(path));
        final response = await request.close();
        if (response.statusCode == 200) {
          final bytes = await consolidateHttpClientResponseBytes(response);
          return bytes;
        }
      } else {
        var cleanPath = path;
        if (cleanPath.startsWith('file:///')) {
          cleanPath = cleanPath.substring(8);
        } else if (cleanPath.startsWith('file://')) {
          cleanPath = cleanPath.substring(7);
        }
        try {
          cleanPath = Uri.decodeComponent(cleanPath);
        } catch (_) {}
        if (cleanPath.startsWith('/') &&
            cleanPath.length > 2 &&
            cleanPath[2] == ':') {
          cleanPath = cleanPath.substring(1);
        }
        final file = File(cleanPath);
        if (await file.exists()) {
          return await file.readAsBytes();
        }
      }
    } catch (e) {
      debugPrint('Error loading image for PDF: $e');
    }
    return null;
  }

  /// Exports a single note to a PDF document.
  Future<void> exportNoteToPdf(BuildContext context, Note note) async {
    final titleClean = note.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final filename = '${titleClean.isEmpty ? "untitled" : titleClean}.pdf';

    try {
      final pdf = pw.Document();
      // Load Chinese font dynamically
      final font = await PdfGoogleFonts.notoSansSCRegular();

      final visualContent = parseVisualNoteContent(note.content, note.images);

      if (visualContent.images.isEmpty) {
        // Text-only: Standard flowing MultiPage format
        pdf.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4,
            theme: pw.ThemeData.withFont(base: font),
            build: (pw.Context context) {
              return [
                pw.Header(
                  level: 0,
                  child: pw.Text(
                    note.title.isEmpty ? '未命名笔记' : note.title,
                    style: pw.TextStyle(
                      fontSize: 24,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.SizedBox(height: 10),
                pw.Text(
                  '创建日期: ${note.createdAt.toLocal().toString().substring(0, 19)}',
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey,
                  ),
                ),
                if (note.category.isNotEmpty)
                  pw.Text(
                    '分类: ${note.category}',
                    style: const pw.TextStyle(
                      fontSize: 10,
                      color: PdfColors.grey,
                    ),
                  ),
                pw.SizedBox(height: 20),
                pw.Paragraph(
                  text: visualContent.text,
                  style: const pw.TextStyle(fontSize: 12),
                ),
              ];
            },
          ),
        );
      } else {
        // Load all images asynchronously
        final List<pw.MemoryImage?> pdfImages = [];
        for (final img in visualContent.images) {
          pw.MemoryImage? pdfImg;
          if (img.url.isNotEmpty) {
            final bytes = await _loadImageBytes(img.url);
            if (bytes != null) {
              try {
                pdfImg = pw.MemoryImage(bytes);
              } catch (e) {
                debugPrint('PDF Image parsing error: $e');
              }
            }
          }
          pdfImages.add(pdfImg);
        }

        final double canvasWidth = visualContent.canvasWidth;
        final double totalPageWidth = canvasWidth + 80.0;
        final double totalPageHeight = totalPageWidth * 1.415;

        final customFormat = PdfPageFormat(
          totalPageWidth,
          totalPageHeight,
          marginLeft: 40.0,
          marginRight: 40.0,
          marginTop: 40.0,
          marginBottom: 40.0,
        );

        final double pageWidth = canvasWidth;
        final double pageHeight = totalPageHeight - 80.0;
        final double headerHeight = 110.0 * (canvasWidth / 515.0);
        final double scale = 1.0;
        final double pageHeightCanvas0 = pageHeight - headerHeight;
        final double pageHeightCanvas = pageHeight;

        // 1. Calculate pages required by canvas elements (images and texts)
        double maxElementY = pageHeightCanvas0;
        for (final img in visualContent.images) {
          final bottomY = img.y + img.height;
          if (bottomY > maxElementY) {
            maxElementY = bottomY;
          }
        }
        for (final txt in visualContent.texts) {
          final bottomY = txt.y + txt.height;
          if (bottomY > maxElementY) {
            maxElementY = bottomY;
          }
        }
        int elementPageCount = 1;
        if (maxElementY > pageHeightCanvas0) {
          elementPageCount =
              1 + ((maxElementY - pageHeightCanvas0) / pageHeightCanvas).ceil();
        }

        // 2. Estimate pages required by text (with wrapping)
        final lines = visualContent.text.split('\n');
        int estimatedLines = 0;
        for (final line in lines) {
          if (line.isEmpty) {
            estimatedLines += 1;
          } else {
            estimatedLines += (line.length / 36.0).ceil();
          }
        }
        int textPageCount = 1;
        if (estimatedLines > 30) {
          textPageCount = 1 + ((estimatedLines - 30) / 38.0).ceil();
        }

        final int pageCount = math.max(elementPageCount, textPageCount);

        for (int pageIndex = 0; pageIndex < pageCount; pageIndex++) {
          pdf.addPage(
            pw.Page(
              pageFormat: customFormat,
              theme: pw.ThemeData.withFont(base: font),
              build: (pw.Context context) {
                final positionedWidgets = <pw.Widget>[];

                // Page-specific slicing parameters
                double startY;
                double textTopOffset;
                if (pageIndex == 0) {
                  startY = 0.0;
                  textTopOffset = headerHeight;

                  // Render Header inside page 0 at the top
                  positionedWidgets.add(
                    pw.Positioned(
                      left: 0,
                      top: 0,
                      child: pw.SizedBox(
                        width: pageWidth,
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Header(
                              level: 0,
                              child: pw.Text(
                                note.title.isEmpty ? '未命名笔记' : note.title,
                                style: pw.TextStyle(
                                  fontSize: 24 * (canvasWidth / 515.0),
                                  fontWeight: pw.FontWeight.bold,
                                  font: font,
                                ),
                              ),
                            ),
                            pw.SizedBox(height: 10 * (canvasWidth / 515.0)),
                            pw.Text(
                              '创建日期: ${note.createdAt.toLocal().toString().substring(0, 19)}',
                              style: pw.TextStyle(
                                fontSize: 10 * (canvasWidth / 515.0),
                                color: PdfColors.grey,
                                font: font,
                              ),
                            ),
                            if (note.category.isNotEmpty)
                              pw.Text(
                                '分类: ${note.category}',
                                style: pw.TextStyle(
                                  fontSize: 10 * (canvasWidth / 515.0),
                                  color: PdfColors.grey,
                                  font: font,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                } else {
                  startY =
                      (pageHeight - headerHeight) +
                      (pageIndex - 1) * pageHeight;
                  textTopOffset = 0.0;
                }

                // 1. Render continuous sliding Text Layer
                positionedWidgets.add(
                  pw.Positioned(
                    left: 0,
                    top: textTopOffset - startY,
                    child: pw.SizedBox(
                      width: pageWidth,
                      child: pw.Text(
                        visualContent.text,
                        style: const pw.TextStyle(fontSize: 14.0),
                      ),
                    ),
                  ),
                );

                // 2. Render Positioned Images belonging to this page slice
                for (int i = 0; i < visualContent.images.length; i++) {
                  final img = visualContent.images[i];
                  final pdfImg = pdfImages[i];
                  if (pdfImg == null) continue;

                  final double imgY = img.y * scale;
                  final double imageTopOnPage = (pageIndex == 0)
                      ? (imgY + headerHeight)
                      : (imgY - startY);

                  if (imageTopOnPage >= textTopOffset &&
                      imageTopOnPage < pageHeight) {
                    positionedWidgets.add(
                      pw.Positioned(
                        left: img.x * scale,
                        top: imageTopOnPage,
                        child: pw.SizedBox(
                          width: img.width * scale,
                          height: img.height * scale,
                          child: pw.Image(pdfImg, fit: pw.BoxFit.cover),
                        ),
                      ),
                    );
                  }
                }

                // 3. Render Positioned Texts belonging to this page slice
                for (int i = 0; i < visualContent.texts.length; i++) {
                  final txt = visualContent.texts[i];
                  final double txtY = txt.y * scale;
                  final double textTopOnPage = (pageIndex == 0)
                      ? (txtY + headerHeight)
                      : (txtY - startY);

                  if (textTopOnPage >= textTopOffset &&
                      textTopOnPage < pageHeight) {
                    positionedWidgets.add(
                      pw.Positioned(
                        left: txt.x * scale,
                        top: textTopOnPage,
                        child: pw.SizedBox(
                          width: txt.width * scale,
                          height: txt.height * scale,
                          child: pw.Text(
                            txt.text,
                            style: pw.TextStyle(fontSize: 14.0, font: font),
                          ),
                        ),
                      ),
                    );
                  }
                }

                return pw.Stack(children: positionedWidgets);
              },
            ),
          );
        }
      }

      final pdfBytes = await pdf.save();

      if (kIsWeb) {
        return;
      }

      if (Platform.isWindows) {
        final outputFilePath = await FilePicker.platform.saveFile(
          dialogTitle: '导出为 PDF',
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );

        if (outputFilePath != null) {
          final file = File(outputFilePath);
          await file.writeAsBytes(pdfBytes);
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('已成功导出至: $outputFilePath')));
          }
        }
      } else if (Platform.isAndroid) {
        await Printing.sharePdf(bytes: pdfBytes, filename: filename);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出 PDF 失败: $e')));
      }
    }
  }

  /// Exports all Firestore user data (notes, tasks, diaries, memos) to a ZIP archive.
  Future<void> exportAllDataToZip(BuildContext context) async {
    final filename =
        'syncnote_backup_${DateTime.now().millisecondsSinceEpoch}.zip';

    try {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('⏳ 正在生成全量数据备份，请稍候...')));
      }

      final zipBytes = await BackupService.instance.buildFullBackupZip();

      if (kIsWeb) {
        return;
      }

      if (Platform.isWindows) {
        // Windows: Show Save File Picker
        final outputFilePath = await FilePicker.platform.saveFile(
          dialogTitle: '保存数据备份 (ZIP)',
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: ['zip'],
        );

        if (outputFilePath != null) {
          final file = File(outputFilePath);
          await file.writeAsBytes(zipBytes);
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('备份成功保存至: $outputFilePath')));
          }
        }
      } else if (Platform.isAndroid) {
        // Android: Save to temp and share
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/$filename');
        await file.writeAsBytes(zipBytes);

        final xFile = XFile(file.path);
        await Share.shareXFiles([xFile], subject: '备份数据 ZIP');
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('备份打包失败: $e')));
      }
    }
  }

  Future<void> importAllDataFromZip(BuildContext context) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: '选择 SyncNote 备份 ZIP',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;

      final file = picked.files.single;
      final bytes =
          file.bytes ??
          (file.path == null
              ? throw const BackupException('无法读取所选 ZIP 文件')
              : await File(file.path!).readAsBytes());
      final preview = BackupService.previewBackupZip(bytes);

      if (!context.mounted) return;
      final strategy = await _showRestorePreviewDialog(context, preview);
      if (strategy == null) return;

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⏳ 正在恢复 ZIP 备份，请保持网络连接...')),
        );
      }

      final result = await BackupService.instance.importBackupZip(
        bytes,
        strategy: strategy,
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '恢复完成：写入 ${result.writtenDocuments} 项，跳过 ${result.skippedDocuments} 项，附件 ${result.uploadedAttachments} 个',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('恢复备份失败: $e')));
      }
    }
  }

  Future<BackupConflictStrategy?> _showRestorePreviewDialog(
    BuildContext context,
    BackupPreview preview,
  ) {
    var strategy = BackupConflictStrategy.skip;
    String label(BackupConflictStrategy value) {
      return switch (value) {
        BackupConflictStrategy.skip => '跳过已有数据',
        BackupConflictStrategy.overwrite => '覆盖已有同 ID 数据',
        BackupConflictStrategy.copyAsNew => '冲突时复制为新内容',
      };
    }

    return showDialog<BackupConflictStrategy>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('恢复 ZIP 备份'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '导出时间：${preview.exportedAt.toLocal().toString().substring(0, 19)}',
                  ),
                  const SizedBox(height: 8),
                  Text('数据文档：${preview.totalDocuments} 项'),
                  Text(
                    '附件：${preview.attachmentCount} 个 / ${_formatBytes(preview.attachmentBytes)}',
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<BackupConflictStrategy>(
                    initialValue: strategy,
                    decoration: const InputDecoration(
                      labelText: '冲突策略',
                      border: OutlineInputBorder(),
                    ),
                    items: BackupConflictStrategy.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(label(value)),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setState(() => strategy = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '恢复会写入当前登录账号的云端数据。失败时会回滚本次写入和本次上传的附件。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(strategy),
                  child: const Text('开始恢复'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
