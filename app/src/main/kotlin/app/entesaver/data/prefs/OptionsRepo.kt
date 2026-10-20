package app.entesaver.data.prefs

import android.annotation.SuppressLint
import android.content.Context
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.entesaver.core.logic.BackupScope
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.DeviceDefaults
import app.entesaver.core.logic.EvidenceRules
import app.entesaver.core.logic.FolderName
import app.entesaver.core.logic.OutFolder
import app.entesaver.core.logic.OutputLayout
import app.entesaver.core.logic.OutputMode
import app.entesaver.core.logic.OutputRoots
import app.entesaver.core.logic.SaveMode
import app.entesaver.core.logic.SpeedMode
import app.entesaver.core.logic.ThemeMode
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext

/**
 * A damaged options file is started afresh rather than thrown on every read:
 * otherwise each start, background wakes included, crashes until the person
 * clears the app's storage. Starting afresh asks setup again and claims no
 * proof; the history in the database is untouched.
 */
private val Context.dataStore by preferencesDataStore(
    name = "options",
    corruptionHandler = ReplaceFileCorruptionHandler { emptyPreferences() }
)

/** All user options (section 6) + small persisted runtime state. */
data class Options(
    val scope: BackupScope = BackupScope.ALL,
    val excludedBuckets: Set<String> = emptySet(),
    val outputMode: OutputMode = OutputMode.SINGLE,
    /**
     * The person's own folder for each kind of copy, as a relative path
     * ("Pictures/My photos"), or "" for the default. See [OutputLayout].
     */
    val folderSingle: String = "",
    val folderPhotos: String = "",
    val folderVideos: String = "",
    /**
     * Folders copies were released into before the person changed where they
     * go. Watched until no copy waits there any more, then dropped with a
     * one-time note that Ente can stop backing that folder up.
     */
    val pastOutputRoots: Set<String> = emptySet(),
    /** An existing install's folders were checked against the new default. */
    val foldersPinned: Boolean = false,
    /** "Not now" on the card that offers the new folder. */
    val moveCardDismissed: Boolean = false,
    /**
     * Copies go to a folder they did not go to before. Ente backs up only the
     * folders turned on in it, so until the person says it is done, Home
     * names the folder and where in Ente to turn it on.
     */
    val newFolderPending: Boolean = false,
    /**
     * The cloud app an earlier version was set to. Ente Saver works with Ente
     * Photos only; anything else here means the person used another app
     * before 11, and Home says once what changed. Set to "ente" when read.
     */
    val cloudSingle: String = "ente",
    val speed: SpeedMode = SpeedMode.SMART,
    /** Where optimised files go ([SaveMode]); an install set up before 14 reads as COPIES. */
    val saveMode: SaveMode = SaveMode.IN_PLACE,
    /**
     * The three space limits below follow the phone's storage (the default),
     * or hold the person's own figures. An install from before 11.1 that never
     * set one counts as Automatic.
     */
    val spaceAuto: Boolean = true,
    val dailyCapMb: Int = Defaults.DAILY_CAP_MB,
    val minFreeMb: Int = Defaults.MIN_FREE_MB,
    val maxExtraMb: Int = Defaults.MAX_EXTRA_MB,
    val theme: ThemeMode = ThemeMode.SYSTEM,
    val dynamicColor: Boolean = false,
    /** MediaStore volume for stage + output; "" = internal (primary). */
    val storageVolume: String = "",
    val appLock: Boolean = false,
    val warningsNotif: Boolean = true,
    /** A legacy placeholder image was cleaned up; show the notice once. */
    val placeholderRemoved: Boolean = false,
    /** The double-backup warning was read during setup (Z5.2). */
    val doubleBackupAck: Boolean = false,
    /** When the very first copy entered the upload folder (Z10.6). */
    val firstReleaseAt: Long = 0,
    /** Files in the upload folder that Ente Saver did not create (DD2.1). */
    val foreignFiles: Int = 0,
    /**
     * A snapshot restore has already been attempted on this install.
     *
     * Restoring is a once-per-install event, not a state to sit in: the old
     * rule ("whenever the item table is empty") re-ran on every launch until
     * the first file was optimised, and each run re-imported the snapshot's
     * settings over choices the user had just made.
     */
    val restoreDone: Boolean = false,
    /** The one-time Kept-light-copies explanation was read (DD2.3). */
    val keptCardSeen: Boolean = false,
    /** "": chain unproven. "SUCCESS"/"STALLED": card pending. "DONE": dismissed. */
    val firstChainState: String = "",
    val freeUpAllowVerified30: Boolean = false,
    /**
     * Where a light copy lands when an original is replaced.
     *
     * False (the default): its own album, Pictures/Light copies, which is
     * outside everything the scanner touches. True: the album the original
     * was in, carrying the original's date so the gallery timeline does not
     * move - the photo stays where it was and is simply smaller.
     */
    val keptInPlace: Boolean = false,
    val pauseAll: Boolean = false,
    // runtime / bookkeeping
    val onboardingDone: Boolean = false,
    val onboardingStep: Int = 0,
    val lastRunAt: Long = 0,
    /**
     * When a pass Android started last chose to wait on purpose - Battery
     * Saver on, no charger in charging-only mode, the day's allowance spent.
     * Separate from [lastRunAt] because that is the app keeping its word,
     * not the phone stopping it; told apart by nothing, two days of Battery
     * Saver became "the phone keeps stopping Ente Saver".
     */
    val lastWakeAt: Long = 0,
    /**
     * Why Android ended the last run, when Android ended it.
     *
     * Empty means the run finished on its own terms. Anything else is the
     * platform's own stop reason, and it is kept because a run the system cut
     * short still stamps [lastRunAt] - so every "is it running?" check stayed
     * green while the app completed a fraction of the work. Android 16 made
     * that the normal case rather than the rare one: a job running alongside
     * a foreground service is now inside the JobScheduler runtime quota, so
     * the app's own 40-minute window and its foreground-service ledger are no
     * longer the binding limit.
     */
    val lastStopReason: String = "",
    val lastSnapshotDay: String = "",
    val fgsSessions: String = "",
    /** Last time the app observed the screen ON (13.G screen-off wait). */
    val lastInteractiveAt: Long = 0,
    /** Latest RunDecider.Wait name, shown on Home in plain English. */
    val waitReason: String = "NONE",
    val agedWarned: Boolean = false,
    val safetyPauseWarnedAt: Long = 0,
    val volumeWarnedAt: Long = 0,
    val oldFilesCleaned: Boolean = false,
    val copiesReattached: Boolean = false,
    /** When a history file last brought rows back (ReattachRules.watching). */
    val restoredAt: Long = 0,
    /** Rows an older restore left inconsistent were set right (StartupRecovery). */
    val queueRepaired: Boolean = false,
    /**
     * Row ids of copies the maintenance pass chose to clear and could not.
     *
     * A copy adopted after a reinstall or a phone move belongs to the
     * install that made it, not this one, and Android refuses a silent
     * delete of somebody else's file. Those copies still counted against
     * the space the user allowed, so once enough of them piled up the
     * resource gate stopped every run - for good, because nothing could
     * ever remove them. They are listed here so Home can ask, once, through
     * Android's own dialog.
     */
    val copiesNeedConsent: Set<String> = emptySet(),
    /**
     * Consecutive per-file confirmations with no failure in between.
     *
     * The release pacing ladder climbs on this: proving the accounting works
     * on this phone is what earns the right to stop holding files back.
     */
    val cleanConfirmStreak: Int = 0,
    /** Files released since the last one sent alone as a proof sample. */
    val releasedSinceSample: Int = 0,
    /** A confirmation failed recently, so samples are taken twice as often. */
    val recentPacingFailure: Boolean = false,
    /** Files seen in the upload folder last pass, so a shrink is detectable. */
    val lastOutputCount: Int = 0,
    /** Active CloudWatchdog.Problem name, or "" when the cloud looks healthy. */
    val cloudProblem: String = "",
    /** Alerts are silenced until this instant ("Mute for 7 days"). */
    val alertsMutedUntil: Long = 0,
    /**
     * When each kind of alert was last posted - the 24 h de-duplication
     * record, one line per kind, as written by Notifications.
     *
     * It used to be a single key-and-time pair, which could only remember the
     * most recent alert. Two problems on the same day overwrote each other's
     * record, and each was then free to post again straight away: a phone
     * with a full cloud and a paused safety check could buzz twice an hour
     * all day, which is exactly what the once-a-day rule exists to stop.
     */
    val lastAlerts: String = "",
    /** Newest Activity row the user has actually looked at. */
    val activitySeenAt: Long = 0,
    /** Days carried over when a day's upload allowance went unused. */
    val catchUpBytes: Long = 0,
    val catchUpDay: String = "",
    /** The one-time "I understand" tick before the first reclaim batch. */
    val reclaimUnderstood: Boolean = false,
    /** The freeable total the last "space can be freed" note named (FreeableNote); 0 = none. */
    val freeableSaidBytes: Long = 0,
    /** How many "the phone stopped background work" alerts have been posted, ever. */
    val stallAlerts: Int = 0,
    /** When the last of them was posted. */
    val stallAlertAt: Long = 0,
    /**
     * The open "Confirm uploads" tap, or null. Stored so the return from
     * Ente is judged even when the phone ended this process meanwhile; every
     * pass reads it only to leave those copies alone (EvidenceRules).
     */
    val confirmWindow: EvidenceRules.ConfirmWindow? = null
) {
    val dailyCapBytes: Long get() = if (dailyCapMb < 0) -1 else dailyCapMb * Defaults.MB
    val minFreeBytes: Long get() = minFreeMb * Defaults.MB
    val maxExtraBytes: Long get() = if (maxExtraMb < 0) -1 else maxExtraMb * Defaults.MB
    val layout: OutputLayout get() = OutputLayout(outputMode, folderSingle, folderPhotos, folderVideos)
}

class OptionsRepo(private val context: Context) {

    object K {
        val SCOPE = stringPreferencesKey("scope")
        val EXCLUDED_BUCKETS = stringSetPreferencesKey("excludedBuckets")
        val OUTPUT_MODE = stringPreferencesKey("outputMode")
        val FOLDER_SINGLE = stringPreferencesKey("folderSingle")
        val FOLDER_PHOTOS = stringPreferencesKey("folderPhotos")
        val FOLDER_VIDEOS = stringPreferencesKey("folderVideos")
        val PAST_OUTPUT_ROOTS = stringSetPreferencesKey("pastOutputRoots")
        val FOLDERS_PINNED = booleanPreferencesKey("foldersPinned")
        val MOVE_CARD_DISMISSED = booleanPreferencesKey("moveCardDismissed")
        val NEW_FOLDER_PENDING = booleanPreferencesKey("newFolderPending")
        val CLOUD_SINGLE = stringPreferencesKey("cloudSingle")
        val SPEED = stringPreferencesKey("speed")
        val SAVE_MODE = stringPreferencesKey("saveMode")
        val SPACE_AUTO = booleanPreferencesKey("spaceAuto")
        /** What Automatic worked out last; the three keys below stay the person's own (Custom). */
        val AUTO_DAILY_CAP_MB = intPreferencesKey("autoDailyCapMb")
        val AUTO_MIN_FREE_MB = intPreferencesKey("autoMinFreeMb")
        val AUTO_MAX_EXTRA_MB = intPreferencesKey("autoMaxExtraMb")
        val DAILY_CAP_MB = intPreferencesKey("dailyCapMb")
        val MIN_FREE_MB = intPreferencesKey("minFreeMb")
        val MAX_EXTRA_MB = intPreferencesKey("maxExtraMb")
        /** The single preset and codec before 11: read only to derive the two below. */
        val THEME = stringPreferencesKey("theme")
        val DYNAMIC_COLOR = booleanPreferencesKey("dynamicColor")
        val STORAGE_VOLUME = stringPreferencesKey("storageVolume")
        val APP_LOCK = booleanPreferencesKey("appLock")
        val WARNINGS_NOTIF = booleanPreferencesKey("warningsNotif")
        val FREE_UP_VERIFIED30 = booleanPreferencesKey("freeUpAllowVerified30")
        val KEPT_IN_PLACE = booleanPreferencesKey("keptInPlace")
        val PAUSE_ALL = booleanPreferencesKey("pauseAll")
        val ONBOARDING_DONE = booleanPreferencesKey("onboardingDone")
        val PLACEHOLDER_REMOVED = booleanPreferencesKey("placeholderRemoved")
        val DOUBLE_BACKUP_ACK = booleanPreferencesKey("doubleBackupAck")
        val FIRST_RELEASE_AT = longPreferencesKey("firstReleaseAt")
        val FOREIGN_FILES = intPreferencesKey("foreignFiles")
        val RESTORE_DONE = booleanPreferencesKey("restoreDone")
        val KEPT_CARD_SEEN = booleanPreferencesKey("keptCardSeen")
        val FIRST_CHAIN_STATE = stringPreferencesKey("firstChainState")
        val ONBOARDING_STEP = intPreferencesKey("onboardingStep")
        val LAST_RUN_AT = longPreferencesKey("lastRunAt")
        val LAST_WAKE_AT = longPreferencesKey("lastWakeAt")
        val LAST_STOP_REASON = stringPreferencesKey("lastStopReason")
        val LAST_SNAPSHOT_DAY = stringPreferencesKey("lastSnapshotDay")
        val FGS_SESSIONS = stringPreferencesKey("fgsSessions")
        val LAST_INTERACTIVE_AT = longPreferencesKey("lastInteractiveAt")
        val WAIT_REASON = stringPreferencesKey("waitReason")
        val AGED_WARNED = booleanPreferencesKey("agedWarned")
        val SAFETY_WARNED_AT = longPreferencesKey("safetyPauseWarnedAt")
        val VOLUME_WARNED_AT = longPreferencesKey("volumeWarnedAt")
        val OLD_FILES_CLEANED = booleanPreferencesKey("oldFilesCleaned")
        // Renamed in 12.0 so that every phone matches its copies up once
        // more: rows restored earlier without proof were never looked at again.
        val COPIES_REATTACHED = booleanPreferencesKey("copiesReattached12")
        val RESTORED_AT = longPreferencesKey("historyRestoredAt")
        val QUEUE_REPAIRED = booleanPreferencesKey("queueRepaired122")
        val COPIES_NEED_CONSENT = stringSetPreferencesKey("copiesNeedConsent")
        val CLEAN_STREAK = intPreferencesKey("cleanConfirmStreak")
        val RELEASED_SINCE_SAMPLE = intPreferencesKey("releasedSinceSample")
        val RECENT_PACING_FAILURE = booleanPreferencesKey("recentPacingFailure")
        val LAST_OUTPUT_COUNT = intPreferencesKey("lastOutputCount")
        val CLOUD_PROBLEM = stringPreferencesKey("cloudProblem")
        val ALERTS_MUTED_UNTIL = longPreferencesKey("alertsMutedUntil")
        val LAST_ALERTS = stringPreferencesKey("lastAlerts")
        val ACTIVITY_SEEN_AT = longPreferencesKey("activitySeenAt")
        val CATCH_UP_BYTES = longPreferencesKey("catchUpBytes")
        val CATCH_UP_DAY = stringPreferencesKey("catchUpDay")
        val RECLAIM_UNDERSTOOD = booleanPreferencesKey("reclaimUnderstood")
        val FREEABLE_SAID_BYTES = longPreferencesKey("freeableSaidBytes")
        val STALL_ALERTS = intPreferencesKey("stallAlerts")
        val STALL_ALERT_AT = longPreferencesKey("stallAlertAt")
        val CONFIRM_OPENED_AT = longPreferencesKey("confirmWindowOpenedAt")
        val CONFIRM_PRESENT = stringSetPreferencesKey("confirmWindowPresent")
    }

    val flow: Flow<Options> = context.dataStore.data.map { p ->
        Options(
            scope = enumOr(p[K.SCOPE], BackupScope.ALL),
            excludedBuckets = p[K.EXCLUDED_BUCKETS] ?: emptySet(),
            outputMode = enumOr(p[K.OUTPUT_MODE], OutputMode.SINGLE),
            folderSingle = p[K.FOLDER_SINGLE] ?: "",
            folderPhotos = p[K.FOLDER_PHOTOS] ?: "",
            folderVideos = p[K.FOLDER_VIDEOS] ?: "",
            pastOutputRoots = p[K.PAST_OUTPUT_ROOTS] ?: emptySet(),
            foldersPinned = p[K.FOLDERS_PINNED] ?: false,
            moveCardDismissed = p[K.MOVE_CARD_DISMISSED] ?: false,
            newFolderPending = p[K.NEW_FOLDER_PENDING] ?: false,
            cloudSingle = p[K.CLOUD_SINGLE] ?: "ente",
            speed = enumOr(p[K.SPEED], SpeedMode.SMART),
            // Nothing stored and set up already: an install from before 14,
            // which keeps making copies until its owner chooses otherwise.
            saveMode = enumOr(
                p[K.SAVE_MODE], if (p[K.ONBOARDING_DONE] == true) SaveMode.COPIES else SaveMode.IN_PLACE
            ),
            spaceAuto = spaceAutoOf(p),
            // Snapped, so a limit stored by an older build still lands on one
            // of the chips instead of leaving the control looking unset.
            dailyCapMb = Defaults.snapToChoice(
                limitOf(p, K.DAILY_CAP_MB, K.AUTO_DAILY_CAP_MB) ?: Defaults.DAILY_CAP_MB, Defaults.DAILY_CAP_CHOICES_MB
            ),
            minFreeMb = Defaults.snapToChoice(
                limitOf(p, K.MIN_FREE_MB, K.AUTO_MIN_FREE_MB) ?: Defaults.MIN_FREE_MB, Defaults.MIN_FREE_CHOICES_MB
            ),
            maxExtraMb = Defaults.snapToChoice(
                limitOf(p, K.MAX_EXTRA_MB, K.AUTO_MAX_EXTRA_MB) ?: Defaults.MAX_EXTRA_MB, Defaults.MAX_EXTRA_CHOICES_MB
            ),
            theme = enumOr(p[K.THEME], ThemeMode.SYSTEM),
            dynamicColor = p[K.DYNAMIC_COLOR] ?: false,
            storageVolume = p[K.STORAGE_VOLUME] ?: "",
            appLock = p[K.APP_LOCK] ?: false,
            warningsNotif = p[K.WARNINGS_NOTIF] ?: true,
            placeholderRemoved = p[K.PLACEHOLDER_REMOVED] ?: false,
            doubleBackupAck = p[K.DOUBLE_BACKUP_ACK] ?: false,
            firstReleaseAt = p[K.FIRST_RELEASE_AT] ?: 0,
            foreignFiles = p[K.FOREIGN_FILES] ?: 0,
            restoreDone = p[K.RESTORE_DONE] ?: false,
            keptCardSeen = p[K.KEPT_CARD_SEEN] ?: false,
            firstChainState = p[K.FIRST_CHAIN_STATE] ?: "",
            freeUpAllowVerified30 = p[K.FREE_UP_VERIFIED30] ?: false,
            keptInPlace = p[K.KEPT_IN_PLACE] ?: false,
            pauseAll = p[K.PAUSE_ALL] ?: false,
            onboardingDone = p[K.ONBOARDING_DONE] ?: false,
            onboardingStep = p[K.ONBOARDING_STEP] ?: 0,
            lastRunAt = p[K.LAST_RUN_AT] ?: 0,
            lastWakeAt = p[K.LAST_WAKE_AT] ?: 0,
            lastStopReason = p[K.LAST_STOP_REASON] ?: "",
            lastSnapshotDay = p[K.LAST_SNAPSHOT_DAY] ?: "",
            fgsSessions = p[K.FGS_SESSIONS] ?: "",
            lastInteractiveAt = p[K.LAST_INTERACTIVE_AT] ?: 0,
            waitReason = p[K.WAIT_REASON] ?: "NONE",
            agedWarned = p[K.AGED_WARNED] ?: false,
            safetyPauseWarnedAt = p[K.SAFETY_WARNED_AT] ?: 0,
            volumeWarnedAt = p[K.VOLUME_WARNED_AT] ?: 0,
            oldFilesCleaned = p[K.OLD_FILES_CLEANED] ?: false,
            copiesReattached = p[K.COPIES_REATTACHED] ?: false,
            restoredAt = p[K.RESTORED_AT] ?: 0,
            queueRepaired = p[K.QUEUE_REPAIRED] ?: false,
            copiesNeedConsent = p[K.COPIES_NEED_CONSENT] ?: emptySet(),
            cleanConfirmStreak = p[K.CLEAN_STREAK] ?: 0,
            releasedSinceSample = p[K.RELEASED_SINCE_SAMPLE] ?: 0,
            recentPacingFailure = p[K.RECENT_PACING_FAILURE] ?: false,
            lastOutputCount = p[K.LAST_OUTPUT_COUNT] ?: 0,
            cloudProblem = p[K.CLOUD_PROBLEM] ?: "",
            alertsMutedUntil = p[K.ALERTS_MUTED_UNTIL] ?: 0,
            lastAlerts = p[K.LAST_ALERTS] ?: "",
            activitySeenAt = p[K.ACTIVITY_SEEN_AT] ?: 0,
            catchUpBytes = p[K.CATCH_UP_BYTES] ?: 0,
            catchUpDay = p[K.CATCH_UP_DAY] ?: "",
            reclaimUnderstood = p[K.RECLAIM_UNDERSTOOD] ?: false,
            freeableSaidBytes = p[K.FREEABLE_SAID_BYTES] ?: 0L,
            stallAlerts = p[K.STALL_ALERTS] ?: 0,
            stallAlertAt = p[K.STALL_ALERT_AT] ?: 0,
            confirmWindow = p[K.CONFIRM_OPENED_AT]?.let { at ->
                EvidenceRules.ConfirmWindow(
                    openedAt = at,
                    presentAtTap = p[K.CONFIRM_PRESENT].orEmpty().mapNotNull { it.toLongOrNull() }.toSet()
                )
            }
        ).also { OutputRoots.remember(it.layout, it.pastOutputRoots) }
    }

    suspend fun current(): Options {
        val o = flow.first()
        if (o.foldersPinned) return o
        pinLegacyFolders()
        return flow.first()
    }

    /**
     * Keeps an install that was already in use on the folder it had.
     *
     * Version 11 makes copies in Pictures/EnteSaver by default, and Ente is
     * backing up Pictures/CloudSaver for everyone who set the app up before.
     * Moving them silently would send every new copy to a folder Ente does
     * not know, where nothing would ever upload. So their folders are written
     * down as the old ones, once, and they move only when they tap Move -
     * which then tells them the one thing to change in Ente. An install that
     * never started setup has no copies and no Ente folder, and takes the new
     * default.
     */
    suspend fun pinLegacyFolders() {
        write { p ->
            if (p[K.FOLDERS_PINNED] == true) return@write
            p[K.FOLDERS_PINNED] = true
            val inUse = (p[K.ONBOARDING_DONE] ?: false) || (p[K.ONBOARDING_STEP] ?: 0) != 0
            if (!inUse) return@write
            if ((p[K.FOLDER_SINGLE] ?: "").isEmpty()) p[K.FOLDER_SINGLE] = Defaults.LEGACY_OUTPUT_DIR
            if ((p[K.FOLDER_PHOTOS] ?: "").isEmpty()) p[K.FOLDER_PHOTOS] = Defaults.LEGACY_OUTPUT_DIR_PHOTOS
            if ((p[K.FOLDER_VIDEOS] ?: "").isEmpty()) p[K.FOLDER_VIDEOS] = Defaults.LEGACY_OUTPUT_DIR_VIDEOS
        }
    }

    /**
     * New folders for copies, in one write: [changes] maps each kind to its
     * new value ("" for the default). Every folder that stops being used is
     * added to the past ones, so the copies still waiting in it are watched
     * until Ente has them; a folder moved back to is current again.
     */
    suspend fun setFolders(changes: Map<OutFolder, String>) {
        write { p ->
            changeFolders(p) {
                for ((folder, value) in changes) {
                    // Only what the folder setting itself could produce.
                    if (FolderName.isStorable(value)) p[keyOf(folder)] = value
                }
            }
        }
    }

    /** One folder for every copy, or separate ones for photos and videos. */
    suspend fun setOutputMode(mode: OutputMode) {
        write { p -> changeFolders(p) { p[K.OUTPUT_MODE] = mode.name } }
    }

    /**
     * Runs [change] to where copies go, and keeps the books on it: a folder
     * copies went to and no longer do joins the past ones, so Home can say
     * what still waits there and when it may be turned off in Ente; one
     * moved back to is current again; and when copies now go somewhere new,
     * Home asks for that folder to be turned on in Ente. Only folders copies
     * really went to are past ones - the unused half of the other
     * arrangement is not, or every change would end in notes about folders
     * nobody ever saw. Waiting copies stay watched through their own rows
     * either way.
     */
    private fun changeFolders(p: MutablePreferences, change: () -> Unit) {
        val before = layoutOf(p)
        change()
        val after = layoutOf(p)
        val inUse = after.current + after.otherMode
        val left = before.current.filter { old -> inUse.none { OutputRoots.same(it, old) } }
        val past = (p[K.PAST_OUTPUT_ROOTS] ?: emptySet())
            .filter { kept -> inUse.none { OutputRoots.same(it, kept) } } + left.map { OutputRoots.normalize(it) }
        p[K.PAST_OUTPUT_ROOTS] = past.toSet()
        if (after.current.any { now -> before.current.none { OutputRoots.same(it, now) } }) {
            p[K.NEW_FOLDER_PENDING] = true
        }
    }

    private fun keyOf(folder: OutFolder) = when (folder) {
        OutFolder.SINGLE -> K.FOLDER_SINGLE
        OutFolder.PHOTOS -> K.FOLDER_PHOTOS
        OutFolder.VIDEOS -> K.FOLDER_VIDEOS
    }

    private fun layoutOf(p: Preferences) = OutputLayout(
        enumOr(p[K.OUTPUT_MODE], OutputMode.SINGLE),
        p[K.FOLDER_SINGLE] ?: "",
        p[K.FOLDER_PHOTOS] ?: "",
        p[K.FOLDER_VIDEOS] ?: ""
    )

    /**
     * A choice, once made, is written even if the screen that made it goes.
     *
     * Every setter here is called from a view-model scope, which is cancelled
     * the moment the activity finishes - so ticking an album and immediately
     * leaving the app could cancel the write mid-transaction and lose the
     * tick. Losing a decision someone has already made is not an acceptable
     * outcome of closing an app, and the write itself is milliseconds.
     */
    private suspend fun write(
        edit: suspend (MutablePreferences) -> Unit
    ) = withContext(NonCancellable) {
        context.dataStore.edit { edit(it) }
    }

    /** Automatic unless set, or unless an earlier version stored a limit of the person's own. */
    private fun spaceAutoOf(p: Preferences): Boolean =
        p[K.SPACE_AUTO] ?: (p[K.DAILY_CAP_MB] == null && p[K.MIN_FREE_MB] == null && p[K.MAX_EXTRA_MB] == null)

    /** A limit in force: Automatic's figure while Automatic is on (the person's own until there is one). */
    private fun limitOf(p: Preferences, custom: Preferences.Key<Int>, auto: Preferences.Key<Int>): Int? =
        if (spaceAutoOf(p)) p[auto] ?: p[custom] else p[custom]

    /** Stores what Automatic works out for this phone now; the person's own figures are left alone. */
    suspend fun applyAutomaticSpace(limits: DeviceDefaults.Limits) {
        write { p ->
            p[K.AUTO_DAILY_CAP_MB] = limits.dailyCapMb
            p[K.AUTO_MIN_FREE_MB] = limits.minFreeMb
            p[K.AUTO_MAX_EXTRA_MB] = limits.maxExtraMb
        }
    }

    /**
     * Automatic or Custom. Custom picked for the first time starts from the
     * figures Automatic was using, so nothing jumps; picked again later, it
     * brings back the person's own.
     */
    suspend fun setSpaceAuto(on: Boolean) {
        write { p ->
            if (!on && p[K.DAILY_CAP_MB] == null && p[K.MIN_FREE_MB] == null && p[K.MAX_EXTRA_MB] == null) {
                p[K.AUTO_DAILY_CAP_MB]?.let { p[K.DAILY_CAP_MB] = it }
                p[K.AUTO_MIN_FREE_MB]?.let { p[K.MIN_FREE_MB] = it }
                p[K.AUTO_MAX_EXTRA_MB]?.let { p[K.MAX_EXTRA_MB] = it }
            }
            p[K.SPACE_AUTO] = on
        }
    }

    suspend fun setString(key: Preferences.Key<String>, value: String) {
        write { it[key] = value }
    }

    suspend fun setInt(key: Preferences.Key<Int>, value: Int) {
        write { it[key] = value }
    }

    suspend fun setLong(key: Preferences.Key<Long>, value: Long) {
        write { it[key] = value }
    }

    suspend fun setBool(key: Preferences.Key<Boolean>, value: Boolean) {
        write { it[key] = value }
    }

    /**
     * A history merged: asks for a reattach pass and, in the same write,
     * dates the restore. [restoredCopies] - copies came back not matched yet
     * - starts a watch from [now]. Otherwise, with no restore dated and none
     * waiting for its pass, the restore is marked looked at, so the pass does
     * not take rows an earlier version's restore left for one to watch.
     */
    suspend fun markRestored(restoredCopies: Boolean, now: Long) = write { p ->
        when {
            restoredCopies -> p[K.RESTORED_AT] = now
            (p[K.RESTORED_AT] ?: 0L) == 0L && (p[K.COPIES_REATTACHED] ?: false) -> p[K.RESTORED_AT] = 1L
        }
        p[K.COPIES_REATTACHED] = false
    }

    suspend fun setStringSet(
        key: Preferences.Key<Set<String>>,
        value: Set<String>
    ) {
        write { it[key] = value }
    }

    /**
     * One album in or out, read and written in a single step.
     *
     * The pickers used to send the whole set, worked out from what the
     * screen last showed. Two quick taps on a slow phone both started from
     * the same set, so the second write put back the album the first had
     * just taken out - which is how an album unticked in setup turned up
     * ticked in Settings.
     */
    suspend fun setBucketIncluded(name: String, include: Boolean) {
        write { p ->
            val excluded = p[K.EXCLUDED_BUCKETS] ?: emptySet()
            p[K.EXCLUDED_BUCKETS] = if (include) excluded - name else excluded + name
        }
    }

    /**
     * Folders the person moved away from: still watched until they run empty.
     * A folder they move back to is current again, not a past one.
     */
    suspend fun addPastOutputRoots(roots: Collection<String>) {
        val add = roots.map { OutputRoots.normalize(it) }.filter { it.isNotEmpty() }
        if (add.isEmpty()) return
        write { it[K.PAST_OUTPUT_ROOTS] = (it[K.PAST_OUTPUT_ROOTS] ?: emptySet()) + add }
    }

    suspend fun removePastOutputRoots(roots: Collection<String>) {
        if (roots.isEmpty()) return
        write { p ->
            val left = (p[K.PAST_OUTPUT_ROOTS] ?: emptySet()).filter { kept ->
                roots.none { OutputRoots.same(it, kept) }
            }.toSet()
            p[K.PAST_OUTPUT_ROOTS] = left
        }
    }

    /** Remembers copies Android would not let the app delete on its own. */
    suspend fun addCopiesNeedingConsent(ids: Collection<Long>) {
        if (ids.isEmpty()) return
        val strings = ids.map { it.toString() }
        write { it[K.COPIES_NEED_CONSENT] = (it[K.COPIES_NEED_CONSENT] ?: emptySet()) + strings }
    }

    suspend fun removeCopiesNeedingConsent(ids: Collection<Long>) {
        if (ids.isEmpty()) return
        val strings = ids.map { it.toString() }.toSet()
        write { it[K.COPIES_NEED_CONSENT] = (it[K.COPIES_NEED_CONSENT] ?: emptySet()) - strings }
    }

    /**
     * Stores the "Confirm uploads" window, or forgets it. The tap time and
     * the copies present then go in one write, so no reader ever sees one
     * without the other; DataStore has it on disk before this returns.
     */
    suspend fun setConfirmWindow(window: EvidenceRules.ConfirmWindow?) {
        write { p ->
            if (window == null) {
                p.remove(K.CONFIRM_OPENED_AT)
                p.remove(K.CONFIRM_PRESENT)
            } else {
                p[K.CONFIRM_OPENED_AT] = window.openedAt
                p[K.CONFIRM_PRESENT] = window.presentAtTap.map { it.toString() }.toSet()
            }
        }
    }

    /** Forgets the window opened at [openedAt] - not a newer tap's. */
    suspend fun clearConfirmWindow(openedAt: Long) {
        write { p ->
            if (p[K.CONFIRM_OPENED_AT] == openedAt) {
                p.remove(K.CONFIRM_OPENED_AT)
                p.remove(K.CONFIRM_PRESENT)
            }
        }
    }

    /** Options export for the snapshot (user-visible options only). */
    suspend fun exportMap(): Map<String, String> {
        val o = current()
        return mapOf(
            "scope" to o.scope.name,
            "excludedBuckets" to o.excludedBuckets.joinToString("|"),
            "outputMode" to o.outputMode.name,
            "folderSingle" to o.folderSingle,
            "folderPhotos" to o.folderPhotos,
            "folderVideos" to o.folderVideos,
            "speed" to o.speed.name,
            "saveMode" to o.saveMode.name,
            "spaceAuto" to o.spaceAuto.toString(),
            "dailyCapMb" to o.dailyCapMb.toString(),
            "minFreeMb" to o.minFreeMb.toString(),
            "maxExtraMb" to o.maxExtraMb.toString(),
            "theme" to o.theme.name,
            "dynamicColor" to o.dynamicColor.toString(),
            "storageVolume" to o.storageVolume,
            "warningsNotif" to o.warningsNotif.toString(),
            "keptInPlace" to o.keptInPlace.toString(),
            "freeUpAllowVerified30" to o.freeUpAllowVerified30.toString()
        )
    }

    /** Restores options from a snapshot map (import). Never touches files. */
    suspend fun importMap(
        map: Map<String, String>,
        onlyIfSetupUntouched: Boolean = false
    ) = withContext(NonCancellable) {
        context.dataStore.edit { p ->
            // Checked inside the same edit as the writes, so nothing the
            // person chooses can land between the check and the import.
            val setupStarted = (p[K.ONBOARDING_DONE] ?: false) || (p[K.ONBOARDING_STEP] ?: 0) != 0
            if (onlyIfSetupUntouched && setupStarted) return@edit
            map["scope"]?.let { p[K.SCOPE] = it }
            map["excludedBuckets"]?.let { s ->
                p[K.EXCLUDED_BUCKETS] = s.split('|').filter { it.isNotEmpty() }.toSet()
            }
            // Through the same books as a change in Settings: the folder left
            // behind is watched and named, the new one is asked for in Ente.
            changeFolders(p) {
                map["outputMode"]?.takeIf { v -> OutputMode.entries.any { it.name == v } }
                    ?.let { p[K.OUTPUT_MODE] = it }
                // A folder of the person's own comes back only if it is one the
                // folder setting itself could have produced.
                map["folderSingle"]?.takeIf { FolderName.isStorable(it) }?.let { p[K.FOLDER_SINGLE] = it }
                map["folderPhotos"]?.takeIf { FolderName.isStorable(it) }?.let { p[K.FOLDER_PHOTOS] = it }
                map["folderVideos"]?.takeIf { FolderName.isStorable(it) }?.let { p[K.FOLDER_VIDEOS] = it }
            }
            // "cloud*" keys from backups made before 11 are ignored: Ente
            // Saver works with Ente Photos only.
            map["speed"]?.let { p[K.SPEED] = it }
            map["saveMode"]?.takeIf { v -> SaveMode.entries.any { it.name == v } }?.let { p[K.SAVE_MODE] = it }
            // Only values the UI itself offers. A hand-edited backup could
            // otherwise set an absurd minimum-free figure, which makes the
            // resource gate refuse to run for good.
            // A backup from before 11.1 has no choice stored: its limits
            // were the person's own, so they come back as Custom rather than
            // being replaced by Automatic on the next run.
            val autoInFile = map["spaceAuto"]?.toBooleanStrictOrNull()
            val limitsInFile = listOf("dailyCapMb", "minFreeMb", "maxExtraMb").any { it in map }
            when {
                autoInFile != null -> p[K.SPACE_AUTO] = autoInFile
                limitsInFile -> p[K.SPACE_AUTO] = false
            }
            map["dailyCapMb"]?.toIntOrNull()
                ?.takeIf { it in Defaults.DAILY_CAP_CHOICES_MB }
                ?.let { p[K.DAILY_CAP_MB] = it }
            map["minFreeMb"]?.toIntOrNull()
                ?.takeIf { it in Defaults.MIN_FREE_CHOICES_MB }
                ?.let { p[K.MIN_FREE_MB] = it }
            map["maxExtraMb"]?.toIntOrNull()
                ?.takeIf { it in Defaults.MAX_EXTRA_CHOICES_MB }
                ?.let { p[K.MAX_EXTRA_MB] = it }
            map["theme"]?.let { p[K.THEME] = it }
            map["dynamicColor"]?.let { p[K.DYNAMIC_COLOR] = it.toBoolean() }
            map["storageVolume"]?.let { p[K.STORAGE_VOLUME] = it }
            map["warningsNotif"]?.let { p[K.WARNINGS_NOTIF] = it.toBoolean() }
            map["keptInPlace"]?.let { p[K.KEPT_IN_PLACE] = it.toBoolean() }
            map["freeUpAllowVerified30"]?.let { p[K.FREE_UP_VERIFIED30] = it.toBoolean() }
        }
    }

    private inline fun <reified T : Enum<T>> enumOr(value: String?, fallback: T): T {
        if (value.isNullOrEmpty()) return fallback
        return try {
            enumValueOf<T>(value)
        } catch (e: IllegalArgumentException) {
            fallback
        }
    }

    companion object {
        /**
         * Only ever constructed with the application context, which lives as
         * long as the process - there is no activity here to leak. DataStore
         * itself must be a singleton, so this cannot be scoped narrower.
         */
        @Volatile
        @SuppressLint("StaticFieldLeak")
        private var instance: OptionsRepo? = null

        fun get(context: Context): OptionsRepo = instance ?: synchronized(this) {
            instance ?: OptionsRepo(context.applicationContext).also { instance = it }
        }
    }
}
