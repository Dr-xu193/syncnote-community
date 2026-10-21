import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:syncnote/shared/services/cloud_office_document_parser.dart';

class CloudSpreadsheetPreview extends StatefulWidget {
  const CloudSpreadsheetPreview({required this.bytes, super.key});

  final Uint8List bytes;

  @override
  State<CloudSpreadsheetPreview> createState() =>
      _CloudSpreadsheetPreviewState();
}

class _CloudSpreadsheetPreviewState extends State<CloudSpreadsheetPreview> {
  late Future<SpreadsheetDocument> _document;
  var _sheetIndex = 0;

  @override
  void initState() {
    super.initState();
    _document = compute(
      CloudOfficeDocumentParser.parseSpreadsheet,
      widget.bytes,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SpreadsheetDocument>(
      future: _document,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _OfficePreviewError(message: 'Excel解析失败：${snapshot.error}');
        }
        final document = snapshot.data;
        if (document == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (document.sheets.isEmpty) {
          return const _OfficePreviewError(message: '没有找到可显示的工作表。');
        }
        final selected = _sheetIndex.clamp(0, document.sheets.length - 1);
        return Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: SizedBox(
                height: 50,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemBuilder: (context, index) => ChoiceChip(
                    label: Text(document.sheets[index].name),
                    selected: selected == index,
                    onSelected: (_) => setState(() => _sheetIndex = index),
                  ),
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemCount: document.sheets.length,
                ),
              ),
            ),
            Expanded(
              child: _SpreadsheetCanvas(sheet: document.sheets[selected]),
            ),
          ],
        );
      },
    );
  }
}

class _SpreadsheetCanvas extends StatelessWidget {
  const _SpreadsheetCanvas({required this.sheet});

  final SpreadsheetSheet sheet;
  static const _rowHeaderWidth = 48.0;
  static const _columnHeaderHeight = 28.0;

  @override
  Widget build(BuildContext context) {
    final columnCount = math.max(8, sheet.maxColumn + 1);
    final rowCount = math.max(24, sheet.maxRow + 1);
    final columnOffsets = List<double>.filled(columnCount + 1, _rowHeaderWidth);
    final rowOffsets = List<double>.filled(rowCount + 1, _columnHeaderHeight);
    for (var i = 0; i < columnCount; i++) {
      columnOffsets[i + 1] = columnOffsets[i] + (sheet.columnWidths[i] ?? 84);
    }
    for (var i = 0; i < rowCount; i++) {
      rowOffsets[i + 1] = rowOffsets[i] + (sheet.rowHeights[i] ?? 26);
    }

    OfficeRect cellRect(int row, int column) {
      final merge = sheet.merges
          .where((item) => item.startRow == row && item.startColumn == column)
          .firstOrNull;
      final endRow = merge?.endRow.clamp(0, rowCount - 1) ?? row;
      final endColumn = merge?.endColumn.clamp(0, columnCount - 1) ?? column;
      return OfficeRect(
        columnOffsets[column],
        rowOffsets[row],
        columnOffsets[endColumn + 1] - columnOffsets[column],
        rowOffsets[endRow + 1] - rowOffsets[row],
      );
    }

    bool hiddenByMerge(SpreadsheetCell cell) => sheet.merges.any(
      (merge) =>
          merge.contains(cell.row, cell.column) &&
          (merge.startRow != cell.row || merge.startColumn != cell.column),
    );

    final totalWidth = columnOffsets.last;
    final totalHeight = rowOffsets.last;
    return ColoredBox(
      color: const Color(0xffe8eaed),
      child: InteractiveViewer(
        constrained: false,
        minScale: 0.35,
        maxScale: 4,
        boundaryMargin: const EdgeInsets.all(240),
        child: SizedBox(
          width: totalWidth,
          height: totalHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CustomPaint(
                size: Size(totalWidth, totalHeight),
                painter: _SpreadsheetGridPainter(
                  sheet: sheet,
                  columnOffsets: columnOffsets,
                  rowOffsets: rowOffsets,
                ),
              ),
              for (final cell in sheet.cells)
                if (cell.row < rowCount &&
                    cell.column < columnCount &&
                    !hiddenByMerge(cell))
                  _SpreadsheetCellWidget(
                    rect: cellRect(cell.row, cell.column),
                    cell: cell,
                  ),
              for (final object in sheet.objects)
                Positioned(
                  left: object.rect.left + _rowHeaderWidth,
                  top: object.rect.top + _columnHeaderHeight,
                  width: object.rect.width,
                  height: object.rect.height,
                  child: switch (object) {
                    SpreadsheetImage(:final bytes) => Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: Color(0xfff1f3f4),
                        child: Center(child: Icon(Icons.broken_image_outlined)),
                      ),
                    ),
                    SpreadsheetChart(:final chart) => OfficeChartView(
                      chart: chart,
                    ),
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpreadsheetCellWidget extends StatelessWidget {
  const _SpreadsheetCellWidget({required this.rect, required this.cell});

  final OfficeRect rect;
  final SpreadsheetCell cell;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Align(
        alignment: cell.style.verticalAlignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            cell.value,
            textAlign: cell.style.horizontalAlignment,
            maxLines: cell.style.wrap ? null : 1,
            overflow: cell.style.wrap
                ? TextOverflow.clip
                : TextOverflow.ellipsis,
            style: TextStyle(
              color: cell.style.foreground,
              fontSize: cell.style.fontSize,
              fontWeight: cell.style.bold ? FontWeight.bold : FontWeight.normal,
              fontStyle: cell.style.italic
                  ? FontStyle.italic
                  : FontStyle.normal,
              height: 1.15,
            ),
          ),
        ),
      ),
    );
  }
}

class _SpreadsheetGridPainter extends CustomPainter {
  const _SpreadsheetGridPainter({
    required this.sheet,
    required this.columnOffsets,
    required this.rowOffsets,
  });

  final SpreadsheetSheet sheet;
  final List<double> columnOffsets;
  final List<double> rowOffsets;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(
        _SpreadsheetCanvas._rowHeaderWidth,
        _SpreadsheetCanvas._columnHeaderHeight,
        size.width - _SpreadsheetCanvas._rowHeaderWidth,
        size.height - _SpreadsheetCanvas._columnHeaderHeight,
      ),
      Paint()..color = Colors.white,
    );
    final headerPaint = Paint()..color = const Color(0xfff1f3f4);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, _SpreadsheetCanvas._columnHeaderHeight),
      headerPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, _SpreadsheetCanvas._rowHeaderWidth, size.height),
      headerPaint,
    );

    for (final cell in sheet.cells) {
      if (cell.style.background == null ||
          cell.row + 1 >= rowOffsets.length ||
          cell.column + 1 >= columnOffsets.length) {
        continue;
      }
      final merge = sheet.merges
          .where(
            (item) =>
                item.startRow == cell.row && item.startColumn == cell.column,
          )
          .firstOrNull;
      final endRow = (merge?.endRow ?? cell.row).clamp(
        0,
        rowOffsets.length - 2,
      );
      final endColumn = (merge?.endColumn ?? cell.column).clamp(
        0,
        columnOffsets.length - 2,
      );
      canvas.drawRect(
        Rect.fromLTRB(
          columnOffsets[cell.column],
          rowOffsets[cell.row],
          columnOffsets[endColumn + 1],
          rowOffsets[endRow + 1],
        ),
        Paint()..color = cell.style.background!,
      );
    }

    final linePaint = Paint()
      ..color = const Color(0xffdadce0)
      ..strokeWidth = 1;
    for (final x in columnOffsets) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }
    for (final y in rowOffsets) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    for (var i = 0; i + 1 < columnOffsets.length; i++) {
      textPainter.text = TextSpan(
        text: _columnName(i),
        style: const TextStyle(color: Color(0xff5f6368), fontSize: 12),
      );
      textPainter.layout(maxWidth: columnOffsets[i + 1] - columnOffsets[i]);
      textPainter.paint(
        canvas,
        Offset(
          columnOffsets[i] +
              (columnOffsets[i + 1] - columnOffsets[i] - textPainter.width) / 2,
          (_SpreadsheetCanvas._columnHeaderHeight - textPainter.height) / 2,
        ),
      );
    }
    for (var i = 0; i + 1 < rowOffsets.length; i++) {
      textPainter.text = TextSpan(
        text: '${i + 1}',
        style: const TextStyle(color: Color(0xff5f6368), fontSize: 11),
      );
      textPainter.layout(maxWidth: _SpreadsheetCanvas._rowHeaderWidth);
      textPainter.paint(
        canvas,
        Offset(
          (_SpreadsheetCanvas._rowHeaderWidth - textPainter.width) / 2,
          rowOffsets[i] +
              (rowOffsets[i + 1] - rowOffsets[i] - textPainter.height) / 2,
        ),
      );
    }
  }

  static String _columnName(int index) {
    var value = index + 1;
    final output = StringBuffer();
    while (value > 0) {
      value--;
      output.writeCharCode(65 + value % 26);
      value ~/= 26;
    }
    return output.toString().split('').reversed.join();
  }

  @override
  bool shouldRepaint(covariant _SpreadsheetGridPainter oldDelegate) =>
      oldDelegate.sheet != sheet;
}

class CloudPresentationPreview extends StatefulWidget {
  const CloudPresentationPreview({required this.bytes, super.key});

  final Uint8List bytes;

  @override
  State<CloudPresentationPreview> createState() =>
      _CloudPresentationPreviewState();
}

class _CloudPresentationPreviewState extends State<CloudPresentationPreview> {
  late Future<PresentationDocument> _document;
  final _pageController = PageController();
  var _page = 0;

  @override
  void initState() {
    super.initState();
    _document = compute(
      CloudOfficeDocumentParser.parsePresentation,
      widget.bytes,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PresentationDocument>(
      future: _document,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _OfficePreviewError(
            message: 'PowerPoint解析失败：${snapshot.error}',
          );
        }
        final document = snapshot.data;
        if (document == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (document.slides.isEmpty) {
          return const _OfficePreviewError(message: '没有找到可显示的幻灯片。');
        }
        return ColoredBox(
          color: const Color(0xff202124),
          child: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: document.slides.length,
                  onPageChanged: (value) => setState(() => _page = value),
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.all(20),
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 5,
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: _PresentationSlideWidget(
                            slide: document.slides[index],
                            width: document.width,
                            height: document.height,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filledTonal(
                        onPressed: _page > 0
                            ? () => _pageController.previousPage(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOut,
                              )
                            : null,
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Text(
                          '${_page + 1} / ${document.slides.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: _page + 1 < document.slides.length
                            ? () => _pageController.nextPage(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOut,
                              )
                            : null,
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PresentationSlideWidget extends StatelessWidget {
  const _PresentationSlideWidget({
    required this.slide,
    required this.width,
    required this.height,
  });

  final PresentationSlide slide;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      child: SizedBox(
        width: width,
        height: height,
        child: ColoredBox(
          color: slide.background,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (final element in slide.elements)
                Positioned(
                  left: element.rect.left,
                  top: element.rect.top,
                  width: element.rect.width,
                  height: element.rect.height,
                  child: switch (element) {
                    PresentationImage(:final bytes) => Image.memory(
                      bytes,
                      fit: BoxFit.fill,
                    ),
                    PresentationChart(:final chart) => OfficeChartView(
                      chart: chart,
                    ),
                    PresentationTable(:final rows) => _PresentationTableWidget(
                      rows: rows,
                    ),
                    PresentationText(
                      :final runs,
                      :final background,
                      :final border,
                      :final alignment,
                      :final verticalAlignment,
                      :final cornerRadius,
                    ) =>
                      Container(
                        alignment: verticalAlignment,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: background,
                          border: border == null
                              ? null
                              : Border.all(color: border),
                          borderRadius: BorderRadius.circular(cornerRadius),
                        ),
                        child: RichText(
                          textAlign: alignment,
                          overflow: TextOverflow.clip,
                          text: TextSpan(
                            children: [
                              for (final run in runs)
                                TextSpan(
                                  text: run.text,
                                  style: TextStyle(
                                    color: run.color,
                                    fontSize: run.fontSize,
                                    fontWeight: run.bold
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontStyle: run.italic
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                    height: 1.12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresentationTableWidget extends StatelessWidget {
  const _PresentationTableWidget({required this.rows});

  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final columns = rows.fold<int>(
      0,
      (value, row) => math.max(value, row.length),
    );
    if (columns == 0) return const SizedBox.shrink();
    return Table(
      border: TableBorder.all(color: const Color(0xff8a8a8a), width: 0.7),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (final row in rows)
          TableRow(
            decoration: rows.first == row
                ? const BoxDecoration(color: Color(0xffd9e2f3))
                : null,
            children: [
              for (var i = 0; i < columns; i++)
                Padding(
                  padding: const EdgeInsets.all(5),
                  child: Text(
                    i < row.length ? row[i] : '',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: rows.first == row ? FontWeight.bold : null,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class OfficeChartView extends StatelessWidget {
  const OfficeChartView({required this.chart, super.key});

  final OfficeChart chart;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffd0d0d0)),
      ),
      child: CustomPaint(painter: _OfficeChartPainter(chart)),
    );
  }
}

class _OfficeChartPainter extends CustomPainter {
  const _OfficeChartPainter(this.chart);

  final OfficeChart chart;
  static const _palette = <Color>[
    Color(0xff4472c4),
    Color(0xffed7d31),
    Color(0xffa5a5a5),
    Color(0xffffc000),
    Color(0xff5b9bd5),
    Color(0xff70ad47),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final titleHeight = chart.title.isEmpty
        ? 8.0
        : math.min(34.0, size.height * 0.16);
    if (chart.title.isNotEmpty) {
      _paintText(
        canvas,
        chart.title,
        Rect.fromLTWH(8, 3, size.width - 16, titleHeight),
        fontSize: math.min(16, titleHeight * 0.6),
        bold: true,
        align: TextAlign.center,
      );
    }
    final plot = Rect.fromLTRB(
      38,
      titleHeight + 8,
      size.width - 12,
      size.height - 28,
    );
    if (plot.width <= 20 || plot.height <= 20) return;
    switch (chart.kind) {
      case OfficeChartKind.pie || OfficeChartKind.doughnut:
        _paintPie(canvas, plot);
      case OfficeChartKind.line ||
          OfficeChartKind.area ||
          OfficeChartKind.scatter:
        _paintLine(canvas, plot);
      case OfficeChartKind.column || OfficeChartKind.bar:
        _paintBars(canvas, plot);
    }
  }

  void _paintBars(Canvas canvas, Rect plot) {
    final maxValue = chart.series
        .expand((series) => series.values)
        .fold<double>(0, math.max);
    if (maxValue <= 0) return;
    final count = chart.series
        .map((series) => series.values.length)
        .fold<int>(0, math.max);
    final groupWidth = plot.width / math.max(1, count);
    final barWidth = groupWidth * 0.72 / chart.series.length;
    for (
      var seriesIndex = 0;
      seriesIndex < chart.series.length;
      seriesIndex++
    ) {
      final series = chart.series[seriesIndex];
      for (var index = 0; index < series.values.length; index++) {
        final value = series.values[index];
        final color = series.color ?? _palette[seriesIndex % _palette.length];
        if (chart.kind == OfficeChartKind.bar) {
          final rowHeight = plot.height / math.max(1, count);
          final height = rowHeight * 0.72 / chart.series.length;
          canvas.drawRect(
            Rect.fromLTWH(
              plot.left,
              plot.top + index * rowHeight + seriesIndex * height,
              plot.width * value / maxValue,
              height,
            ),
            Paint()..color = color,
          );
        } else {
          final height = plot.height * value / maxValue;
          canvas.drawRect(
            Rect.fromLTWH(
              plot.left +
                  index * groupWidth +
                  seriesIndex * barWidth +
                  groupWidth * 0.14,
              plot.bottom - height,
              barWidth,
              height,
            ),
            Paint()..color = color,
          );
        }
      }
    }
    _paintAxes(canvas, plot);
  }

  void _paintLine(Canvas canvas, Rect plot) {
    final allValues = chart.series.expand((series) => series.values).toList();
    if (allValues.isEmpty) return;
    final maxValue = allValues.reduce(math.max);
    final minValue = math.min(0, allValues.reduce(math.min));
    final range = math.max(1.0, maxValue - minValue);
    for (
      var seriesIndex = 0;
      seriesIndex < chart.series.length;
      seriesIndex++
    ) {
      final series = chart.series[seriesIndex];
      final path = Path();
      for (var index = 0; index < series.values.length; index++) {
        final x =
            plot.left +
            plot.width * index / math.max(1, series.values.length - 1);
        final y =
            plot.bottom -
            plot.height * (series.values[index] - minValue) / range;
        index == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
        canvas.drawCircle(
          Offset(x, y),
          2.5,
          Paint()
            ..color = series.color ?? _palette[seriesIndex % _palette.length],
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = series.color ?? _palette[seriesIndex % _palette.length]
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
    _paintAxes(canvas, plot);
  }

  void _paintPie(Canvas canvas, Rect plot) {
    final values = chart.series.first.values;
    final total = values.fold<double>(0, (sum, value) => sum + value.abs());
    if (total <= 0) return;
    final side = math.min(plot.width, plot.height);
    final rect = Rect.fromCenter(
      center: plot.center,
      width: side,
      height: side,
    );
    var start = -math.pi / 2;
    for (var index = 0; index < values.length; index++) {
      final sweep = math.pi * 2 * values[index].abs() / total;
      canvas.drawArc(
        rect,
        start,
        sweep,
        true,
        Paint()..color = _palette[index % _palette.length],
      );
      start += sweep;
    }
    if (chart.kind == OfficeChartKind.doughnut) {
      canvas.drawCircle(
        plot.center,
        side * 0.22,
        Paint()..color = Colors.white,
      );
    }
  }

  void _paintAxes(Canvas canvas, Rect plot) {
    canvas.drawLine(
      plot.bottomLeft,
      plot.topLeft,
      Paint()..color = const Color(0xff888888),
    );
    canvas.drawLine(
      plot.bottomLeft,
      plot.bottomRight,
      Paint()..color = const Color(0xff888888),
    );
  }

  void _paintText(
    Canvas canvas,
    String text,
    Rect rect, {
    required double fontSize,
    bool bold = false,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: const Color(0xff333333),
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: rect.width);
    painter.paint(canvas, Offset(rect.left, rect.top));
  }

  @override
  bool shouldRepaint(covariant _OfficeChartPainter oldDelegate) =>
      oldDelegate.chart != chart;
}

class _OfficePreviewError extends StatelessWidget {
  const _OfficePreviewError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
