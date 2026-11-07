package com.limlink.app

import android.app.Application
import com.limlink.kit.notify.TransferNotifications

class LimLinkApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        com.limlink.app.transfer.LanController.initialize(this)
        TransferNotifications.ensureChannel(
            this,
            getString(R.string.channel_transfer_name),
            getString(R.string.channel_transfer_description),
        )
        com.limlink.app.service.OfferNotifications.ensureChannel(this)
    }
}
