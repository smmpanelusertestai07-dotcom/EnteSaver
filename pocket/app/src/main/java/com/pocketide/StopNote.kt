package com.pocketide

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import java.io.File
import java.time.Instant
import kotlin.system.exitProcess

/**
 * When an error nothing else caught stops PocketIDE, what it was is kept in the app's private
 * storage and a screen ([StoppedActivity]) says so, with a button to copy the details for a
 * report. Nothing is sent anywhere. The screen runs in a process of its own, so it shows even when
 * the error comes while the app starts, before any of the app's parts exist.
 */
internal object StopNote {
    private const val FILE = "last-stop.txt"
    private const val PROCESS = ":stopped"
    private const val MAX_CHARS = 24_000
    private const val EXIT_CODE = 10

    /** True in the note's own process, where the rest of the app does not start. */
    fun isNoteProcess(): Boolean = Application.getProcessName().endsWith(PROCESS)

    /** From now on, such an error is kept and shown instead of Android's "keeps stopping". */
    fun install(context: Context) {
        val app = context.applicationContext
        val system = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, failure ->
            val kept = runCatching {
                save(file(app), details(thread.name, failure))
                app.startActivity(
                    Intent(app, StoppedActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
                )
            }.isSuccess
            if (kept) {
                // The note screen takes over; if Android did not let it open now, the next start shows it.
                Process.killProcess(Process.myPid())
                exitProcess(EXIT_CODE)
            }
            system?.uncaughtException(thread, failure)
        }
    }

    /** The details of the last stop, until the owner closes its screen; null when there is none. */
    fun pending(context: Context): String? = read(file(context))

    fun clear(context: Context) {
        file(context).delete()
    }

    /** What the owner copies: the app and phone, when, and the error with where it happened. */
    fun details(thread: String, failure: Throwable, at: Instant = Instant.now()): String = buildString {
        appendLine("PocketIDE ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
        appendLine("Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}), ${Build.MANUFACTURER} ${Build.MODEL}")
        appendLine("$at, thread $thread")
        appendLine()
        append(failure.stackTraceToString())
    }.take(MAX_CHARS)

    /** Written whole and renamed into place, so a half-written note is never shown. */
    fun save(file: File, text: String) {
        file.parentFile?.mkdirs()
        val temp = File(file.path + ".tmp")
        temp.writeText(text)
        if (!temp.renameTo(file)) {
            file.delete()
            temp.renameTo(file)
        }
    }

    fun read(file: File): String? = runCatching { file.takeIf { it.isFile }?.readText() }.getOrNull()?.takeIf { it.isNotBlank() }

    private fun file(context: Context) = File(context.noBackupFilesDir, FILE)
}
