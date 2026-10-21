/// Turns stored note text into a compact, single-flow preview for list cards.
///
/// Line breaks and repeated whitespace are useful in the editor, but they can
/// consume most of a list card before the reader sees meaningful content.
/// The full source text is never changed; this only prepares the display copy.
String compactListPreviewText(String value) {
  return value.replaceAll(RegExp(r'\s+'), ' ').trim();
}
