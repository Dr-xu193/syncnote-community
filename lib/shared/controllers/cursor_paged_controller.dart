import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:syncnote/shared/services/firestore_service.dart';

typedef PageLoader<T> =
    Future<FirestorePage<T>> Function(
      DocumentSnapshot<Map<String, dynamic>>? cursor,
    );

/// Keeps one live first page and loads older pages only when requested.
/// First-page updates are merged by stable ID, so an edit cannot duplicate an
/// item that is already present in a historical page.
class CursorPagedController<T> extends ChangeNotifier {
  CursorPagedController({required this.idOf});

  final String Function(T item) idOf;
  final List<T> _first = [];
  final List<T> _tail = [];
  StreamSubscription<FirestorePage<T>>? _subscription;
  PageLoader<T>? _loader;
  DocumentSnapshot<Map<String, dynamic>>? _nextCursor;
  bool _hasMore = false;
  bool _ready = false;
  bool _loadingMore = false;
  Object? _error;

  bool get ready => _ready;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  Object? get error => _error;

  List<T> get items {
    final seen = <String>{};
    return <T>[
      ..._first,
      ..._tail,
    ].where((item) => seen.add(idOf(item))).toList(growable: false);
  }

  void start({
    required Stream<FirestorePage<T>> firstPage,
    required PageLoader<T> loadPage,
  }) {
    _loader = loadPage;
    _subscription?.cancel();
    _subscription = firstPage.listen(
      (page) {
        _first
          ..clear()
          ..addAll(page.items);
        if (_tail.isEmpty) {
          _nextCursor = page.cursor;
          _hasMore = page.hasMore;
        }
        _ready = true;
        _error = null;
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
        _ready = true;
        _error = error;
        notifyListeners();
      },
    );
  }

  Future<void> loadMore() async {
    final loader = _loader;
    if (loader == null || !_hasMore || _loadingMore) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final page = await loader(_nextCursor);
      final known = items.map(idOf).toSet();
      _tail.addAll(page.items.where((item) => known.add(idOf(item))));
      _nextCursor = page.cursor;
      _hasMore = page.hasMore;
      _error = null;
    } catch (error) {
      _error = error;
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
