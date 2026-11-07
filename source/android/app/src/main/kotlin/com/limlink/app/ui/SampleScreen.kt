package com.limlink.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.limlink.app.R
import com.limlink.app.storage.LocationKind
import com.limlink.app.storage.SaveLocationRepository
import com.limlink.app.storage.SaveLocationStatus
import com.limlink.kit.storage.SamplePayload
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun SampleScreen(
    padding: PaddingValues,
    snackbarHostState: SnackbarHostState,
) {
    val context = LocalContext.current
    val repository = remember { SaveLocationRepository(context.applicationContext) }
    val status by repository.status.collectAsState(
        initial = SaveLocationStatus(LocationKind.DOWNLOADS, null, null),
    )
    val scope = rememberCoroutineScope()
    val appContext = context.applicationContext
    Column(
        Modifier
            .fillMaxSize()
            .padding(padding)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = stringResource(R.string.sample_hint),
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = FontFamily.Default,
        )
        CapsuleButton(
            text = stringResource(R.string.action_write_sample),
            onClick = {
                val current = status
                scope.launch {
                    val message = withContext(Dispatchers.IO) {
                        runCatching {
                            val opened = repository.openStore(current)
                            val published = SamplePayload.write(opened.store)
                            if (opened.fellBackToDownloads) {
                                appContext.getString(R.string.save_fell_back)
                            } else {
                                appContext.getString(R.string.sample_saved, published.displayName)
                            }
                        }.getOrElse {
                            appContext.getString(R.string.sample_failed)
                        }
                    }
                    snackbarHostState.showSnackbar(message)
                }
            },
            modifier = Modifier.fillMaxWidth(),
            primary = true,
            testTag = "sample_write",
        )
    }
}
