import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:syncnote/core/providers/auth_provider.dart';
import 'package:syncnote/features/auth/login_screen.dart';
import 'package:syncnote/features/diary/diary_screen.dart';
import 'package:syncnote/features/memos/memos_screen.dart';
import 'package:syncnote/features/notes/notes_screen.dart';
import 'package:syncnote/features/search/search_screen.dart';
import 'package:syncnote/features/tasks/tasks_screen.dart';
import 'package:syncnote/features/trash/trash_screen.dart';
import 'package:syncnote/shared/widgets/home_shell.dart';

/// Global navigator key for showing dialogs from anywhere (like background alarms)
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Creates and returns the application [GoRouter].
///
/// Pass the [authProvider] so the router can rebuild whenever auth state
/// changes (via [ChangeNotifier.addListener] → [GoRouter.refresh]).
GoRouter createRouter(AuthProvider authProvider) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/login',
    refreshListenable: authProvider,
    redirect: _globalRedirect(authProvider),
    routes: [
      // Login ----------------------------------------------------------------
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),

      GoRoute(
        path: '/home',
        redirect: (_, _) => '/home/memos',
      ),

      // Home shell (stateful shell route for persistent navigation) ----------
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return HomeShell(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home/memos',
                name: 'memos',
                builder: (context, state) => const MemosScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home/tasks',
                name: 'tasks',
                builder: (context, state) => const TasksScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home/notes',
                name: 'notes',
                builder: (context, state) => const NotesScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home/diary',
                name: 'diary',
                builder: (context, state) => const DiaryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home/search',
                name: 'search',
                builder: (context, state) => const SearchScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/trash',
        name: 'trash',
        builder: (context, state) => const TrashScreen(),
      ),
    ],
  );
}

/// Global redirect guard applied to every navigation event.
GoRouterRedirect _globalRedirect(AuthProvider authProvider) {
  return (BuildContext context, GoRouterState state) {
    // If we're still checking auth state on startup, stay on current page (which is /login)
    if (authProvider.isLoading && state.matchedLocation == '/login') return null;

    final isAuthenticated = authProvider.isAuthenticated;
    final isOnLogin = state.matchedLocation == '/login';

    if (!isAuthenticated && !isOnLogin) {
      // Redirect to login for any protected route.
      return '/login';
    }

    if (isAuthenticated && isOnLogin) {
      // Redirect away from login when already signed in.
      return '/home/memos';
    }

    return null; // No redirect needed.
  };
}

/// Convenience extension so [AuthProvider] can be accessed from the router
/// without manually threading it through.
extension RouterContext on BuildContext {
  AuthProvider get authProvider => read<AuthProvider>();
}
