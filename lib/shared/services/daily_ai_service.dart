import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/shared/models/ai_assistant_model.dart';
import 'package:syncnote/shared/services/ai_assistant_service.dart';
import 'package:uuid/uuid.dart';

enum DailyAiWindow { morning, evening }

/// A lightweight process-wide signal used when the desktop window becomes
/// visible again. Flutter does not emit a resumed lifecycle event when a
/// Windows tray icon merely restores a hidden window, so the home shell needs
/// an explicit wake-up signal to re-check the current daily card.
class DailyAiWakeSignal {
  DailyAiWakeSignal._();

  static final DailyAiWakeSignal instance = DailyAiWakeSignal._();

  final StreamController<void> _controller = StreamController<void>.broadcast(
    sync: true,
  );

  Stream<void> get stream => _controller.stream;

  void requestCheck() => _controller.add(null);
}

class DailyAiClock {
  const DailyAiClock._();

  static DailyAiWindow windowAt(DateTime local) =>
      local.hour >= 7 && local.hour < 23
      ? DailyAiWindow.morning
      : DailyAiWindow.evening;

  static DateTime logicalDayAt(DateTime local) {
    final day = DateTime(local.year, local.month, local.day);
    return local.hour < 7 ? day.subtract(const Duration(days: 1)) : day;
  }

  static String dayKey(DateTime local) {
    final day = logicalDayAt(local);
    return '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
  }

  static DateTime nextBoundary(DateTime local) {
    final day = DateTime(local.year, local.month, local.day);
    if (local.hour < 7) return day.add(const Duration(hours: 7));
    if (local.hour < 23) return day.add(const Duration(hours: 23));
    return day.add(const Duration(days: 1, hours: 7));
  }
}

class DailyAiPresentationState {
  const DailyAiPresentationState._();

  // Version 2 changes presentation from an eager permanent claim to a
  // short-lived reservation that is only confirmed after the sheet is on
  // screen. Bumping the version also repairs any current-day state consumed by
  // the previous eager-claim implementation.
  static const int currentVersion = 2;

  static String presentedField(DailyAiWindow window) =>
      '${window.name}Presented';

  static String presentationLeaseOwnerField(DailyAiWindow window) =>
      '${window.name}PresentationLeaseOwner';

  static String presentationLeaseExpiresField(DailyAiWindow window) =>
      '${window.name}PresentationLeaseExpiresAt';

  static String generationLeaseOwnerField(DailyAiWindow window) =>
      '${window.name}LeaseOwner';

  static String generationLeaseExpiresField(DailyAiWindow window) =>
      '${window.name}LeaseExpiresAt';

  static bool shouldClaim(
    Map<String, dynamic> state, {
    required DailyAiWindow window,
    required String dayKey,
  }) {
    if (state['presentationVersion'] != currentVersion) return true;
    if (state['logicalDay'] != dayKey) return true;
    return state[presentedField(window)] != true;
  }

  static bool hasActiveReservation(
    Map<String, dynamic> state, {
    required DailyAiWindow window,
    required String dayKey,
    required DateTime now,
  }) {
    if (state['presentationVersion'] != currentVersion ||
        state['logicalDay'] != dayKey) {
      return false;
    }
    final owner = '${state[presentationLeaseOwnerField(window)] ?? ''}'.trim();
    final expires = (state[presentationLeaseExpiresField(window)] as Timestamp?)
        ?.toDate();
    return owner.isNotEmpty && expires != null && expires.isAfter(now.toUtc());
  }
}

class DailyAiReportResult {
  const DailyAiReportResult({
    required this.window,
    required this.logicalDay,
    required this.content,
    required this.generatedNow,
  });

  final DailyAiWindow window;
  final DateTime logicalDay;
  final String content;
  final bool generatedNow;
}

class DailyAiPresentationClaim {
  const DailyAiPresentationClaim({
    required this.window,
    required this.logicalDay,
    required this.dayKey,
    required this.leaseOwner,
  });

  final DailyAiWindow window;
  final DateTime logicalDay;
  final String dayKey;
  final String leaseOwner;
}

class DailyAiService {
  DailyAiService._();

  static final DailyAiService instance = DailyAiService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String get _uid {
    final user = _auth.currentUser;
    if (user == null) throw StateError('请先登录');
    return user.uid;
  }

  DocumentReference<Map<String, dynamic>> get _userRef =>
      _db.collection(AppConfig.usersCollection).doc(_uid);

  DocumentReference<Map<String, dynamic>> get _stateRef =>
      _userRef.collection('daily_ai_state').doc('current');

  DocumentReference<Map<String, dynamic>> get _reportRef =>
      _userRef.collection('daily_ai_reports').doc('current');

  DocumentReference<Map<String, dynamic>> get _settingsRef =>
      _userRef.collection('ai_settings').doc('current');

  Future<Map<String, bool>> getAutoSettings() async {
    final doc = await _settingsRef.get();
    return {
      'morning': doc.data()?['autoMorningEnabled'] as bool? ?? true,
      'evening': doc.data()?['autoEveningEnabled'] as bool? ?? true,
    };
  }

  Future<void> setAutoEnabled({
    required DailyAiWindow window,
    required bool enabled,
  }) => _settingsRef.set({
    window == DailyAiWindow.morning
            ? 'autoMorningEnabled'
            : 'autoEveningEnabled':
        enabled,
  }, SetOptions(merge: true));

  Stream<Map<String, bool>> watchAutoSettings() => _settingsRef.snapshots().map(
    (doc) => {
      'morning': doc.data()?['autoMorningEnabled'] as bool? ?? true,
      'evening': doc.data()?['autoEveningEnabled'] as bool? ?? true,
    },
  );

  /// Atomically reserves the automatic card presentation for the active
  /// logical day/window. The reservation is short-lived and is not the final
  /// "presented" state: callers must confirm it after the sheet is actually on
  /// screen, or release it when presentation fails.
  Future<DailyAiPresentationClaim?> claimAutomaticPresentation({
    DateTime? now,
    DailyAiWindow? forceWindow,
  }) async {
    final clock = (now ?? DateTime.now()).toLocal();
    final window = forceWindow ?? DailyAiClock.windowAt(clock);
    final logicalDay = DailyAiClock.logicalDayAt(clock);
    final dayKey = DailyAiClock.dayKey(clock);
    final settings = await getAutoSettings();
    final enabled =
        settings[window == DailyAiWindow.morning ? 'morning' : 'evening']!;
    if (!enabled) return null;

    final leaseOwner = const Uuid().v4();

    final claimed = await _db.runTransaction((transaction) async {
      final stateSnapshot = await transaction.get(_stateRef);
      final reportSnapshot = await transaction.get(_reportRef);
      final state = stateSnapshot.data() ?? const <String, dynamic>{};
      final isNewDay = state['logicalDay'] != dayKey;
      final needsPresentationReset =
          isNewDay ||
          state['presentationVersion'] !=
              DailyAiPresentationState.currentVersion;
      if (!DailyAiPresentationState.shouldClaim(
            state,
            window: window,
            dayKey: dayKey,
          ) ||
          DailyAiPresentationState.hasActiveReservation(
            state,
            window: window,
            dayKey: dayKey,
            now: clock,
          )) {
        return false;
      }

      final reservationOwnerField =
          DailyAiPresentationState.presentationLeaseOwnerField(window);
      final reservationExpiresField =
          DailyAiPresentationState.presentationLeaseExpiresField(window);
      transaction.set(_stateRef, {
        if (isNewDay) ...{
          'logicalDay': dayKey,
          'morningStatus': 'idle',
          'eveningStatus': 'idle',
        },
        if (needsPresentationReset) ...{
          'morningPresented': false,
          'eveningPresented': false,
          'morningPresentedAt': FieldValue.delete(),
          'eveningPresentedAt': FieldValue.delete(),
          DailyAiPresentationState.presentationLeaseOwnerField(
            DailyAiWindow.morning,
          ): FieldValue.delete(),
          DailyAiPresentationState.presentationLeaseExpiresField(
            DailyAiWindow.morning,
          ): FieldValue.delete(),
          DailyAiPresentationState.presentationLeaseOwnerField(
            DailyAiWindow.evening,
          ): FieldValue.delete(),
          DailyAiPresentationState.presentationLeaseExpiresField(
            DailyAiWindow.evening,
          ): FieldValue.delete(),
        },
        'presentationVersion': DailyAiPresentationState.currentVersion,
        reservationOwnerField: leaseOwner,
        reservationExpiresField: Timestamp.fromDate(
          clock.toUtc().add(const Duration(minutes: 2)),
        ),
        'updatedAt': Timestamp.now(),
      }, SetOptions(merge: true));

      if (reportSnapshot.data()?['logicalDay'] != dayKey) {
        transaction.set(_reportRef, {
          'logicalDay': dayKey,
          'morningContent': '',
          'eveningContent': '',
          'updatedAt': Timestamp.now(),
        });
      }
      return true;
    });

    if (!claimed) return null;
    return DailyAiPresentationClaim(
      window: window,
      logicalDay: logicalDay,
      dayKey: dayKey,
      leaseOwner: leaseOwner,
    );
  }

  /// Finalizes a reservation only after the report sheet has been pushed onto
  /// the navigator. This prevents a transient startup/UI failure from consuming
  /// the only presentation for the day.
  Future<bool> confirmAutomaticPresentation(DailyAiPresentationClaim claim) =>
      _db.runTransaction((transaction) async {
        final snapshot = await transaction.get(_stateRef);
        final data = snapshot.data();
        final ownerField = DailyAiPresentationState.presentationLeaseOwnerField(
          claim.window,
        );
        final expiresField =
            DailyAiPresentationState.presentationLeaseExpiresField(
              claim.window,
            );
        if (data?['logicalDay'] != claim.dayKey ||
            data?['presentationVersion'] !=
                DailyAiPresentationState.currentVersion ||
            data?[ownerField] != claim.leaseOwner) {
          return false;
        }
        transaction.update(_stateRef, {
          DailyAiPresentationState.presentedField(claim.window): true,
          '${claim.window.name}PresentedAt': Timestamp.now(),
          ownerField: FieldValue.delete(),
          expiresField: FieldValue.delete(),
          'updatedAt': Timestamp.now(),
        });
        return true;
      });

  /// Releases an unconfirmed reservation so a later foreground/wake check can
  /// retry during the same 07:00/23:00 window.
  Future<void> releaseAutomaticPresentation(DailyAiPresentationClaim claim) =>
      _db.runTransaction((transaction) async {
        final snapshot = await transaction.get(_stateRef);
        final data = snapshot.data();
        final ownerField = DailyAiPresentationState.presentationLeaseOwnerField(
          claim.window,
        );
        if (data?['logicalDay'] != claim.dayKey ||
            data?[ownerField] != claim.leaseOwner) {
          return;
        }
        transaction.update(_stateRef, {
          ownerField: FieldValue.delete(),
          DailyAiPresentationState.presentationLeaseExpiresField(claim.window):
              FieldValue.delete(),
          'updatedAt': Timestamp.now(),
        });
      });

  Future<DailyAiReportResult?> checkAndGenerate({
    DateTime? now,
    bool automatic = true,
    DailyAiWindow? forceWindow,
  }) async {
    final clock = (now ?? DateTime.now()).toLocal();
    final window = forceWindow ?? DailyAiClock.windowAt(clock);
    final logicalDay = DailyAiClock.logicalDayAt(clock);
    final dayKey = DailyAiClock.dayKey(clock);
    // Reading and showing an already-generated report costs nothing. Budget
    // checks therefore belong only to the generation path, never to card
    // presentation or cached-report retrieval.
    final existing = await _readCompleted(window, dayKey);
    if (existing != null) return existing;

    if (automatic) {
      final settings = await getAutoSettings();
      final enabled =
          settings[window == DailyAiWindow.morning ? 'morning' : 'evening']!;
      if (!enabled) return null;
      if (!await AiAssistantService.instance.isAutomaticBudgetAvailable()) {
        return null;
      }
    }

    final leaseOwner = const Uuid().v4();
    final acquired = await _acquireLease(
      window: window,
      dayKey: dayKey,
      leaseOwner: leaseOwner,
      now: clock,
    );
    if (!acquired) return _readCompleted(window, dayKey);

    try {
      final start = window == DailyAiWindow.morning
          ? logicalDay.subtract(const Duration(days: 3))
          : logicalDay;
      final end = logicalDay.add(
        const Duration(hours: 23, minutes: 59, seconds: 59),
      );
      final plan = AiRetrievalPlan(
        from: start,
        to: end,
        sources: const {'tasks', 'diary'},
        statuses: window == DailyAiWindow.evening
            ? const {'done', 'active'}
            : const {'active'},
        concepts: const [],
        includeColdArchive: false,
        maxItems: 20,
        reason: window == DailyAiWindow.morning
            ? '晨报读取今日任务和最近三天日记'
            : '晚间复盘读取逻辑日任务和日记',
      );
      final context = await AiAssistantService.instance.retrievePersonalContext(
        plan,
      );
      final generated = await AiAssistantService.instance.generateDailyReport(
        type: window.name,
        logicalDay: logicalDay,
        contextItems: context.items,
      );
      await _completeLease(
        window: window,
        dayKey: dayKey,
        leaseOwner: leaseOwner,
        content: generated.content,
        usage: generated.usage,
      );
      return DailyAiReportResult(
        window: window,
        logicalDay: logicalDay,
        content: generated.content,
        generatedNow: true,
      );
    } catch (error) {
      await _failLease(
        window: window,
        dayKey: dayKey,
        leaseOwner: leaseOwner,
        error: '$error',
      );
      rethrow;
    }
  }

  Future<DailyAiReportResult?> _readCompleted(
    DailyAiWindow window,
    String dayKey,
  ) async {
    final report = await _reportRef.get();
    final data = report.data();
    if (data == null || data['logicalDay'] != dayKey) return null;
    final content = '${data['${window.name}Content'] ?? ''}'.trim();
    if (content.isEmpty) return null;
    final parts = dayKey.split('-').map(int.parse).toList();
    return DailyAiReportResult(
      window: window,
      logicalDay: DateTime(parts[0], parts[1], parts[2]),
      content: content,
      generatedNow: false,
    );
  }

  Future<bool> _acquireLease({
    required DailyAiWindow window,
    required String dayKey,
    required String leaseOwner,
    required DateTime now,
  }) => _db.runTransaction((transaction) async {
    final snapshot = await transaction.get(_stateRef);
    final reportSnapshot = await transaction.get(_reportRef);
    final data = snapshot.data() ?? const <String, dynamic>{};
    final isNewDay = data['logicalDay'] != dayKey;
    final status = isNewDay
        ? 'idle'
        : '${data['${window.name}Status'] ?? 'idle'}';
    final ownerField = DailyAiPresentationState.generationLeaseOwnerField(
      window,
    );
    final expiresField = DailyAiPresentationState.generationLeaseExpiresField(
      window,
    );
    final expires = isNewDay
        ? null
        : (data[expiresField] as Timestamp?)?.toDate();
    final reportData = reportSnapshot.data();
    final completedContent = reportData?['logicalDay'] == dayKey
        ? '${reportData?['${window.name}Content'] ?? ''}'.trim()
        : '';
    if (completedContent.isNotEmpty) return false;
    // A stale "completed" flag without report content must not block
    // regeneration; the report document is the source of truth.
    if (status == 'generating' &&
        expires != null &&
        expires.isAfter(now.toUtc())) {
      return false;
    }
    final reset = isNewDay
        ? <String, dynamic>{
            'logicalDay': dayKey,
            'morningStatus': 'idle',
            'eveningStatus': 'idle',
            'morningPresented': false,
            'eveningPresented': false,
            'presentationVersion': DailyAiPresentationState.currentVersion,
          }
        : <String, dynamic>{};
    transaction.set(_stateRef, {
      ...reset,
      '${window.name}Status': 'generating',
      ownerField: leaseOwner,
      expiresField: Timestamp.fromDate(
        now.toUtc().add(const Duration(minutes: 2)),
      ),
      'updatedAt': Timestamp.now(),
    }, SetOptions(merge: true));
    if (isNewDay) {
      transaction.set(_reportRef, {
        'logicalDay': dayKey,
        'morningContent': '',
        'eveningContent': '',
        'updatedAt': Timestamp.now(),
      });
    }
    return true;
  });

  Future<void> _completeLease({
    required DailyAiWindow window,
    required String dayKey,
    required String leaseOwner,
    required String content,
    required AiUsageRecord usage,
  }) => _db.runTransaction((transaction) async {
    final state = await transaction.get(_stateRef);
    final data = state.data();
    final ownerField = DailyAiPresentationState.generationLeaseOwnerField(
      window,
    );
    final expiresField = DailyAiPresentationState.generationLeaseExpiresField(
      window,
    );
    if (data?['logicalDay'] != dayKey || data?[ownerField] != leaseOwner) {
      return;
    }
    transaction.set(_reportRef, {
      'logicalDay': dayKey,
      '${window.name}Content': content,
      '${window.name}Usage': usage.toJson(),
      '${window.name}GeneratedAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    }, SetOptions(merge: true));
    transaction.update(_stateRef, {
      '${window.name}Status': 'completed',
      ownerField: FieldValue.delete(),
      expiresField: FieldValue.delete(),
      'updatedAt': Timestamp.now(),
    });
  });

  Future<void> _failLease({
    required DailyAiWindow window,
    required String dayKey,
    required String leaseOwner,
    required String error,
  }) => _db.runTransaction((transaction) async {
    final state = await transaction.get(_stateRef);
    final data = state.data();
    final ownerField = DailyAiPresentationState.generationLeaseOwnerField(
      window,
    );
    final expiresField = DailyAiPresentationState.generationLeaseExpiresField(
      window,
    );
    if (data?['logicalDay'] != dayKey || data?[ownerField] != leaseOwner) {
      return;
    }
    transaction.update(_stateRef, {
      '${window.name}Status': 'failed',
      '${window.name}Error': error.length > 500
          ? error.substring(0, 500)
          : error,
      ownerField: FieldValue.delete(),
      expiresField: FieldValue.delete(),
      'updatedAt': Timestamp.now(),
    });
  });
}
