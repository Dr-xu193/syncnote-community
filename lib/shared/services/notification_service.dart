import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';

import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/core/router/app_router.dart';
import 'package:syncnote/features/diary/diary_screen.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/daily_ai_service.dart';
import 'package:window_manager/window_manager.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _androidNotificationChannelCreated = false;
  bool _androidPermissionsRequested = false;
  String? _pendingPayload;
  String? _visibleTaskDialogId;

  // Windows platform specific notification timers for morning/evening reports
  Timer? _briefingTimer;
  Timer? _reflectionTimer;
  final Map<String, Timer> _taskTimers = {};
  Future<void> _taskSyncChain = Future<void>.value();

  static const AndroidNotificationChannel _taskAlarmChannel =
      AndroidNotificationChannel(
        'task_alarms_sound_v3',
        '任务提醒闹钟',
        description: '用于任务截止时间的强提醒，包含声音、振动和锁屏弹窗',
        importance: Importance.max,
        bypassDnd: true,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('ding'),
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
      );

  String? consumePendingPayload() {
    final p = _pendingPayload;
    _pendingPayload = null;
    return p;
  }

  Future<void> initialize({bool requestAndroidPermissions = true}) async {
    if (_initialized) {
      if (requestAndroidPermissions) {
        await _configureAndroidNotifications(requestPermissions: true);
      }
      return;
    }

    tz.initializeTimeZones();
    tz.setLocalLocation(
      tz.getLocation('Asia/Shanghai'),
    ); // Optional: you can get device locale in production

    // The Windows plugin uses FFI calls for notification query/cancel/schedule.
    // A standalone Flutter EXE has no package identity and these calls can
    // abort the process at the C++ boundary. Windows is deliberately handled
    // by the local timer + foreground task dialog flow below instead.
    if (_isWindows) {
      _initialized = true;
      return;
    }

    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const WindowsInitializationSettings windowsInit =
        WindowsInitializationSettings(
          appName: 'SyncNote Community',
          appUserModelId: 'com.syncnote.community',
          guid: 'E76C3B14-703D-4A5B-82A6-24FEF0206F90',
        );
    // In a real production app we'd configure Darwin for macOS/iOS too.
    const InitializationSettings initSettings = InitializationSettings(
      android: androidInit,
      windows: windowsInit,
    );

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (details) async {
        if (!kIsWeb && Platform.isWindows) {
          await windowManager.show();
          await windowManager.focus();
        }
        final payload = details.payload;
        if (payload != null) {
          if (payload == 'daily_briefing' || payload == 'evening_reflection') {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final context = rootNavigatorKey.currentContext;
              if (context != null) {
                Future.delayed(const Duration(milliseconds: 500), () {
                  final activeContext = rootNavigatorKey.currentContext;
                  if (activeContext != null && activeContext.mounted) {
                    showAiReportSheet(activeContext, initialType: payload);
                  }
                });
              } else {
                _pendingPayload = payload;
              }
            });
          } else if (payload.startsWith('task_')) {
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              final context = rootNavigatorKey.currentContext;
              if (context != null) {
                await showTaskAlarmFromPayload(context, payload);
              } else {
                _pendingPayload = payload;
              }
            });
          }
        }
      },
    );

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails != null && launchDetails.didNotificationLaunchApp) {
      final payload = launchDetails.notificationResponse?.payload;
      if (payload != null) {
        _pendingPayload = payload;
      }
    }

    _initialized = true;
    await _configureAndroidNotifications(
      requestPermissions: requestAndroidPermissions,
    );
  }

  Future<void> _configureAndroidNotifications({
    required bool requestPermissions,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin == null) return;

    if (!_androidNotificationChannelCreated) {
      await androidPlugin.createNotificationChannel(_taskAlarmChannel);
      _androidNotificationChannelCreated = true;
    }

    // Android permission request APIs require an Activity context. Background
    // isolates used by WorkManager do not have one, so they must only
    // create channels and schedule already-authorized alarms.
    if (!requestPermissions || _androidPermissionsRequested) return;

    final notificationsEnabled = await androidPlugin
        .requestNotificationsPermission();
    final exactAlarmsEnabled = await androidPlugin
        .requestExactAlarmsPermission();
    final fullScreenEnabled = await androidPlugin
        .requestFullScreenIntentPermission();
    var notificationPolicyEnabled = await androidPlugin
        .hasNotificationPolicyAccess();
    if (!(notificationPolicyEnabled ?? false)) {
      notificationPolicyEnabled = await androidPlugin
          .requestNotificationPolicyAccess();
    }
    _androidPermissionsRequested = true;
    debugPrint(
      'Notification permissions: notifications=$notificationsEnabled, '
      'exactAlarms=$exactAlarmsEnabled, fullScreen=$fullScreenEnabled, '
      'notificationPolicy=$notificationPolicyEnabled',
    );
  }

  @visibleForTesting
  static int taskNotificationId(String taskId, [DateTime? reminderTime]) {
    // Stable FNV-1a based ID. String.hashCode is not guaranteed to stay the
    // same across processes, which makes cancellation after restart unreliable.
    final source = reminderTime == null
        ? taskId
        : '$taskId|${reminderTime.toUtc().millisecondsSinceEpoch}';
    int hash = 0x811c9dc5;
    for (final codeUnit in source.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x3fffffff;
    }
    return hash + 10000;
  }

  Future<AndroidScheduleMode> _resolveAndroidScheduleMode({
    bool useAlarmClock = false,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      return AndroidScheduleMode.exactAllowWhileIdle;
    }
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final canScheduleExact =
        await androidPlugin?.canScheduleExactNotifications() ?? false;
    if (canScheduleExact) {
      return useAlarmClock
          ? AndroidScheduleMode.alarmClock
          : AndroidScheduleMode.exactAllowWhileIdle;
    }
    debugPrint(
      'Exact alarm access is disabled; Android may delay this notification.',
    );
    return AndroidScheduleMode.inexactAllowWhileIdle;
  }

  Future<void> showTaskAlarmFromPayload(
    BuildContext context,
    String payload,
  ) async {
    if (!payload.startsWith('task_')) return;

    final task = await FirestoreService.instance.getTask(payload.substring(5));
    if (task != null && context.mounted) {
      await showTaskAlarmDialog(context, task);
    }
  }

  Future<void> showTaskAlarmDialog(BuildContext context, Task task) async {
    if (_visibleTaskDialogId == task.id || !context.mounted) return;
    _visibleTaskDialogId = task.id;

    try {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.alarm, color: Colors.red, size: 32),
              SizedBox(width: 8),
              Text(
                '任务提醒',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
            ],
          ),
          content: Text(
            task.description.isEmpty
                ? '该任务现在需要进行：\n\n${task.title}'
                : '该任务现在需要进行：\n\n${task.title}\n\n${task.description}',
            style: const TextStyle(fontSize: 18),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('我知道了', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      );
    } finally {
      if (_visibleTaskDialogId == task.id) {
        _visibleTaskDialogId = null;
      }
    }
  }

  /// Reconciles all local task alarms with the latest Firestore task snapshot.
  ///
  /// Every signed-in device runs this method, so a task created or changed on
  /// another device is scheduled locally as soon as Firestore delivers it.
  Future<void> syncTaskAlarms(List<Task> tasks) {
    final snapshot = List<Task>.from(tasks);
    final operation = _taskSyncChain.then((_) async {
      if (!_initialized) await initialize();

      if (_usesNativeNotificationPlugin) {
        final pending = await _plugin.pendingNotificationRequests();
        for (final request in pending) {
          if (request.payload?.startsWith('task_') ?? false) {
            await _plugin.cancel(id: request.id);
          }
        }
      }

      for (final timer in _taskTimers.values) {
        timer.cancel();
      }
      _taskTimers.clear();

      final now = DateTime.now();
      final activeTasks = snapshot.where((task) {
        return !task.isDeleted &&
            !task.isArchived &&
            task.status != TaskStatus.done &&
            task.effectiveReminderTimes.any((time) => time.isAfter(now));
      });

      for (final task in activeTasks) {
        final scheduled = await scheduleTaskAlarm(task);
        if (!scheduled) {
          debugPrint(
            'Task alarm was not scheduled: ${task.id} at ${task.dueDate}',
          );
        }
      }
    });

    _taskSyncChain = operation.catchError((Object error, StackTrace stack) {
      debugPrint('Task alarm sync failed: $error');
    });
    return operation;
  }

  Future<void> clearTaskAlarms() {
    if (!_initialized) {
      for (final timer in _taskTimers.values) {
        timer.cancel();
      }
      _taskTimers.clear();
      return Future<void>.value();
    }
    return syncTaskAlarms(const <Task>[]);
  }

  Future<bool> scheduleTaskAlarm(Task task) async {
    if (!_initialized) await initialize();
    if (task.isDeleted || task.isArchived || task.status == TaskStatus.done) {
      return false;
    }

    final reminderTimes = task.effectiveReminderTimes
        .where((time) => time.isAfter(DateTime.now()))
        .toList(growable: false);
    if (reminderTimes.isEmpty) return false;

    if (_usesNativeNotificationPlugin) {
      await _plugin.cancel(id: taskNotificationId(task.id));
      // Remove schedules created by older versions that used String.hashCode.
      await _plugin.cancel(id: task.id.hashCode);
    }
    for (final entry
        in _taskTimers.entries
            .where((entry) => entry.key.startsWith('${task.id}|'))
            .toList()) {
      entry.value.cancel();
      _taskTimers.remove(entry.key);
    }

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'task_alarms_sound_v3',
          '任务提醒闹钟',
          channelDescription: '用于任务截止时间的强提醒，包含声音、振动和锁屏弹窗',
          channelBypassDnd: true,
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('ding'),
          enableVibration: true,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          audioAttributesUsage: AudioAttributesUsage.alarm,
        );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );

    var scheduledAny = false;
    for (final reminderTime in reminderTimes) {
      final scheduleTime = tz.TZDateTime.from(reminderTime, tz.local);
      final id = taskNotificationId(task.id, reminderTime);
      try {
        if (_usesNativeNotificationPlugin) {
          final androidScheduleMode = await _resolveAndroidScheduleMode(
            useAlarmClock: true,
          );
          await _plugin.zonedSchedule(
            id: id,
            title: '任务提醒: ${task.title}',
            body: task.description.isEmpty ? '您有一个任务需要现在完成！' : task.description,
            scheduledDate: scheduleTime,
            notificationDetails: details,
            androidScheduleMode: androidScheduleMode,
            payload: 'task_${task.id}',
          );
        }
        scheduledAny = true;
        debugPrint(
          'Scheduled task alarm ${task.id} for $scheduleTime '
          'using ${_isWindows ? 'the Windows local timer' : 'the native notification scheduler'}',
        );

        if (!kIsWeb && Platform.isWindows) {
          final delay = scheduleTime.difference(DateTime.now());
          if (!delay.isNegative) {
            final timerKey =
                '${task.id}|${reminderTime.toUtc().millisecondsSinceEpoch}';
            _taskTimers[timerKey] = Timer(delay, () async {
              _taskTimers.remove(timerKey);
              await windowManager.show();
              await windowManager.focus();

              SystemSound.play(SystemSoundType.alert);
              Future.delayed(const Duration(seconds: 1), () {
                SystemSound.play(SystemSoundType.alert);
              });
              Future.delayed(const Duration(seconds: 2), () {
                SystemSound.play(SystemSoundType.alert);
              });

              final context = rootNavigatorKey.currentContext;
              if (context != null && context.mounted) {
                await showTaskAlarmDialog(context, task);
              }
            });
          }
        }
      } catch (e) {
        debugPrint('Schedule alarm failed for $reminderTime: $e');
      }
    }
    return scheduledAny;
  }

  Future<void> cancelTaskAlarm(Task task) async {
    if (!_initialized) await initialize();
    for (final entry
        in _taskTimers.entries
            .where((entry) => entry.key.startsWith('${task.id}|'))
            .toList()) {
      entry.value.cancel();
      _taskTimers.remove(entry.key);
    }
    if (_usesNativeNotificationPlugin) {
      await _plugin.cancel(id: taskNotificationId(task.id));
      for (final reminderTime in task.effectiveReminderTimes) {
        await _plugin.cancel(id: taskNotificationId(task.id, reminderTime));
      }
      await _plugin.cancel(id: task.id.hashCode);
    }
  }

  /// Schedules the daily morning AI briefing notification at 7:00 AM.
  Future<void> scheduleDailyBriefingAlarm() async {
    if (!_initialized) await initialize();

    const id = 8888; // Unified ID for daily briefing alarm

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'daily_briefing_v1',
          'AI 每日晨报提醒',
          channelDescription: '每天早上 7:00 为你生成并推送今日简报，点击可查看精美总结卡片',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          fullScreenIntent: true,
        );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );

    if (_usesNativeNotificationPlugin) {
      try {
        final androidScheduleMode = await _resolveAndroidScheduleMode();
        await _plugin.zonedSchedule(
          id: id,
          title: 'SyncNote 智能晨报已准备就绪',
          body: '点击查看今日待办与心灵分析简报',
          scheduledDate: _nextInstanceOfSevenAM(),
          notificationDetails: details,
          androidScheduleMode: androidScheduleMode,
          matchDateTimeComponents: DateTimeComponents.time,
          payload: 'daily_briefing',
        );
        debugPrint(
          'Successfully scheduled daily briefing alarm at 7:00 AM on Android.',
        );
      } catch (e) {
        debugPrint('Schedule daily briefing alarm failed: $e');
      }
    }

    // Windows local Timer scheduling at 7:00 AM
    if (!kIsWeb && Platform.isWindows) {
      _briefingTimer?.cancel();
      final targetTime = _nextInstanceOfSevenAM();
      final delay = targetTime.difference(DateTime.now());
      if (!delay.isNegative) {
        _briefingTimer = Timer(delay, () async {
          DailyAiWakeSignal.instance.requestCheck();
          // Self-reschedule for next day
          await scheduleDailyBriefingAlarm();
        });
        debugPrint(
          'Successfully scheduled daily briefing Timer at 7:00 AM on Windows.',
        );
      }
    }
  }

  /// Schedules the daily evening AI reflection notification at 23:00 PM (11:00 PM).
  Future<void> scheduleDailyEveningReflectionAlarm() async {
    if (!_initialized) await initialize();

    const id = 9999; // Unified ID for daily evening reflection alarm

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'daily_evening_reflection_v1',
          'AI 每日暮省提醒',
          channelDescription: '每天晚上 23:00 为你生成并推送今日暮省，点击可查看精美总结卡片',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          fullScreenIntent: true,
        );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );

    if (_usesNativeNotificationPlugin) {
      try {
        final androidScheduleMode = await _resolveAndroidScheduleMode();
        await _plugin.zonedSchedule(
          id: id,
          title: 'SyncNote 智能暮省已准备就绪',
          body: '点击查看今日待办总结与心灵暮省',
          scheduledDate: _nextInstanceOfElevenPM(),
          notificationDetails: details,
          androidScheduleMode: androidScheduleMode,
          matchDateTimeComponents: DateTimeComponents.time,
          payload: 'evening_reflection',
        );
        debugPrint(
          'Successfully scheduled daily evening reflection alarm at 23:00 PM on Android.',
        );
      } catch (e) {
        debugPrint('Schedule daily evening reflection alarm failed: $e');
      }
    }

    // Windows local Timer scheduling at 23:00 PM (11:00 PM)
    if (!kIsWeb && Platform.isWindows) {
      _reflectionTimer?.cancel();
      final targetTime = _nextInstanceOfElevenPM();
      final delay = targetTime.difference(DateTime.now());
      if (!delay.isNegative) {
        _reflectionTimer = Timer(delay, () async {
          DailyAiWakeSignal.instance.requestCheck();
          // Self-reschedule for next day
          await scheduleDailyEveningReflectionAlarm();
        });
        debugPrint(
          'Successfully scheduled daily evening reflection Timer at 23:00 PM on Windows.',
        );
      }
    }
  }

  tz.TZDateTime _nextInstanceOfSevenAM() {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      7,
      0,
    );
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }

  tz.TZDateTime _nextInstanceOfElevenPM() {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      23,
      0,
    );
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }

  static bool get _isWindows => !kIsWeb && Platform.isWindows;

  static bool get _usesNativeNotificationPlugin =>
      !kIsWeb && !Platform.isWindows;
}
