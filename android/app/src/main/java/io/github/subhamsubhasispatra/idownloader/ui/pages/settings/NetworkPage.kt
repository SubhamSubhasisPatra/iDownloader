package io.github.subhamsubhasispatra.idownloader.ui.pages.settings

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.subhamsubhasispatra.idownloader.R
import io.github.subhamsubhasispatra.idownloader.model.Settings
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.ActionSettingRow
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.LoadingRow
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingSection
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingsScaffold
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SwitchSettingRow
import io.github.subhamsubhasispatra.idownloader.ui.navigation.ProxySettingsRoute
import io.github.subhamsubhasispatra.idownloader.ui.navigation.Route

@Composable
fun NetworkPage(onNavigate: (Route) -> Unit, onBack: () -> Unit, viewModel: SettingsViewModel) {
    val settings by viewModel.settings.collectAsStateWithLifecycle()

    SettingsScaffold(stringResource(R.string.settings_section_network), onBack) {
        settings?.let { NetworkRows(it, viewModel::set, { onNavigate(ProxySettingsRoute) }) } ?: LoadingRow()
    }
}

@Composable
private fun ColumnScope.NetworkRows(settings: Settings, set: (String, Any) -> Unit, onProxy: () -> Unit) {
    SettingSection {
        SwitchSettingRow(
            title = stringResource(R.string.settings_system_dns),
            subtitle = stringResource(R.string.settings_system_dns_desc),
            checked = settings.shouldUseSystemDns,
            onCheckedChange = { set("shouldUseSystemDns", it) },
        )
        ActionSettingRow(
            title = stringResource(R.string.settings_proxy),
            subtitle = proxySummary(settings.proxyServer),
            onClick = onProxy,
        )
        SwitchSettingRow(
            title = stringResource(R.string.settings_verify_ssl),
            checked = settings.shouldVerifySsl,
            onCheckedChange = { set("shouldVerifySsl", it) },
        )
    }
}
