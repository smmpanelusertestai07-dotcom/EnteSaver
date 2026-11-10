package com.pocketide.core

import com.pocketide.agents.AddedAgent
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

@Serializable
enum class ThemeMode { SYSTEM, LIGHT, DARK }

/**
 * The owner's choices, kept on this phone only. A newer version's extra fields are ignored by an
 * older one, and fields an older version wrote that this one no longer knows are dropped.
 */
@Serializable
data class Settings(
    val theme: ThemeMode = ThemeMode.SYSTEM,
    /** Colours from the wallpaper (Android 12 and newer) instead of PocketIDE's violet. */
    val dynamicColor: Boolean = false,
    /** The version of the terms the owner accepted; 0 = not yet. */
    val termsAccepted: Int = 0,
    val onboardingDone: Boolean = false,
    /** Ask for the phone's screen lock when the app opens, and cover the app in Recents. */
    val appLock: Boolean = false,
    /** The Google account Cloud Shell opens with, picked in Android's own account chooser; empty = not yet. */
    val cloudAccount: String = "",
    /** When the owner said Cloud Shell's set-up had finished (UTC epoch ms); 0 = not yet. */
    val cloudSetUpAt: Long = 0,
    /** When PocketIDE last opened Cloud Shell (UTC epoch ms): Google deletes its home after 120 days unused. */
    val cloudOpenedAt: Long = 0,
    /** The commit of the set-up script the owner last ran; a newer app version may bring a newer one. */
    val cloudScript: String = "",
    /** The Google account gcloud signed in with on this phone, for PocketIDE's connection; empty = not yet. */
    val gcloudAccount: String = "",
    /**
     * The secret in every address of PocketIDE's private door to Cloud Shell's ports (32 hex
     * characters), and the phone port that door listens on. Kept, so the pages' cache stays valid.
     */
    val proxyKey: String = "",
    val proxyPort: Int = 0,
    /**
     * When PocketIDE's connection to Cloud Shell was up in the last 8 days: start and end (UTC epoch
     * ms) of each time, one after the other. Usage adds them up against Google's weekly hours.
     */
    val connectedTimes: List<Long> = emptyList(),
    /** The keys a phone keyboard lacks stay above the screen's foot, keyboard or not (Tools > Keys bar). */
    val keysAlways: Boolean = false,
    /** The AI agents the owner added, as Cloud Shell last said (Home lists them while not connected). */
    val addedAgents: List<AddedAgent> = emptyList(),
)

/** The connection's last 8 days of [Settings.connectedTimes], with [start] to [end] added. */
fun Settings.withConnectedTime(start: Long, end: Long): Settings {
    val keep = end - CONNECTED_TIMES_KEPT_MS
    val pairs = connectedTimes.chunked(2).filter { it.size == 2 && it[1] >= keep } + listOf(listOf(start, end))
    return copy(connectedTimes = pairs.takeLast(CONNECTED_TIMES_MAX).flatten())
}

/** How long, of the [windowMs] before [now], the connection was up ([openSince]: up since then, still). */
fun Settings.connectedFor(now: Long, windowMs: Long, openSince: Long? = null): Long {
    val from = now - windowMs
    val times = connectedTimes.chunked(2).filter { it.size == 2 }.map { it[0] to it[1] } +
        listOfNotNull(openSince?.let { it to now })
    return times.sumOf { (start, end) -> (minOf(end, now) - maxOf(start, from)).coerceAtLeast(0) }
}

private const val CONNECTED_TIMES_KEPT_MS = 8 * 24 * 60 * 60 * 1000L
private const val CONNECTED_TIMES_MAX = 500

/** The settings after "Delete everything": every choice back to its default. */
fun Settings.afterDeleteEverything(): Settings = Settings()

/** Settings on this phone, observed by every screen and module. */
interface SettingsStore {
    val settings: StateFlow<Settings>
    fun update(change: (Settings) -> Settings)
}
