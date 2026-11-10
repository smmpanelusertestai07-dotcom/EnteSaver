package com.pocketide.ui.components

import com.pocketide.core.Ist
import java.util.Locale
import kotlin.math.roundToLong

/** Numbers and times the way the screens say them: short, rounded, in the phone's own zone. */
object Formats {
    private const val MINUTE = 60_000L
    private const val HOUR = 60 * MINUTE
    private const val DAY = 24 * HOUR
    private const val TWO_DAYS = 2 * DAY
    private const val MONTH = 30 * DAY
    private const val TWO_MONTHS = 2 * MONTH
    private const val MINUTES_PER_HOUR = 60
    private const val KB = 1_000L
    private const val MB = 1_000_000L
    private const val GB = 1_000_000_000L
    private const val WHOLE_FROM = 10

    fun ago(epochMs: Long?, now: Long): String {
        if (epochMs == null) return "never"
        val gone = (now - epochMs).coerceAtLeast(0)
        return when {
            gone < MINUTE -> "just now"
            gone < HOUR -> "${gone / MINUTE} min ago"
            gone < DAY -> "${gone / HOUR} h ago"
            gone < TWO_DAYS -> "yesterday"
            gone < MONTH -> "${gone / DAY} days ago"
            else -> Ist.date(epochMs)
        }
    }

    /** "in 12 days", "tomorrow", "today"; a date further out. */
    fun until(epochMs: Long, now: Long): String {
        val left = epochMs - now
        return when {
            left <= DAY -> "within a day"
            left < TWO_DAYS -> "tomorrow"
            left < TWO_MONTHS -> "in ${left / DAY} days"
            else -> "on ${Ist.date(epochMs)}"
        }
    }

    /** A size the way Android's storage screen says it: decimal units, "850 MB", "2.4 GB". */
    fun size(bytes: Long): String = when {
        bytes >= GB -> String.format(Locale.ENGLISH, "%.1f GB", bytes / GB.toDouble())
        bytes >= MB -> String.format(Locale.ENGLISH, "%.0f MB", bytes / MB.toDouble())
        else -> String.format(Locale.ENGLISH, "%.0f KB", bytes / KB.toDouble())
    }

    /** One decimal below 10, whole numbers above: 3.5 h, 42 h. */
    fun amount(value: Double): String =
        if (value < WHOLE_FROM) String.format(Locale.ENGLISH, "%.1f", value).removeSuffix(".0") else value.roundToLong().toString()

    fun minutes(value: Int): String = when {
        value == MINUTES_PER_HOUR -> "1 hour"
        value > MINUTES_PER_HOUR && value % MINUTES_PER_HOUR == 0 -> "${value / MINUTES_PER_HOUR} hours"
        else -> "$value minutes"
    }

    fun days(value: Int): String = if (value == 1) "1 day" else "$value days"
}
