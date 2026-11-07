package com.limlink.app.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.limlink.app.R
import com.limlink.app.transfer.LanController

@Composable
fun BindingSettings() {
    val peers by LanController.peers.collectAsState()
    val records by LanController.bindings.collectAsState()
    val state by LanController.bindingState.collectAsState()
    var picker by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.binding_title))
        CapsuleButton(text = stringResource(R.string.binding_add), onClick = { picker = true }, modifier = Modifier.fillMaxWidth())
        records.forEach { record ->
            Text(record.alias)
            TextButton(onClick = { LanController.unbind(record) }) { Text(stringResource(R.string.binding_unbind)) }
        }
        if (records.isEmpty()) Text(stringResource(R.string.binding_empty))
        when (state.state) {
            "waiting" -> {
                Text(stringResource(R.string.binding_waiting, state.peer))
                TextButton(onClick = LanController::cancelBinding) { Text(stringResource(R.string.action_cancel)) }
            }
            "completed" -> Text(stringResource(R.string.binding_completed, state.peer))
            "failed" -> Text(stringResource(R.string.binding_failed))
            "cancelled" -> Text(stringResource(R.string.binding_cancelled))
            "unbound" -> Text(stringResource(R.string.binding_unbound))
        }
    }
    if (picker) AlertDialog(
        onDismissRequest = { picker = false },
        title = { Text(stringResource(R.string.binding_add)) },
        text = { Column {
            if (peers.isEmpty()) Text(stringResource(R.string.binding_no_devices))
            peers.forEach { peer ->
                TextButton(onClick = { picker = false; LanController.bind(peer) }) {
                    Text(stringResource(R.string.binding_bind_device, peer.name))
                }
            }
        } },
        confirmButton = {},
        dismissButton = { TextButton(onClick = { picker = false }) { Text(stringResource(R.string.action_cancel)) } },
    )
}

@Composable
fun BindingConsent() {
    val prompt by LanController.bindingPrompt.collectAsState()
    prompt?.let { request ->
        AlertDialog(
            onDismissRequest = { LanController.decideBinding(request.pairId, false) },
            title = { Text(stringResource(R.string.binding_request, request.alias)) },
            text = { Text(stringResource(R.string.binding_grant)) },
            confirmButton = { TextButton(onClick = { LanController.decideBinding(request.pairId, true) }) { Text(stringResource(R.string.binding_accept)) } },
            dismissButton = { TextButton(onClick = { LanController.decideBinding(request.pairId, false) }) { Text(stringResource(R.string.binding_reject)) } },
        )
    }
}
