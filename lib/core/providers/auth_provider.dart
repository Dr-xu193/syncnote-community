import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart' as g_mobile;
import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart'
    as g_desktop;
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/services/android_integration_service.dart';
import 'package:syncnote/shared/services/firestore_service.dart';
import 'package:syncnote/shared/services/notification_service.dart';
import 'package:syncnote/core/community_config.dart';

/// Authentication state provider.
///
/// Listens to [FirebaseAuth.authStateChanges] and exposes the current [User],
/// loading state, and any error messages. Also provides [signInWithGoogle] and
/// [signOut] methods.
class AuthProvider extends ChangeNotifier {
  AuthProvider() {
    _init();
  }

  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Desktop sign in client
  // The clientSecret is provided for Desktop OAuth to work.
  g_desktop.GoogleSignIn? _desktopClient;
  g_desktop.GoogleSignIn get _desktopSignIn =>
      _desktopClient ??= g_desktop.GoogleSignIn(
        params: g_desktop.GoogleSignInParams(
          clientId: CommunityConfig.string('google.desktopClientId'),
          clientSecret: CommunityConfig.string('google.desktopClientSecret'),
          scopes: ['email', 'profile'],
          redirectPort: 8000,
        ),
      );

  User? _currentUser;
  bool _isLoading = true;
  String? _errorMessage;
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<List<Task>>? _tasksSubscription;

  /// The currently authenticated Firebase [User], or `null` if signed out.
  User? get currentUser => _currentUser;

  /// `true` while an auth operation (sign-in / sign-out / initial load) is
  /// in progress.
  bool get isLoading => _isLoading;

  /// The last error message produced by a sign-in or sign-out attempt.
  String? get errorMessage => _errorMessage;

  /// Whether there is an authenticated user.
  bool get isAuthenticated => _currentUser != null;

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  void _init() {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      g_mobile.GoogleSignIn.instance.initialize(
        serverClientId: CommunityConfig.string('google.serverClientId'),
      );
    }

    _authSubscription = _auth.authStateChanges().listen((User? user) async {
      await _tasksSubscription?.cancel();
      _tasksSubscription = null;

      _currentUser = user;
      _isLoading = false;
      notifyListeners();
      if (user != null) {
        await NotificationService.instance.initialize();
        await AndroidIntegrationService.instance.startForSignedInUser(user.uid);
        try {
          await FirestoreService.instance.migrateLegacyTaskFields();
        } catch (error) {
          debugPrint('Legacy task migration deferred: $error');
        }
        _tasksSubscription = FirestoreService.instance.watchTasks().listen(
          (tasks) {
            NotificationService.instance.syncTaskAlarms(tasks);
          },
          onError: (Object error, StackTrace stack) {
            debugPrint('Task alarm Firestore sync failed: $error');
          },
        );
        // Trigger auto-purge of trash documents older than 30 days
        FirestoreService.instance.purgeExpiredTrash();
        // Trigger scheduling of the daily morning briefing alarm
        NotificationService.instance.scheduleDailyBriefingAlarm();
        // Trigger scheduling of the daily evening reflection alarm
        NotificationService.instance.scheduleDailyEveningReflectionAlarm();
      } else {
        await AndroidIntegrationService.instance.stopForSignedOutUser();
        await NotificationService.instance.clearTaskAlarms();
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _tasksSubscription?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Sign-in with Google
  // ---------------------------------------------------------------------------

  /// Signs the user in with their Google account.
  ///
  /// Returns `true` on success, `false` on failure.
  Future<bool> signInWithGoogle() async {
    _setLoading(true);
    _clearError();

    try {
      OAuthCredential credential;

      if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux) {
        // Clear any stale local cache to ensure the browser always opens for re-authentication
        try {
          await _desktopSignIn.signOut();
        } catch (_) {}

        final credentials = await _desktopSignIn.signIn();
        if (credentials == null) {
          _setLoading(false);
          return false;
        }
        credential = GoogleAuthProvider.credential(
          accessToken: credentials.accessToken,
          idToken: credentials.idToken,
        );
      } else {
        final googleUser = await g_mobile.GoogleSignIn.instance.authenticate(
          scopeHint: ['email', 'profile'],
        );
        final googleAuth = googleUser.authentication;
        credential = GoogleAuthProvider.credential(
          accessToken: null,
          idToken: googleAuth.idToken,
        );
      }

      await _auth.signInWithCredential(credential);
      _setLoading(false);
      return true;
    } on FirebaseAuthException catch (e) {
      if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux) {
        try {
          await _desktopSignIn.signOut();
        } catch (_) {}
      }
      _setError(_firebaseAuthErrorMessage(e));
      _setLoading(false);
      return false;
    } catch (e) {
      if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux) {
        try {
          await _desktopSignIn.signOut();
        } catch (_) {}
      }
      _setError('登录失败，请重试。\n$e');
      _setLoading(false);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Sign-out
  // ---------------------------------------------------------------------------

  /// Signs the current user out of both Firebase and Google Sign-In.
  Future<void> signOut() async {
    _setLoading(true);
    _clearError();

    try {
      await Future.wait([
        _auth.signOut(),
        if (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)
          _desktopSignIn.signOut()
        else
          g_mobile.GoogleSignIn.instance.signOut(),
      ]);
    } on FirebaseAuthException catch (e) {
      _setError(_firebaseAuthErrorMessage(e));
    } catch (e) {
      _setError('退出登录失败，请重试。');
    } finally {
      _setLoading(false);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();
  }

  void _clearError() {
    _errorMessage = null;
  }

  String _firebaseAuthErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'account-exists-with-different-credential':
        return '该邮箱已关联其他登录方式。';
      case 'invalid-credential':
        return '登录凭证无效，请重试。';
      case 'operation-not-allowed':
        return '该登录方式未启用，请联系管理员。';
      case 'user-disabled':
        return '该账号已被禁用。';
      case 'user-not-found':
        return '未找到该用户。';
      case 'wrong-password':
        return '密码错误。';
      case 'network-request-failed':
        return '网络连接失败，请检查网络后重试。';
      default:
        return e.message ?? '登录失败，请重试。';
    }
  }
}
