package io.github.subhamsubhasispatra.idownloader.ui.components.settings

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import io.github.subhamsubhasispatra.idownloader.R
import io.github.subhamsubhasispatra.idownloader.ui.platform.canInstallPackages
import io.github.subhamsubhasispatra.idownloader.ui.platform.canRequestNotifications
import io.github.subhamsubhasispatra.idownloader.ui.platform.hasNotificationAccess
import io.github.subhamsubhasispatra.idownloader.ui.platform.hasStorageAccess
import io.github.subhamsubhasispatra.idownloader.ui.platform.isBatteryUnrestricted
import io.github.subhamsubhasispatra.idownloader.ui.platform.openInstallPackagesSettings
import io.github.subhamsubhasispatra.idownloader.ui.platform.openNotificationSettings
import io.github.subhamsubhasispatra.idownloader.ui.platform.openStorageAccessSettings
import io.github.subhamsubhasispatra.idownloader.ui.platform.requestBatteryUnrestricted

@Composable
fun PermissionRows() {
    StoragePermissionRow()
    NotificationPermissionRow()
    BatteryPermissionRow()
    InstallPackagesRow()
}

@Composable
fun StoragePermissionRow() {
    val context = LocalContext.current
    var isGranted by remember { mutableStateOf(false) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        isGranted = context.hasStorageAccess()
    }
    PermissionRow(
        icon = R.drawable.ic_folder,
        title = stringResource(R.string.settings_storage_access),
        subtitle = stringResource(if (isGranted) R.string.permission_granted else R.string.permission_denied),
        isGranted = isGranted,
        onClick = { context.openStorageAccessSettings() },
    )
}

@Composable
fun NotificationPermissionRow() {
    val context = LocalContext.current
    var isGranted by remember { mutableStateOf(false) }
    var canAsk by remember { mutableStateOf(true) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        isGranted = context.hasNotificationAccess()
    }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        isGranted = granted
        canAsk = granted || context.canRequestNotifications()
    }
    PermissionRow(
        icon = R.drawable.ic_notification_download,
        title = stringResource(R.string.settings_notifications),
        subtitle = stringResource(if (isGranted) R.string.permission_granted else R.string.permission_denied),
        isGranted = isGranted,
        onClick = {
            if (!isGranted && canAsk && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                request.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                context.openNotificationSettings()
            }
        },
    )
}

@Composable
fun BatteryPermissionRow() {
    val context = LocalContext.current
    var isGranted by remember { mutableStateOf(false) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        isGranted = context.isBatteryUnrestricted()
    }
    PermissionRow(
        icon = R.drawable.ic_download,
        title = stringResource(R.string.settings_battery_unrestricted),
        subtitle = stringResource(
            if (isGranted) R.string.permission_granted else R.string.settings_battery_unrestricted_desc,
        ),
        isGranted = isGranted,
        onClick = { context.requestBatteryUnrestricted() },
    )
}

@Composable
fun InstallPackagesRow() {
    val context = LocalContext.current
    var isGranted by remember { mutableStateOf(false) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        isGranted = context.canInstallPackages()
    }
    PermissionRow(
        icon = R.drawable.ic_permissions,
        title = stringResource(R.string.settings_install_packages),
        subtitle = stringResource(
            if (isGranted) R.string.permission_granted else R.string.settings_install_packages_desc,
        ),
        isGranted = isGranted,
        onClick = { context.openInstallPackagesSettings() },
    )
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun PermissionRow(
    icon: Int,
    title: String,
    subtitle: String,
    isGranted: Boolean,
    onClick: () -> Unit,
) {
    ActionSettingRow(
        title = title,
        subtitle = subtitle,
        leading = { Icon(painterResource(icon), contentDescription = null) },
        colors = if (isGranted) ListItemDefaults.segmentedColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
            supportingContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
            leadingContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ) else ListItemDefaults.segmentedColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        ),
        onClick = onClick,
    )
}
