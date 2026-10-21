import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:syncnote/core/community_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:workmanager/workmanager.dart' as wm;

import 'package:syncnote/core/router/app_router.dart';
import 'package:syncnote/features/memos/memos_screen.dart';
import 'package:syncnote/firebase_options.dart';
import 'package:syncnote/shared/models/memo_model.dart';
import 'package:syncnote/shared/models/note_model.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/notification_service.dart';
import 'package:syncnote/shared/services/upload_service.dart';

const String syncNoteAlarmSyncTask = 'syncnote.alarmSync';
const String syncNotePeriodicAlarmSyncName = 'syncnote.periodicAlarmSync';
const String syncNoteManualAlarmSyncName = 'syncnote.manualAlarmSync';

@pragma('vm:entry-point')
void syncNoteWorkmanagerDispatcher() {
  wm.Workmanager().executeTask((task, inputData) async {
    return AndroidIntegrationService.runBackgroundAlarmSync(task);
  });
}

class AndroidPermissionSnapshot {
  const AndroidPermissionSnapshot({
    required this.notifications,
    required this.exactAlarms,
    required this.fullScreenIntent,
    required this.notificationPolicy,
    required this.ignoringBatteryOptimizations,
    required this.sdkInt,
  });

  final bool notifications;
  final bool exactAlarms;
  final bool fullScreenIntent;
  final bool notificationPolicy;
  final bool ignoringBatteryOptimizations;
  final int sdkInt;

  bool get allSatisfied =>
      notifications &&
      exactAlarms &&
      fullScreenIntent &&
      notificationPolicy &&
      ignoringBatteryOptimizations;

  factory AndroidPermissionSnapshot.fromMap(Map<Object?, Object?> map) {
    bool readBool(String key) => map[key] == true;
    int readInt(String key) => (map[key] as num?)?.toInt() ?? 0;
    return AndroidPermissionSnapshot(
      notifications: readBool('notifications'),
      exactAlarms: readBool('exactAlarms'),
      fullScreenIntent: readBool('fullScreenIntent'),
      notificationPolicy: readBool('notificationPolicy'),
      ignoringBatteryOptimizations: readBool('batteryOptimizations'),
      sdkInt: readInt('sdkInt'),
    );
  }
}

class AndroidWidgetSnapshot {
  const AndroidWidgetSnapshot({
    required this.recentMemo,
    required this.todayTaskSummary,
    required this.todayTaskCount,
  });

  final String recentMemo;
  final String todayTaskSummary;
  final int todayTaskCount;
}

class AndroidIntegrationService {
  AndroidIntegrationService._();

  static final AndroidIntegrationService instance =
      AndroidIntegrationService._();
  static const MethodChannel _channel = MethodChannel('syncnote/android');

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  bool _channelReady = false;
  bool _workmanagerReady = false;
  StreamSubscription<List<Task>>? _tasksSubscription;
  StreamSubscription<List<Memo>>? _memosSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  List<Task> _latestTasks = const [];
  List<Memo> _latestMemos = const [];
  Map<String, dynamic>? _queuedShare;
  String? _queuedAction;

  Future<void> startForSignedInUser(String uid) async {
    if (!isAndroid) return;
    await _ensureChannel();
    await _configureWorkmanager();
    _startForegroundSubscriptions();
    await processPendingLaunchData();
  }

  Future<void> stopForSignedOutUser() async {
    await _tasksSubscription?.cancel();
    await _memosSubscription?.cancel();
    _tasksSubscription = null;
    _memosSubscription = null;
    _latestTasks = const [];
    _latestMemos = const [];
    if (isAndroid) {
      await _safeInvoke('updateWidgets', buildWidgetPayload([], []));
    }
  }

  Future<void> processPendingLaunchData() async {
    if (!isAndroid) return;
    await _ensureChannel();
    final raw = await _safeInvoke<Map<dynamic, dynamic>>(
      'consumeInitialLaunchData',
    );
    if (raw == null) return;
    final share = raw['share'];
    final action = raw['action'] as String?;
    if (share is Map) {
      await _handleShare(Map<String, dynamic>.from(share));
    }
    if (action != null && action.isNotEmpty) {
      await _handleAction(action);
    }
  }

  Future<AndroidPermissionSnapshot?> getPermissionSnapshot() async {
    if (!isAndroid) return null;
    await _ensureChannel();
    final raw = await _safeInvoke<Map<dynamic, dynamic>>(
      'getAndroidPermissionStatus',
    );
    if (raw == null) return null;
    return AndroidPermissionSnapshot.fromMap(raw);
  }

  Future<void> openPermissionTarget(String target) async {
    if (!isAndroid) return;
    await _safeInvoke<void>('openAndroidSettings', {'target': target});
  }

  Future<void> triggerImmediateAlarmSync({String reason = 'manual'}) async {
    if (!isAndroid) return;
    await wm.Workmanager().registerOneOffTask(
      '$syncNoteManualAlarmSyncName.${DateTime.now().millisecondsSinceEpoch}',
      syncNoteAlarmSyncTask,
      inputData: {'reason': reason},
      constraints: wm.Constraints(networkType: wm.NetworkType.connected),
      existingWorkPolicy: wm.ExistingWorkPolicy.replace,
    );
  }

  void _startForegroundSubscriptions() {
    _tasksSubscription ??= FirestoreService.instance.watchTasks().listen((
      tasks,
    ) {
      _latestTasks = tasks;
      unawaited(_pushWidgetData());
    });
    _memosSubscription ??= FirestoreService.instance.watchMemos().listen((
      memos,
    ) {
      _latestMemos = memos;
      unawaited(_pushWidgetData());
    });
  }

  Future<void> _ensureChannel() async {
    if (_channelReady) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'androidShare':
          await _handleShare(Map<String, dynamic>.from(call.arguments as Map));
          return;
        case 'androidAction':
          await _handleAction(call.arguments?.toString() ?? '');
          return;
      }
    });
    _channelReady = true;
  }

  Future<void> _configureWorkmanager() async {
    if (_workmanagerReady) return;
    await wm.Workmanager().initialize(syncNoteWorkmanagerDispatcher);
    await wm.Workmanager().registerPeriodicTask(
      syncNotePeriodicAlarmSyncName,
      syncNoteAlarmSyncTask,
      frequency: const Duration(minutes: 15),
      flexInterval: const Duration(minutes: 10),
      constraints: wm.Constraints(networkType: wm.NetworkType.connected),
      existingWorkPolicy: wm.ExistingPeriodicWorkPolicy.update,
      inputData: const {'reason': 'periodic'},
    );
    _connectivitySubscription ??= Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      if (results.any((result) => result != ConnectivityResult.none)) {
        unawaited(triggerImmediateAlarmSync(reason: 'network_restored'));
      }
    });
    _workmanagerReady = true;
  }

  Future<void> _pushWidgetData() async {
    if (!isAndroid) return;
    await _safeInvoke(
      'updateWidgets',
      buildWidgetPayload(_latestTasks, _latestMemos),
    );
  }

  Future<void> _handleShare(Map<String, dynamic> payload) async {
    if (FirebaseAuth.instance.currentUser == null) {
      _queuedShare = payload;
      return;
    }
    try {
      final result = await importSharedPayload(payload);
      _showSnackBar(result);
      _navigateForShare(payload);
    } catch (error) {
      _showSnackBar('导入系统分享失败：$error');
    }
  }

  Future<void> _handleAction(String action) async {
    if (action.isEmpty) return;
    if (FirebaseAuth.instance.currentUser == null) {
      _queuedAction = action;
      return;
    }
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) {
      _queuedAction = action;
      return;
    }
    switch (action) {
      case 'quick_memo':
        context.go('/home/memos');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final active = rootNavigatorKey.currentContext;
          if (active != null && active.mounted) {
            unawaited(showAddMemoDialog(active));
          }
        });
        return;
      case 'open_tasks':
        context.go('/home/tasks');
        return;
      case 'open_memos':
        context.go('/home/memos');
        return;
    }
  }

  Future<void> drainQueuedWork() async {
    final share = _queuedShare;
    final action = _queuedAction;
    _queuedShare = null;
    _queuedAction = null;
    if (share != null) await _handleShare(share);
    if (action != null) await _handleAction(action);
  }

  Future<String> importSharedPayload(Map<String, dynamic> payload) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const FormatException('需要先登录');
    }
    final text = (payload['text'] as String?)?.trim() ?? '';
    final uriStrings = List<String>.from(payload['uris'] as List? ?? const []);
    final localImagePaths = uriStrings
        .where((path) => path.isNotEmpty && !path.startsWith('content://'))
        .toList(growable: false);
    if (localImagePaths.isNotEmpty) {
      final uploaded = <String>[];
      for (final path in localImagePaths) {
        final file = File(path);
        if (!await file.exists()) continue;
        final url = await UploadService.instance.uploadFile(file, 'notes');
        if (url != null) uploaded.add(url);
      }
      if (uploaded.isEmpty) {
        throw const FormatException('没有可导入的图片文件');
      }
      await FirestoreService.instance.addNote(
        Note(
          id: const Uuid().v4(),
          title: text.isEmpty ? '系统分享图片' : _titleFromText(text),
          content: text.isEmpty ? '来自 Android 系统分享的图片。' : text,
          images: uploaded,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          userId: user.uid,
        ),
      );
      return '已把分享图片保存为笔记';
    }

    if (text.isEmpty) {
      throw const FormatException('没有可导入的分享内容');
    }
    if (isLikelyUrl(text)) {
      await FirestoreService.instance.addNote(
        Note(
          id: const Uuid().v4(),
          title: _titleFromUrl(text),
          content: text,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          userId: user.uid,
        ),
      );
      return '已把分享链接保存为笔记';
    }
    await FirestoreService.instance.addMemo(
      Memo(
        id: const Uuid().v4(),
        content: text,
        source: MemoSource.shared,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        userId: user.uid,
      ),
    );
    return '已把分享文字保存为备忘录';
  }

  void _navigateForShare(Map<String, dynamic> payload) {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final text = (payload['text'] as String?)?.trim() ?? '';
    final hasImage = (payload['uris'] as List? ?? const []).isNotEmpty;
    context.go(hasImage || isLikelyUrl(text) ? '/home/notes' : '/home/memos');
  }

  void _showSnackBar(String message) {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  static Map<String, Object?> buildWidgetPayload(
    List<Task> tasks,
    List<Memo> memos,
  ) {
    final snapshot = buildWidgetSnapshot(tasks, memos);
    return {
      'recentMemo': snapshot.recentMemo,
      'todayTasks': snapshot.todayTaskSummary,
      'todayTaskCount': snapshot.todayTaskCount,
    };
  }

  @visibleForTesting
  static AndroidWidgetSnapshot buildWidgetSnapshot(
    List<Task> tasks,
    List<Memo> memos,
  ) {
    final recentMemo = memos.isEmpty
        ? '暂无备忘录'
        : _compactText(memos.first.content, 80);
    final now = DateTime.now();
    final todayTasks = tasks
        .where((task) {
          final due = task.dueDate;
          return due != null &&
              _isSameDay(due, now) &&
              !task.isDeleted &&
              !task.isArchived &&
              task.status != TaskStatus.done;
        })
        .toList(growable: false);
    final taskSummary = todayTasks.isEmpty
        ? '今天暂无待办'
        : todayTasks.take(3).map((task) => '• ${task.title}').join('\n');
    return AndroidWidgetSnapshot(
      recentMemo: recentMemo,
      todayTaskSummary: taskSummary,
      todayTaskCount: todayTasks.length,
    );
  }

  @visibleForTesting
  static bool isLikelyUrl(String value) {
    final text = value.trim();
    final uri = Uri.tryParse(text);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static String _titleFromUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri?.host.isNotEmpty ?? false) return '分享链接：${uri!.host}';
    return '分享链接';
  }

  static String _titleFromText(String value) => _compactText(value, 28);

  static String _compactText(String value, int maxLength) {
    final oneLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= maxLength) return oneLine;
    return '${oneLine.substring(0, maxLength)}…';
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static Future<bool> runBackgroundAlarmSync(String reason) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await CommunityConfig.load();
      if (!CommunityConfig.configured) return true;
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      if (isAndroid) {
        FirebaseFirestore.instance.settings = const Settings(
          persistenceEnabled: false,
        );
      }
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('Background alarm sync skipped: no signed-in user');
        return true;
      }
      await NotificationService.instance.initialize(
        requestAndroidPermissions: false,
      );
      final tasks = await FirestoreService.instance.getTasksOnce();
      await NotificationService.instance.syncTaskAlarms(tasks);
      debugPrint('Background alarm sync completed: $reason');
      return true;
    } catch (error) {
      debugPrint('Background alarm sync failed: $error');
      return false;
    }
  }

  Future<T?> _safeInvoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } catch (error) {
      debugPrint('Android channel $method failed: $error');
      return null;
    }
  }
}
