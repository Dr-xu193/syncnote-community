import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncnote/shared/services/upload_service.dart';
import 'package:syncnote/shared/widgets/webdav_image_widget.dart';

class DoodleLine {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  DoodleLine({
    required this.points,
    required this.color,
    this.strokeWidth = 4.0,
  });
}

class DoodleScreen extends StatefulWidget {
  final String imageUrl;

  const DoodleScreen({super.key, required this.imageUrl});

  @override
  State<DoodleScreen> createState() => _DoodleScreenState();
}

class _DoodleScreenState extends State<DoodleScreen> {
  final GlobalKey _repaintBoundaryKey = GlobalKey();
  final GlobalKey _canvasKey = GlobalKey();
  final List<DoodleLine> _lines = [];
  List<Offset> _currentPoints = [];
  Color _selectedColor = Colors.red;
  double _strokeWidth = 4.0;
  bool _isSaving = false;

  double _imageAspectRatio = 1.0;
  bool _imageLoaded = false;
  String? _resolvedImagePath;
  String? _imageLoadError;

  final List<Color> _colors = [
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.purple,
    Colors.black,
    Colors.white,
  ];

  @override
  void initState() {
    super.initState();
    _loadImageAspectRatio();
  }

  String _cleanFilePath(String url) {
    var cleanPath = url.replaceFirst('file://', '');
    if (cleanPath.startsWith('/') && cleanPath.contains(':')) {
      final driveMatch = RegExp(r'^/[a-zA-Z]:').firstMatch(cleanPath);
      if (driveMatch != null) {
        cleanPath = cleanPath.substring(1);
      }
    }
    return cleanPath;
  }

  Future<void> _loadImageAspectRatio() async {
    if (mounted) {
      setState(() {
        _imageLoaded = false;
        _imageLoadError = null;
      });
    }

    try {
      final ImageProvider provider;
      if (widget.imageUrl.startsWith('webdav://')) {
        final path = await WebdavCacheManager.instance.resolveLocalPath(
          widget.imageUrl,
        );
        _resolvedImagePath = path;
        provider = FileImage(File(_cleanFilePath(path)));
      } else if (widget.imageUrl.startsWith('http://') ||
          widget.imageUrl.startsWith('https://')) {
        provider = NetworkImage(widget.imageUrl);
      } else {
        _resolvedImagePath = _cleanFilePath(widget.imageUrl);
        provider = FileImage(File(_resolvedImagePath!));
      }

      final stream = provider.resolve(const ImageConfiguration());
      stream.addListener(
        ImageStreamListener(
          (info, _) {
            if (mounted) {
              setState(() {
                _imageAspectRatio = info.image.width / info.image.height;
                _imageLoaded = true;
              });
            }
          },
          onError: (exception, stackTrace) {
            if (mounted) {
              setState(() {
                _imageLoadError = '图片文件无法解析';
                _imageLoaded = false;
              });
            }
          },
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _imageLoadError = '图片下载失败：$error';
          _imageLoaded = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNetwork =
        widget.imageUrl.startsWith('http://') ||
        widget.imageUrl.startsWith('https://');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('照片涂鸦编辑'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: '撤销',
            onPressed: _lines.isEmpty
                ? null
                : () {
                    setState(() {
                      _lines.removeLast();
                    });
                  },
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '清空涂鸦',
            onPressed: _lines.isEmpty
                ? null
                : () {
                    setState(() {
                      _lines.clear();
                    });
                  },
          ),
          if (_isSaving)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            )
          else
            TextButton.icon(
              icon: const Icon(Icons.check, color: Colors.greenAccent),
              label: const Text(
                '保存',
                style: TextStyle(
                  color: Colors.greenAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onPressed: _saveDoodle,
            ),
        ],
      ),
      body: _imageLoadError != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white70,
                    size: 52,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _imageLoadError!,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _loadImageAspectRatio,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重新加载'),
                  ),
                ],
              ),
            )
          : !_imageLoaded
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: AspectRatio(
                        aspectRatio: _imageAspectRatio,
                        child: RepaintBoundary(
                          key: _repaintBoundaryKey,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Background Image
                              Positioned.fill(
                                child: _resolvedImagePath != null
                                    ? Image.file(
                                        File(_resolvedImagePath!),
                                        fit: BoxFit.fill,
                                      )
                                    : (isNetwork
                                          ? Image.network(
                                              widget.imageUrl,
                                              fit: BoxFit.fill,
                                              errorBuilder:
                                                  (
                                                    context,
                                                    error,
                                                    stackTrace,
                                                  ) => const Icon(
                                                    Icons.broken_image,
                                                    size: 64,
                                                    color: Colors.grey,
                                                  ),
                                            )
                                          : Image.file(
                                              File(widget.imageUrl),
                                              fit: BoxFit.fill,
                                              errorBuilder:
                                                  (
                                                    context,
                                                    error,
                                                    stackTrace,
                                                  ) => const Icon(
                                                    Icons.broken_image,
                                                    size: 64,
                                                    color: Colors.grey,
                                                  ),
                                            )),
                              ),
                              // Drawing Canvas
                              Positioned.fill(
                                child: GestureDetector(
                                  key: _canvasKey,
                                  onPanStart: (details) {
                                    setState(() {
                                      final box =
                                          _canvasKey.currentContext!
                                                  .findRenderObject()
                                              as RenderBox;
                                      final localPos = box.globalToLocal(
                                        details.globalPosition,
                                      );
                                      _currentPoints = [localPos];
                                      _lines.add(
                                        DoodleLine(
                                          points: _currentPoints,
                                          color: _selectedColor,
                                          strokeWidth: _strokeWidth,
                                        ),
                                      );
                                    });
                                  },
                                  onPanUpdate: (details) {
                                    setState(() {
                                      final box =
                                          _canvasKey.currentContext!
                                                  .findRenderObject()
                                              as RenderBox;
                                      final localPos = box.globalToLocal(
                                        details.globalPosition,
                                      );
                                      _currentPoints.add(localPos);
                                    });
                                  },
                                  onPanEnd: (details) {
                                    _currentPoints = [];
                                  },
                                  child: CustomPaint(
                                    painter: DoodlePainter(lines: _lines),
                                    size: Size.infinite,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Tool Panel
                Container(
                  color: Colors.grey.withValues(alpha: 0.15),
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 16,
                  ),
                  child: SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Color selection row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: _colors.map((color) {
                            final isSelected = _selectedColor == color;
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedColor = color;
                                });
                              },
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.transparent,
                                    width: 2.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.3,
                                      ),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 12),
                        // Stroke width slider
                        Row(
                          children: [
                            const Icon(
                              Icons.line_weight,
                              color: Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Slider(
                                value: _strokeWidth,
                                min: 1.0,
                                max: 12.0,
                                activeColor: _selectedColor,
                                inactiveColor: Colors.grey,
                                onChanged: (val) {
                                  setState(() {
                                    _strokeWidth = val;
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _saveDoodle() async {
    setState(() => _isSaving = true);
    try {
      final boundary =
          _repaintBoundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      // Capture drawing context as image
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final buffer = byteData!.buffer.asUint8List();

      final tempDir = await getTemporaryDirectory();
      final path =
          '${tempDir.path}/syncnote_doodle_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File(path);
      await file.writeAsBytes(buffer);

      if (mounted) {
        Navigator.pop(context, file); // Return the edited file
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存编辑失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

class DoodlePainter extends CustomPainter {
  final List<DoodleLine> lines;

  DoodlePainter({required this.lines});

  @override
  void paint(Canvas canvas, Size size) {
    for (final line in lines) {
      final paint = Paint()
        ..color = line.color
        ..strokeCap = StrokeCap.round
        ..strokeWidth = line.strokeWidth
        ..style = PaintingStyle.stroke;

      if (line.points.length > 1) {
        for (int i = 0; i < line.points.length - 1; i++) {
          canvas.drawLine(line.points[i], line.points[i + 1], paint);
        }
      } else if (line.points.isNotEmpty) {
        canvas.drawCircle(line.points[0], line.strokeWidth / 2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant DoodlePainter oldDelegate) => true;
}

void showPhotoPreviewDialog(
  BuildContext context,
  String url,
  Function(String newUrl)? onEdited,
  String uploadFolder,
) {
  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      return Scaffold(
        backgroundColor: Colors.black.withValues(alpha: 0.9),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 28),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            if (onEdited != null)
              IconButton(
                icon: const Icon(Icons.edit, color: Colors.white, size: 26),
                tooltip: '涂鸦编辑',
                onPressed: () async {
                  String finalUrl = url;
                  if (url.startsWith('webdav://')) {
                    try {
                      finalUrl = await WebdavCacheManager.instance
                          .resolveLocalPath(url);
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('图片下载失败：$error')),
                        );
                      }
                      return;
                    }
                  }
                  if (!context.mounted) return;
                  Navigator.pop(context); // Close preview dialog
                  final File? editedFile = await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => DoodleScreen(imageUrl: finalUrl),
                    ),
                  );
                  if (editedFile != null) {
                    final newUrl = await UploadService.instance.uploadFile(
                      editedFile,
                      uploadFolder,
                    );
                    if (newUrl != null) {
                      onEdited(newUrl);
                    }
                  }
                },
              ),
          ],
        ),
        body: Center(
          child: InteractiveViewer(
            maxScale: 4.0,
            child: WebdavImageWidget(url: url, fit: BoxFit.contain),
          ),
        ),
      );
    },
  );
}
