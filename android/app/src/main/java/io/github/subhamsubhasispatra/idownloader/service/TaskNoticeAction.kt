package io.github.subhamsubhasispatra.idownloader.service

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationManagerCompat
import io.github.subhamsubhasispatra.idownloader.bridge.bridge
import kotlinx.coroutines.runBlocking

private const val ACTION_RETRY = "io.github.subhamsubhasispatra.idownloader.RETRY_TASK"
private const val EXTRA_TASK_ID = "taskId"

fun retryAction(context: Context, taskId: String): PendingIntent =
    PendingIntent.getBroadcast(
        context, taskId.hashCode(),
        Intent(context, TaskNoticeActionReceiver::class.java)
            .setAction(ACTION_RETRY)
            .putExtra(EXTRA_TASK_ID, taskId),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

class TaskNoticeActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val taskId = intent.getStringExtra(EXTRA_TASK_ID) ?: return
        if (intent.action != ACTION_RETRY) return
        val pending = goAsync()
        Thread {
            runBlocking { bridge.invoke("redownload", taskId) }
            NotificationManagerCompat.from(context).cancel(taskNoticeId(taskId))
            pending.finish()
        }.start()
    }
}
