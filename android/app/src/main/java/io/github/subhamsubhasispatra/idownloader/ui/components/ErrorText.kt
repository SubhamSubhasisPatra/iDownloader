package io.github.subhamsubhasispatra.idownloader.ui.components

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import io.github.subhamsubhasispatra.idownloader.i18n.engineText
import io.github.subhamsubhasispatra.idownloader.model.TaskError

@Composable
fun ErrorText(error: TaskError?, modifier: Modifier = Modifier) {
    error ?: return
    Text(engineText(error), modifier, color = MaterialTheme.colorScheme.error)
}
