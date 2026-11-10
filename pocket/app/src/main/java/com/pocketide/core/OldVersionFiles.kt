package com.pocketide.core

import android.content.Context
import java.io.File
import java.io.IOException

/** The app's private folders, as plain files so what empties them can be tested off a phone. */
internal class AppFolders(val files: File, val noBackup: File, val cache: File, val data: File) {
    /** Where versions 4 and 5 kept sealed sign-ins and keys; this version keeps none. */
    val secure: File get() = File(noBackup, SECURE)

    /** PocketIDE 5's computer ([OldComputer]). */
    val oldComputer: File get() = File(files, OldComputer.FOLDER)

    companion object {
        const val SECURE = "secure"

        fun of(context: Context) = AppFolders(context.filesDir, context.noBackupFilesDir, context.cacheDir, context.dataDir)
    }
}

/**
 * What earlier PocketIDE versions kept in the app's private storage, deleted once after an update.
 *
 * Up to 3.0.0 the computer had another layout (rooms, a chat vault, copies of the projects, a
 * Google account's name). Versions 4 and 5 kept a sealed GitHub sign-in or the owner's keys, and
 * version 5 the agents' page in a WebView. Version 6 has no use for any of it: its computer is
 * Google Cloud Shell, and it keeps only its settings. PocketIDE 5's own computer, with the owner's
 * projects in it, is the one thing left in place, until the owner saves what they want from it and
 * deletes it ([OldComputer]).
 */
internal object OldVersionFiles {
    private const val DONE = "old-versions-removed"

    /** Versions 4 and 5's sealed files and WebView storage were deleted. */
    private const val DONE_V6 = "v6-removed"

    /** The settings, and the backup Android keeps of them while it writes. */
    private const val SETTINGS_PREFS = "pocketide.settings."

    /** The WebView's own folder in the app's data. */
    private const val WEB_VIEW = "app_webview"

    /** Chromium's own files for a web page, by the names it gives them. */
    private val WEB_PAGE = listOf("WebView", "org.chromium")

    /**
     * Once per install, after an update from an older version (a new install has nothing to find).
     * True when something was deleted now, so the caller can also remove what only Android's own
     * APIs may (notification channels, keys in the phone's secure hardware).
     */
    fun removeOnce(folders: AppFolders): Boolean {
        var removed = false
        val done = File(folders.noBackup, DONE)
        if (!done.exists() && remove(folders, keepComputer = true)) {
            removed = true
            mark(done)
        }
        val doneV6 = File(folders.noBackup, DONE_V6)
        if (!doneV6.exists() && removeV5(folders)) {
            removed = true
            mark(doneV6)
        }
        return removed
    }

    private fun mark(file: File) {
        try {
            file.createNewFile()
        } catch (_: IOException) {
            // Tried again at the next start, which then finds nothing to delete.
        }
    }

    /** Versions 4 and 5's sealed sign-ins and keys, and the WebView's storage of version 5's agent page. */
    private fun removeV5(folders: AppFolders): Boolean = listOf(
        FileTrees.delete(folders.secure),
        FileTrees.delete(File(folders.data, WEB_VIEW)),
        FileTrees.deleteContents(folders.cache) { !isWebPage(it) },
        FileTrees.deleteContents(File(folders.data, "shared_prefs")) { !isWebPage(it) },
    ).all { it }

    /**
     * Everything but the settings and these markers; true when all of it went. [keepComputer] leaves
     * PocketIDE 5's computer for the owner to save from first.
     */
    fun remove(folders: AppFolders, keepComputer: Boolean = false): Boolean = listOf(
        FileTrees.deleteContents(folders.files) { keepComputer && it == OldComputer.FOLDER },
        FileTrees.deleteContents(folders.noBackup) { it == DONE || it == DONE_V6 },
        FileTrees.deleteContents(folders.cache),
        FileTrees.delete(File(folders.data, WEB_VIEW)),
        FileTrees.deleteContents(File(folders.data, "databases")),
        FileTrees.deleteContents(File(folders.data, "shared_prefs")) { it.startsWith(SETTINGS_PREFS) },
    ).all { it }

    private fun isWebPage(name: String) = WEB_PAGE.any(name::startsWith)
}
