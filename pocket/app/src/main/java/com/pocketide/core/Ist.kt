package com.pocketide.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Times are stored as UTC epoch milliseconds everywhere and shown in the phone's own zone
 * (IST for the owner). A clock or time-zone change never alters what was stored.
 */
object Ist {
    private val dateTime = DateTimeFormatter.ofPattern("d MMM yyyy, h:mm a", Locale.ENGLISH)
    private val date = DateTimeFormatter.ofPattern("d MMM yyyy", Locale.ENGLISH)
    private val branchDate = DateTimeFormatter.ofPattern("yyyy-MM-dd", Locale.ROOT)

    fun zone(): ZoneId = ZoneId.systemDefault()

    fun dateTime(epochMs: Long): String = dateTime.format(Instant.ofEpochMilli(epochMs).atZone(zone()))

    fun date(epochMs: Long): String = date.format(Instant.ofEpochMilli(epochMs).atZone(zone()))

    /** The date part of a session branch name, in the phone's zone. */
    fun branchDate(epochMs: Long): String = branchDate.format(Instant.ofEpochMilli(epochMs).atZone(zone()))
}
