import 'community_config.dart';

/// Public builds contain no shared credentials. Each user configures services.
class AppConfig {
  AppConfig._();

  // ── App Info ──────────────────────────────────────────
  static const String appName = 'SyncNote Community';
  static const String appVersion = '0.1.0';

  // ── Gemini AI (Fallback for Audio Transcription) ─────
  static String get geminiApiKey => CommunityConfig.string('ai.geminiApiKey');
  // Keep the verified audio model until the newer Flash endpoint is reliable.
  static const String geminiModel = 'gemini-2.5-flash';

  // ── DeepSeek AI ───────────────────────────────────────
  static String get deepseekApiKey =>
      CommunityConfig.string('ai.deepseekApiKey');
  static const String deepseekModel = 'deepseek-flash';
  static const String deepseekBaseUrl =
      'https://api.deepseek.com/chat/completions';

  // ── Firebase ──────────────────────────────────────────
  static String get firebaseProjectId =>
      CommunityConfig.string('firebase.projectId');

  // ── Firestore Collections ─────────────────────────────
  static const String usersCollection = 'users';
  static const String tasksCollection = 'tasks';
  static const String notesCollection = 'notes';
  static const String diaryCollection = 'diary';
  static const String memosCollection = 'memos';
  static const String cloudFilesCollection = 'cloud_files';
  static const String explorationStateCollection = 'exploration_state';
  static const String literatureLibraryCollection = 'literature_library';
  static const String stockWatchlistCollection = 'stock_watchlist';
  static const String stockFiltersCollection = 'stock_filters';
  static const String stockReportsCollection = 'stock_reports';
  static const String stockQuantReportsCollection = 'stock_quant_reports';
  static const String stockPortfolioCollection = 'stock_portfolio';
  static const String stockPlansCollection = 'stock_plans';
  static const String stockOrderDraftsCollection = 'stock_order_drafts';
  static const String stockMonitorCollection = 'stock_monitor';
  static const String stockAgentExperimentsCollection =
      'stock_agent_experiments';
  static const String searchIndexCollection = 'search_index';
  static const String migrationsCollection = 'schema_migrations';
  static const String archiveIndexCollection = 'archive_index';
  static const String settingsDocument = 'user_prefs';

  // ── Notification IDs ──────────────────────────────────
  static const int taskReminderNotifId = 1000;
  static const int diaryReminderNotifId = 2000;
  static const int dailyDigestNotifId = 3000;

  // ── AI Request Limits ─────────────────────────────────
  // Conservative daily limit to stay within free tier
  static const int maxDailyAiRequests = 450;

  // ── Recycle Bin ───────────────────────────────────────
  static const int recycleBinRetentionDays = 30;

  // ── Version History ───────────────────────────────────
  static const int maxVersionsPerNote = 5;
}
