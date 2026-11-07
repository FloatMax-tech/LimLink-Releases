package com.limlink.app

import android.content.pm.PackageManager
import android.os.Build
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBarItemColors
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemColors
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.limlink.app.ui.AboutScreen
import com.limlink.app.ui.DetailScaffold
import com.limlink.app.ui.DiagnosticsScreen
import com.limlink.app.ui.HistoryScreen
import com.limlink.app.ui.HomeScreen
import com.limlink.app.ui.InvitePlaceholderScreen
import com.limlink.app.ui.PrivacyScreen
import com.limlink.app.ui.SampleScreen
import com.limlink.app.ui.SettingsScreen
import com.limlink.app.ui.TransferScreen
import com.limlink.app.ui.UsageScreen
import com.limlink.ui.theme.BrandFontSetting
import com.limlink.ui.theme.BrandTextRole
import com.limlink.ui.theme.LocalLimLinkTheme
import com.limlink.ui.theme.ProvideLimLinkTheme

@Composable
fun LimLinkApp(
    routeRequest: String?,
    onRouteConsumed: () -> Unit,
) {
    ProvideLimLinkTheme(
        brandFont = BrandFontSetting(
            enabled = ShellPrefs.brandEnabled,
            fontFamily = if (ShellPrefs.standInFont) FontFamily.Serif else null,
            appliesTo = BrandTextRole.entries.toSet(),
        ),
    ) {
        val nav = rememberNavController()
        val snackbar = remember { SnackbarHostState() }
        val versionName = rememberVersionName()
        LaunchedEffect(routeRequest) {
            if (routeRequest == Routes.TRANSFER) {
                nav.navigate(Routes.TRANSFER) { launchSingleTop = true }
                onRouteConsumed()
            }
        }
        Scaffold(
            snackbarHost = { SnackbarHost(snackbar) },
        ) { padding ->
            Row(
                Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                NavHost(
                    navController = nav,
                    startDestination = Routes.HOME,
                    modifier = Modifier.weight(1f),
                ) {
                    composable(Routes.HOME) {
                        HomeScreen(onSettings = { nav.navigate(Routes.SETTINGS) })
                    }
                    composable(Routes.HISTORY) { HistoryScreen() }
                    composable(Routes.SETTINGS) {
                        DetailScaffold(titleId = R.string.title_settings, onBack = { nav.popBackStack() }) { inner ->
                            SettingsScreen(
                                modifier = Modifier.padding(inner),
                                snackbarHostState = snackbar,
                                onAbout = { nav.navigate(Routes.ABOUT) },
                                onPrivacy = { nav.navigate(Routes.PRIVACY) },
                                onUsage = { nav.navigate(Routes.USAGE) },
                                onDemo = { nav.navigate(Routes.TRANSFER) },
                                onSample = { nav.navigate(Routes.SAMPLE) },
                            )
                        }
                    }
                    composable(Routes.ABOUT) {
                        DetailScaffold(titleId = R.string.title_about, onBack = { nav.popBackStack() }) { inner ->
                            AboutScreen(
                                padding = inner,
                                versionName = versionName,
                                onDiagnostics = { nav.navigate(Routes.DIAGNOSTICS) },
                            )
                        }
                    }
                    composable(Routes.DIAGNOSTICS) {
                        DetailScaffold(titleId = R.string.title_diagnostics, onBack = { nav.popBackStack() }) { inner ->
                            DiagnosticsScreen(inner)
                        }
                    }
                    composable(Routes.PRIVACY) {
                        DetailScaffold(titleId = R.string.title_privacy, onBack = { nav.popBackStack() }, backTestTag = "privacy.back") { inner ->
                            PrivacyScreen(inner)
                        }
                    }
                    composable(Routes.USAGE) {
                        DetailScaffold(titleId = R.string.usage_title, onBack = { nav.popBackStack() }, backTestTag = "terms.back") { inner ->
                            UsageScreen(inner)
                        }
                    }
                    composable(Routes.INVITE_SHOW) {
                        DetailScaffold(titleId = R.string.title_show_invite, onBack = { nav.popBackStack() }) { inner ->
                            InvitePlaceholderScreen(inner, showing = true)
                        }
                    }
                    composable(Routes.INVITE_ENTER) {
                        DetailScaffold(titleId = R.string.title_enter_invite, onBack = { nav.popBackStack() }) { inner ->
                            InvitePlaceholderScreen(inner, showing = false)
                        }
                    }
                    composable(Routes.TRANSFER) {
                        DetailScaffold(titleId = R.string.title_transfer, onBack = { nav.popBackStack() }) { inner ->
                            TransferScreen(inner)
                        }
                    }
                    composable(Routes.SAMPLE) {
                        DetailScaffold(titleId = R.string.title_sample, onBack = { nav.popBackStack() }) { inner ->
                            SampleScreen(inner, snackbar)
                        }
                    }
                }
            }
        }
        // Drawn after the Scaffold so the consent panel covers every page.
        com.limlink.app.ui.ReceiveConsent()
        com.limlink.app.ui.BindingConsent()
    }
}

@Composable
private fun rememberVersionName(): String {
    val context = LocalContext.current
    return remember {
        val info = if (Build.VERSION.SDK_INT >= 33) {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.PackageInfoFlags.of(0),
            )
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0)
        }
        info.versionName.orEmpty()
    }
}
