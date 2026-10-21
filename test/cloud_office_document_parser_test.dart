import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/services/cloud_office_document_parser.dart';

void main() {
  group('in-memory OOXML preview parser', () {
    test('keeps spreadsheet cells, merges, image and chart', () {
      final document = CloudOfficeDocumentParser.parseSpreadsheet(
        _zip({
          'xl/workbook.xml': _workbookXml,
          'xl/_rels/workbook.xml.rels': _workbookRels,
          'xl/sharedStrings.xml': _sharedStrings,
          'xl/styles.xml': _styles,
          'xl/worksheets/sheet1.xml': _sheet,
          'xl/worksheets/_rels/sheet1.xml.rels': _sheetRels,
          'xl/drawings/drawing1.xml': _drawing,
          'xl/drawings/_rels/drawing1.xml.rels': _drawingRels,
          'xl/charts/chart1.xml': _chart,
          'xl/media/image1.png': _transparentPng,
        }),
      );

      expect(document.sheets, hasLength(1));
      final sheet = document.sheets.single;
      expect(sheet.name, '数据看板');
      expect(sheet.cells.singleWhere((cell) => cell.column == 0).value, '项目');
      expect(sheet.merges, hasLength(1));
      expect(sheet.objects.whereType<SpreadsheetImage>(), hasLength(1));
      final chart = sheet.objects.whereType<SpreadsheetChart>().single.chart;
      expect(chart.title, '完成情况');
      expect(chart.series.single.values, [3, 7]);
    });

    test('keeps presentation coordinates, styled text, image and chart', () {
      final document = CloudOfficeDocumentParser.parsePresentation(
        _zip({
          'ppt/presentation.xml': _presentation,
          'ppt/_rels/presentation.xml.rels': _presentationRels,
          'ppt/slides/slide1.xml': _slide,
          'ppt/slides/_rels/slide1.xml.rels': _slideRels,
          'ppt/charts/chart1.xml': _chart,
          'ppt/media/image1.png': _transparentPng,
        }),
      );

      expect(document.slides, hasLength(1));
      final slide = document.slides.single;
      expect(slide.elements.whereType<PresentationText>(), hasLength(1));
      expect(
        slide.elements
            .whereType<PresentationText>()
            .single
            .runs
            .map((run) => run.text)
            .join(),
        contains('季度总结'),
      );
      expect(slide.elements.whereType<PresentationImage>(), hasLength(1));
      expect(slide.elements.whereType<PresentationChart>(), hasLength(1));
    });
  });
}

Uint8List _zip(Map<String, Object> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = entry.value is Uint8List
        ? entry.value as Uint8List
        : Uint8List.fromList(utf8.encode(entry.value as String));
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

final _transparentPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

const _workbookXml = '''
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
 <sheets><sheet name="数据看板" sheetId="1" r:id="rId1"/></sheets>
</workbook>''';

const _workbookRels = '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Id="rId1" Target="worksheets/sheet1.xml"/>
</Relationships>''';

const _sharedStrings = '''
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
 <si><t>项目</t></si><si><t>进度</t></si>
</sst>''';

const _styles = '''
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
 <fonts count="1"><font><b/><sz val="12"/><color rgb="FF112233"/></font></fonts>
 <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFEE88"/></patternFill></fill></fills>
 <cellXfs count="2"><xf fontId="0" fillId="0"/><xf fontId="0" fillId="1"><alignment horizontal="center" wrapText="1"/></xf></cellXfs>
</styleSheet>''';

const _sheet = '''
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
 <cols><col min="1" max="2" width="15"/></cols>
 <sheetData><row r="1" ht="25"><c r="A1" t="s" s="1"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row></sheetData>
 <mergeCells><mergeCell ref="A1:A2"/></mergeCells><drawing r:id="rId1"/>
</worksheet>''';

const _sheetRels = '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Id="rId1" Target="../drawings/drawing1.xml"/>
</Relationships>''';

const _drawing = '''
<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
 xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">
 <xdr:twoCellAnchor><xdr:from><xdr:col>2</xdr:col><xdr:row>1</xdr:row></xdr:from><xdr:to><xdr:col>5</xdr:col><xdr:row>7</xdr:row></xdr:to><xdr:pic><xdr:blipFill><a:blip r:embed="rIdImg"/></xdr:blipFill></xdr:pic></xdr:twoCellAnchor>
 <xdr:twoCellAnchor><xdr:from><xdr:col>2</xdr:col><xdr:row>8</xdr:row></xdr:from><xdr:to><xdr:col>7</xdr:col><xdr:row>18</xdr:row></xdr:to><xdr:graphicFrame><a:graphic><a:graphicData><c:chart r:id="rIdChart"/></a:graphicData></a:graphic></xdr:graphicFrame></xdr:twoCellAnchor>
</xdr:wsDr>''';

const _drawingRels = '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Id="rIdImg" Target="../media/image1.png"/><Relationship Id="rIdChart" Target="../charts/chart1.xml"/>
</Relationships>''';

const _chart = '''
<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">
 <c:chart><c:title><c:tx><c:rich><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:r><a:t>完成情况</a:t></a:r></a:p></c:rich></c:tx></c:title>
 <c:plotArea><c:barChart><c:barDir val="col"/><c:ser><c:tx><c:v>数量</c:v></c:tx><c:cat><c:strRef><c:strCache><c:pt idx="0"><c:v>一月</c:v></c:pt><c:pt idx="1"><c:v>二月</c:v></c:pt></c:strCache></c:strRef></c:cat><c:val><c:numRef><c:numCache><c:pt idx="0"><c:v>3</c:v></c:pt><c:pt idx="1"><c:v>7</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser></c:barChart></c:plotArea></c:chart>
</c:chartSpace>''';

const _presentation = '''
<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
 <p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/>
</p:presentation>''';

const _presentationRels = '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Target="slides/slide1.xml"/></Relationships>''';

const _slide = '''
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">
 <p:cSld><p:spTree>
  <p:sp><p:spPr><a:xfrm><a:off x="500000" y="400000"/><a:ext cx="5000000" cy="1200000"/></a:xfrm></p:spPr><p:txBody><a:bodyPr/><a:p><a:r><a:rPr sz="3200" b="1"><a:solidFill><a:srgbClr val="336699"/></a:solidFill></a:rPr><a:t>季度总结</a:t></a:r></a:p></p:txBody></p:sp>
  <p:pic><p:blipFill><a:blip r:embed="rIdImg"/></p:blipFill><p:spPr><a:xfrm><a:off x="600000" y="1800000"/><a:ext cx="3000000" cy="2500000"/></a:xfrm></p:spPr></p:pic>
  <p:graphicFrame><p:xfrm><a:off x="4500000" y="1700000"/><a:ext cx="6500000" cy="3800000"/></p:xfrm><a:graphic><a:graphicData><c:chart r:id="rIdChart"/></a:graphicData></a:graphic></p:graphicFrame>
 </p:spTree></p:cSld>
</p:sld>''';

const _slideRels = '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdImg" Target="../media/image1.png"/><Relationship Id="rIdChart" Target="../charts/chart1.xml"/></Relationships>''';
