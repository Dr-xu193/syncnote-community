import 'package:flutter_test/flutter_test.dart';
import 'package:syncnote/shared/utils/list_preview_text.dart';

void main() {
  test('list preview collapses line breaks and repeated whitespace', () {
    expect(compactListPreviewText('  第一段\n\n第二段\t  第三段  '), '第一段 第二段 第三段');
  });

  test('list preview does not discard source content', () {
    const source = '第一行\n第二行内容';
    final preview = compactListPreviewText(source);

    expect(preview, '第一行 第二行内容');
    expect(source, '第一行\n第二行内容');
  });
}
