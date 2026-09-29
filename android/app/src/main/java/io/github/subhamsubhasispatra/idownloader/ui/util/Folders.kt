package io.github.subhamsubhasispatra.idownloader.ui.util

import java.io.File

fun isValidOutputFolder(folder: String): Boolean = folder.isBlank() || File(folder.trim()).isAbsolute
