package io.github.subhamsubhasispatra.idownloader.ui.pages.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.subhamsubhasispatra.idownloader.R
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.ClientProfileRow
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.LoadingRow
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.matchClientProfile
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingsEdit
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingsEditor
import io.github.subhamsubhasispatra.idownloader.ui.components.settings.SettingsScaffold

@Composable
fun ClientProfilePage(
    onBack: () -> Unit,
    viewModel: IdentityViewModel,
    modifier: Modifier = Modifier,
    edit: SettingsEdit = viewModel(),
) {
    val uiState by viewModel.state.collectAsStateWithLifecycle()
    val editState by edit.state.collectAsStateWithLifecycle()
    val identityState = uiState
    if (identityState == null) {
        SettingsScaffold(stringResource(R.string.identity_profile_choose), onBack, modifier) { LoadingRow() }
        return
    }
    var value by rememberSaveable { mutableStateOf(identityState.identity.clientProfile) }
    SettingsEditor(
        stringResource(R.string.identity_profile_choose), editState,
        isChanged = value != identityState.identity.clientProfile,
        canSave = matchClientProfile(value, identityState.profiles),
        onSave = { val selected = value; edit.save { viewModel.setClientProfile(selected) } },
        onBack = onBack, modifier = modifier,
    ) {
        ClientProfileRow(value, identityState.profiles, { value = it }, isEnabled = !editState.isSaving)
    }
}
