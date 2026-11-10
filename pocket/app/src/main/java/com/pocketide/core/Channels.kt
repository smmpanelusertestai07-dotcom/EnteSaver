package com.pocketide.core

/** Notification channel ids. Channels are created once at start-up. */
object Channels {
    /** The ongoing "Connected to Cloud Shell" notice with its Disconnect button. */
    const val CONNECTION = "connection"

    /** A file from Cloud Shell on its way to the phone's Downloads, then done (tap: open or install). */
    const val DOWNLOADS = "downloads"
}

/**
 * Notification ids, all in one place: Android replaces a notification posted with the same id,
 * so two kinds of notice sharing one would overwrite each other.
 */
object NotificationIds {
    /** The connection service's ongoing notice (its foreground notification). */
    const val CONNECTION = 4201

    /** Each download's notice: this plus the download's number (see [com.pocketide.downloads.Downloads]). */
    const val DOWNLOADS = 5000
}
