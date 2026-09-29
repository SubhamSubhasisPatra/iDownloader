package io.github.subhamsubhasispatra.idownloader.ui.pages.settings

import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.subhamsubhasispatra.idownloader.R
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.ActionSettingRow
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.clientProfileLabel
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.LoadingRow
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingSection
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingsScaffold
import io.github.subhamsubhasispatra.idownloader.ui.navigation.ClientProfileRoute
import io.github.subhamsubhasispatra.idownloader.ui.navigation.HeadersPresetsRoute
import io.github.subhamsubhasispatra.idownloader.ui.navigation.IdentityRulesRoute
import io.github.subhamsubhasispatra.idownloader.ui.navigation.Route

@Composable
fun IdentityPage(onNavigate: (Route) -> Unit, onBack: () -> Unit,
    modifier: Modifier = Modifier, viewModel: IdentityViewModel) {
    val uiState by viewModel.state.collectAsStateWithLifecycle()
    val state = uiState?.identity
    val tint = MaterialTheme.colorScheme.onSurfaceVariant
    val chevron: @Composable () -> Unit = {
        Icon(painterResource(R.drawable.ic_chevron_right), contentDescription = null, tint = tint)
    }
    SettingsScaffold(stringResource(R.string.identity_title), onBack, modifier) {
        if (state == null) { LoadingRow(); return@SettingsScaffold }
        SettingSection {
            ActionSettingRow(stringResource(R.string.identity_default_profile),
                subtitle = clientProfileLabel(state.clientProfile),
                leading = { Icon(painterResource(R.drawable.ic_account_box), contentDescription = null, tint = tint) },
                trailing = chevron,
                onClick = { onNavigate(ClientProfileRoute) })
            ActionSettingRow(stringResource(R.string.identity_rules),
                subtitle = stringResource(R.string.identity_rules_summary,
                    state.identityPresets.size, state.identityPresets.count { it.isEnabled }),
                leading = { Icon(painterResource(R.drawable.ic_sort), contentDescription = null, tint = tint) },
                trailing = chevron,
                onClick = { onNavigate(IdentityRulesRoute) })
            val active = state.headersPresets.getOrNull(state.currentHeadersPreset)
            ActionSettingRow(stringResource(R.string.identity_headers_presets),
                subtitle = active?.let { stringResource(R.string.identity_headers_summary, it.name, it.headers.size) },
                leading = { Icon(painterResource(R.drawable.ic_cat_code), contentDescription = null, tint = tint) },
                trailing = chevron,
                onClick = { onNavigate(HeadersPresetsRoute) })
        }
    }
}
