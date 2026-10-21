package com.syncnote.community

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "syncnote/android"
    private var channel: MethodChannel? = null
    private var pendingShare: Map<String, Any?>? = null
    private var pendingAction: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureIntent(intent, notifyFlutter = false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeInitialLaunchData" -> {
                    result.success(
                        mapOf(
                            "share" to pendingShare,
                            "action" to pendingAction,
                        ),
                    )
                    pendingShare = null
                    pendingAction = null
                }

                "updateWidgets" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = call.arguments as? Map<String, Any?>
                    if (args != null) {
                        SyncNoteWidgetStore.save(this, args)
                        SyncNoteWidgets.updateAll(this)
                    }
                    result.success(null)
                }

                "getAndroidPermissionStatus" -> result.success(permissionStatus())

                "openAndroidSettings" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = call.arguments as? Map<String, Any?>
                    openAndroidSettings(args?.get("target")?.toString().orEmpty())
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureIntent(intent, notifyFlutter = true)
    }

    private fun captureIntent(intent: Intent?, notifyFlutter: Boolean) {
        if (intent == null) return
        when (intent.action) {
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                val payload = extractSharePayload(intent)
                if (payload != null) {
                    pendingShare = payload
                    if (notifyFlutter) channel?.invokeMethod("androidShare", payload)
                }
            }

            SyncNoteWidgetActions.ACTION_QUICK_MEMO -> setAction(
                "quick_memo",
                notifyFlutter,
            )

            SyncNoteWidgetActions.ACTION_OPEN_TASKS -> setAction(
                "open_tasks",
                notifyFlutter,
            )

            SyncNoteWidgetActions.ACTION_OPEN_MEMOS -> setAction(
                "open_memos",
                notifyFlutter,
            )
        }
    }

    private fun setAction(action: String, notifyFlutter: Boolean) {
        pendingAction = action
        if (notifyFlutter) channel?.invokeMethod("androidAction", action)
    }

    private fun extractSharePayload(intent: Intent): Map<String, Any?>? {
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            ?: intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val uris = mutableListOf<String>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val streams = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            }
            streams?.forEach { uri ->
                copySharedUriToCache(uri)?.let { uris.add(it) }
            }
        } else {
            val stream = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            stream?.let { copySharedUriToCache(it)?.let(uris::add) }
        }
        if (text.isNullOrBlank() && uris.isEmpty()) return null
        return mapOf(
            "text" to text.orEmpty(),
            "uris" to uris,
            "mimeType" to intent.type.orEmpty(),
        )
    }

    private fun copySharedUriToCache(uri: Uri): String? {
        return try {
            val mimeType = contentResolver.getType(uri)
            val extension = MimeTypeMap.getSingleton()
                .getExtensionFromMimeType(mimeType)
                ?: uri.lastPathSegment?.substringAfterLast('.', "bin")
                ?: "bin"
            val dir = File(cacheDir, "shared")
            if (!dir.exists()) dir.mkdirs()
            val outFile = File(
                dir,
                "share_${System.currentTimeMillis()}_${urisafe(uri.hashCode())}.$extension",
            )
            contentResolver.openInputStream(uri)?.use { input ->
                outFile.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            outFile.absolutePath
        } catch (error: Exception) {
            null
        }
    }

    private fun urisafe(value: Int): String = value.toString().replace("-", "n")

    private fun permissionStatus(): Map<String, Any> {
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val notifications = if (Build.VERSION.SDK_INT >= 33) {
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        val exactAlarms = if (Build.VERSION.SDK_INT >= 31) {
            alarmManager.canScheduleExactAlarms()
        } else {
            true
        }
        val fullScreenIntent = if (Build.VERSION.SDK_INT >= 34) {
            notificationManager.canUseFullScreenIntent()
        } else {
            true
        }
        val battery = powerManager.isIgnoringBatteryOptimizations(packageName)
        return mapOf(
            "notifications" to notifications,
            "exactAlarms" to exactAlarms,
            "fullScreenIntent" to fullScreenIntent,
            "notificationPolicy" to notificationManager.isNotificationPolicyAccessGranted,
            "batteryOptimizations" to battery,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    private fun openAndroidSettings(target: String) {
        val intent = when (target) {
            "notifications" -> {
                if (Build.VERSION.SDK_INT >= 26) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                } else {
                    appDetailsIntent()
                }
            }

            "exactAlarms" -> {
                if (Build.VERSION.SDK_INT >= 31) {
                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                        .setData(Uri.parse("package:$packageName"))
                } else {
                    appDetailsIntent()
                }
            }

            "fullScreenIntent" -> {
                if (Build.VERSION.SDK_INT >= 34) {
                    Intent("android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT")
                        .setData(Uri.parse("package:$packageName"))
                } else {
                    appDetailsIntent()
                }
            }

            "notificationPolicy" -> Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
            "battery" -> Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:$packageName"))

            else -> appDetailsIntent()
        }
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun appDetailsIntent(): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:$packageName"))
}
