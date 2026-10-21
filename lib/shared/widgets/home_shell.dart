import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:syncnote/core/theme/app_theme.dart';
import 'package:syncnote/features/memos/memos_screen.dart';
import 'package:syncnote/features/tasks/task_editor_screen.dart';
import 'package:syncnote/features/notes/note_editor_screen.dart';
import 'package:syncnote/features/diary/diary_screen.dart';

import 'package:syncnote/shared/services/notification_service.dart';
import 'package:syncnote/shared/services/android_integration_service.dart';
import 'package:syncnote/shared/services/sync_status_service.dart';
import 'package:syncnote/shared/services/daily_ai_service.dart';
import 'package:syncnote/shared/widgets/app_lock_widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Breakpoint (dp) below which the bottom bar is used instead of the rail.
const double _kMobileBreakpoint = 720;

/// The adaptive shell that wraps every home sub-route.
///
/// * On narrow screens ( < 720 dp wide ) → [BottomNavigationBar].
/// * On wider screens → [NavigationRail] on the left side.
class HomeShell extends StatefulWidget {
  const HomeShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<void>? _dailyWakeSubscription;
  Timer? _dailyBoundaryTimer;
  Timer? _dailyRetryTimer;
  bool _checkingDailyAi = false;

  // Tab configuration ---------------------------------------------------------

  static const List<_NavItem> _items = [
    _NavItem(
      label: '备忘录',
      icon: Icons.sticky_note_2_outlined,
      activeIcon: Icons.sticky_note_2_rounded,
      route: '/home/memos',
    ),
    _NavItem(
      label: '任务',
      icon: Icons.check_circle_outline_rounded,
      activeIcon: Icons.check_circle_rounded,
      route: '/home/tasks',
    ),
    _NavItem(
      label: '知识库',
      icon: Icons.auto_stories_outlined,
      activeIcon: Icons.auto_stories_rounded,
      route: '/home/notes',
    ),
    _NavItem(
      label: '日记',
      icon: Icons.menu_book_outlined,
      activeIcon: Icons.menu_book_rounded,
      route: '/home/diary',
    ),
    _NavItem(
      label: '搜索',
      icon: Icons.manage_search_outlined,
      activeIcon: Icons.manage_search_rounded,
      route: '/home/search',
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SyncStatusService.instance.start();
    _initializeConnectivity();
    _dailyWakeSubscription = DailyAiWakeSignal.instance.stream.listen((_) {
      _checkDailyAi();
      _scheduleDailyBoundary();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingNotificationLaunch();
      AndroidIntegrationService.instance.drainQueuedWork();
      _checkDailyAi();
    });
    _scheduleDailyBoundary();
  }

  Future<void> _initializeConnectivity() async {
    final connectivity = Connectivity();
    _refreshNetworkStatus(await connectivity.checkConnectivity());
    _connectivitySubscription = connectivity.onConnectivityChanged.listen(
      _refreshNetworkStatus,
    );
  }

  void _refreshNetworkStatus(List<ConnectivityResult> results) {
    final hasNetworkAdapter =
        results.isNotEmpty &&
        results.any((result) => result != ConnectivityResult.none);
    SyncStatusService.instance.setNetworkOffline(!hasNetworkAdapter);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dailyBoundaryTimer?.cancel();
    _dailyRetryTimer?.cancel();
    _dailyWakeSubscription?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkDailyAi();
      _scheduleDailyBoundary();
    }
  }

  void _scheduleDailyBoundary() {
    _dailyBoundaryTimer?.cancel();
    final now = DateTime.now();
    final delay = DailyAiClock.nextBoundary(now).difference(now);
    _dailyBoundaryTimer = Timer(delay + const Duration(seconds: 1), () {
      _checkDailyAi();
      _scheduleDailyBoundary();
    });
  }

  void _scheduleDailyRetry() {
    if (!mounted || _dailyRetryTimer?.isActive == true) return;
    _dailyRetryTimer = Timer(const Duration(minutes: 1), _checkDailyAi);
  }

  Future<void> _checkDailyAi() async {
    if (_checkingDailyAi || !mounted) return;
    _dailyRetryTimer?.cancel();
    _dailyRetryTimer = null;
    _checkingDailyAi = true;
    DailyAiPresentationClaim? claim;
    var confirmed = false;
    try {
      claim = await DailyAiService.instance.claimAutomaticPresentation();
      if (!mounted || claim == null) return;
      if (!kIsWeb && Platform.isWindows) {
        if (await windowManager.isMinimized()) {
          await windowManager.restore();
        }
        await windowManager.show();
        await windowManager.focus();
      }
      if (!mounted) return;
      final shown = await showAiReportSheet(
        context,
        initialType: claim.window == DailyAiWindow.morning
            ? 'daily_briefing'
            : 'evening_reflection',
        automatic: true,
        onPresented: () async {
          confirmed = await DailyAiService.instance
              .confirmAutomaticPresentation(claim!);
        },
      );
      if (!shown || !confirmed) {
        await DailyAiService.instance.releaseAutomaticPresentation(claim);
        _scheduleDailyRetry();
      }
    } catch (error, stackTrace) {
      debugPrint('Daily AI automatic presentation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (claim != null && !confirmed) {
        try {
          await DailyAiService.instance.releaseAutomaticPresentation(claim);
        } catch (releaseError) {
          debugPrint('Daily AI reservation release failed: $releaseError');
        }
      }
      _scheduleDailyRetry();
    } finally {
      _checkingDailyAi = false;
    }
  }

  void _checkPendingNotificationLaunch() async {
    final payload = NotificationService.instance.consumePendingPayload();
    if (payload == null || !mounted) return;

    if (payload == 'daily_briefing' || payload == 'evening_reflection') {
      showAiReportSheet(context, initialType: payload);
    } else if (payload.startsWith('task_')) {
      await NotificationService.instance.showTaskAlarmFromPayload(
        context,
        payload,
      );
    }
  }

  void _onTap(BuildContext context, int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  // Build ---------------------------------------------------------------------

  void _handleNewItemShortcut(BuildContext context, int currentIndex) {
    switch (currentIndex) {
      case 0: // Memos
        showAddMemoDialog(context);
        break;
      case 1: // Tasks
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const TaskEditorScreen()));
        break;
      case 2: // Notes
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const NoteEditorScreen()));
        break;
      case 3: // Diary
        showDiaryEntrySheet(context, DateTime.now(), null);
        break;
    }
  }

  void _handleSearchShortcut(BuildContext context) {
    widget.navigationShell.goBranch(4); // Search tab index is 4
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = width < _kMobileBreakpoint;
    final currentIndex = widget.navigationShell.currentIndex;

    final content = _SyncStatusOverlay(child: widget.navigationShell);

    final shellWidget = isMobile
        ? _MobileShell(
            items: _items,
            currentIndex: currentIndex,
            onTap: (i) => _onTap(context, i),
            child: content,
          )
        : _DesktopShell(
            items: _items,
            currentIndex: currentIndex,
            onTap: (i) => _onTap(context, i),
            child: content,
          );

    return AppLockGate(
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyN):
              const NewItemIntent(),
          LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyN):
              const NewItemIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyK):
              const SearchIntent(),
          LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyK):
              const SearchIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            NewItemIntent: CallbackAction<NewItemIntent>(
              onInvoke: (intent) =>
                  _handleNewItemShortcut(context, currentIndex),
            ),
            SearchIntent: CallbackAction<SearchIntent>(
              onInvoke: (intent) => _handleSearchShortcut(context),
            ),
          },
          child: Focus(autofocus: true, child: shellWidget),
        ),
      ),
    );
  }
}

class _SyncStatusOverlay extends StatelessWidget {
  const _SyncStatusOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: 8,
          left: 0,
          right: 0,
          child: ValueListenableBuilder<SyncStatusSnapshot>(
            valueListenable: SyncStatusService.instance.status,
            builder: (context, status, _) {
              return IgnorePointer(
                child: SafeArea(
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: status.isVisible
                          ? _SyncStatusChip(status: status)
                          : const SizedBox.shrink(key: ValueKey('online')),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SyncStatusChip extends StatelessWidget {
  const _SyncStatusChip({required this.status});

  final SyncStatusSnapshot status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSyncing = status.level == SyncStatusLevel.syncing;
    final isFailure = status.level == SyncStatusLevel.failure;
    final background = isSyncing
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.errorContainer;
    final foreground = isSyncing
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onErrorContainer;
    final icon = isSyncing
        ? Icons.sync_rounded
        : isFailure
        ? Icons.error_outline_rounded
        : Icons.cloud_off_rounded;

    return Container(
      key: ValueKey(status.level),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 8),
          Text(
            status.message,
            style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile layout
// ---------------------------------------------------------------------------

class _MobileShell extends StatelessWidget {
  const _MobileShell({
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.child,
  });

  final List<_NavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = theme.extension<AppColors>();
    final navBg = appColors?.navBackground ?? theme.colorScheme.surface;
    final primary = theme.colorScheme.primary;
    final unselected = theme.colorScheme.onSurfaceVariant;

    return Scaffold(
      body: child,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: navBg,
          boxShadow: [
            BoxShadow(
              color: (appColors?.cardShadowColor ?? Colors.black).withValues(
                alpha: 0.12,
              ),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: SizedBox(
            height: 64,
            child: Row(
              children: List.generate(items.length, (i) {
                final item = items[i];
                final isSelected = i == currentIndex;
                return Expanded(
                  child: _NavBarItem(
                    item: item,
                    isSelected: isSelected,
                    selectedColor: primary,
                    unselectedColor: unselected,
                    onTap: () => onTap(i),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBarItem extends StatelessWidget {
  const _NavBarItem({
    required this.item,
    required this.isSelected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.onTap,
  });

  final _NavItem item;
  final bool isSelected;
  final Color selectedColor;
  final Color unselectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? selectedColor : unselectedColor;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                isSelected ? item.activeIcon : item.icon,
                key: ValueKey(isSelected),
                color: color,
                size: 24,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
              child: Text(item.label),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Desktop / wide layout
// ---------------------------------------------------------------------------

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.child,
  });

  final List<_NavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = theme.extension<AppColors>();
    final railBg = appColors?.navBackground ?? theme.colorScheme.surface;

    return Scaffold(
      body: Row(
        children: [
          // Rail
          Container(
            width: 80,
            color: railBg,
            child: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  // App logo
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          theme.colorScheme.primary,
                          theme.colorScheme.secondary,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.4,
                          ),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.sync_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Navigation items
                  ...List.generate(items.length, (i) {
                    final item = items[i];
                    final isSelected = i == currentIndex;
                    return _RailItem(
                      item: item,
                      isSelected: isSelected,
                      selectedColor: theme.colorScheme.primary,
                      unselectedColor: theme.colorScheme.onSurfaceVariant,
                      indicatorColor: theme.colorScheme.primary.withValues(
                        alpha: 0.12,
                      ),
                      onTap: () => onTap(i),
                    );
                  }),
                ],
              ),
            ),
          ),
          // Divider
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: appColors?.dividerColor ?? theme.dividerColor,
          ),
          // Content
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.item,
    required this.isSelected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.indicatorColor,
    required this.onTap,
  });

  final _NavItem item;
  final bool isSelected;
  final Color selectedColor;
  final Color unselectedColor;
  final Color indicatorColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? selectedColor : unselectedColor;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Tooltip(
        message: item.label,
        preferBelow: false,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            width: 64,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: isSelected ? indicatorColor : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    isSelected ? item.activeIcon : item.icon,
                    key: ValueKey(isSelected),
                    color: color,
                    size: 22,
                  ),
                ),
                const SizedBox(height: 4),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                  child: Text(
                    item.label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Nav item data class
// ---------------------------------------------------------------------------

class _NavItem {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.route,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final String route;
}

class NewItemIntent extends Intent {
  const NewItemIntent();
}

class SearchIntent extends Intent {
  const SearchIntent();
}
