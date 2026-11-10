package com.pocketide.link

import android.os.FileObserver
import com.pocketide.ui.web.WebPolicy
import java.io.File

/**
 * Opens the web addresses programs inside Linux ask for: xdg-open (PocketIDE's own, in
 * /opt/pocketide/bin) writes each one into a file in ~/.pocketide/open, and this hands it to
 * [open], which shows it in Chrome, or as a notification when the app is not in front. Sign-in
 * commands in the terminal (claude auth login, codex login, agy) use it.
 *
 * Only web addresses pass ([WebPolicy.isWebLink]); anything else in the folder is deleted unread.
 */
class LinkOpener(private val folder: File, private val open: (String) -> Unit) {
    private var observer: FileObserver? = null

    @Synchronized
    fun start() {
        if (observer != null) return
        folder.mkdirs()
        observer = object : FileObserver(folder, MOVED_TO or CLOSE_WRITE) {
            override fun onEvent(event: Int, path: String?) {
                if (path != null && path.endsWith(SUFFIX)) takeAll()
            }
        }.also { it.startWatching() }
        takeAll()
    }

    @Synchronized
    fun stop() {
        observer?.stopWatching()
        observer = null
    }

    /** Every waiting address, oldest first; each file is deleted once read. */
    @Synchronized
    fun takeAll() {
        val files = folder.listFiles()?.filter { it.isFile && it.name.endsWith(SUFFIX) }?.sortedBy { it.name }.orEmpty()
        for (file in files) {
            val url = runCatching { if (file.length() <= MAX_BYTES) file.readText().trim() else null }.getOrNull()
            file.delete()
            if (url != null && WebPolicy.isWebLink(url)) open(url)
        }
    }

    private companion object {
        const val SUFFIX = ".url"
        const val MAX_BYTES = 16L * 1024
    }
}
