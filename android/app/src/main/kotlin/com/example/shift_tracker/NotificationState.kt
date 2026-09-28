package com.example.shift_tracker

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import java.io.File
import java.util.UUID

/** Contains only device identifiers and local delivery switches, never inbox content. */
internal object NotificationState {
    val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var tokenLoading = false
    @Volatile var onTokenChanged: ((String) -> Unit)? = null

    val labels = linkedMapOf(
        "hours_closed" to "Часы и закрытие дня",
        "request_decision" to "Ответы на запросы часов",
        "schedule_changed" to "Изменения графика",
        "shift_reminder" to "Напоминания о смене",
        "request_created" to "Новые запросы часов",
        "unfilled_days" to "Незаполненные дни",
        "delivery_failed" to "Ошибки отправки табеля",
    )

    fun uuid(value: String?): String? = value?.takeIf {
        it.matches(Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"))
    }?.lowercase()

    fun prefs(context: Context): SharedPreferences = synchronized(lock) {
        val prefs = context.getSharedPreferences("chereda_notifications", Context.MODE_PRIVATE)
        // Android backup must not clone an installation/binding onto another phone.
        // noBackupFilesDir is deliberately excluded from Android's backup transport.
        val marker = File(context.noBackupFilesDir, "chereda-notification-installation")
        val installation = if (marker.isFile) uuid(marker.readText().trim()) else null
        val current = installation ?: UUID.randomUUID().toString().also { marker.writeText(it) }
        if (prefs.getString("installation_id", null) != current) {
            check(prefs.edit().clear().putString("installation_id", current).commit())
        }
        prefs
    }

    fun configured(context: Context): Boolean = try {
        FirebaseApp.getApps(context).any { it.name == FirebaseApp.DEFAULT_APP_NAME } ||
            FirebaseApp.initializeApp(context) != null
    } catch (_: Exception) { false }

    fun permission(context: Context): String {
        val allowed = NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED)
        if (allowed) return "granted"
        return if (Build.VERSION.SDK_INT >= 33 &&
            !prefs(context).getBoolean("permission_asked", false)) "not_requested" else "denied"
    }

    fun status(context: Context): Map<String, Any?> {
        val preferences = prefs(context)
        val configured = configured(context)
        val permission = permission(context)
        if (configured) {
            createChannels(context)
            if (permission == "granted") refreshToken(context)
        }
        return mapOf(
            "supported" to true,
            "configured" to configured,
            "permission" to permission,
            "installation_id" to preferences.getString("installation_id", null),
            "token" to if (configured) preferences.getString("token", null) else null,
        )
    }

    fun refreshToken(context: Context) {
        synchronized(lock) {
            if (tokenLoading || !configured(context)) return
            tokenLoading = true
        }
        try {
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                synchronized(lock) { tokenLoading = false }
                if (task.isSuccessful) task.result?.let { saveToken(context, it) }
            }
        } catch (_: Exception) {
            synchronized(lock) { tokenLoading = false }
        }
    }

    fun saveToken(context: Context, token: String) {
        if (token.isBlank() || token.length > 4096) return
        val changed = synchronized(lock) {
            val preferences = prefs(context)
            if (preferences.getString("token", null) == token) false else {
                preferences.edit().putString("token", token).commit()
                true
            }
        }
        if (changed) mainHandler.post { onTokenChanged?.invoke(token) }
    }

    fun configure(context: Context, binding: String, enabled: Boolean, kinds: Map<*, *>) =
        synchronized(lock) {
            val preferences = prefs(context)
            val previous = preferences.getString("binding_id", null)
            val wasEnabled = preferences.getBoolean("enabled", false)
            val editor = preferences.edit().putString("binding_id", binding).putBoolean("enabled", enabled)
            for (kind in labels.keys) editor.putBoolean("kind_$kind", kinds[kind] == true)
            check(editor.commit())
            if (previous != binding || (wasEnabled && !enabled)) cancelAll(context)
            else for (kind in labels.keys) if (kinds[kind] != true) cancelKind(context, kind)
        }

    fun clear(context: Context) = synchronized(lock) {
        val preferences = prefs(context)
        val editor = preferences.edit().remove("binding_id").putBoolean("enabled", false)
        for (kind in labels.keys) editor.remove("kind_$kind")
        check(editor.commit())
        cancelAll(context)
    }

    fun accepts(context: Context, binding: String, kind: String): Boolean = synchronized(lock) {
        val preferences = prefs(context)
        labels.containsKey(kind) && preferences.getBoolean("enabled", false) &&
            preferences.getString("binding_id", null) == binding &&
            preferences.getBoolean("kind_$kind", false) && permission(context) == "granted"
    }

    fun currentBinding(context: Context): String? = prefs(context).getString("binding_id", null)

    fun channelId(kind: String) = "chereda_$kind"
    fun tag(kind: String, id: String) = "chereda:$kind:$id"

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        for ((kind, label) in labels) {
            manager.createNotificationChannel(NotificationChannel(
                channelId(kind), label, NotificationManager.IMPORTANCE_DEFAULT,
            ).apply { description = "Уведомления приложения «Череда»" })
        }
    }

    private fun cancelKind(context: Context, kind: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.activeNotifications.filter { it.tag?.startsWith("chereda:$kind:") == true }
            .forEach { manager.cancel(it.tag, it.id) }
    }

    private fun cancelAll(context: Context) {
        // These are all notifications created by this application, never other apps.
        NotificationManagerCompat.from(context).cancelAll()
    }
}
