package com.syncnote.community

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

object SyncNoteWidgetActions {
    const val ACTION_QUICK_MEMO = "com.syncnote.community.action.QUICK_MEMO"
    const val ACTION_OPEN_TASKS = "com.syncnote.community.action.OPEN_TASKS"
    const val ACTION_OPEN_MEMOS = "com.syncnote.community.action.OPEN_MEMOS"
}

object SyncNoteWidgetStore {
    private const val PREFS = "syncnote_widgets"
    private const val KEY_RECENT_MEMO = "recentMemo"
    private const val KEY_TODAY_TASKS = "todayTasks"
    private const val KEY_TODAY_TASK_COUNT = "todayTaskCount"
    private const val KEY_LAST_SYSTEM_EVENT = "lastSystemEvent"

    fun save(context: Context, data: Map<String, Any?>) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_RECENT_MEMO, data["recentMemo"]?.toString().orEmpty())
            .putString(KEY_TODAY_TASKS, data["todayTasks"]?.toString().orEmpty())
            .putInt(KEY_TODAY_TASK_COUNT, (data["todayTaskCount"] as? Number)?.toInt() ?: 0)
            .apply()
    }

    fun recordSystemEvent(context: Context, action: String?) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_LAST_SYSTEM_EVENT, action.orEmpty())
            .apply()
    }

    fun recentMemo(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_RECENT_MEMO, "打开 SyncNote 后自动显示最近备忘") ?: "打开 SyncNote 后自动显示最近备忘"

    fun todayTasks(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_TODAY_TASKS, "打开 SyncNote 后自动显示今日任务") ?: "打开 SyncNote 后自动显示今日任务"

    fun todayTaskCount(context: Context): Int =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(KEY_TODAY_TASK_COUNT, 0)
}

object SyncNoteWidgets {
    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        updateProvider(context, manager, RecentMemoWidgetProvider::class.java)
        updateProvider(context, manager, TodayTasksWidgetProvider::class.java)
        updateProvider(context, manager, QuickActionWidgetProvider::class.java)
    }

    private fun updateProvider(
        context: Context,
        manager: AppWidgetManager,
        providerClass: Class<out AppWidgetProvider>,
    ) {
        val component = ComponentName(context, providerClass)
        val ids = manager.getAppWidgetIds(component)
        if (ids.isEmpty()) return
        val provider = providerClass.getDeclaredConstructor().newInstance()
        provider.onUpdate(context, manager, ids)
    }

    fun pendingIntent(context: Context, action: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(action)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            context,
            action.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

class RecentMemoWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_recent_memo)
            views.setTextViewText(R.id.widget_memo_content, SyncNoteWidgetStore.recentMemo(context))
            views.setOnClickPendingIntent(
                R.id.widget_root,
                SyncNoteWidgets.pendingIntent(context, SyncNoteWidgetActions.ACTION_OPEN_MEMOS),
            )
            views.setOnClickPendingIntent(
                R.id.widget_quick_add,
                SyncNoteWidgets.pendingIntent(context, SyncNoteWidgetActions.ACTION_QUICK_MEMO),
            )
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}

class TodayTasksWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_today_tasks)
            val count = SyncNoteWidgetStore.todayTaskCount(context)
            views.setTextViewText(R.id.widget_task_count, "今日任务 $count")
            views.setTextViewText(R.id.widget_task_content, SyncNoteWidgetStore.todayTasks(context))
            views.setOnClickPendingIntent(
                R.id.widget_root,
                SyncNoteWidgets.pendingIntent(context, SyncNoteWidgetActions.ACTION_OPEN_TASKS),
            )
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}

class QuickActionWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_quick_action)
            views.setOnClickPendingIntent(
                R.id.widget_quick_memo,
                SyncNoteWidgets.pendingIntent(context, SyncNoteWidgetActions.ACTION_QUICK_MEMO),
            )
            views.setOnClickPendingIntent(
                R.id.widget_open_tasks,
                SyncNoteWidgets.pendingIntent(context, SyncNoteWidgetActions.ACTION_OPEN_TASKS),
            )
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
