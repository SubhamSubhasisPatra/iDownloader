package io.github.subhamsubhasispatra.idownloader.features.github_pack

import io.github.subhamsubhasispatra.idownloader.R
import io.github.subhamsubhasispatra.idownloader.packs.PackSettingsContent
import io.github.subhamsubhasispatra.idownloader.packs.PackUi

object GitHubUi : PackUi {
    override val packId = "github"

    override val settingsTitle = R.string.pack_github

    override val searchItems = listOf(
        R.string.github_enabled to R.string.github_enabled_desc,
        R.string.proxy_site to null,
    )

    override val settingsContent: PackSettingsContent =
        { config, keys, set, send -> GitHubSettings(config, keys, set, send) }
}
