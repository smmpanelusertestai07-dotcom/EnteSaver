package com.pocketide.ui.screens.data

import android.content.Context
import com.pocketide.AppGraph
import com.pocketide.core.AppFolders
import com.pocketide.core.OldVersionFiles
import com.pocketide.core.afterDeleteEverything
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * PocketIDE's own data on this phone, deleted: its connection (gcloud signed out first, so Google
 * ends that sign-in too, then Ubuntu and gcloud removed), its files and caches, what older versions
 * left (PocketIDE 5's computer included), and its settings, back to their defaults, so the app
 * starts again from the welcome. The owner's Cloud Shell is not touched.
 */
suspend fun deletePhoneData(context: Context, graph: AppGraph) {
    runCatching { graph.link.signOut() }
    runCatching { graph.computer.remove() }
    graph.pages.releaseAll()
    withContext(Dispatchers.IO) { OldVersionFiles.remove(AppFolders.of(context)) }
    graph.settings.update { it.afterDeleteEverything() }
}
