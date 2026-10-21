import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:docx_file_viewer/docx_file_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:syncnote/features/cloud_files/cloud_office_document_preview.dart';
import 'package:syncnote/shared/models/cloud_file_item.dart';
import 'package:syncnote/shared/services/cloud_file_preview_service.dart';

class CloudFilePreviewScreen extends StatelessWidget {
  const CloudFilePreviewScreen({
    required this.file,
    required this.preview,
    super.key,
  });

  final CloudFileItem file;
  final CloudFilePreviewData preview;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: switch (preview.kind) {
        CloudPreviewKind.image => _ImagePreview(bytes: preview.bytes!),
        CloudPreviewKind.pdf => PdfViewer.data(
          preview.bytes!,
          sourceName: '${file.id}-${file.updatedAt.millisecondsSinceEpoch}',
          params: const PdfViewerParams(
            backgroundColor: Color(0xff303030),
            margin: 12,
          ),
        ),
        CloudPreviewKind.docx => ColoredBox(
          color: const Color(0xffd9d9d9),
          child: DocxView.bytes(
            preview.bytes!,
            config: const DocxViewConfig(
              pageMode: DocxPageMode.paged,
              enableZoom: true,
              enableSearch: true,
              enableSelection: true,
              pageWidth: 794,
              showPageBreaks: true,
            ),
          ),
        ),
        CloudPreviewKind.spreadsheet => CloudSpreadsheetPreview(
          bytes: preview.bytes!,
        ),
        CloudPreviewKind.presentation => CloudPresentationPreview(
          bytes: preview.bytes!,
        ),
        CloudPreviewKind.markdown => Markdown(
          data: preview.text ?? '',
          selectable: true,
          padding: const EdgeInsets.all(20),
        ),
        CloudPreviewKind.text || CloudPreviewKind.archive => _TextPreview(
          text: preview.text ?? '',
          monospace:
              preview.kind == CloudPreviewKind.text ||
              preview.kind == CloudPreviewKind.archive,
        ),
        CloudPreviewKind.audio => _MemoryAudioPreview(
          bytes: preview.bytes!,
          mimeType: file.mimeType,
          fileName: file.name,
        ),
        CloudPreviewKind.info => _InfoPreview(
          file: file,
          message: preview.message ?? '此格式暂不支持纯内存预览。',
        ),
      },
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                const Text('图片解码失败', style: TextStyle(color: Colors.white)),
          ),
        ),
      ),
    );
  }
}

class _TextPreview extends StatelessWidget {
  const _TextPreview({required this.text, required this.monospace});

  final String text;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: SizedBox(
          width: double.infinity,
          child: Text(
            text,
            style: TextStyle(
              fontSize: 15,
              height: 1.65,
              fontFamily: monospace ? 'monospace' : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _MemoryAudioPreview extends StatefulWidget {
  const _MemoryAudioPreview({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
  });

  final Uint8List bytes;
  final String mimeType;
  final String fileName;

  @override
  State<_MemoryAudioPreview> createState() => _MemoryAudioPreviewState();
}

class _MemoryAudioPreviewState extends State<_MemoryAudioPreview> {
  late final AudioPlayer _player;
  late final Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _ready = _player.setSource(
      BytesSource(widget.bytes, mimeType: widget.mimeType),
    );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _InfoPreview(file: null, message: '音频解码失败：${snapshot.error}');
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.audio_file_rounded,
                        size: 72,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.fileName,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 20),
                      StreamBuilder<Duration>(
                        stream: _player.onDurationChanged,
                        initialData: Duration.zero,
                        builder: (context, durationSnapshot) {
                          final duration =
                              durationSnapshot.data ?? Duration.zero;
                          return StreamBuilder<Duration>(
                            stream: _player.onPositionChanged,
                            initialData: Duration.zero,
                            builder: (context, positionSnapshot) {
                              final position =
                                  positionSnapshot.data ?? Duration.zero;
                              final max = duration.inMilliseconds
                                  .toDouble()
                                  .clamp(1.0, double.infinity)
                                  .toDouble();
                              return Column(
                                children: [
                                  Slider(
                                    max: max,
                                    value: position.inMilliseconds
                                        .toDouble()
                                        .clamp(0.0, max)
                                        .toDouble(),
                                    onChanged: (value) => _player.seek(
                                      Duration(milliseconds: value.round()),
                                    ),
                                  ),
                                  Text(
                                    '${_duration(position)} / ${_duration(duration)}',
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      StreamBuilder<PlayerState>(
                        stream: _player.onPlayerStateChanged,
                        initialData: PlayerState.stopped,
                        builder: (context, stateSnapshot) {
                          final playing =
                              stateSnapshot.data == PlayerState.playing;
                          return FilledButton.icon(
                            onPressed: playing ? _player.pause : _player.resume,
                            icon: Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                            label: Text(playing ? '暂停' : '播放'),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _duration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _InfoPreview extends StatelessWidget {
  const _InfoPreview({required this.file, required this.message});

  final CloudFileItem? file;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.preview_outlined,
                size: 72,
                color: theme.colorScheme.primary,
              ),
              if (file != null) ...[
                const SizedBox(height: 16),
                Text(
                  file!.name,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
              ],
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              const Text('预览过程不会在设备上创建文件。', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
