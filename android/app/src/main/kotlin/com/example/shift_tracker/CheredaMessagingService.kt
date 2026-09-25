package com.example.shift_tracker

import android.Manifest
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import androidx.annotation.RequiresPermission
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class CheredaMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        try { NotificationState.saveToken(applicationContext, token) } catch (_: Exception) { }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // Production sends data-only messages. Never trust remote titles or bodies.
        if (message.notification != null) return
        val data = message.data
        val id = NotificationState.uuid(data["notification_id"]) ?: return
        val binding = NotificationState.uuid(data["binding_id"]) ?: return
        val kind = data["kind"] ?: return
        try {
            synchronized(NotificationState.lock) {
                if (!NotificationState.accepts(this, binding, kind)) return
                showNotification(id, binding, kind)
            }
        } catch (_: Exception) {
            // Revoked permission, unavailable OS service, or bad local storage:
            // inbox delivery remains intact; never fall back to exposing payloads.
        }
    }

    @RequiresPermission(Manifest.permission.POST_NOTIFICATIONS)
    private fun showNotification(id: String, binding: String, kind: String) {
        NotificationState.createChannels(this)
        val intent = Intent(this, MainActivity::class.java).apply {
            action = NotificationBridge.tapAction
            data = Uri.parse("chereda-notification://$binding/$id")
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("notification_id", id)
            putExtra("binding_id", binding)
        }
        val tap = PendingIntent.getActivity(this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val body = when (kind) {
            "hours_closed" -> "Изменён статус дня. Проверьте учтённые часы в приложении."
            "request_decision" -> "Получен ответ на запрос часов."
            "schedule_changed" -> "Ваш график изменился. Посмотрите актуальную смену."
            "shift_reminder" -> "Проверьте предстоящую смену в приложении."
            "request_created" -> "Есть новый запрос часов, ожидающий решения."
            "unfilled_days" -> "В учёте рабочего времени есть дни, требующие внимания."
            "delivery_failed" -> "Не удалось отправить табель. Проверьте отправку в приложении."
            else -> return
        }
        val publicVersion = NotificationCompat.Builder(this, NotificationState.channelId(kind))
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Череда")
            .setContentText("Новое уведомление")
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        val notification = NotificationCompat.Builder(this, NotificationState.channelId(kind))
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(NotificationState.labels[kind])
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .build()
        // One stable tag per event, including FCM retries: no duplicate cards.
        NotificationManagerCompat.from(this).notify(NotificationState.tag(kind, id), 0, notification)
    }
}
