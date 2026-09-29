package io.github.subhamsubhasispatra.idownloader.ui.pages.settings

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import io.github.subhamsubhasispatra.idownloader.R
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.PermissionRows
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingSection
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingsScaffold

@Composable
fun PermissionsPage(onBack: () -> Unit) {
    SettingsScaffold(stringResource(R.string.settings_section_permissions), onBack) {
        SettingSection { PermissionRows() }
    }
}
