package io.github.subhamsubhasispatra.idownloader.ui.pages.settings

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import io.github.subhamsubhasispatra.idownloader.R
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.RuntimeRows
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingSection
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingsScaffold

@Composable
fun RuntimesPage(onBack: () -> Unit) {
    SettingsScaffold(stringResource(R.string.settings_section_runtimes), onBack) {
        SettingSection { RuntimeRows() }
    }
}
