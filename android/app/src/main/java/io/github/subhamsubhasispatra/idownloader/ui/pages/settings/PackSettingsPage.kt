package io.github.subhamsubhasispatra.idownloader.ui.pages.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.subhamsubhasispatra.idownloader.bridge.bridge
import io.github.subhamsubhasispatra.idownloader.packs.PackKeys
import io.github.subhamsubhasispatra.idownloader.packs.PackRegistry
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.LoadingRow
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingsScaffold

@Composable
fun PackSettingsPage(
    packId: String,
    onBack: () -> Unit,
    viewModel: SettingsViewModel,
) {
    val entry = PackRegistry.entry(packId) ?: return
    val packUi = entry.packUi
    val content = packUi.settingsContent ?: return
    val keys = PackKeys(entry.configClass!!)

    val config by viewModel.config.collectAsStateWithLifecycle()

    SettingsScaffold(stringResource(packUi.settingsTitle), onBack) {
        config?.let {
            content(it, keys, viewModel::set) { action, args ->
                bridge.query("requestPack", packId, action, *args.toTypedArray())
            }
        } ?: LoadingRow()
    }
}
