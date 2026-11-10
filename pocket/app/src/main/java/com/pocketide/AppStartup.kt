package com.pocketide

import android.content.Context
import android.net.ConnectivityManager
import androidx.core.app.NotificationManagerCompat
import com.pocketide.core.AppFolders
import com.pocketide.core.OldVersionFiles
import com.pocketide.linux.ComputerState
import com.pocketide.linux.UpdateOutcome
import com.pocketide.ui.components.AgentIcons
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.security.KeyStore

/**
 * What runs once per process start: once after an update, the deletion of what an older version
 * left that nothing uses now; the agents' icons, ready before Home shows them; the opener of pages
 * gcloud asks for; and, once a week on Wi-Fi (a network that is not metered), the updates of
 * PocketIDE's connection (Ubuntu's security fixes and Google's gcloud, by its own updater). Mobile
 * data is never used for them: Update now (Computer) runs them on any network.
 */
object AppStartup {
    fun onCreate(graph: AppGraph) {
        graph.housekeeping = graph.scope.launch(Dispatchers.IO) {
            // Housekeeping must never stop the app from starting; what fails is tried at the next start.
            val removed = runCatching { OldVersionFiles.removeOnce(AppFolders.of(graph.context)) }.getOrDefault(false)
            if (removed) removeOldSystemEntries(graph.context)
        }
        graph.scope.launch(Dispatchers.IO) {
            runCatching { AgentIcons.preload(graph.context.cacheDir) }
            graph.housekeeping?.join()
            runCatching { graph.linkOpener.start() }
            updateConnection(graph)
        }
    }

    /** Ubuntu's updates and gcloud's own updater, at most once a week on Wi-Fi, when the connection is set up. */
    private suspend fun updateConnection(graph: AppGraph) {
        val computer = graph.computer
        val last = runCatching { computer.info().updatedAt }.getOrNull() ?: 0L
        val due = computer.state.value == ComputerState.Ready && graph.clock.now() - last >= WEEK_MS
        if (!due || metered(graph.context)) return
        // Right after a start the owner may be opening an agent: the connection goes first.
        delay(UPDATE_DELAY_MS)
        val outcome = if (metered(graph.context)) null else runCatching { computer.updateBase() }.getOrNull()
        if (outcome is UpdateOutcome.Updated) graph.link.gcloudUpdated()
    }

    /** True on mobile data (or a hotspot), and when Android cannot tell. */
    private fun metered(context: Context): Boolean =
        runCatching { context.getSystemService(ConnectivityManager::class.java).isActiveNetworkMetered }.getOrDefault(true)

    private const val WEEK_MS = 7 * 24 * 60 * 60 * 1000L
    private const val UPDATE_DELAY_MS = 2 * 60 * 1000L

    /**
     * Version 5's notification channels (the computer's "on" notice, sign-in pages) and the key it
     * sealed the owner's keys with, in the phone's secure hardware: only Android's APIs remove them.
     */
    private fun removeOldSystemEntries(context: Context) {
        runCatching {
            val notifications = NotificationManagerCompat.from(context)
            OLD_CHANNELS.forEach(notifications::deleteNotificationChannel)
        }
        runCatching { KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }.deleteEntry(OLD_KEY) }
    }

    private val OLD_CHANNELS = listOf("computer", "links")
    private const val ANDROID_KEY_STORE = "AndroidKeyStore"
    private const val OLD_KEY = "pocketide.secure.v1"
}
