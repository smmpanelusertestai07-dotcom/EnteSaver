package com.pocketide.linux

import java.io.InputStream
import java.io.InputStreamReader

/** One line printed by bootstrap.sh or update.sh, as the app understands it. */
internal sealed interface GuestLine {
    /** The script's own position, "pocketide-progress <0..100>". */
    data class Progress(val percent: Int) : GuestLine

    /** The script's current step, "pocketide-step <text>", which the progress screen shows. */
    data class Step(val text: String) : GuestLine

    /** apt's status (APT::Status-Fd): a download, or a package being set up. */
    data class Apt(val installing: Boolean, val percent: Float, val text: String) : GuestLine

    /** "Fetched 27.9 MB in 30s": what apt moved over the network. */
    data class Fetched(val bytes: Long) : GuestLine

    /** "pocketide-fixed <count>" from update.sh. */
    data class Fixed(val count: Int) : GuestLine

    /** "pocketide-installed <count>" from bootstrap.sh: tools that were missing and are now installed. */
    data class Installed(val count: Int) : GuestLine

    /** Anything else. */
    data class Text(val text: String) : GuestLine
}

internal object GuestLines {
    private val PROGRESS = Regex("""^pocketide-progress (\d{1,3})$""")
    private val STEP = Regex("""^pocketide-step (.+)$""")
    private val FIXED = Regex("""^pocketide-fixed (\d{1,6})$""")
    private val INSTALLED = Regex("""^pocketide-installed (\d{1,6})$""")
    private val APT = Regex("""^(dlstatus|pmstatus):[^:]*:([0-9.]+):(.*)$""")
    private val FETCHED = Regex("""^Fetched ([0-9.]+) ([kMGT]?)B in """)
    private val ESCAPES = Regex("""\u001B\[[;\d?]*[ -/]*[@-~]""")
    private val CONTROLS = Regex("""[\u0000-\u0008\u000B-\u001F\u007F]""")
    private const val MAX_SHOWN = 160

    fun parse(raw: String): GuestLine {
        val line = clean(raw)
        PROGRESS.matchEntire(line)?.let { return GuestLine.Progress(it.groupValues[1].toInt().coerceIn(0, 100)) }
        STEP.matchEntire(line)?.let { return GuestLine.Step(it.groupValues[1]) }
        FIXED.matchEntire(line)?.let { return GuestLine.Fixed(it.groupValues[1].toInt()) }
        INSTALLED.matchEntire(line)?.let { return GuestLine.Installed(it.groupValues[1].toInt()) }
        APT.matchEntire(line)?.let { match ->
            val percent = match.groupValues[2].toFloatOrNull() ?: 0f
            return GuestLine.Apt(match.groupValues[1] == "pmstatus", percent.coerceIn(0f, 100f), match.groupValues[3].trim())
        }
        FETCHED.find(line)?.let { match ->
            val amount = match.groupValues[1].toDoubleOrNull() ?: 0.0
            return GuestLine.Fetched((amount * scale(match.groupValues[2])).toLong())
        }
        return GuestLine.Text(line)
    }

    /** Terminal colours and control characters are for a terminal; the phone shows plain text. */
    fun clean(raw: String): String {
        val plain = CONTROLS.replace(ESCAPES.replace(raw, ""), "").trim()
        return if (plain.length > MAX_SHOWN) plain.take(MAX_SHOWN - 1) + "…" else plain
    }

    /** apt counts in decimal units, like Android's own storage screen. */
    private fun scale(prefix: String): Double = when (prefix) {
        "k" -> 1e3
        "M" -> 1e6
        "G" -> 1e9
        "T" -> 1e12
        else -> 1.0
    }
}

/**
 * Passes each line of [this] to [onLine] (a trailing CR dropped), splitting any line longer
 * than [maxChars] so that a program printing without newlines cannot fill the app's memory.
 */
internal fun InputStream.forEachLine(maxChars: Int = 16 * 1024, onLine: (String) -> Unit) {
    val reader = InputStreamReader(this, Charsets.UTF_8)
    val line = StringBuilder()
    val buffer = CharArray(8 * 1024)
    while (true) {
        val read = reader.read(buffer)
        if (read < 0) break
        for (i in 0 until read) {
            val c = buffer[i]
            if (c == '\n') {
                if (line.endsWith('\r')) line.setLength(line.length - 1)
                onLine(line.toString())
                line.setLength(0)
            } else {
                if (line.length >= maxChars) {
                    onLine(line.toString())
                    line.setLength(0)
                }
                line.append(c)
            }
        }
    }
    if (line.isNotEmpty()) onLine(line.toString())
}
