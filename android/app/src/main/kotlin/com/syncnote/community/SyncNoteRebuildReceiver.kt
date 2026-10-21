package com.syncnote.community

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class SyncNoteRebuildReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        SyncNoteWidgetStore.recordSystemEvent(context, intent?.action)
        SyncNoteWidgets.updateAll(context)
    }
}
