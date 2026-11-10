package com.pocketide.linux

import android.content.Context
import java.io.File

/**
 * Where PocketIDE's connection to Cloud Shell lives, all of it in the app's private storage: no
 * other app, and nothing on the phone's shared storage, can read it.
 *
 * | Host (under files/connector/) | Inside Linux | Reset             |
 * |-------------------------------|--------------|-------------------|
 * | rootfs/                       | /            | deleted, rebuilt  |
 * | home/                         | /root        | kept              |
 *
 * The home holds gcloud's sign-in and settings (~/.config/gcloud). Ubuntu itself can be rebuilt at
 * any time from the pinned downloads.
 */
class LinuxDirs(val base: File) {
    val rootfs = File(base, "rootfs")
    val home = File(base, "home")

    /** Partial and finished downloads of the pinned archives. */
    val downloads = File(base, "downloads")

    /** How far set-up got ([SetupRecord]); outside the rootfs, so nothing inside Linux can change it. */
    val record = File(base, "connector.json")

    /** PRoot's own temporary files, and each command's private variables file. */
    val prootTmp = File(base, "proot-tmp")

    /** Stand-ins for the /proc files Android hides ([ProcStandIns]). */
    val procFakes = File(base, "proc")

    /** Links a program inside Linux asks the phone to open (xdg-open writes them, the app opens them). */
    val openRequests = File(home, OPEN_REQUESTS)

    /** The connection's own files inside Linux (its ssh control socket and forwarded ports). */
    val sockets = File(rootfs, SOCKETS.removePrefix("/"))

    companion object {
        const val FOLDER = "connector"
        const val GUEST_HOME = "/root"
        const val APP_FILES = ".pocketide"
        const val OPEN_REQUESTS = "$APP_FILES/open"

        /** Short, because a Unix socket's whole path must fit in 108 bytes on the phone. */
        const val SOCKETS = "/tmp/pi"

        fun of(context: Context) = LinuxDirs(File(context.filesDir, FOLDER))
    }
}
