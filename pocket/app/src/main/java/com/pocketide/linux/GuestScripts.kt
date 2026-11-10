package com.pocketide.linux

import android.content.res.AssetManager
import java.io.File

/** The files shipped in the app's assets/linux folder, by their paths inside it ("bin/claude"). */
internal interface LinuxAssets {
    fun names(): List<String>
    fun read(name: String): ByteArray
}

internal class AndroidLinuxAssets(private val assets: AssetManager) : LinuxAssets {
    override fun names(): List<String> = files(FOLDER).map { it.removePrefix("$FOLDER/") }.sorted()

    override fun read(name: String): ByteArray = assets.open("$FOLDER/$name").use { it.readBytes() }

    /** Android lists a folder's entries without saying which are folders; a folder is one that has entries. */
    private fun files(path: String): List<String> = assets.list(path).orEmpty().flatMap { name ->
        val child = "$path/$name"
        if (assets.list(child).isNullOrEmpty()) listOf(child) else files(child)
    }

    private companion object {
        const val FOLDER = "linux"
    }
}

/** Runs a program inside a given Linux root (production: proot). */
internal fun interface GuestRunner {
    suspend fun run(root: File, argv: List<String>, onLine: (String) -> Unit): Int
}

/** How a script ended, and the last thing it said, for the message the owner sees. */
internal data class ScriptResult(val exitCode: Int, val lastWords: String?)

/**
 * The app's scripts inside Linux. They are copied into /opt/pocketide before every use, so an app
 * update replaces them, and run with their output read line by line. The commands in bin/ (the
 * agents' command-line tools, and xdg-open) come first on the computer's PATH.
 */
internal class GuestScripts(private val assets: LinuxAssets, private val runner: GuestRunner) {

    /** Copies the scripts in; returns how many were missing or different. Everything in bin/ is a command. */
    fun install(rootfs: File): Int {
        val guest = GuestRoot(rootfs)
        return assets.names().count { name ->
            val command = name.startsWith("bin/") || name.endsWith(".sh") || name.endsWith(".pl")
            guest.write("$FOLDER/$name", assets.read(name), if (command) FileModes.EXECUTABLE else FileModes.PLAIN)
        }
    }

    /** Identifies the bootstrap this app carries, so a changed one runs again after an update. */
    fun bootstrapVersion(): String = Downloader.sha256(assets.read(BOOTSTRAP))

    suspend fun run(rootfs: File, script: String, onLine: (GuestLine) -> Unit): ScriptResult {
        var lastWords: String? = null
        val code = runner.run(rootfs, listOf("/bin/bash", "$FOLDER/$script")) { raw ->
            val line = GuestLines.parse(raw)
            if (line is GuestLine.Text && line.text.isNotEmpty()) lastWords = line.text
            onLine(line)
        }
        return ScriptResult(code, lastWords)
    }

    companion object {
        const val FOLDER = "/opt/pocketide"
        const val BOOTSTRAP = "bootstrap.sh"
        const val UPDATE = "update.sh"

        /** Written by bootstrap.sh as its last step. */
        const val STAMP = "$FOLDER/bootstrap.stamp"
    }
}
