import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

enum OfficeChartKind { column, bar, line, area, pie, doughnut, scatter }

class OfficeChartSeries {
  const OfficeChartSeries({
    required this.name,
    required this.values,
    this.categories = const [],
    this.color,
  });

  final String name;
  final List<double> values;
  final List<String> categories;
  final Color? color;
}

class OfficeChart {
  const OfficeChart({
    required this.kind,
    required this.series,
    this.title = '',
  });

  final OfficeChartKind kind;
  final List<OfficeChartSeries> series;
  final String title;
}

class OfficeRect {
  const OfficeRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;
}

class SpreadsheetCellStyle {
  const SpreadsheetCellStyle({
    this.background,
    this.foreground = const Color(0xff202124),
    this.fontSize = 14,
    this.bold = false,
    this.italic = false,
    this.horizontalAlignment = TextAlign.left,
    this.verticalAlignment = Alignment.centerLeft,
    this.wrap = false,
  });

  final Color? background;
  final Color foreground;
  final double fontSize;
  final bool bold;
  final bool italic;
  final TextAlign horizontalAlignment;
  final Alignment verticalAlignment;
  final bool wrap;
}

class SpreadsheetCell {
  const SpreadsheetCell({
    required this.row,
    required this.column,
    required this.value,
    required this.style,
  });

  final int row;
  final int column;
  final String value;
  final SpreadsheetCellStyle style;
}

class SpreadsheetMerge {
  const SpreadsheetMerge(
    this.startRow,
    this.startColumn,
    this.endRow,
    this.endColumn,
  );

  final int startRow;
  final int startColumn;
  final int endRow;
  final int endColumn;

  bool contains(int row, int column) =>
      row >= startRow &&
      row <= endRow &&
      column >= startColumn &&
      column <= endColumn;
}

sealed class SpreadsheetFloatingObject {
  const SpreadsheetFloatingObject(this.rect);
  final OfficeRect rect;
}

class SpreadsheetImage extends SpreadsheetFloatingObject {
  const SpreadsheetImage(super.rect, this.bytes);
  final Uint8List bytes;
}

class SpreadsheetChart extends SpreadsheetFloatingObject {
  const SpreadsheetChart(super.rect, this.chart);
  final OfficeChart chart;
}

class SpreadsheetSheet {
  const SpreadsheetSheet({
    required this.name,
    required this.cells,
    required this.columnWidths,
    required this.rowHeights,
    required this.merges,
    required this.objects,
    required this.maxRow,
    required this.maxColumn,
  });

  final String name;
  final List<SpreadsheetCell> cells;
  final Map<int, double> columnWidths;
  final Map<int, double> rowHeights;
  final List<SpreadsheetMerge> merges;
  final List<SpreadsheetFloatingObject> objects;
  final int maxRow;
  final int maxColumn;
}

class SpreadsheetDocument {
  const SpreadsheetDocument(this.sheets);
  final List<SpreadsheetSheet> sheets;
}

sealed class PresentationElement {
  const PresentationElement(this.rect);
  final OfficeRect rect;
}

class PresentationTextRun {
  const PresentationTextRun({
    required this.text,
    this.fontSize = 24,
    this.bold = false,
    this.italic = false,
    this.color = const Color(0xff202124),
  });

  final String text;
  final double fontSize;
  final bool bold;
  final bool italic;
  final Color color;
}

class PresentationText extends PresentationElement {
  const PresentationText(
    super.rect, {
    required this.runs,
    this.background,
    this.border,
    this.alignment = TextAlign.left,
    this.verticalAlignment = Alignment.topLeft,
    this.cornerRadius = 0,
  });

  final List<PresentationTextRun> runs;
  final Color? background;
  final Color? border;
  final TextAlign alignment;
  final Alignment verticalAlignment;
  final double cornerRadius;
}

class PresentationImage extends PresentationElement {
  const PresentationImage(super.rect, this.bytes);
  final Uint8List bytes;
}

class PresentationChart extends PresentationElement {
  const PresentationChart(super.rect, this.chart);
  final OfficeChart chart;
}

class PresentationTable extends PresentationElement {
  const PresentationTable(super.rect, this.rows);
  final List<List<String>> rows;
}

class PresentationSlide {
  const PresentationSlide({required this.background, required this.elements});
  final Color background;
  final List<PresentationElement> elements;
}

class PresentationDocument {
  const PresentationDocument({
    required this.width,
    required this.height,
    required this.slides,
  });

  final double width;
  final double height;
  final List<PresentationSlide> slides;
}

abstract final class CloudOfficeDocumentParser {
  static SpreadsheetDocument parseSpreadsheet(Uint8List bytes) {
    final package = _OfficePackage(bytes);
    final sharedStrings = _parseSharedStrings(
      package.xml('xl/sharedStrings.xml'),
    );
    final styles = _parseSpreadsheetStyles(package.xml('xl/styles.xml'));
    final workbook = package.xml('xl/workbook.xml');
    if (workbook == null) return const SpreadsheetDocument([]);
    final workbookRels = package.relationships('xl/_rels/workbook.xml.rels');
    final sheets = <SpreadsheetSheet>[];

    for (final sheetNode in _descendants(workbook.rootElement, 'sheet')) {
      final name = sheetNode.getAttribute('name') ?? '工作表${sheets.length + 1}';
      final relationshipId = _relationshipId(sheetNode);
      final target = workbookRels[relationshipId];
      if (target == null) continue;
      final sheetPath = _resolvePart('xl/workbook.xml', target);
      final sheetXml = package.xml(sheetPath);
      if (sheetXml == null) continue;
      sheets.add(
        _parseSheet(package, sheetPath, name, sheetXml, sharedStrings, styles),
      );
    }
    return SpreadsheetDocument(sheets);
  }

  static PresentationDocument parsePresentation(Uint8List bytes) {
    final package = _OfficePackage(bytes);
    final presentationXml = package.xml('ppt/presentation.xml');
    if (presentationXml == null) {
      return const PresentationDocument(width: 960, height: 540, slides: []);
    }
    final size = _firstDescendant(presentationXml.rootElement, 'sldSz');
    final sourceWidth =
        double.tryParse(size?.getAttribute('cx') ?? '') ?? 12192000;
    final sourceHeight =
        double.tryParse(size?.getAttribute('cy') ?? '') ?? 6858000;
    const targetWidth = 960.0;
    final targetHeight = targetWidth * sourceHeight / sourceWidth;
    final rels = package.relationships('ppt/_rels/presentation.xml.rels');
    final themeColors = _parseThemeColors(package.xml('ppt/theme/theme1.xml'));
    final slides = <PresentationSlide>[];

    for (final id in _descendants(presentationXml.rootElement, 'sldId')) {
      final target = rels[_relationshipId(id)];
      if (target == null) continue;
      final path = _resolvePart('ppt/presentation.xml', target);
      final slideXml = package.xml(path);
      if (slideXml == null) continue;
      slides.add(
        _parseSlide(
          package,
          path,
          slideXml,
          sourceWidth,
          sourceHeight,
          targetWidth,
          targetHeight,
          themeColors,
        ),
      );
    }
    return PresentationDocument(
      width: targetWidth,
      height: targetHeight,
      slides: slides,
    );
  }

  static List<String> _parseSharedStrings(XmlDocument? document) {
    if (document == null) return const [];
    return _descendants(document.rootElement, 'si')
        .map(
          (node) =>
              _descendants(node, 't').map((text) => text.innerText).join(),
        )
        .toList();
  }

  static List<SpreadsheetCellStyle> _parseSpreadsheetStyles(
    XmlDocument? document,
  ) {
    if (document == null) return const [SpreadsheetCellStyle()];
    final fontsParent = _firstDescendant(document.rootElement, 'fonts');
    final fillsParent = _firstDescendant(document.rootElement, 'fills');
    final fonts = fontsParent == null
        ? const <_SpreadsheetFont>[]
        : _children(fontsParent, 'font').map((node) {
            final colorNode = _firstDescendant(node, 'color');
            return _SpreadsheetFont(
              color: _spreadsheetColor(colorNode) ?? const Color(0xff202124),
              size:
                  double.tryParse(
                    _firstDescendant(node, 'sz')?.getAttribute('val') ?? '',
                  ) ??
                  11,
              bold: _firstDescendant(node, 'b') != null,
              italic: _firstDescendant(node, 'i') != null,
            );
          }).toList();
    final fills = fillsParent == null
        ? const <Color?>[]
        : _children(fillsParent, 'fill').map((node) {
            final pattern = _firstDescendant(node, 'patternFill');
            return _spreadsheetColor(_firstDescendant(pattern, 'fgColor'));
          }).toList();
    final xfsParent = _descendants(document.rootElement, 'cellXfs').firstOrNull;
    if (xfsParent == null) return const [SpreadsheetCellStyle()];
    return _children(xfsParent, 'xf').map((node) {
      final fontId = int.tryParse(node.getAttribute('fontId') ?? '') ?? 0;
      final fillId = int.tryParse(node.getAttribute('fillId') ?? '') ?? 0;
      final font = fontId < fonts.length
          ? fonts[fontId]
          : const _SpreadsheetFont();
      final alignment = _firstDescendant(node, 'alignment');
      final horizontal = switch (alignment?.getAttribute('horizontal')) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        _ => TextAlign.left,
      };
      final vertical = switch (alignment?.getAttribute('vertical')) {
        'top' => Alignment.topLeft,
        'bottom' => Alignment.bottomLeft,
        _ => Alignment.centerLeft,
      };
      return SpreadsheetCellStyle(
        background: fillId < fills.length ? fills[fillId] : null,
        foreground: font.color,
        fontSize: font.size * 1.18,
        bold: font.bold,
        italic: font.italic,
        horizontalAlignment: horizontal,
        verticalAlignment: horizontal == TextAlign.center
            ? Alignment(vertical.x + 1, vertical.y)
            : horizontal == TextAlign.right
            ? Alignment(1, vertical.y)
            : vertical,
        wrap: alignment?.getAttribute('wrapText') == '1',
      );
    }).toList();
  }

  static SpreadsheetSheet _parseSheet(
    _OfficePackage package,
    String sheetPath,
    String name,
    XmlDocument document,
    List<String> sharedStrings,
    List<SpreadsheetCellStyle> styles,
  ) {
    final cells = <SpreadsheetCell>[];
    final columnWidths = <int, double>{};
    final rowHeights = <int, double>{};
    final merges = <SpreadsheetMerge>[];
    var maxRow = 0;
    var maxColumn = 0;

    for (final col in _descendants(document.rootElement, 'col')) {
      final start = (int.tryParse(col.getAttribute('min') ?? '') ?? 1) - 1;
      final end =
          (int.tryParse(col.getAttribute('max') ?? '') ?? start + 1) - 1;
      final width =
          (double.tryParse(col.getAttribute('width') ?? '') ?? 12) * 7.2;
      for (var index = start; index <= math.min(end, 199); index++) {
        columnWidths[index] = width.clamp(24, 360);
      }
    }
    for (final row in _descendants(document.rootElement, 'row')) {
      final rowIndex = (int.tryParse(row.getAttribute('r') ?? '') ?? 1) - 1;
      final height = double.tryParse(row.getAttribute('ht') ?? '');
      if (height != null) rowHeights[rowIndex] = (height * 1.34).clamp(18, 240);
    }
    for (final cellNode in _descendants(document.rootElement, 'c')) {
      final ref = cellNode.getAttribute('r') ?? 'A1';
      final position = _cellPosition(ref);
      if (position == null || position.$1 > 499 || position.$2 > 199) continue;
      final type = cellNode.getAttribute('t');
      final raw = _firstDescendant(cellNode, 'v')?.innerText ?? '';
      final inline = _firstDescendant(cellNode, 'is');
      final sharedStringIndex = int.tryParse(raw);
      final value = switch (type) {
        's' =>
          sharedStringIndex != null &&
                  sharedStringIndex >= 0 &&
                  sharedStringIndex < sharedStrings.length
              ? sharedStrings[sharedStringIndex]
              : raw,
        'inlineStr' =>
          inline == null
              ? ''
              : _descendants(inline, 't').map((node) => node.innerText).join(),
        'b' => raw == '1' ? 'TRUE' : 'FALSE',
        _ => raw,
      };
      final styleIndex = int.tryParse(cellNode.getAttribute('s') ?? '') ?? 0;
      cells.add(
        SpreadsheetCell(
          row: position.$1,
          column: position.$2,
          value: value,
          style: styleIndex < styles.length
              ? styles[styleIndex]
              : const SpreadsheetCellStyle(),
        ),
      );
      maxRow = math.max(maxRow, position.$1);
      maxColumn = math.max(maxColumn, position.$2);
    }
    for (final merge in _descendants(document.rootElement, 'mergeCell')) {
      final range = merge.getAttribute('ref')?.split(':');
      if (range == null || range.length != 2) continue;
      final start = _cellPosition(range.first);
      final end = _cellPosition(range.last);
      if (start == null || end == null) continue;
      merges.add(SpreadsheetMerge(start.$1, start.$2, end.$1, end.$2));
      maxRow = math.max(maxRow, end.$1);
      maxColumn = math.max(maxColumn, end.$2);
    }

    final objects = _parseSpreadsheetObjects(
      package,
      sheetPath,
      document,
      columnWidths,
      rowHeights,
    );
    for (final object in objects) {
      maxColumn = math.max(maxColumn, (object.rect.left / 84).ceil());
      maxRow = math.max(maxRow, (object.rect.top / 26).ceil());
    }
    return SpreadsheetSheet(
      name: name,
      cells: cells,
      columnWidths: columnWidths,
      rowHeights: rowHeights,
      merges: merges,
      objects: objects,
      maxRow: math.min(maxRow, 499),
      maxColumn: math.min(maxColumn, 199),
    );
  }

  static List<SpreadsheetFloatingObject> _parseSpreadsheetObjects(
    _OfficePackage package,
    String sheetPath,
    XmlDocument sheetXml,
    Map<int, double> columnWidths,
    Map<int, double> rowHeights,
  ) {
    final sheetRelsPath = _relsPath(sheetPath);
    final sheetRels = package.relationships(sheetRelsPath);
    final output = <SpreadsheetFloatingObject>[];
    for (final drawing in _descendants(sheetXml.rootElement, 'drawing')) {
      final drawingTarget = sheetRels[_attributeLocal(drawing, 'id')];
      if (drawingTarget == null) continue;
      final drawingPath = _resolvePart(sheetPath, drawingTarget);
      final drawingXml = package.xml(drawingPath);
      if (drawingXml == null) continue;
      final drawingRels = package.relationships(_relsPath(drawingPath));
      for (final anchor
          in drawingXml.rootElement.children.whereType<XmlElement>()) {
        if (!{
          'twoCellAnchor',
          'oneCellAnchor',
          'absoluteAnchor',
        }.contains(anchor.name.local)) {
          continue;
        }
        final rect = _spreadsheetAnchorRect(anchor, columnWidths, rowHeights);
        if (rect == null) continue;
        final blip = _firstDescendant(anchor, 'blip');
        final imageTarget = drawingRels[_attributeLocal(blip, 'embed')];
        if (imageTarget != null) {
          final imageBytes = package.bytes(
            _resolvePart(drawingPath, imageTarget),
          );
          if (imageBytes != null) {
            output.add(SpreadsheetImage(rect, imageBytes));
          }
        }
        final chartNode = _firstDescendant(anchor, 'chart');
        final chartTarget = drawingRels[_attributeLocal(chartNode, 'id')];
        if (chartTarget != null) {
          final chart = _parseChart(
            package.xml(_resolvePart(drawingPath, chartTarget)),
          );
          if (chart != null) output.add(SpreadsheetChart(rect, chart));
        }
      }
    }
    return output;
  }

  static OfficeRect? _spreadsheetAnchorRect(
    XmlElement anchor,
    Map<int, double> columnWidths,
    Map<int, double> rowHeights,
  ) {
    double colOffset(int index) {
      var total = 0.0;
      for (var i = 0; i < index; i++) {
        total += columnWidths[i] ?? 84;
      }
      return total;
    }

    double rowOffset(int index) {
      var total = 0.0;
      for (var i = 0; i < index; i++) {
        total += rowHeights[i] ?? 26;
      }
      return total;
    }

    final from = _firstDescendant(anchor, 'from');
    final to = _firstDescendant(anchor, 'to');
    if (from == null) return null;
    final fromCol =
        int.tryParse(_firstDescendant(from, 'col')?.innerText ?? '') ?? 0;
    final fromRow =
        int.tryParse(_firstDescendant(from, 'row')?.innerText ?? '') ?? 0;
    final left =
        colOffset(fromCol) +
        (double.tryParse(_firstDescendant(from, 'colOff')?.innerText ?? '') ??
                0) /
            9525;
    final top =
        rowOffset(fromRow) +
        (double.tryParse(_firstDescendant(from, 'rowOff')?.innerText ?? '') ??
                0) /
            9525;
    if (to != null) {
      final toCol =
          int.tryParse(_firstDescendant(to, 'col')?.innerText ?? '') ??
          fromCol + 4;
      final toRow =
          int.tryParse(_firstDescendant(to, 'row')?.innerText ?? '') ??
          fromRow + 10;
      final right =
          colOffset(toCol) +
          (double.tryParse(_firstDescendant(to, 'colOff')?.innerText ?? '') ??
                  0) /
              9525;
      final bottom =
          rowOffset(toRow) +
          (double.tryParse(_firstDescendant(to, 'rowOff')?.innerText ?? '') ??
                  0) /
              9525;
      return OfficeRect(
        left,
        top,
        math.max(80, right - left),
        math.max(60, bottom - top),
      );
    }
    final ext = _firstDescendant(anchor, 'ext');
    final width =
        (double.tryParse(ext?.getAttribute('cx') ?? '') ?? 320 * 9525) / 9525;
    final height =
        (double.tryParse(ext?.getAttribute('cy') ?? '') ?? 180 * 9525) / 9525;
    return OfficeRect(left, top, width, height);
  }

  static PresentationSlide _parseSlide(
    _OfficePackage package,
    String slidePath,
    XmlDocument document,
    double sourceWidth,
    double sourceHeight,
    double targetWidth,
    double targetHeight,
    Map<String, Color> themeColors,
  ) {
    final relationships = package.relationships(_relsPath(slidePath));
    final scaleX = targetWidth / sourceWidth;
    final scaleY = targetHeight / sourceHeight;
    final backgroundNode = _firstDescendant(document.rootElement, 'bg');
    final background =
        _drawingColor(backgroundNode, themeColors) ?? Colors.white;
    final elements = <PresentationElement>[];
    final tree = _firstDescendant(document.rootElement, 'spTree');
    if (tree == null) {
      return PresentationSlide(background: background, elements: elements);
    }

    for (final node in tree.children.whereType<XmlElement>()) {
      final rect = _presentationRect(node, scaleX, scaleY);
      if (rect == null) continue;
      if (node.name.local == 'pic') {
        final target =
            relationships[_attributeLocal(
              _firstDescendant(node, 'blip'),
              'embed',
            )];
        final imageBytes = target == null
            ? null
            : package.bytes(_resolvePart(slidePath, target));
        if (imageBytes != null) {
          elements.add(PresentationImage(rect, imageBytes));
        }
        continue;
      }
      if (node.name.local == 'graphicFrame') {
        final chartNode = _firstDescendant(node, 'chart');
        final chartTarget = relationships[_attributeLocal(chartNode, 'id')];
        if (chartTarget != null) {
          final chart = _parseChart(
            package.xml(_resolvePart(slidePath, chartTarget)),
          );
          if (chart != null) elements.add(PresentationChart(rect, chart));
          continue;
        }
        final table = _firstDescendant(node, 'tbl');
        if (table != null) {
          final rows = _children(table, 'tr')
              .map(
                (row) => _children(row, 'tc')
                    .map(
                      (cell) => _descendants(
                        cell,
                        't',
                      ).map((t) => t.innerText).join(),
                    )
                    .toList(),
              )
              .toList();
          elements.add(PresentationTable(rect, rows));
        }
        continue;
      }
      if (node.name.local == 'sp') {
        final runs = <PresentationTextRun>[];
        for (final paragraph in _descendants(node, 'p')) {
          final paragraphProperties = _firstDescendant(paragraph, 'pPr');
          final bullet = _firstDescendant(
            paragraphProperties,
            'buChar',
          )?.getAttribute('char');
          if (bullet != null) {
            runs.add(PresentationTextRun(text: '$bullet ', fontSize: 18));
          }
          for (final run in _children(paragraph, 'r')) {
            final properties = _firstDescendant(run, 'rPr');
            final text = _firstDescendant(run, 't')?.innerText ?? '';
            if (text.isEmpty) continue;
            final size =
                (double.tryParse(properties?.getAttribute('sz') ?? '') ??
                    1800) /
                100;
            runs.add(
              PresentationTextRun(
                text: text,
                fontSize: size.clamp(6, 96),
                bold: properties?.getAttribute('b') == '1',
                italic: properties?.getAttribute('i') == '1',
                color:
                    _drawingColor(properties, themeColors) ??
                    const Color(0xff202124),
              ),
            );
          }
          if (paragraph != _descendants(node, 'p').lastOrNull) {
            runs.add(const PresentationTextRun(text: '\n', fontSize: 10));
          }
        }
        if (runs.isEmpty) {
          final text = _descendants(
            node,
            't',
          ).map((part) => part.innerText).join(' ');
          if (text.isNotEmpty) runs.add(PresentationTextRun(text: text));
        }
        final spPr = _firstDescendant(node, 'spPr');
        final backgroundColor = _drawingColor(
          _firstDescendant(spPr, 'solidFill'),
          themeColors,
        );
        final border = _drawingColor(_firstDescendant(spPr, 'ln'), themeColors);
        final preset = _firstDescendant(spPr, 'prstGeom')?.getAttribute('prst');
        final paragraphAlignment = _firstDescendant(
          node,
          'pPr',
        )?.getAttribute('algn');
        final bodyProperties = _firstDescendant(node, 'bodyPr');
        elements.add(
          PresentationText(
            rect,
            runs: runs,
            background: backgroundColor,
            border: border,
            alignment: switch (paragraphAlignment) {
              'ctr' => TextAlign.center,
              'r' => TextAlign.right,
              _ => TextAlign.left,
            },
            verticalAlignment: switch (bodyProperties?.getAttribute('anchor')) {
              'ctr' => Alignment.centerLeft,
              'b' => Alignment.bottomLeft,
              _ => Alignment.topLeft,
            },
            cornerRadius: preset == 'roundRect' ? 14 : 0,
          ),
        );
      }
    }
    return PresentationSlide(background: background, elements: elements);
  }

  static OfficeRect? _presentationRect(
    XmlElement element,
    double scaleX,
    double scaleY,
  ) {
    final xfrm = _firstDescendant(element, 'xfrm');
    final offset = _firstDescendant(xfrm, 'off');
    final extent = _firstDescendant(xfrm, 'ext');
    if (offset == null || extent == null) return null;
    final x = (double.tryParse(offset.getAttribute('x') ?? '') ?? 0) * scaleX;
    final y = (double.tryParse(offset.getAttribute('y') ?? '') ?? 0) * scaleY;
    final width =
        (double.tryParse(extent.getAttribute('cx') ?? '') ?? 0) * scaleX;
    final height =
        (double.tryParse(extent.getAttribute('cy') ?? '') ?? 0) * scaleY;
    if (width <= 0 || height <= 0) return null;
    return OfficeRect(x, y, width, height);
  }

  static OfficeChart? _parseChart(XmlDocument? document) {
    if (document == null) return null;
    final root = document.rootElement;
    final kind =
        <String, OfficeChartKind>{
          'barChart': OfficeChartKind.column,
          'lineChart': OfficeChartKind.line,
          'areaChart': OfficeChartKind.area,
          'pieChart': OfficeChartKind.pie,
          'doughnutChart': OfficeChartKind.doughnut,
          'scatterChart': OfficeChartKind.scatter,
        }.entries.firstWhereOrNull(
          (entry) => _firstDescendant(root, entry.key) != null,
        );
    if (kind == null) return null;
    final chartNode = _firstDescendant(root, kind.key)!;
    final direction = _firstDescendant(
      chartNode,
      'barDir',
    )?.getAttribute('val');
    final actualKind =
        kind.value == OfficeChartKind.column && direction == 'bar'
        ? OfficeChartKind.bar
        : kind.value;
    final titleNode = _firstDescendant(root, 'title');
    final title = titleNode == null
        ? ''
        : _descendants(titleNode, 't').map((node) => node.innerText).join();
    final series = <OfficeChartSeries>[];
    for (final seriesNode in _children(chartNode, 'ser')) {
      final titleContainer = _firstDescendant(seriesNode, 'tx');
      final name = titleContainer == null
          ? '系列${series.length + 1}'
          : _descendants(
                  titleContainer,
                  'v',
                ).map((node) => node.innerText).firstOrNull ??
                _descendants(
                  titleContainer,
                  't',
                ).map((node) => node.innerText).join();
      final categoriesNode =
          _firstDescendant(seriesNode, 'cat') ??
          _firstDescendant(seriesNode, 'xVal');
      final valuesNode =
          _firstDescendant(seriesNode, 'val') ??
          _firstDescendant(seriesNode, 'yVal');
      final categories = categoriesNode == null
          ? const <String>[]
          : _descendants(categoriesNode, 'pt')
                .map((point) => _firstDescendant(point, 'v')?.innerText ?? '')
                .toList();
      final values = valuesNode == null
          ? const <double>[]
          : _descendants(valuesNode, 'pt')
                .map(
                  (point) =>
                      double.tryParse(
                        _firstDescendant(point, 'v')?.innerText ?? '',
                      ) ??
                      0,
                )
                .toList();
      final color = _drawingColor(
        _firstDescendant(seriesNode, 'spPr'),
        const {},
      );
      if (values.isNotEmpty) {
        series.add(
          OfficeChartSeries(
            name: name,
            values: values,
            categories: categories,
            color: color,
          ),
        );
      }
    }
    if (series.isEmpty) return null;
    return OfficeChart(kind: actualKind, series: series, title: title);
  }

  static Map<String, Color> _parseThemeColors(XmlDocument? document) {
    final result = <String, Color>{..._defaultThemeColors};
    if (document == null) return result;
    final scheme = _firstDescendant(document.rootElement, 'clrScheme');
    if (scheme == null) return result;
    for (final node in scheme.children.whereType<XmlElement>()) {
      final color = _drawingColor(node, const {});
      if (color != null) result[node.name.local] = color;
    }
    return result;
  }

  static Color? _drawingColor(
    XmlElement? node,
    Map<String, Color> themeColors,
  ) {
    if (node == null) return null;
    final srgb = _firstDescendant(node, 'srgbClr');
    final system = _firstDescendant(node, 'sysClr');
    final scheme = _firstDescendant(node, 'schemeClr');
    Color? color =
        _hexColor(srgb?.getAttribute('val')) ??
        _hexColor(system?.getAttribute('lastClr')) ??
        themeColors[scheme?.getAttribute('val')];
    if (color == null) return null;
    final colorNode = srgb ?? system ?? scheme;
    final transparency = double.tryParse(
      _firstDescendant(colorNode, 'alpha')?.getAttribute('val') ?? '',
    );
    if (transparency != null) {
      color = color.withValues(alpha: (transparency / 100000).clamp(0, 1));
    }
    return color;
  }

  static Color? _spreadsheetColor(XmlElement? node) {
    if (node == null) return null;
    final rgb = node.getAttribute('rgb');
    if (rgb != null) return _hexColor(rgb.length == 8 ? rgb.substring(2) : rgb);
    final indexed = int.tryParse(node.getAttribute('indexed') ?? '');
    if (indexed != null && indexed < _indexedColors.length) {
      return _indexedColors[indexed];
    }
    return null;
  }

  static Color? _hexColor(String? value) {
    if (value == null) return null;
    final normalized = value.replaceAll('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(normalized)) return null;
    return Color(0xff000000 | int.parse(normalized, radix: 16));
  }

  static (int, int)? _cellPosition(String reference) {
    final match = RegExp(r'^([A-Za-z]+)(\d+)$').firstMatch(reference);
    if (match == null) return null;
    var column = 0;
    for (final unit in match.group(1)!.toUpperCase().codeUnits) {
      column = column * 26 + unit - 64;
    }
    return (int.parse(match.group(2)!) - 1, column - 1);
  }

  static String? _attributeLocal(XmlElement? element, String localName) =>
      element?.attributes
          .firstWhereOrNull((attribute) => attribute.name.local == localName)
          ?.value;

  static String? _relationshipId(XmlElement? element) {
    if (element == null) return null;
    return element.attributes
            .firstWhereOrNull(
              (attribute) =>
                  attribute.name.local == 'id' &&
                  (attribute.name.prefix == 'r' ||
                      attribute.name.namespaceUri ==
                          'http://schemas.openxmlformats.org/officeDocument/2006/relationships'),
            )
            ?.value ??
        _attributeLocal(element, 'id');
  }

  static XmlElement? _firstDescendant(XmlNode? node, String localName) =>
      node == null ? null : _descendants(node, localName).firstOrNull;

  static Iterable<XmlElement> _descendants(XmlNode node, String localName) =>
      node.descendants.whereType<XmlElement>().where(
        (element) => element.name.local == localName,
      );

  static Iterable<XmlElement> _children(XmlNode node, String localName) => node
      .children
      .whereType<XmlElement>()
      .where((element) => element.name.local == localName);

  static String _relsPath(String partPath) {
    final slash = partPath.lastIndexOf('/');
    final directory = slash < 0 ? '' : partPath.substring(0, slash + 1);
    final name = slash < 0 ? partPath : partPath.substring(slash + 1);
    return '${directory}_rels/$name.rels';
  }

  static String _resolvePart(String sourcePart, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final sourceSegments = sourcePart.split('/')..removeLast();
    for (final segment in target.replaceAll('\\', '/').split('/')) {
      if (segment == '..') {
        if (sourceSegments.isNotEmpty) sourceSegments.removeLast();
      } else if (segment != '.' && segment.isNotEmpty) {
        sourceSegments.add(segment);
      }
    }
    return sourceSegments.join('/');
  }

  static const _defaultThemeColors = <String, Color>{
    'dk1': Color(0xff000000),
    'lt1': Color(0xffffffff),
    'dk2': Color(0xff44546a),
    'lt2': Color(0xffe7e6e6),
    'accent1': Color(0xff4472c4),
    'accent2': Color(0xffed7d31),
    'accent3': Color(0xffa5a5a5),
    'accent4': Color(0xffffc000),
    'accent5': Color(0xff5b9bd5),
    'accent6': Color(0xff70ad47),
    'tx1': Color(0xff000000),
    'bg1': Color(0xffffffff),
  };

  static const _indexedColors = <Color>[
    Color(0xff000000),
    Color(0xffffffff),
    Color(0xffff0000),
    Color(0xff00ff00),
    Color(0xff0000ff),
    Color(0xffffff00),
    Color(0xffff00ff),
    Color(0xff00ffff),
    Color(0xff000000),
    Color(0xffffffff),
    Color(0xffff0000),
    Color(0xff00ff00),
    Color(0xff0000ff),
    Color(0xffffff00),
    Color(0xffff00ff),
    Color(0xff00ffff),
  ];
}

class _SpreadsheetFont {
  const _SpreadsheetFont({
    this.color = const Color(0xff202124),
    this.size = 11,
    this.bold = false,
    this.italic = false,
  });
  final Color color;
  final double size;
  final bool bold;
  final bool italic;
}

class _OfficePackage {
  _OfficePackage(Uint8List source) {
    final archive = ZipDecoder().decodeBytes(source, verify: false);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      _files[file.name.replaceAll('\\', '/')] = Uint8List.fromList(
        file.content as List<int>,
      );
    }
  }

  final Map<String, Uint8List> _files = {};

  Uint8List? bytes(String path) => _files[path];

  XmlDocument? xml(String path) {
    final data = _files[path];
    if (data == null) return null;
    try {
      return XmlDocument.parse(utf8.decode(data, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  Map<String?, String> relationships(String path) {
    final document = xml(path);
    if (document == null) return const {};
    return {
      for (final relationship
          in document.rootElement.children.whereType<XmlElement>())
        relationship.getAttribute('Id'):
            relationship.getAttribute('Target') ?? '',
    };
  }
}

extension _IterableFirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? get lastOrNull => isEmpty ? null : last;

  T? firstWhereOrNull(bool Function(T value) predicate) {
    for (final value in this) {
      if (predicate(value)) return value;
    }
    return null;
  }
}
