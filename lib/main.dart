import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'package:system_tray/system_tray.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/providers/auth_provider.dart';
import 'core/providers/theme_provider.dart';
import 'core/community_config.dart';
import 'features/settings/community_setup_screen.dart';
import 'features/memos/memos_screen.dart';
import 'features/exploration/services/stock_agent_runtime.dart';
import 'firebase_options.dart';
import 'shared/services/daily_ai_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = SystemProxyHttpOverrides();

  await CommunityConfig.load();
  if (!CommunityConfig.configured) {
    _showCommunitySetup();
    return;
  }
  try {
    await _startConfiguredApp();
  } catch (_) {
    CommunityConfig.loadError = '服务初始化失败，请核对当前平台的 Firebase 配置和网络。';
    _showCommunitySetup();
  }
}

void _showCommunitySetup() => runApp(
  MaterialApp(
    title: 'SyncNote Community',
    theme: AppTheme.lightTheme,
    home: CommunitySetupScreen(onConfigured: _startConfiguredApp),
  ),
);

Future<void> _startConfiguredApp() async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Cloud-first storage on both clients. Windows must not open a damaged
  // persistent LevelDB cache while completing Google sign-in.
  if (!kIsWeb && (Platform.isAndroid || Platform.isWindows)) {
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
    );
  }

  // Initialize desktop services if running on Windows
  await initDesktopServices();
  StockAgentRuntime.instance.startScheduler();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
      ],
      child: const SyncNoteApp(),
    ),
  );
}

Future<void> initDesktopServices() async {
  if (kIsWeb) return;
  if (Platform.isWindows) {
    try {
      // 1. Initialize Window Manager
      await windowManager.ensureInitialized();
      await windowManager.setPreventClose(true);

      // 2. Initialize Hotkey Manager
      await hotKeyManager.unregisterAll();

      // 3. Initialize System Tray
      final SystemTray systemTray = SystemTray();
      final Menu menu = Menu();

      await systemTray.initSystemTray(
        title: "SyncNote Community",
        iconPath: File.fromUri(
          File(
            Platform.resolvedExecutable,
          ).parent.uri.resolve('data/flutter_assets/assets/icons/app_icon.ico'),
        ).path,
      );

      await menu.buildFrom([
        MenuItemLabel(
          label: '显示主窗口',
          onClicked: (menuItem) async {
            await _showMainWindow();
          },
        ),
        MenuItemLabel(
          label: '快速新建备忘录',
          onClicked: (menuItem) async {
            await _openQuickMemoFromTray();
          },
        ),
        MenuItemLabel(
          label: '隐藏主窗口',
          onClicked: (menuItem) async {
            await windowManager.hide();
          },
        ),
        MenuSeparator(),
        MenuItemLabel(
          label: '退出',
          onClicked: (menuItem) async {
            exit(0);
          },
        ),
      ]);

      await systemTray.setContextMenu(menu);

      systemTray.registerSystemTrayEventHandler((eventName) {
        if (eventName == kSystemTrayEventClick) {
          _showMainWindow();
        } else if (eventName == kSystemTrayEventDoubleClick) {
          _showMainWindow();
        } else if (eventName == kSystemTrayEventRightClick) {
          systemTray.popUpContextMenu();
        }
      });

      // 4. Register Global Hotkey (Ctrl + Alt + S) to toggle visibility
      final hotKey = HotKey(
        key: PhysicalKeyboardKey.keyS,
        modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
        scope: HotKeyScope.system,
      );

      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (hk) async {
          final isVisible = await windowManager.isVisible();
          if (isVisible) {
            await windowManager.hide();
          } else {
            await _showMainWindow();
          }
        },
      );
    } catch (e) {
      debugPrint('Desktop initialization failed: $e');
    }
  }
}

Future<void> _showMainWindow() async {
  if (await windowManager.isMinimized()) {
    await windowManager.restore();
  }
  await windowManager.show();
  await windowManager.focus();
  DailyAiWakeSignal.instance.requestCheck();
}

Future<void> _openQuickMemoFromTray() async {
  await _showMainWindow();
  final context = rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;

  final authProvider = context.read<AuthProvider>();
  if (!authProvider.isAuthenticated) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('请先登录后再新建备忘录')));
    return;
  }

  context.go('/home/memos');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final activeContext = rootNavigatorKey.currentContext;
    if (activeContext != null && activeContext.mounted) {
      showAddMemoDialog(activeContext);
    }
  });
}

class SyncNoteApp extends StatefulWidget {
  const SyncNoteApp({super.key});

  @override
  State<SyncNoteApp> createState() => _SyncNoteAppState();
}

class _SyncNoteAppState extends State<SyncNoteApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isWindows) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (rootNavigatorKey.currentContext != null) {
      final option = await showDialog<int>(
        context: rootNavigatorKey.currentContext!,
        barrierDismissible: true,
        builder: (context) => AlertDialog(
          title: const Text('关闭选项'),
          content: const Text('选择如何处理当前窗口：'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(1),
              child: const Text('最小化到系统托盘'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(2),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('彻底关闭'),
            ),
          ],
        ),
      );

      if (option == 1) {
        await windowManager.hide();
      } else if (option == 2) {
        await windowManager.setPreventClose(false);
        await windowManager.close();
        exit(0);
      }
    } else {
      await windowManager.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final authProvider = context.watch<AuthProvider>();

    // Router is recreated when authProvider changes so redirects stay reactive
    final router = createRouter(authProvider);

    return MaterialApp.router(
      title: 'SyncNote',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeProvider.themeMode,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', '')],
      routerConfig: router,
    );
  }
}

class SystemProxyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      return HttpClient.findProxyFromEnvironment(uri);
    };
    return client;
  }
}
