package com.limlink.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.limlink.app.R
import com.limlink.app.transfer.LanController
import com.limlink.app.transfer.LanPhase

@Composable
fun TransferScreen(padding: PaddingValues) {
    Column(Modifier.padding(padding).padding(16.dp)) { TransferStatus() }
}

@Composable
fun TransferStatus() {
    val state by LanController.state.collectAsState()
    val phaseText = when (state.phase) {
        LanPhase.IDLE -> R.string.lan_idle
        LanPhase.PREPARING -> R.string.lan_preparing
        LanPhase.READY -> R.string.lan_ready
        LanPhase.WAITING -> R.string.lan_waiting
        LanPhase.TRANSFERRING -> if (state.receiving) R.string.lan_receiving else R.string.lan_sending
        LanPhase.COMPLETED -> R.string.lan_completed
        LanPhase.CANCELLED -> R.string.lan_cancelled
        LanPhase.FAILED -> when {
            state.error.contains("E_FILE_TOO_LARGE") -> R.string.lan_error_size
            state.error.contains("E_REJECTED") -> R.string.lan_error_rejected
            else -> R.string.lan_error
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(phaseText), style = MaterialTheme.typography.titleMedium)
        if (state.fileName.isNotEmpty()) Text(stringResource(R.string.lan_file_size, state.fileName, state.size))
        if (state.peer.isNotEmpty()) Text(stringResource(if (state.receiving) R.string.lan_from else R.string.lan_to, state.peer))
        if (state.phase == LanPhase.TRANSFERRING) {
            LinearProgressIndicator(progress = { if (state.size == 0L) 0f else (state.transferred.toDouble() / state.size).toFloat() }, modifier = Modifier.fillMaxWidth())
            Text(stringResource(R.string.lan_bytes, state.transferred, state.size))
        }
        if (state.phase in listOf(LanPhase.PREPARING, LanPhase.READY, LanPhase.WAITING, LanPhase.TRANSFERRING)) {
            TextButton(onClick = LanController::cancel) { Text(stringResource(R.string.action_cancel)) }
        }
    }
}
