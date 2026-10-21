String compactIndexSummary(String text, {int maxCharacters = 180}) {
  final compact = text
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ')
      .replaceAll(RegExp(r'\[[^\]]+\]\([^)]*\)'), ' ')
      .replaceAll(RegExp(r'[#>*_`~\-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (compact.length <= maxCharacters) return compact;
  return '${compact.substring(0, maxCharacters).trimRight()}…';
}

/// Produces a bounded set of lower-case words, Chinese characters and Chinese
/// bigrams.  It is deliberately an index, not a copy of the source body.
List<String> buildSearchTerms(Iterable<String> values, {int maxTerms = 400}) {
  final terms = <String>{};
  void add(String value) {
    final normalized = value.toLowerCase().trim();
    if (normalized.isEmpty || terms.length >= maxTerms) return;
    terms.add(
      normalized.length > 40 ? normalized.substring(0, 40) : normalized,
    );
  }

  for (final value in values) {
    if (terms.length >= maxTerms) break;
    final bounded = value.length > 4000 ? value.substring(0, 4000) : value;
    for (final word in bounded.split(RegExp(r'[^a-zA-Z0-9\u4e00-\u9fff]+'))) {
      if (terms.length >= maxTerms) break;
      if (word.isEmpty) continue;
      final latin = RegExp(r'^[a-zA-Z0-9]+$').hasMatch(word);
      if (latin) {
        add(word);
        continue;
      }
      final chars = word.runes.map(String.fromCharCode).toList();
      for (final char in chars) {
        add(char);
      }
      for (var index = 0; index + 1 < chars.length; index++) {
        add('${chars[index]}${chars[index + 1]}');
      }
    }
  }
  return terms.toList(growable: false);
}

List<String> querySearchTerms(String query) =>
    buildSearchTerms([query], maxTerms: 24);
