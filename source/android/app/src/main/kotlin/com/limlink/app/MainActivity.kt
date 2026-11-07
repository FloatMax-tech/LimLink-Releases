package com.limlink.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf

class MainActivity : ComponentActivity() {
    private val routeRequest = mutableStateOf<String?>(null)

    override fun attachBaseContext(newBase: android.content.Context) {
        super.attachBaseContext(AppLanguage.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        androidx.core.content.ContextCompat.startForegroundService(this, Intent(this, com.limlink.app.service.TransferForegroundService::class.java))
        routeRequest.value = intent.getStringExtra(EXTRA_ROUTE)
        handleShare(intent)
        setContent {
            com.limlink.app.ui.UpdateHost { LimLinkApp(
                routeRequest = routeRequest.value,
                onRouteConsumed = { routeRequest.value = null },
            ) }
        }
    }

    override fun onStart() {
        super.onStart()
        com.limlink.app.transfer.LanController.foreground = true
    }

    override fun onStop() {
        com.limlink.app.transfer.LanController.foreground = false
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeRequest.value = intent.getStringExtra(EXTRA_ROUTE)
        handleShare(intent)
    }

    /** ACTION_SEND delivers a content URI granted to this activity; the controller snapshots it immediately. */
    private fun handleShare(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val uri = if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, android.net.Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
        if (uri != null) com.limlink.app.transfer.LanController.selectFromShare(uri)
    }

    companion object {
        const val EXTRA_ROUTE = "limlink_route"
    }
}
