package io.github.subhamsubhasispatra.idownloader.features.bili_pack

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import io.github.subhamsubhasispatra.idownloader.R
import io.github.subhamsubhasispatra.idownloader.bridge.bridge
import io.github.subhamsubhasispatra.idownloader.model.DraftPreview
import io.github.subhamsubhasispatra.idownloader.packs.PackSettingsContent
import io.github.subhamsubhasispatra.idownloader.packs.PackUi
import io.github.subhamsubhasispatra.idownloader.packs.bool
import io.github.subhamsubhasispatra.idownloader.packs.int
import io.github.subhamsubhasispatra.idownloader.packs.optionList
import io.github.subhamsubhasispatra.idownloader.packs.strings
import io.github.subhamsubhasispatra.idownloader.ui.components.draft.DraftChoices
import io.github.subhamsubhasispatra.idownloader.ui.components.draft.DraftTrim
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

object BilibiliUi : PackUi {
    override val packId = "bili"

    override val settingsTitle = R.string.pack_bilibili

    override val searchItems = listOf(
        R.string.bili_login to null,
        R.string.bili_import_cookie to null,
        R.string.bili_logout to null,
        R.string.bili_default_quality to null,
        R.string.bili_alternative_quality to null,
        R.string.bili_hdr to R.string.bili_hdr_desc,
        R.string.bili_dolby to R.string.bili_dolby_desc,
    )

    override val settingsContent: PackSettingsContent =
        { config, keys, set, send ->
            BilibiliLoginRows()
            BilibiliSettings(config, keys, set, send)
        }

    override val draftExtra: (@Composable (JsonObject, String, suspend (String, List<Any?>) -> Unit) -> Unit) =
        { packFields, url, send ->
            val scope = rememberCoroutineScope()
            val subtitles = packFields.optionList("subtitles")
            val duration = packFields.int("duration")

            if (packFields.bool("hasCover")) Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(
                    packFields.bool("isCoverEnabled"), role = Role.Switch,
                    onValueChange = { scope.launch { send("setControl", listOf("cover", if (it) "1" else "")) } }),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.draft_track_cover), Modifier.weight(1f))
                Switch(checked = packFields.bool("isCoverEnabled"), onCheckedChange = null)
            }

            if (subtitles.isNotEmpty()) DraftChoices(subtitles, packFields.strings("subtitleLanguages"),
                onChange = { langs -> scope.launch { send("setSubtitles", listOf(langs.joinToString(","))) } })

            if (duration > 0) DraftTrim(url, duration, packFields.bool("hasPreview"),
                packFields.int("startTime"), packFields.int("endTime"),
                onChange = { start, end -> scope.launch { send("setTrim", listOf(start, end)) } },
                fetchPreview = { bridge.query<DraftPreview>("draftPreview", it) })
        }
}
