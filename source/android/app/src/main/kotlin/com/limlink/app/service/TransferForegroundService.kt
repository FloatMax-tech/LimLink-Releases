package com.limlink.app.service

import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.limlink.app.MainActivity
import com.limlink.app.R
import com.limlink.app.transfer.LanController
import com.limlink.app.transfer.LanPhase
import com.limlink.kit.notify.TransferNotifications
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.combine

/** The foreground notification keeps the real LAN listener/transfer alive. */
class TransferForegroundService : Service() {
    override fun attachBaseContext(newBase: android.content.Context) {
        super.attachBaseContext(com.limlink.app.AppLanguage.wrap(newBase))
    }

    private var lastNotificationTime = 0L
    private var lastNotificationText = ""
    private val postedOffers = mutableSetOf<String>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        show(getString(R.string.lan_listening), null, false)
        LanController.start()
        scope.launch {
            combine(LanController.state, LanController.offers, LanController.receive) { state, offers, receive -> Triple(state, offers, receive) }.collect { (state, offers, receive) ->
                val ids = offers.map { it.sessionId }.toSet()
                offers.filter { it.sessionId !in postedOffers }.forEach { offer ->
                    postedOffers += offer.sessionId
                    if (!LanController.foreground) OfferNotifications.show(this@TransferForegroundService, offer)
                }
                (postedOffers - ids).forEach { OfferNotifications.cancel(this@TransferForegroundService, it); postedOffers -= it }

                val receiving = receive?.takeIf { it.phase == LanPhase.TRANSFERRING }
                val sending = state.takeIf { !it.receiving && it.phase == LanPhase.TRANSFERRING }
                val active = receiving ?: sending
                val text = when {
                    offers.isNotEmpty() -> getString(R.string.lan_notification_offer, offers.first().senderName)
                    receiving != null -> getString(R.string.notif_receiving, receiving.fileName)
                    sending != null -> getString(R.string.notif_sending, sending.peer)
                    state.phase == LanPhase.WAITING -> getString(R.string.lan_waiting)
                    else -> getString(R.string.lan_listening)
                }
                val percent = active?.let { if (it.size > 0) (100L * it.transferred / it.size).toInt() else 0 }
                show(text, percent, active != null || state.phase == LanPhase.WAITING)
            }
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopSelf()
            ACTION_CANCEL -> LanController.cancel()
        }
        return START_NOT_STICKY
    }
    override fun onDestroy() { scope.cancel(); LanController.stop(); super.onDestroy() }
    private fun show(text: String, percent: Int?, busy: Boolean) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (text == lastNotificationText && now - lastNotificationTime < 1000) return
        lastNotificationTime = now; lastNotificationText = text
        val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val action = if (busy) {
            val cancel = PendingIntent.getService(this, 3, Intent(this, TransferForegroundService::class.java).setAction(ACTION_CANCEL), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            TransferNotifications.Action(getString(R.string.action_cancel), cancel)
        } else {
            val stop = PendingIntent.getService(this, 2, Intent(this, TransferForegroundService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            TransferNotifications.Action(getString(R.string.lan_stop), stop)
        }
        val notification = TransferNotifications.build(this, R.drawable.ic_stat_transfer, getString(R.string.brand_name), text, percent, false, true, open, listOf(action))
        if (Build.VERSION.SDK_INT >= 34) startForeground(1001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(1001, notification)
    }
    companion object {
        const val ACTION_STOP = "com.limlink.app.transfer.STOP"
        const val ACTION_CANCEL = "com.limlink.app.transfer.CANCEL"
    }
}
