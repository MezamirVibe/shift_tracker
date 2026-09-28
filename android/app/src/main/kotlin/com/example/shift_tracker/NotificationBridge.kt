package com.example.shift_tracker

import android.Manifest
import android.content.Intent
import android.os.Build
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Small platform bridge; the Flutter service owns auth, preferences and API registration. */
internal class NotificationBridge(
    private val activity: FlutterActivity,
    engine: FlutterEngine,
) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "chereda/notifications")
    private var pendingTap: Map<String, String>? = null
    private var disposed = false
    private val tokenListener: (String) -> Unit = { token ->
        if (!disposed) channel.invokeMethod("tokenChanged", token)
    }

    init {
        NotificationState.onTokenChanged = tokenListener
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> result.success(NotificationState.status(activity))
                    "requestPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            NotificationState.configured(activity) &&
                            NotificationState.permission(activity) != "granted") {
                            NotificationState.prefs(activity).edit()
                                .putBoolean("permission_asked", true).commit()
                            ActivityCompat.requestPermissions(activity,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS), permissionRequest)
                        }
                        // Never keep a platform call pending behind a system dialog.
                        // The permission result / app resume triggers a fresh status.
                        result.success(NotificationState.status(activity))
                    }
                    "configure" -> {
                        val binding = NotificationState.uuid(call.argument<String>("binding_id"))
                        val enabled = call.argument<Boolean>("enabled")
                        val kinds = call.argument<Map<*, *>>("kinds")
                        if (binding == null || enabled == null || kinds == null ||
                            kinds.keys.any { it !in NotificationState.labels.keys } ||
                            kinds.values.any { it !is Boolean }) {
                            result.error("invalid_preferences", "Некорректные настройки уведомлений.", null)
                        } else {
                            if (NotificationState.currentBinding(activity) != binding) pendingTap = null
                            NotificationState.configure(activity, binding, enabled, kinds)
                            result.success(null)
                        }
                    }
                    "clear" -> {
                        pendingTap = null
                        NotificationState.clear(activity)
                        result.success(null)
                    }
                    "takePendingTap" -> {
                        val tap = pendingTap?.takeIf {
                            NotificationState.currentBinding(activity) == it["binding_id"]
                        }
                        pendingTap = null
                        result.success(tap)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                // Never expose tokens, intent contents or Firebase internals in errors.
                result.error("notifications_unavailable", "Не удалось обновить настройки уведомлений на устройстве.", null)
            }
        }
    }

    fun acceptIntent(intent: Intent?, notifyFlutter: Boolean) {
        if (intent?.action != tapAction) return
        try {
            val id = NotificationState.uuid(intent.getStringExtra("notification_id")) ?: return
            val binding = NotificationState.uuid(intent.getStringExtra("binding_id")) ?: return
            if (NotificationState.currentBinding(activity) != binding) return
            val tap = mapOf("notification_id" to id, "binding_id" to binding)
            pendingTap = tap
            // Avoid replay after an Activity recreation using its old launch Intent.
            intent.removeExtra("notification_id")
            intent.removeExtra("binding_id")
            if (notifyFlutter && !disposed) {
                channel.invokeMethod("notificationOpened", tap, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (result == true && pendingTap == tap) pendingTap = null
                    }
                    override fun error(code: String, message: String?, details: Any?) = Unit
                    override fun notImplemented() = Unit
                })
            }
        } catch (_: Exception) { /* An invalid external Intent is never trusted. */ }
    }

    fun onPermissionResult(requestCode: Int) {
        if (requestCode != permissionRequest || disposed) return
        // Even an unchanged cached token forces Dart to re-check permission state.
        tokenListener(NotificationState.prefs(activity).getString("token", "") ?: "")
        if (NotificationState.permission(activity) == "granted") NotificationState.refreshToken(activity)
    }

    fun dispose() {
        disposed = true
        if (NotificationState.onTokenChanged === tokenListener) NotificationState.onTokenChanged = null
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val tapAction = "com.example.shift_tracker.OPEN_NOTIFICATION"
        private const val permissionRequest = 18014
    }
}
