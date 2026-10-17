package app.entesaver.core.logic

/**
 * Item lifecycle. GONE carries a [GoneReason]; a maintain pass promotes GONE to DONE.
 *
 * FREED and FREED_KEPT are both "the user reclaimed this original", kept apart
 * because they leave the phone in different states: FREED_KEPT means a light
 * copy is still in the gallery, so the file is still there to look at.
 */
enum class ItemState {
    NEW, STAGED, RELEASED, GONE, DONE, SKIP, FREED, FREED_KEPT, UNKNOWN;

    /** True once the user has reclaimed the original, either way. */
    val isReclaimed: Boolean get() = this == FREED || this == FREED_KEPT
}

enum class GoneReason { CONFIRMED, APP_DELETED, USER_DELETED }

/**
 * How well the app knows a released copy reached the cloud. Ordinal order is
 * strength order, so `maxOf` picks the better of two findings.
 *
 *  - AGED            time alone; no network evidence at all
 *  - VERIFIED        a whole batch's bytes were transmitted
 *  - CONFIRMED_PACED the copy went out alone and the transmitted bytes match
 *                    its size before anything else was sent
 *  - CONFIRMED_EXACT the copy vanished from the upload folder, the app did
 *                    not remove it, and its bytes were transmitted
 */
enum class Evidence {
    NONE, AGED, VERIFIED, CONFIRMED_PACED, CONFIRMED_EXACT;

    /** True for the two per-file grades that may offer an original for reclaim. */
    val isPerFile: Boolean get() = this == CONFIRMED_PACED || this == CONFIRMED_EXACT

    companion object {
        /**
         * Rows written before the two grades existed say "CONFIRMED"; those
         * came from the disappearance check, which is now CONFIRMED_EXACT.
         */
        fun parse(name: String?): Evidence = when (name) {
            null, "" -> NONE
            "CONFIRMED" -> CONFIRMED_EXACT
            else -> entries.firstOrNull { it.name == name } ?: NONE
        }
    }
}

enum class BackupScope { ALL, PHOTOS, VIDEOS }

enum class OutputMode { SINGLE, SEPARATE }

/**
 * Where an optimised file goes.
 *
 * IN_PLACE replaces each original where it is - same file, same name, same
 * album - keeping the original in the phone's trash for 30 days; Ente
 * Photos, backing that album up, uploads the smaller version over the one it
 * holds. COPIES puts optimised copies in Ente Saver's own folder for Ente to
 * back up, as much a day as the daily limit allows, and leaves the originals
 * until they are freed. Installs set up before 14 stay on COPIES.
 */
enum class SaveMode { IN_PLACE, COPIES }

/** Scheduling mode (13.G). SMART is the default. */
enum class SpeedMode { SMART, CHARGING_ONLY, FAST }

enum class Preset { STORAGE_SAVER, BALANCED, MAX_SAVER }

enum class VideoCodec { H264, HEVC }

enum class ThemeMode { SYSTEM, LIGHT, DARK }

/** Which public output folder a released copy lives in. */
enum class OutFolder { SINGLE, PHOTOS, VIDEOS }

object Defaults {
    // Every choice below is a round decimal number, because [MB] is decimal
    // and a chip labelled "2 GB" has to store the number the Storage screen
    // will later print. 1024 and 1536 were binary leftovers: picking "1 GB"
    // used to produce a limit the app reported as 1.07 GB.
    const val DAILY_CAP_MB = 250
    val DAILY_CAP_CHOICES_MB = listOf(250, 500, 1000, 2000, -1) // -1 = unlimited

    const val MAX_EXTRA_MB = 1500
    val MAX_EXTRA_CHOICES_MB = listOf(1500, 3000, 5000, -1) // -1 = unlimited

    const val MIN_FREE_MB = 1500
    val MIN_FREE_CHOICES_MB = listOf(1500, 3000, 5000)

    /**
     * Maps a value stored by an older build onto the chip list it belongs to.
     *
     * Upgrading someone whose cap is 1536 must not leave every chip unselected
     * - a control with nothing highlighted reads as "not configured", and the
     * obvious fix is to reset it, which silently changes their limit.
     */
    fun snapToChoice(storedMb: Int, choices: List<Int>): Int = when {
        storedMb < 0 -> storedMb
        storedMb in choices -> storedMb
        else -> choices.filter { it > 0 }.minByOrNull { kotlin.math.abs(it - storedMb) }
            ?: storedMb
    }

    const val KEEP_MIN_DAYS = 5
    const val AGED_DAYS = 10
    const val MAX_RUN_MIN = 40
    const val BATTERY_MAX_TEMP_TENTHS_C = 420 // 42.0 °C

    // Scheduling (13.G).
    const val SMART_BATTERY_FLOOR = 30
    const val FAST_BATTERY_FLOOR = 25
    /** Charging floor for video encodes, and the hard floor for "Run now". */
    const val CHARGING_BATTERY_FLOOR = 15
    const val SMART_BUDGET_MS = 30 * 60_000L // 30 min of on-battery encoding
    const val FAST_BUDGET_MS = 60 * 60_000L
    const val SMART_SCREEN_OFF_WAIT_MS = 2 * 60_000L
    const val PHOTO_CAP_ON_BATTERY = 200

    const val FGS_BUDGET_MS = 19_800_000L // 5.5 h per rolling 24 h
    const val FGS_WINDOW_MS = 86_400_000L

    /**
     * How long after "Confirm uploads" opened Ente its return is still
     * believed. Freeing up space takes minutes; a day was long enough for a
     * person to clear the folder by hand and have that counted as uploads.
     */
    const val CONFIRM_WINDOW_MS = 3_600_000L

    const val SAFETY_TX_MIN_BYTES = 5L * 1024 * 1024 // below this over 3 days => "TX ~ 0"
    const val SAFETY_TX_DAYS = 3

    const val STAGE_CAP_FACTOR = 2 // stage dir may hold at most 2 x DAILY_CAP

    /**
     * One megabyte, decimal.
     *
     * The settings offer "500 MB" and the screen has to read back "500 MB".
     * With the binary megabyte it did not: 500 x 1048576 formatted as 524 MB,
     * because sizes are shown in the decimal units cloud plans are sold in.
     * A limit the user picked and a limit the app reports must be the same
     * number, so both sides count the same way.
     */
    const val MB = 1_000_000L

    // Pictures (never DCIM): keeps Ente's camera backup, if it is on, from
    // grabbing originals. The default for a new install; someone upgrading
    // stays on the folder they had until they move (OptionsRepo).
    const val OUTPUT_DIR = "Pictures/EnteSaver"

    /**
     * The folder every version before 11 released into. Still watched for as
     * long as a copy waits there, and the name existing installs keep until
     * the person moves to the new one themselves.
     */
    const val LEGACY_OUTPUT_DIR = "Pictures/CloudSaver"
    const val LEGACY_OUTPUT_DIR_PHOTOS = "Pictures/CloudSaver/Photos"
    const val LEGACY_OUTPUT_DIR_VIDEOS = "Pictures/CloudSaver/Videos"

    /**
     * Where a "Replace with light copy" file lives.
     *
     * Deliberately outside the app's own folder and plainly named: these are
     * the user's photos now, not Ente Saver's working files. An album named
     * after the app would read as something to delete when the app goes, and
     * the whole point is that they outlive it.
     */
    const val KEPT_DIR = "Pictures/Light copies"
    const val OUTPUT_DIR_PHOTOS = "Pictures/EnteSaver/Photos"
    const val OUTPUT_DIR_VIDEOS = "Pictures/EnteSaver/Videos"
    /**
     * The daily history file: one visible file, history.json, in an
     * "Ente Saver" folder under Documents - under Download on a phone that
     * refuses Documents.
     *
     * Visible on purpose. Android lets an app find a non-media file in shared
     * storage only while the install that wrote it exists: after an uninstall
     * or "Clear data" the file is still there, but the new install cannot see
     * it by itself. It can open a file the person picks - and the system file
     * picker hides hidden folders. So the file sits where Restore, on the
     * first setup screen, opens. (Android also renames a hidden folder an app
     * asks for: ".x" becomes "_.x". That is how the hidden copies written
     * before 12.0 were never found again, and multiplied.)
     */
    const val HISTORY_DIR = "Documents/Ente Saver"
    const val HISTORY_DIR_FALLBACK = "Download/Ente Saver"
    const val HISTORY_NAME = "history.json"

    /** Where the history file goes, in the order tried: the first that takes it is used. */
    val SNAPSHOT_TARGETS: List<Pair<String, String>> = listOf(
        HISTORY_DIR to HISTORY_NAME,
        HISTORY_DIR_FALLBACK to HISTORY_NAME
    )

    /**
     * The hidden folders builds before 12.0 asked for, under both the name
     * asked for and the name Android gave them. Whatever this app wrote there
     * is read on an upgrade and removed once history.json exists.
     */
    val PREVIOUS_SNAPSHOT_DIRS: List<String> = listOf(
        "Documents/.cloudsaver", "Download/.cloudsaver",
        "Documents/_.cloudsaver", "Download/_.cloudsaver"
    )

    /** Older builds wrote here. Read on upgrade, never written again. */
    const val SNAPSHOT_DIR_LEGACY_OUTPUT = "Pictures/CloudSaver/.cloudsaver"
    const val SNAPSHOT_DIR_LEGACY_DOTFILE = "Pictures/CloudSaver"
    const val SNAPSHOT_DIR_LEGACY_VISIBLE = "Documents/CloudSaver"

    const val SNAPSHOT_NAME = "state.json"
    const val SNAPSHOT_NAME_DOTFILE = ".cloudsaver.json"
    const val SNAPSHOT_NAME_VISIBLE = "backup.json"

    /** The app-private copy, relative to the app's own files dir. */
    const val SNAPSHOT_PRIVATE_NAME = "state.json"

    /**
     * Where older builds wrote the automatic snapshot. Read-only: recovery
     * still looks here so an upgrade keeps its state, but nothing is written
     * here again and the file is removed once it is no longer needed.
     */
    val LEGACY_SNAPSHOT_TARGETS: List<Pair<String, String>> = listOf(
        SNAPSHOT_DIR_LEGACY_OUTPUT to SNAPSHOT_NAME,
        SNAPSHOT_DIR_LEGACY_DOTFILE to SNAPSHOT_NAME_DOTFILE,
        SNAPSHOT_DIR_LEGACY_VISIBLE to SNAPSHOT_NAME,
        SNAPSHOT_DIR_LEGACY_VISIBLE to SNAPSHOT_NAME_VISIBLE
    )

    /** Where a copy of this kind went before a row recorded its own folder. */
    fun legacyRelPath(folder: OutFolder): String = when (folder) {
        OutFolder.SINGLE -> LEGACY_OUTPUT_DIR
        OutFolder.PHOTOS -> LEGACY_OUTPUT_DIR_PHOTOS
        OutFolder.VIDEOS -> LEGACY_OUTPUT_DIR_VIDEOS
    }

    /**
     * SQL pattern for "inside the old output folder". The trailing slash
     * matters: without it, an unrelated user folder such as
     * Pictures/CloudSaverBackup would match too.
     */
    const val LEGACY_OUTPUT_DIR_LIKE = "$LEGACY_OUTPUT_DIR/%"

    /** True for any folder light copies are released into, old or current. */
    fun isOutputPath(relativePath: String?): Boolean = OutputRoots.isOwned(relativePath)

    /** True for the kept light copies album. */
    fun isKeptPath(relativePath: String?): Boolean {
        if (relativePath.isNullOrEmpty()) return false
        val path = relativePath.trimEnd('/')
        return path == KEPT_DIR || path.startsWith("$KEPT_DIR/")
    }

    /**
     * Folders the scanner must never queue: our working folder and the light
     * copies. Re-optimising either would loop forever, and a light copy is a
     * finished user file, not a candidate.
     */
    fun isAppOwnedPath(relativePath: String?): Boolean =
        isOutputPath(relativePath) || isKeptPath(relativePath)
}

/**
 * The first-run proof of the whole chain (Z10.6).
 *
 * Setup can be perfect and the chain still dead - the cloud app not watching
 * the folder, or simply never having run. The one moment that proves
 * everything is the first confirmation; the one moment that disproves it is
 * 48 hours of silence after the first copy went out. Both get exactly one
 * card, and the stalled one names the two likely causes instead of a shrug.
 */
object FirstChain {

    const val STALL_MS: Long = 48L * 3_600_000

    /** "": nothing to show. SUCCESS/STALLED: card pending. DONE: dismissed. */
    fun next(
        state: String,
        firstReleaseAt: Long,
        confirmedCount: Int,
        now: Long
    ): String = when {
        state == "DONE" -> "DONE"
        confirmedCount > 0 && state != "SUCCESS" && state != "DONE" -> "SUCCESS"
        state.isEmpty() && firstReleaseAt > 0 &&
            confirmedCount == 0 && now - firstReleaseAt >= STALL_MS -> "STALLED"
        else -> state
    }
}
