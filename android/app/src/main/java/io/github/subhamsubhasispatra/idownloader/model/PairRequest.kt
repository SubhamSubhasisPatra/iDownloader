package io.github.subhamsubhasispatra.idownloader.model

import kotlinx.serialization.Serializable

@Serializable
data class PairRequest(
    val requestId: String = "",
    val clientKind: String = "",
    val extensionVersion: String = "",
    val peerAddress: String = "",
)
