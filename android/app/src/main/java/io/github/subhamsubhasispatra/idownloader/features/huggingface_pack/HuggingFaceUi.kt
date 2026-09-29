package io.github.subhamsubhasispatra.idownloader.features.huggingface_pack

import io.github.subhamsubhasispatra.idownloader.R
import io.github.subhamsubhasispatra.idownloader.packs.PackSettingsContent
import io.github.subhamsubhasispatra.idownloader.packs.PackUi

object HuggingFaceUi : PackUi {
    override val packId = "huggingface"

    override val settingsTitle = R.string.pack_huggingface

    override val searchItems = listOf(
        R.string.huggingface_enabled to R.string.huggingface_enabled_desc,
        R.string.huggingface_access_token to R.string.huggingface_access_token_desc,
        R.string.proxy_site to null,
    )

    override val settingsContent: PackSettingsContent =
        { config, keys, set, send -> HuggingFaceSettings(config, keys, set, send) }
}
