package com.limlink.app.service

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.text.format.Formatter
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.limlink.app.MainActivity
import com.limlink.app.R
import com.limlink.app.transfer.LanController
import com.limlink.kit.lan.Offer

/** Heads-up consent requests with Accept / Decline actions, shown only while LimLink is in the background. */
object OfferNotifications {
    private const val CHANNEL_ID = "limlink_offers"

    fun ensureChannel(context: Context) {
        val channel = NotificationChannel(CHANNEL_ID, context.getString(R.string.channel_offer_name), NotificationManager.IMPORTANCE_HIGH).apply {
            description = context.getString(R.string.channel_offer_description)
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    fun id(sessionId: String): Int = 2000 + (sessionId.hashCode() and 0x0fffffff)

    @SuppressLint("MissingPermission")
    fun show(context: Context, offer: Offer) {
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return
        val open = PendingIntent.getActivity(context, id(offer.sessionId), Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_transfer)
            .setContentTitle(context.getString(R.string.notif_offer_title, offer.senderName))
            .setContentText(context.getString(R.string.notif_offer_body, offer.fileName, Formatter.formatShortFileSize(context, offer.size)))
            .setStyle(NotificationCompat.BigTextStyle().bigText(context.getString(R.string.notif_offer_body, offer.fileName, Formatter.formatShortFileSize(context, offer.size))))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setTimeoutAfter(120_000)
            .setAutoCancel(true)
            .setContentIntent(open)
            .addAction(R.drawable.ic_stat_transfer, context.getString(R.string.lan_accept), action(context, offer.sessionId, OfferActionReceiver.ACTION_ACCEPT))
            .addAction(R.drawable.ic_stat_transfer, context.getString(R.string.lan_reject), action(context, offer.sessionId, OfferActionReceiver.ACTION_REJECT))
            .build()
        runCatching { manager.notify(id(offer.sessionId), notification) }
    }

    fun cancel(context: Context, sessionId: String) = NotificationManagerCompat.from(context).cancel(id(sessionId))

    private fun action(context: Context, sessionId: String, action: String): PendingIntent {
        val intent = Intent(context, OfferActionReceiver::class.java).setAction(action).putExtra(OfferActionReceiver.EXTRA_SESSION, sessionId)
        val code = id(sessionId) * 2 + if (action == OfferActionReceiver.ACTION_ACCEPT) 1 else 0
        return PendingIntent.getBroadcast(context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}

class OfferActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val sessionId = intent.getStringExtra(EXTRA_SESSION) ?: return
        LanController.decide(sessionId, intent.action == ACTION_ACCEPT)
        OfferNotifications.cancel(context, sessionId)
    }

    companion object {
        const val ACTION_ACCEPT = "com.limlink.app.offer.ACCEPT"
        const val ACTION_REJECT = "com.limlink.app.offer.REJECT"
        const val EXTRA_SESSION = "session"
    }
}
