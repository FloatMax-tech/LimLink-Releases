package com.limlink.kit.notify

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import androidx.core.app.NotificationCompat

object TransferNotifications {
    const val CHANNEL_ID = "limlink_transfer"

    fun ensureChannel(context: Context, name: String, description: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            name,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            this.description = description
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    fun build(
        context: Context,
        smallIcon: Int,
        title: String,
        text: String,
        percent: Int?,
        indeterminate: Boolean,
        ongoing: Boolean,
        contentIntent: PendingIntent?,
        actions: List<Action> = emptyList(),
    ): Notification {
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(ongoing)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        if (contentIntent != null) {
            builder.setContentIntent(contentIntent)
        }
        when {
            indeterminate -> builder.setProgress(0, 0, true)
            percent != null -> builder.setProgress(100, percent.coerceIn(0, 100), false)
        }
        actions.forEach { action ->
            builder.addAction(smallIcon, action.label, action.intent)
        }
        return builder.build()
    }

    data class Action(
        val label: String,
        val intent: PendingIntent,
    )
}
