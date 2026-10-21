import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:syncnote/core/app_config.dart';

enum SyncStatusLevel { online, offline, syncing, failure }

class SyncStatusSnapshot {
  const SyncStatusSnapshot({
    required this.level,
    required this.message,
    required this.updatedAt,
  });

  final SyncStatusLevel level;
  final String message;
  final DateTime updatedAt;

  bool get isVisible => level != SyncStatusLevel.online;

  static SyncStatusSnapshot online() => SyncStatusSnapshot(
    level: SyncStatusLevel.online,
    message: '云端已同步',
    updatedAt: DateTime.now(),
  );
}

class SyncStatusService {
  SyncStatusService._();

  static final SyncStatusService instance = SyncStatusService._();

  final ValueNotifier<SyncStatusSnapshot> status =
      ValueNotifier<SyncStatusSnapshot>(SyncStatusSnapshot.online());

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _metadataSubscription;
  StreamSubscription<User?>? _authSubscription;
  bool _networkOffline = false;
  bool _hasServerConfirmation = false;

  @visibleForTesting
  static SyncStatusLevel classifyFirestoreState({
    required bool networkOffline,
    required bool isFromCache,
    required bool hasPendingWrites,
  }) {
    if (networkOffline || isFromCache) return SyncStatusLevel.offline;
    if (hasPendingWrites) return SyncStatusLevel.syncing;
    return SyncStatusLevel.online;
  }

  void start() {
    _authSubscription ??= FirebaseAuth.instance.authStateChanges().listen((
      user,
    ) {
      _metadataSubscription?.cancel();
      _metadataSubscription = null;
      if (user != null) {
        bindUser(user.uid);
      } else {
        _hasServerConfirmation = false;
        status.value = SyncStatusSnapshot.online();
      }
    });
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) bindUser(uid);
  }

  void dispose() {
    _metadataSubscription?.cancel();
    _authSubscription?.cancel();
    _metadataSubscription = null;
    _authSubscription = null;
  }

  void bindUser(String uid) {
    _metadataSubscription?.cancel();
    _hasServerConfirmation = false;
    if (!_networkOffline) {
      status.value = SyncStatusSnapshot(
        level: SyncStatusLevel.syncing,
        message: '正在确认云端连接...',
        updatedAt: DateTime.now(),
      );
    }
    _metadataSubscription = FirebaseFirestore.instance
        .collection(AppConfig.usersCollection)
        .doc(uid)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snapshot) {
            final metadata = snapshot.metadata;
            final level = classifyFirestoreState(
              networkOffline: _networkOffline,
              isFromCache: metadata.isFromCache,
              hasPendingWrites: metadata.hasPendingWrites,
            );
            _hasServerConfirmation = level != SyncStatusLevel.offline;
            if (level == SyncStatusLevel.offline) {
              status.value = SyncStatusSnapshot(
                level: SyncStatusLevel.offline,
                message: _networkOffline ? '当前无网络连接' : '云端连接尚未确认，当前数据可能不是最新版本',
                updatedAt: DateTime.now(),
              );
            } else if (level == SyncStatusLevel.syncing) {
              status.value = SyncStatusSnapshot(
                level: SyncStatusLevel.syncing,
                message: '正在同步云端数据...',
                updatedAt: DateTime.now(),
              );
            } else if (status.value.level != SyncStatusLevel.syncing) {
              status.value = SyncStatusSnapshot.online();
            } else {
              status.value = SyncStatusSnapshot.online();
            }
          },
          onError: (Object error) {
            _hasServerConfirmation = false;
            reportFailure(error);
          },
        );
  }

  void setNetworkOffline(bool offline) {
    _networkOffline = offline;
    if (offline) {
      _hasServerConfirmation = false;
      status.value = SyncStatusSnapshot(
        level: SyncStatusLevel.offline,
        message: '当前无网络连接',
        updatedAt: DateTime.now(),
      );
    } else if (!_hasServerConfirmation &&
        status.value.level == SyncStatusLevel.offline) {
      status.value = SyncStatusSnapshot(
        level: SyncStatusLevel.syncing,
        message: '网络已连接，正在确认云端连接...',
        updatedAt: DateTime.now(),
      );
    }
  }

  void setSyncing(String message) {
    if (_networkOffline) return;
    status.value = SyncStatusSnapshot(
      level: SyncStatusLevel.syncing,
      message: message,
      updatedAt: DateTime.now(),
    );
  }

  void markOnline() {
    if (!_networkOffline && _hasServerConfirmation) {
      status.value = SyncStatusSnapshot.online();
    }
  }

  void reportFailure(Object error) {
    _hasServerConfirmation = false;
    status.value = SyncStatusSnapshot(
      level: SyncStatusLevel.failure,
      message: '同步失败：$error',
      updatedAt: DateTime.now(),
    );
  }

  Future<T> track<T>(String message, Future<T> Function() action) async {
    setSyncing(message);
    try {
      final result = await action();
      markOnline();
      return result;
    } catch (e) {
      reportFailure(e);
      rethrow;
    }
  }
}
