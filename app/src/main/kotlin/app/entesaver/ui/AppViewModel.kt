package app.entesaver.ui

import android.app.Application
import android.app.RecoverableSecurityException
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.datastore.preferences.core.Preferences
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.entesaver.R
import app.entesaver.core.logic.ActivityWording
import app.entesaver.core.logic.BackupScope
import app.entesaver.core.logic.CapacityMath
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.DeviceDefaults
import app.entesaver.core.logic.EvidenceRules
import app.entesaver.core.logic.Fingerprint
import app.entesaver.core.logic.FolderName
import app.entesaver.core.logic.FreeUpFlow
import app.entesaver.core.logic.GoneReason
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.KeptCopies
import app.entesaver.core.logic.KnownClouds
import app.entesaver.core.logic.LeftoverRules
import app.entesaver.core.logic.MediaProfile
import app.entesaver.core.logic.OutFolder
import app.entesaver.core.logic.OutputMode
import app.entesaver.core.logic.OutputPaths
import app.entesaver.core.logic.OutputRoots
import app.entesaver.core.logic.Pacing
import app.entesaver.core.logic.Projection
import app.entesaver.core.logic.QualityKept
import app.entesaver.core.logic.ReclaimRules
import app.entesaver.core.logic.SaveMode
import app.entesaver.core.logic.ScanSources
import app.entesaver.core.logic.SpeedMode
import app.entesaver.core.logic.StallAlert
import app.entesaver.core.logic.Stops
import app.entesaver.core.logic.ThemeMode
import app.entesaver.core.logic.VideoCodec
import app.entesaver.data.EarlierInstall
import app.entesaver.data.EnteApp
import app.entesaver.data.db.ActivityRow
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.db.KeptOriginals
import app.entesaver.data.db.RatioSample
import app.entesaver.data.db.Search
import app.entesaver.data.db.leftFolderAtAfter
import app.entesaver.data.prefs.Options
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.engine.ActivityLog
import app.entesaver.engine.DuplicateScanner
import app.entesaver.engine.MaintainEngine
import app.entesaver.engine.ProfileBuilder
import app.entesaver.engine.ReclaimEligibility
import app.entesaver.engine.SnapshotStore
import app.entesaver.engine.UsageVerifier
import app.entesaver.media.EncoderCaps
import app.entesaver.media.HeicSupport
import app.entesaver.media.InPlace
import app.entesaver.media.MediaScanner
import app.entesaver.media.OutputInventory
import app.entesaver.media.PlannedEncode
import app.entesaver.media.Stager
import app.entesaver.ui.components.AccessNotice
import app.entesaver.util.DeviceTier
import app.entesaver.util.Errand
import app.entesaver.util.FirstFrame
import app.entesaver.util.Formats
import app.entesaver.util.Locks
import app.entesaver.util.OemPages
import app.entesaver.util.Permissions
import app.entesaver.util.PowerPages
import app.entesaver.util.SpaceLimits
import app.entesaver.util.SqlChunks
import app.entesaver.util.Storage
import app.entesaver.util.TamperCheck
import app.entesaver.util.TrialRecord
import app.entesaver.util.Volumes
import app.entesaver.work.Gates
import app.entesaver.work.Scheduler
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class AppViewModel(app: Application) : AndroidViewModel(app) {

    companion object {
        /** Minimum time between Home status-line changes (G2). */
        const val STATUS_DEBOUNCE_MS = 800L

        /** The most the trial ever touches. Enough to prove it, cheap to run. */
        const val TRIAL_SIZE = 3

        /**
         * How long the search waits for the typing to stop.
         *
         * Long enough that a word is one query rather than five, short enough
         * that the pause between words already shows results.
         */
        const val SEARCH_DEBOUNCE_MS = 220L

        /**
         * How many rows the Files list holds.
         *
         * The cap is on the ANSWER, not on the table: the chip, the album
         * scope and the sort are all applied in SQL first, so this is the
         * newest 500 of what the user actually asked for. It used to be the
         * newest 500 of everything, which the filters then whittled to
         * nothing while Home's counter said thousands.
         */
        const val FILES_PAGE = 500

        /**
         * How long a second "Confirm uploads" tap is ignored after Ente was
         * asked to open, if this screen is neither left nor returned to.
         */
        const val ENTE_LAUNCH_GRACE_MS = 10_000L

    }

    private val ctx get() = getApplication<Application>()
    val repo = OptionsRepo.get(ctx)
    private val db = AppDb.get(ctx)

    /**
     * How a flow that backs one screen is shared: collected while that
     * screen is on, kept warm for five seconds across a rotation or a quick
     * tab hop, and stopped otherwise.
     *
     * Every Room flow re-runs its query on every write to the table it
     * reads, and a scan writes one row at a time - so an eagerly collected
     * aggregate over `items` ran its full-table sum for each of twelve
     * thousand files while the user was on Settings. Sharing it only while
     * subscribed costs nothing visible: a StateFlow keeps its last value, so
     * a screen that comes back sees what it saw and then the fresh answer,
     * never a blank. What stays eager is what the tab bar and the lock gate
     * read on every screen, and the options every screen is built from.
     *
     * Declared here, first, because a Kotlin property initialiser runs in
     * source order: a flow above this line that named it would read null.
     */
    private val screenLocal = SharingStarted.WhileSubscribed(5_000)

    val options: StateFlow<Options> =
        repo.flow.stateIn(viewModelScope, SharingStarted.Eagerly, Options())

    /**
     * False until DataStore has actually handed over the stored options.
     *
     * [options] has to start on something, and that something is the defaults
     * - which say setup has not been done. Rendering on that first value
     * flashed the welcome card at every returning user for a frame or two, and
     * made a resumed setup restart from the beginning.
     */
    val optionsLoaded: StateFlow<Boolean> = repo.flow
        .map { true }
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    /** 13.A tamper evidence: true = re-signed/modified copy, deletions disabled. */
    val tampered = MutableStateFlow(false)

    init {
        viewModelScope.launch(Dispatchers.Default) {
            tampered.value = TamperCheck.isModified(ctx)
        }
        // A theme chosen before the mirror existed is mirrored on the first
        // load after the update, so it holds from the next open onwards.
        viewModelScope.launch(Dispatchers.Default) {
            FirstFrame.remember(ctx, repo.current().theme)
        }
    }

    // ---- counters (Home) ----------------------------------------------------

    /** The four stages an item passes through, as Home shows them. */
    data class Counters(
        val waiting: Int = 0,
        val inFolder: Int = 0,
        val confirmed: Int = 0,
        /** Problems only: unreadable, too large, encoder refused, and so on. */
        val skipped: Int = 0,
        /** Files handled once under an identical twin. Not a problem. */
        val duplicates: Int = 0,
        /** Compressed and waiting for a pacing slot, not yet in the folder. */
        val heldBack: Int = 0
    )

    // The inventory is whole-phone on purpose (returned copies, duplicates,
    // presence); the promise of future work is not. "Waiting" follows the
    // album selection live, so unticking Screenshots takes its photos out of
    // every count the same moment it takes them out of the queue.
    @OptIn(ExperimentalCoroutinesApi::class)
    private val newInScope: Flow<Int> = options
        .map { it.excludedBuckets }
        .distinctUntilChanged()
        .flatMapLatest { db.items().newInScopeCountFlow(it) }

    /**
     * True when the app has photos on file and not one of them is in an
     * album the user ticked.
     *
     * This is the difference between "the queue is empty because everything
     * is done" and "the queue is empty because nothing was ever offered",
     * and Home said the first of those in both cases.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    val noAlbumsTicked: StateFlow<Boolean> = options
        .map { it.excludedBuckets }
        .distinctUntilChanged()
        .flatMapLatest { excluded ->
            combine(
                db.items().inScopeItemCountFlow(excluded),
                db.items().bucketedItemCountFlow()
            ) { inScope, known -> known > 0 && inScope == 0 }
        }
        .stateIn(viewModelScope, screenLocal, false)

    /**
     * True while an AGED or VERIFIED copy waits in the folder. Nothing beside
     * it can be proved by Ente's traffic, so Home offers Ente's own free-up,
     * which is the one route to proof left - for the graded copies too: the
     * return pass credits every copy without per-file proof that Ente took
     * (EvidenceRules.collectedByFreeUp).
     */
    val gradedInFolder: StateFlow<Boolean> = db.items().gradedInFolderCountFlow()
        .map { it > 0 }
        .distinctUntilChanged()
        .stateIn(viewModelScope, screenLocal, false)

    /**
     * Null until the first read lands. The flow starts when Home subscribes,
     * so the first frame used to be drawn from the initial value - all zeros
     * - and zeros are not "unknown": they are "nothing waiting, nothing in
     * the folder, nothing backed up", which Home dutifully wrote out as a
     * sentence above a trial card, a frame before the real counts arrived
     * and both vanished. Home now waits for a value instead.
     */
    val counters: StateFlow<Counters?> = combine(
        combine(newInScope, db.items().stateCountsFlow()) { n, s -> n to s },
        db.items().confirmedCountFlow(),
        db.items().verifiedCountFlow(),
        db.items().problemSkippedCountFlow(),
        db.items().duplicatesHandledCountFlow()
    ) { (newCount, states), confirmed, verified, problems, duplicates ->
        val byState = states.associate { it.state to it.cnt }
        Counters(
            // CC1.3: "in the upload folder" means a file the cloud app can
            // actually see. A STAGED item is compressed and held back by the
            // pacing limit - it is not in the folder, and counting it there
            // is what made the tile disagree with the gallery.
            waiting = newCount +
                (byState[ItemState.STAGED.name] ?: 0),
            inFolder = byState[ItemState.RELEASED.name] ?: 0,
            heldBack = byState[ItemState.STAGED.name] ?: 0,
            // Both count as backed up on Home; how strong the evidence is
            // belongs in the item's details, not in a headline number.
            confirmed = confirmed + verified,
            // Real problems only. A duplicate was handled under its twin,
            // which is the app working, not the app failing.
            skipped = problems,
            duplicates = duplicates
        )
    }.stateIn(viewModelScope, screenLocal, null)

    /**
     * The Home status line, slowed to human speed.
     *
     * A run that finishes twenty files a minute updated this text twenty
     * times, and a caption strobing between "12 files in the queue" and
     * "Everything is backed up" reads as an error, not as progress. One change
     * per 800 ms is fast enough to feel live and slow enough to read.
     */
    @OptIn(FlowPreview::class)
    val statusWaiting: StateFlow<Int?> = counters
        .filterNotNull()
        .map { it.waiting }
        .debounce(STATUS_DEBOUNCE_MS)
        // Null until a count actually arrives. This used to start at zero,
        // which does not mean "not known yet" - it means "nothing is
        // waiting" - so for the first eight hundred milliseconds of every
        // launch Home stated "Everything is backed up" directly above a tile
        // already reading eleven files still to do.
        .stateIn(viewModelScope, screenLocal, null)

    val savedBytes: StateFlow<Long> =
        db.items().savedBytesFlow().stateIn(viewModelScope, screenLocal, 0L)

    /** Null until read, for the same reason as [counters]. */
    val processedCount: StateFlow<Int?> =
        db.items().processedCountFlow().stateIn(viewModelScope, screenLocal, null)

    /**
     * Savings split by media kind.
     *
     * One combined figure hides the thing people actually want to know: a
     * single 4K clip can outweigh a thousand photos, and someone deciding
     * whether to keep videos on needs those two numbers apart.
     */
    data class Savings(
        val photoBytes: Long = 0,
        val photoCount: Int = 0,
        val videoBytes: Long = 0,
        val videoCount: Int = 0
    ) {
        val totalBytes: Long get() = photoBytes + videoBytes
    }

    val savings: StateFlow<Savings> = combine(
        db.items().savedBytesFlow(false),
        db.items().processedCountFlow(false),
        db.items().savedBytesFlow(true),
        db.items().processedCountFlow(true)
    ) { pb, pc, vb, vc -> Savings(pb, pc, vb, vc) }
        .stateIn(viewModelScope, screenLocal, Savings())

    /**
     * How much this phone's own files actually shrank.
     *
     * The preset percentages are an estimate for the encoder settings; this is
     * the measurement. Showing both, clearly labelled, is the difference
     * between a claim and a number.
     */
    data class MeasuredQuality(
        val photoShrinkPercent: Int = 0,
        val photoCount: Int = 0,
        val videoShrinkPercent: Int = 0,
        val videoCount: Int = 0
    ) {
        val hasAny: Boolean get() = photoCount > 0 || videoCount > 0
    }

    val measuredQuality = MutableStateFlow(MeasuredQuality())

    fun refreshMeasuredQuality() {
        viewModelScope.launch(Dispatchers.IO) {
            val o = repo.current()
            val photos = db.items().photoRatioSamples(PlannedEncode.photoKey())
            val videos = db.items().videoRatioSamples(PlannedEncode.videoKey())
            fun shrink(rows: List<RatioSample>): Int {
                val original = rows.sumOf { it.sizeBytes }
                if (original <= 0) return 0
                val output = rows.sumOf { it.outputBytes }
                return (((original - output).toDouble() / original) * 100).toInt().coerceIn(0, 100)
            }
            measuredQuality.value = MeasuredQuality(
                photoShrinkPercent = shrink(photos),
                photoCount = photos.size,
                videoShrinkPercent = shrink(videos),
                videoCount = videos.size
            )
        }
    }

    /** Files copied byte-for-byte, with the reasons, for the "kept as is" card. */
    data class AsIs(val count: Int = 0, val reasons: List<Pair<String, Int>> = emptyList())

    val asIs = MutableStateFlow(AsIs())

    /** Why items were skipped, as chips under the Skipped tile. */
    val skipReasons = MutableStateFlow<List<Pair<String, Int>>>(emptyList())

    fun refreshSkipReasons() {
        viewModelScope.launch(Dispatchers.IO) {
            skipReasons.value = db.items().skipReasons()
                .map { it.state to it.cnt }
        }
    }

    fun refreshAsIs() {
        viewModelScope.launch(Dispatchers.IO) {
            val reasons = (db.items().asIsReasons(false) + db.items().asIsReasons(true))
                .groupBy { it.state }
                .map { (reason, rows) -> reason to rows.sumOf { it.cnt } }
                .sortedByDescending { it.second }
            asIs.value = AsIs(
                count = db.items().asIsCount(false) + db.items().asIsCount(true),
                reasons = reasons
            )
        }
    }

    // ---- activity log -------------------------------------------------------

    private val activityLog = ActivityLog(ctx)

    /** Which of the three groups the Activity screen is showing. */
    val activityFilter = MutableStateFlow<ActivityLog.Group?>(null)

    /**
     * Null until the database has answered for the first time. The screen
     * opened on "Nothing logged yet" for the moment the read took - the one
     * thing it must never say to someone looking for what happened overnight.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    val activityRows: StateFlow<List<ActivityRow>?> = activityFilter
        .flatMapLatest { group ->
            if (group == null) {
                db.activity().recentFlow(ActivityLog.RETENTION_ROWS)
            } else {
                db.activity().byKindsFlow(
                    ActivityLog.Kind.entries.filter { it.group == group }.map { it.name },
                    ActivityLog.RETENTION_ROWS
                )
            }
        }
        // Three taps through the quality presets is one decision, not three
        // events, and a history that records each of them buries the rest.
        .map { rows ->
            ActivityWording.coalesce(
                rows = rows,
                isSettingChange = { it.kind == ActivityLog.Kind.SETTINGS_CHANGED.name },
                detailOf = { it.detail },
                atMsOf = { it.atMs }
            )
        }
        .stateIn(viewModelScope, screenLocal, null)

    /** Unread dot on Home: anything logged since the screen was last opened. */
    @OptIn(ExperimentalCoroutinesApi::class)
    val activityUnread: StateFlow<Int> = options
        .map { it.activitySeenAt }
        .flatMapLatest { seen -> db.activity().unreadCountFlow(seen) }
        .stateIn(viewModelScope, screenLocal, 0)

    fun markActivitySeen() {
        viewModelScope.launch {
            repo.setLong(OptionsRepo.K.ACTIVITY_SEEN_AT, System.currentTimeMillis())
        }
    }

    fun clearActivity() {
        viewModelScope.launch(Dispatchers.IO) { activityLog.clear() }
    }

    fun exportActivity(uri: Uri, doneLabel: String, failLabel: String) {
        viewModelScope.launch(Dispatchers.IO) {
            val ok = runCatching {
                val text = activityLog.exportText()
                ctx.contentResolver.openOutputStream(uri)?.use { out ->
                    out.write(text.toByteArray())
                } ?: error("no stream")
            }.isSuccess
            transferMessage.value = if (ok) doneLabel else failLabel
        }
    }

    /**
     * Re-keyed off options so the settled-by cutoff moves with the clock and
     * the opt-in switch: a value fixed at construction would go stale in a
     * process that stays alive for days.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    val reclaimableBytes: StateFlow<Long> = options
        .flatMapLatest { o ->
            // The one refusal SQL cannot make. Without Ente, or with Ente
            // flagged, nothing at all is offered - so a mark on the tab
            // would send someone to an empty screen.
            if (o.cloudProblem.isNotEmpty() || !EnteApp.isInstalled(ctx)) {
                flowOf(0L)
            } else {
                val now = System.currentTimeMillis()
                db.items().reclaimableBytesFlow(
                    settledBefore = now - EvidenceRules.RECLAIM_MIN_DAYS * 86_400_000L,
                    addedBeforeSeconds =
                        (now - ReclaimRules.MIN_CONFIRM_AGE_DAYS * 86_400_000L) / 1000L,
                    minSizeBytes = ReclaimRules.MIN_SIZE_BYTES,
                    includeVerified = o.freeUpAllowVerified30
                )
            }
        }
        // Asking the package manager is a call to another process, and this
        // flow is collected wherever the tab bar is. It does not belong on
        // the frame thread.
        .flowOn(Dispatchers.IO)
        .stateIn(viewModelScope, SharingStarted.Eagerly, 0L)

    // ---- files list ---------------------------------------------------------

    val search = MutableStateFlow("")

    /** Files list filter: an [ItemState] name, or null for everything. */
    val filesState = MutableStateFlow<String?>(null)

    enum class FilesSort { NEWEST, SAVED, LARGEST }

    val filesSort = MutableStateFlow(FilesSort.NEWEST)

    /**
     * The states one chip stands for.
     *
     * "Backed up" is a story rather than one state: an item can be finished,
     * its copy already tidied away, or its original reclaimed, and all three
     * read the same to the user. Empty means the chip is off - every state.
     */
    private fun statesFor(chip: String?): List<String> = when (chip) {
        null -> emptyList()
        ItemState.DONE.name ->
            listOf(ItemState.DONE.name, ItemState.GONE.name, ItemState.FREED.name)
        ItemState.RELEASED.name ->
            listOf(ItemState.STAGED.name, ItemState.RELEASED.name)
        else -> listOf(chip)
    }

    /** Everything the Files list is currently asking for, as one value. */
    private data class FilesQuery(
        val typed: String,
        val chip: String?,
        val sort: FilesSort,
        val excluded: Set<String>
    )

    /**
     * The list the Files screen shows.
     *
     * Every part of the question - the typed name, the chip, the album scope
     * and the sort - goes into the statement, because the statement is what
     * carries the LIMIT. A NEW row in an un-ticked album is inventory, not
     * work: no run will touch it, so it is excluded there too, while history
     * stays whatever the ticks say now.
     *
     * Search runs one query behind the keyboard rather than one per key.
     * Typing "beach" used to start five database queries and throw four of
     * them away, which on a large library is five scans of the items table
     * while the finger is still moving. The debounce is short enough that a
     * pause between words already shows results, and distinctUntilChanged
     * stops a re-emitted identical term from re-querying at all.
     */
    @OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
    val items: StateFlow<List<ItemRow>?> = combine(
        search.debounce { if (it.isEmpty()) 0L else SEARCH_DEBOUNCE_MS }.distinctUntilChanged(),
        filesState,
        filesSort,
        options.map { it.excludedBuckets }.distinctUntilChanged()
    ) { typed, chip, sort, excluded -> FilesQuery(typed, chip, sort, excluded) }
        .distinctUntilChanged()
        .flatMapLatest { ask ->
            val states = statesFor(ask.chip)
            db.items().searchFlow(
                // Escaped on the way in, because the box takes a name and the
                // query takes a pattern: a '%' or a '_' typed into it is a
                // wildcard to SQL, and one percent sign used to return the
                // entire library.
                q = Search.escapeLike(ask.typed),
                states = states,
                // An empty IN () matches nothing in SQLite, which is right for
                // a chip that names states and wrong for no chip at all.
                anyState = if (states.isEmpty()) 1 else 0,
                excludedBuckets = ask.excluded,
                sortKey = when (ask.sort) {
                    FilesSort.NEWEST -> 0
                    FilesSort.SAVED -> 1
                    FilesSort.LARGEST -> 2
                },
                limit = FILES_PAGE
            )
        }
        .stateIn(viewModelScope, screenLocal, null)

    // ---- health chips -------------------------------------------------------

    data class Health(
        val batteryRestricted: Boolean = false,
        /** App info › Battery › Restricted: Android itself bans the background runs. */
        val backgroundRestricted: Boolean = false,
        /** Android will reset the permissions if the app is not opened for months. */
        val permissionsAutoReset: Boolean = false,
        /** The phone-wide Battery Saver is on; runs wait until it is off or the phone charges. */
        val batterySaverOn: Boolean = false,
        val usageAccessOff: Boolean = false,
        val cloudMissing: Boolean = false,
        /** The Ente Saver of 12.2 and before is still installed beside this one. */
        val earlierInstall: Boolean = false,
        /**
         * No cloud app of any kind is installed. The pipeline still runs -
         * copies are made on schedule - but nothing will ever collect them,
         * so this is worth saying rather than leaving the folder to fill.
         */
        val spaceLow: Boolean = false,
        val paused: Boolean = false,
        /**
         * The phone is not letting this app finish its work.
         *
         * Two shapes of one failure. Either nothing has run for two days
         * while work waited - the phone stopped scheduling it altogether -
         * or runs do happen and Android cuts each one short, which from
         * Android 16 is what a job alongside a foreground service normally
         * gets. The second shape used to be invisible: a cut run still stamps
         * the last-run time, so the two-day silence never accumulated and
         * every check stayed green while the queue barely moved.
         */
        val backgroundWorkStopped: Boolean = false,

        /** The chosen SD card is gone; work is paused safely (Z3.3). */
        val volumeMissing: Boolean = false,

        // Everything the Home action needs to decide whether a run the user
        // asks for could actually go ahead.
        val thermalThrottled: Boolean = false,
        val batteryPct: Int = 0,
        val plugged: Boolean = false,
        val freeBytes: Long = 0
    )

    val health = MutableStateFlow(Health())

    /**
     * How much of the gallery the app can see, re-read on every ON_START and
     * permission result. Home, Files, Storage and the calculator all observe
     * it: under PARTIAL nothing scans and no total is shown as a number,
     * because the number would describe the user's selection, not their
     * gallery (BB1).
     */
    val mediaAccess = MutableStateFlow(Permissions.MediaAccess.FULL)

    /**
     * Unlocked, for this run of the app.
     *
     * It lives here rather than in the composition because turning the phone
     * recreates the activity: composition state asked for a fingerprint on
     * every rotation, which is how people turn an app lock off. A view model
     * dies with the process, so an app the phone killed in the background is
     * locked again when it returns - the half that saved instance state,
     * the other obvious home for this, would have got wrong.
     */
    val unlocked = MutableStateFlow(false)

    /**
     * Shuts the lock again, and lets the next lock screen ask by itself once.
     *
     * The prompt comes up on its own when the app opens, the way every locked
     * app behaves - but only once per locking. It used to come up on every
     * resume, and on Android 10 the PIN pad is an activity of its own:
     * cancelling it resumes this one, which asked again, which the person
     * cancelled, which resumed this one. After the first prompt the button
     * on the lock screen asks.
     */
    fun relock() {
        unlocked.value = false
        lockAutoPrompted = false
    }

    /** Whether this locking has already put up its prompt by itself. */
    var lockAutoPrompted = false

    /**
     * A prompt is on screen and has not answered yet. A second authenticate
     * call while one is showing stacks another sheet behind it.
     */
    var lockPromptOpen = false

    /**
     * The password for the backup being saved right now.
     *
     * Here rather than in the composition because the file picker is another
     * app's screen: coming back from it can recreate this one, and a password
     * kept in composition would be null by the time the picked file arrives.
     * The backup would then be written readable, under the name the person
     * was told means encrypted. Never in saved state - that is written to
     * disk. It lives for one save and is cleared by the caller.
     */
    var backupPassword: String? = null

    /**
     * Which app holds this item's copy (Z10.1): the app recorded on the batch
     * the file went out with. Before 11 that could be another cloud app, and
     * a copy sent there is still there.
     */
    suspend fun holdingAppLabel(row: ItemRow): String? {
        val pkg = row.batchId?.let { db.batches().byId(it)?.cloudPackage } ?: return null
        return KnownClouds.labelOf(pkg)
    }

    /**
     * The phone's screen lock was removed, so nothing can verify anyone: the
     * app lock turns itself off, visibly. Silent would read as broken, and
     * staying on would brick the app behind a door with no key.
     */
    fun disableLockNoCredential() {
        viewModelScope.launch(Dispatchers.IO) {
            if (!repo.current().appLock) return@launch
            repo.setBool(OptionsRepo.K.APP_LOCK, false)
            activityLog.record(
                ActivityLog.Kind.PROBLEM,
                detail = ctx.getString(R.string.lock_disabled_no_credential)
            )
        }
    }

    /** Z5.2: the double-backup warning was on screen and the user moved on. */
    fun acknowledgeDoubleBackup() {
        viewModelScope.launch(Dispatchers.IO) {
            repo.setBool(OptionsRepo.K.DOUBLE_BACKUP_ACK, true)
        }
    }

    fun acknowledgeKeptCard() {
        viewModelScope.launch(Dispatchers.IO) {
            repo.setBool(OptionsRepo.K.KEPT_CARD_SEEN, true)
        }
    }

    fun refreshHealth() {
        viewModelScope.launch(Dispatchers.Default) {
            val o = repo.current()
            // Scoped to ticked albums: a phone whose only NEW rows sit in
            // excluded albums has no work stopped - warning that background
            // work stalled over files no run may touch is a false alarm that
            // never clears.
            val waiting = runCatching { db.items().newInScopeCount(o.excludedBuckets) }
                .getOrDefault(0)
            val power = Gates.readPower(ctx, o.lastInteractiveAt, System.currentTimeMillis())
            val free = Storage.freeBytes(ctx)
            val access = Permissions.mediaAccess(ctx)
            // Anything short of full access is what the screens are waiting
            // on - a handful of picked photos and no access at all alike. The
            // old test asked only about the handful, so someone who switched
            // the permission off and back on again went on being told the app
            // was waiting until the next scheduled run came round.
            val wasLimited = AccessNotice.isLimited(mediaAccess.value)
            mediaAccess.value = access
            // Access became full again: recompute without waiting for the
            // next scheduled run, so the screens stop saying "waiting".
            if (wasLimited && access == Permissions.MediaAccess.FULL) {
                refreshCalculator()
                refreshProjection()
            }
            val volumeGone = o.storageVolume.isNotEmpty() &&
                Volumes.byName(ctx, o.storageVolume) == null
            // A returned card must be probed afresh, not trusted from cache.
            if (!volumeGone && o.storageVolume.isNotEmpty()) Unit else Volumes.invalidateProbes()
            health.value = Health(
                volumeMissing = volumeGone,
                batteryRestricted = !Permissions.isIgnoringBatteryOptimizations(ctx),
                backgroundRestricted = Permissions.isBackgroundRestricted(ctx),
                permissionsAutoReset = Permissions.permissionsAutoResetOn(ctx) == true,
                batterySaverOn = power.saverOn,
                usageAccessOff = !UsageVerifier.hasUsageAccess(ctx),
                cloudMissing = !EnteApp.isInstalled(ctx),
                earlierInstall = EarlierInstall.isInstalled(ctx),
                spaceLow = free < o.minFreeBytes,
                thermalThrottled = power.thermalThrottled ||
                    power.batteryTempTenthsC >= Defaults.BATTERY_MAX_TEMP_TENTHS_C,
                batteryPct = power.batteryPct,
                plugged = power.plugged,
                freeBytes = free,
                paused = o.pauseAll,
                // One rule, shared with the notification the engine posts,
                // so the chip and the alert can never disagree (StallAlert).
                backgroundWorkStopped = !o.pauseAll && StallAlert.stalled(
                    System.currentTimeMillis(), StallAlert.lastSeen(o.lastRunAt, o.lastWakeAt), waiting,
                    Stops.isRationed(o.lastStopReason)
                )
            )
        }
    }

    // ---- today's upload allowance (D3) --------------------------------------

    /**
     * How much of today's upload allowance is left, and when it refills.
     *
     * "Waiting" with no reason is the complaint every background app gets. If
     * the app is holding files back because the daily limit is spent, it says
     * so, and says when that stops being true.
     */
    data class Budget(
        val usedBytes: Long = 0,
        val totalBytes: Long = 0,
        val resetsAt: Long = 0,
        val carriedBytes: Long = 0
    ) {
        val unlimited: Boolean get() = totalBytes < 0
        val spent: Boolean get() = !unlimited && usedBytes >= totalBytes
        val fraction: Float
            get() = if (unlimited || totalBytes <= 0) {
                0f
            } else {
                (usedBytes.toFloat() / totalBytes).coerceIn(0f, 1f)
            }
    }

    val budget = MutableStateFlow(Budget())

    fun refreshBudget() {
        viewModelScope.launch(Dispatchers.IO) {
            val o = repo.current()
            val now = System.currentTimeMillis()
            val total = Pacing.dailyBudgetWithCatchUp(
                o.dailyCapBytes,
                if (Formats.dayKey(now) == o.catchUpDay) o.catchUpBytes else 0L
            )
            budget.value = Budget(
                usedBytes = db.batches().bytesSince(Formats.startOfDay(now)),
                totalBytes = total,
                resetsAt = Formats.nextMidnight(now),
                carriedBytes = if (Formats.dayKey(now) == o.catchUpDay) o.catchUpBytes else 0L
            )
        }
    }

    // ---- storage screen -----------------------------------------------------

    data class StorageStats(
        val stageBytes: Long = 0,
        val outputBytes: Long = 0,
        val tempBytes: Long = 0,
        /** How much the last Clear actually freed, so the button proves itself. */
        val lastTempFreed: Long? = null
    )

    val storageStats = MutableStateFlow(StorageStats())

    fun refreshStorage() {
        viewModelScope.launch(Dispatchers.IO) {
            storageStats.value = storageStats.value.copy(
                stageBytes = Storage.totalStageBytes(ctx),
                outputBytes = db.items().releasedBytes(),
                tempBytes = Storage.totalTempBytes(ctx)
            )
        }
    }

    // ---- storage volumes (13.D) ----------------------------------------

    val volumes = MutableStateFlow<List<Volumes.Vol>>(emptyList())

    /**
     * Volumes that really accept gallery inserts, by probe (BB2). The
     * primary always does; an SD card is offered as the storage location
     * only when its name is in here, and is otherwise absent - not greyed -
     * with one line saying why.
     */
    val writableVolumes = MutableStateFlow<Set<String>>(emptySet())

    fun refreshVolumes() {
        viewModelScope.launch(Dispatchers.IO) {
            val found = Volumes.listForDisplay(ctx)
            volumes.value = found
            writableVolumes.value = found
                .filter { it.isPrimary || Volumes.probeWritable(ctx, it.mediaVolumeName) }
                .map { it.mediaVolumeName }
                .toSet()
        }
    }

    // ---- cloud calculator (13.C) ----------------------------------------

    val calcGallery = MutableStateFlow<CapacityMath.Gallery?>(null)
    val calcRatios = MutableStateFlow<CapacityMath.Ratios?>(null)

    /**
     * Which figures the calculator is using.
     *
     * Null means "decide for me": measured where this phone has enough
     * representative data, typical otherwise. A user choice pins it, and the
     * badge always names the one in use, so no number is ever unattributed.
     */
    val calcSource = MutableStateFlow<CapacityMath.Source?>(null)


    fun refreshCalculator() {
        viewModelScope.launch(Dispatchers.IO) {
            // Under partial access a totals() sweep would count the selection
            // and present it as the gallery. The screen shows "waiting for
            // full access" instead of any number (BB1.3).
            if (Permissions.mediaAccess(ctx) != Permissions.MediaAccess.FULL) {
                calcGallery.value = null
                return@launch
            }
            val o = repo.current()
            // Summed straight off the cursor: the calculator needs five
            // numbers, not a copy of the gallery in memory.
            val totals = runCatching { MediaScanner(ctx, db).totals(o.excludedBuckets) }
                .getOrDefault(MediaScanner.Totals())
            calcGallery.value = CapacityMath.Gallery(
                photoBytes = totals.photoBytes,
                videoBytes = totals.videoBytes,
                videoMinutes = totals.videoMinutes,
                monthlyPhotoBytes = totals.monthlyPhotoBytes,
                monthlyVideoBytes = totals.monthlyVideoBytes,
                videoCount = totals.videoCount
            )
            val photoSamples = db.items().photoRatioSamples(PlannedEncode.photoKey()).map {
                CapacityMath.Sample(it.sizeBytes, it.outputBytes)
            }
            val videoSamples = db.items().videoRatioSamples(PlannedEncode.videoKey()).map {
                CapacityMath.Sample(it.sizeBytes, it.outputBytes, it.durationMs / 60_000.0)
            }
            // The gallery's own median is what the sample is judged against:
            // twenty screenshots must not get to speak for a library of
            // photographs.
            calcRatios.value = CapacityMath.ratios(
                photo = photoSamples,
                video = videoSamples,
                codec = PlannedEncode.videoCodec(),
                source = calcSource.value ?: CapacityMath.Source.MEASURED,
                galleryPhotoMedian = if (totals.photoCount > 0) {
                    totals.photoBytes / totals.photoCount
                } else {
                    0L
                },
                galleryVideoMedian = if (totals.videoCount > 0) {
                    totals.videoBytes / totals.videoCount
                } else {
                    0L
                }
            )
        }
    }

    // ---- media profile: the one source every estimate reads from ------------

    val profile = MutableStateFlow(MediaProfile.Profile())

    fun refreshProfile() {
        viewModelScope.launch(Dispatchers.IO) {
            profile.value = ProfileBuilder(ctx).current(repo.current())
        }
    }


    /**
     * What finishing the queue would save.
     *
     * Photos and videos are projected separately and added, from this phone's
     * measured ratios where they exist and typical ratios where they do not.
     * It used to report zero until something had been measured, which for a
     * queue of 249 MB of video read as "about 0 MB could be saved" - not
     * cautious, just wrong. The basis is carried alongside so the screen can
     * say whether the figure is measured or an estimate.
     */
    val projectedSavings = MutableStateFlow(Projection.Estimate(0L, Projection.Basis.TYPICAL))

    fun refreshProjection() {
        viewModelScope.launch(Dispatchers.IO) {
            val o = repo.current()
            val p = ProfileBuilder(ctx).current(o)
            val excluded = o.excludedBuckets
            projectedSavings.value = Projection.forQueue(
                photoBytes = db.items().pendingBytesByType(video = false, excluded),
                videoBytes = db.items().pendingBytesByType(video = true, excluded),
                measuredPhotoRatio = p.photos.ratio,
                measuredVideoRatio = p.videos.ratio,
                photoCount = db.items().pendingCountByType(video = false, excluded),
                videoCount = db.items().pendingCountByType(video = true, excluded)
            )
        }
    }

    // ---- find space (v2.3 G1) -----------------------------------------------

    data class FindSpace(
        val duplicateBytes: Long = 0,
        val duplicateGroups: Int = 0,
        val biggestBytes: Long = 0,
        val reclaimableBytes: Long = 0,
        val reclaimableCount: Int = 0
    )

    val findSpace = MutableStateFlow(FindSpace())

    /**
     * False until the first scan has actually answered.
     *
     * The scan hashes files and takes seconds on a full phone, and until it
     * returned the hub read its zeroes as an answer and said there was
     * nothing to free up - then filled with rows a moment later. A number
     * that has not been worked out yet is not the number zero.
     */
    val findSpaceChecked = MutableStateFlow(false)

    fun refreshFindSpace() {
        viewModelScope.launch(Dispatchers.IO) {
            val groups = runCatching { DuplicateScanner(ctx).groups() }.getOrDefault(emptyList())
            val largest = runCatching { db.items().largest(50) }.getOrDefault(emptyList())
            // Through the same gate the Reclaim screen uses, not the raw
            // candidate list: the hub must never advertise a figure the screen
            // it links to will refuse in full.
            val freeable = runCatching {
                ReclaimEligibility.judged(
                    ctx, db, repo.current(), System.currentTimeMillis()
                )
            }.getOrDefault(emptyList())
            findSpaceChecked.value = true
            findSpace.value = FindSpace(
                duplicateBytes = groups.sumOf { it.reclaimableBytes },
                duplicateGroups = groups.size,
                biggestBytes = largest.sumOf { it.sizeBytes },
                reclaimableBytes = freeable.sumOf { it.row.sizeBytes },
                reclaimableCount = freeable.size
            )
        }
    }

    // Counted as the history screen lists them: a batch whose trash Android
    // has emptied is not history anyone can act on.
    val reclaimHistoryCount: StateFlow<Int> = db.reclaim().recentBatchesFlow(50)
        .map { batches ->
            val now = System.currentTimeMillis()
            batches.count { !FreeUpFlow.trashExpired(it.atMs, now) }
        }
        .stateIn(viewModelScope, screenLocal, 0)

    val keptBytes: StateFlow<Long> =
        db.items().keptBytesFlow().stateIn(viewModelScope, screenLocal, 0L)

    /** Originals replaced in place that still wait in the trash. */
    val keptOriginals: StateFlow<KeptOriginals> =
        db.items().keptOriginalsFlow().stateIn(viewModelScope, screenLocal, KeptOriginals(0, 0L))

    /**
     * Writes the original of [row], replaced on this phone, back in its
     * place; [done] hears how it went, on the main thread.
     */
    fun putBackOriginal(row: ItemRow, done: (InPlace.PutBack) -> Unit) {
        viewModelScope.launch(Dispatchers.IO) {
            val outcome = runCatching { Stager(ctx, db).putBackOriginal(row.id) }.getOrDefault(InPlace.PutBack.FAILED)
            withContext(Dispatchers.Main) { done(outcome) }
        }
    }

    /** Deletes those originals for good, after the person confirmed it; the result goes to [message]. */
    fun deleteKeptOriginals(done: (count: Int, bytes: Long) -> Unit) {
        // A modified build deletes nothing (TamperCheck).
        if (TamperCheck.isModified(ctx)) return
        viewModelScope.launch(Dispatchers.IO) {
            val (count, bytes) = Stager(ctx, db).deleteKeptOriginals()
            withContext(Dispatchers.Main) { done(count, bytes) }
        }
    }

    val neverOptimiseCount: StateFlow<Int> = db.items().neverOptimiseCountFlow()
        .stateIn(viewModelScope, screenLocal, 0)

    /** One row by id, for screens that hold ids rather than rows. */
    suspend fun itemById(id: Long): ItemRow? =
        withContext(Dispatchers.IO) { runCatching { db.items().byId(id) }.getOrNull() }

    fun clearNeverOptimise() {
        viewModelScope.launch(Dispatchers.IO) {
            db.items().clearNeverOptimise(System.currentTimeMillis())
        }
    }

    // ---- per-item controls (v2.2 B) -----------------------------------------

    /** The same jump-the-queue action for a whole selection. */
    fun optimiseNow(ids: List<Long>) {
        for (id in ids) optimiseNow(id)
    }

    /** Bring one file to the front of the queue. */
    fun optimiseNow(id: Long) {
        viewModelScope.launch(Dispatchers.IO) {
            val row = db.items().byId(id) ?: return@launch
            val now = System.currentTimeMillis()
            // Ask for the jump, do not fake the date. captureAt is what the
            // camera recorded: it is shown in the details dialog, stamped
            // onto the copy so the cloud files it chronologically, and used
            // by the Newest sort. Writing `now` into it bought one run's
            // queue position at the cost of the file's real date, for good.
            db.items().update(Stager.askedFirst(row, now))
        }
    }

    /** A permanent, reversible "leave this one alone". */
    fun setNeverOptimise(id: Long, never: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            val row = db.items().byId(id) ?: return@launch
            val now = System.currentTimeMillis()
            val state = if (never) ItemState.SKIP.name else ItemState.NEW.name
            db.items().update(
                row.copy(
                    neverOptimise = never,
                    state = state,
                    skipReason = if (never) "user_excluded" else null,
                    leftFolderAt = row.leftFolderAtAfter(state, now),
                    updatedAt = now
                )
            )
        }
    }

    // ---- kept light copies (v2.4 J2) ----------------------------------------

    /**
     * Null until the first read has answered, so the screen can show its
     * loading rows rather than "No kept copies" for the moment the read takes.
     */
    val keptCopies = MutableStateFlow<List<ItemRow>?>(null)

    fun loadKeptCopies() {
        viewModelScope.launch(Dispatchers.IO) {
            keptCopies.value = db.items().keptLightCopies()
        }
    }

    /**
     * Removes one kept light copy. No Android dialog is needed - the app
     * created the file - which is exactly why the confirm sheet has to say
     * what is being given up.
     */
    fun removeKeptCopy(row: ItemRow) {
        // The tamper banner promises that on a modified build deleting is off
        // and stays off. This is a delete - of a gallery file the user kept -
        // and it was the one path the promise did not cover.
        if (TamperCheck.isModified(ctx)) return
        viewModelScope.launch(Dispatchers.IO) {
            val uri = keptCopyUri(row)
            val gone = uri != null &&
                runCatching { ctx.contentResolver.delete(uri, null, null) > 0 }.getOrDefault(false)
            // An in-place row stood for the copy itself, so with that file
            // gone it describes nothing on the phone - and says so, rather
            // than an address a restore would take for the original's.
            val inPlace = row.contentUri != null && row.contentUri == row.keptUri
            db.items().update(
                row.copy(
                    keptUri = null,
                    state = KeptCopies.stateAfterRemoval(row.state),
                    originalMissing = row.originalMissing || (inPlace && gone),
                    updatedAt = System.currentTimeMillis()
                )
            )
            loadKeptCopies()
        }
    }

    /**
     * The kept copy's URI, but only when the file there is the copy the row
     * describes - see [KeptCopies]. A restored row can carry another phone's
     * MediaStore number, and this is what stands between that number and
     * `delete()`.
     */
    private fun keptCopyUri(row: ItemRow): Uri? {
        val uri = row.keptUri?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return null
        val (name, size) = runCatching {
            ctx.contentResolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE),
                null, null, null
            )?.use { c -> if (c.moveToFirst()) c.getString(0)?.let { it to c.getLong(1) } else null }
        }.getOrNull() ?: return null
        return if (KeptCopies.isRowsCopy(name, size, row.displayName, row.fingerprint, row.outputBytes)) uri else null
    }


    // ---- device-aware recommendations (F4) ----------------------------------

    /**
     * What these limits should be on *this* phone.
     *
     * A 64 GB phone and a 512 GB phone should not reserve the same headroom,
     * and a cap that suits a metered connection is wrong for someone on Wi-Fi
     * all week. Nothing is changed behind the user's back: the numbers are
     * offered as a one-tap suggestion and only when what is stored has drifted
     * far enough to be worth mentioning.
     */
    data class Recommended(
        val dailyCapMb: Int = Defaults.DAILY_CAP_MB,
        val minFreeMb: Int = Defaults.MIN_FREE_MB,
        val maxExtraMb: Int = Defaults.MAX_EXTRA_MB,
        val capLooksWrong: Boolean = false,
        val freeLooksWrong: Boolean = false,
        /**
         * False until the figures have actually been measured on this phone.
         * The screen stays quiet on the defaults rather than recommending
         * one number and correcting itself a frame later.
         */
        val computed: Boolean = false
    )

    val recommended = MutableStateFlow(Recommended())

    fun refreshRecommended() {
        viewModelScope.launch(Dispatchers.IO) {
            val limits = SpaceLimits.refresh(ctx)
            val o = repo.current()
            recommended.value = Recommended(
                dailyCapMb = limits.dailyCapMb,
                minFreeMb = limits.minFreeMb,
                maxExtraMb = limits.maxExtraMb,
                capLooksWrong = DeviceDefaults.looksWrong(o.dailyCapMb, limits.dailyCapMb),
                freeLooksWrong = DeviceDefaults.looksWrong(o.minFreeMb, limits.minFreeMb),
                computed = true
            )
        }
    }

    // One recommendation, one setting, one button. The old single
    // applyRecommended() silently rewrote all three limits from a button
    // sitting on one card - pressing "Use recommended" beside the daily cap
    // changed two settings the user was not looking at.

    fun applyRecommendedCap() {
        viewModelScope.launch {
            repo.setInt(OptionsRepo.K.DAILY_CAP_MB, recommended.value.dailyCapMb)
            refreshRecommended()
        }
    }

    fun applyRecommendedMinFree() {
        viewModelScope.launch {
            repo.setInt(OptionsRepo.K.MIN_FREE_MB, recommended.value.minFreeMb)
            refreshRecommended()
        }
    }

    fun applyRecommendedMaxExtra() {
        viewModelScope.launch {
            repo.setInt(OptionsRepo.K.MAX_EXTRA_MB, recommended.value.maxExtraMb)
            refreshRecommended()
        }
    }

    fun cleanTemp() {
        viewModelScope.launch(Dispatchers.IO) {
            val freed = Storage.cleanTemp(ctx)
            storageStats.value = storageStats.value.copy(lastTempFreed = freed)
            refreshStorage()
        }
    }

    // ---- actions ------------------------------------------------------------

    /**
     * A run the user asked for.
     *
     * It skips everything the scheduler was waiting for - charger, screen off,
     * today's battery budget - because those exist to avoid surprising
     * someone, and a tap is not a surprise. The safety guards (heat, a nearly
     * flat battery, free space) still apply; [HomeAction] decides whether the
     * button was offered at all.
     */
    fun optimiseNow() {
        Scheduler.runNow(ctx)
        Scheduler.maintainNow(ctx)
        viewModelScope.launch(Dispatchers.IO) {
            activityLog.record(ActivityLog.Kind.OPTIMISED, detail = ctx.getString(R.string.activity_started_by_you))
        }
    }

    /** True while a compression run is actually executing. */
    val running: StateFlow<Boolean> = Scheduler.runningFlow(ctx)
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    fun quickMaintain() {
        viewModelScope.launch(Dispatchers.Default) {
            runCatching { MaintainEngine(ctx).confirmPass() }
            refreshHealth()
        }
    }

    // ---- confirm-uploads flow ----------------------------------------------

    val confirmResult = MutableStateFlow<Int?>(null)

    /**
     * The tap being turned into a window, or the return pass running. A
     * second tap meanwhile is ignored rather than queued, and a resume in
     * the middle of a tap - the notification shade, say - does not spend the
     * window before Ente has even opened.
     */
    private var confirmJob: Job? = null

    /** Whether this screen is in front: Ente is opened only from the front. */
    private var inFront = false

    /**
     * When Ente was last asked to open, until the next return to this screen.
     * The tap's job ends once the launch is handed off, but the screen takes
     * taps until Ente covers it. A second tap then would replace the stored
     * window, find the screen gone, and drop it - and the first tap's window
     * with it. Bounded, so a launch that never came up leaves no dead button.
     */
    private var enteLaunchedAt = 0L

    fun startConfirmFlow() {
        val tappedAt = System.currentTimeMillis()
        if (confirmJob?.isActive == true || !inFront) return
        if (tappedAt - enteLaunchedAt in 0 until ENTE_LAUNCH_GRACE_MS) return
        confirmJob = viewModelScope.launch {
            // One read of the folders, not a pass: it does not wait behind
            // one, so Ente opens at once. The window is on disk before Ente
            // opens, so a return to a new process still counts it. Copies
            // already missing are left out and judged by the normal rules.
            val engine = MaintainEngine(ctx)
            val window = withContext(Dispatchers.IO) {
                runCatching { engine.openConfirmWindow(tappedAt) }.getOrNull()
            }
            // Noted before the launch, on this thread, so no later tap can
            // slip in between.
            val opened = inFront && run {
                enteLaunchedAt = System.currentTimeMillis()
                EnteApp.launch(ctx).also { if (!it) enteLaunchedAt = 0L }
            }
            // A window whose Ente never came up would credit, on the next
            // return, whatever the person cleared by hand meanwhile.
            if (!opened && window != null) {
                withContext(Dispatchers.IO) { runCatching { engine.dropConfirmWindow(window.openedAt) } }
            }
        }
    }

    fun dismissConfirmResult() {
        confirmResult.value = null
    }

    /** The app being in the foreground proves the screen is on (13.G). */
    fun noteScreenOn() {
        viewModelScope.launch {
            repo.setLong(OptionsRepo.K.LAST_INTERACTIVE_AT, System.currentTimeMillis())
        }
    }

    fun onPaused() {
        inFront = false
    }

    fun onResumed() {
        // The battery rows are re-read on every return to the app, so a
        // switch flipped on the system page shows as Allowed the moment the
        // person is back - not, as before, only after the next tap.
        refreshPowerRequirements()
        noteScreenOn()
        inFront = true
        enteLaunchedAt = 0L
        // The first return after "Confirm uploads" judges what Ente took, in
        // this process or a new one: the window is read from where the tap
        // stored it, and spent by that one pass.
        if (confirmJob?.isActive != true) {
            confirmJob = viewModelScope.launch(Dispatchers.Default) {
                if (repo.current().confirmWindow == null) return@launch
                val n = runCatching { MaintainEngine(ctx).returnPass() }.getOrNull()
                if (n != null) confirmResult.value = n
            }
        }
        refreshHealth()
    }

    private var lastMediaMaintain = 0L

    /** Output-folder ContentObserver (foreground only): throttled quick pass. */
    fun onMediaChanged() {
        val now = System.currentTimeMillis()
        if (now - lastMediaMaintain < 5_000) return
        lastMediaMaintain = now
        quickMaintain()
    }

    // ---- deep links from alerts ---------------------------------------------

    /** Route an alert asked for, consumed once by the navigation host. */
    val deepLink = MutableStateFlow<String?>(null)

    /**
     * The route an alert or a launcher shortcut asked for.
     *
     * It arrives on an intent to an exported activity, so it is a string from
     * outside this app and is treated as one: anything the graph does not
     * contain is dropped here rather than handed to the navigator, which
     * would throw and take the app down on launch.
     */
    fun consumeDeepLink(route: String?) {
        if (Routes.isKnown(route)) deepLink.value = route
    }

    fun clearDeepLink() {
        deepLink.value = null
    }

    // ---- option setters -----------------------------------------------------

    fun setScope(v: BackupScope) {
        setStr(OptionsRepo.K.SCOPE, v.name)
        noteSettingChange(
            detail = ActivityWording.encode(ActivityWording.Setting.SCOPE, v.name)
        )
    }

    fun setOutputMode(v: OutputMode) {
        viewModelScope.launch { repo.setOutputMode(v) }
        noteSettingChange(
            detail = ActivityWording.encode(ActivityWording.Setting.LAYOUT, v.name)
        )
    }
    /** Z10.6: the first-chain card was read, either way. */
    fun dismissFirstChainNotice() {
        viewModelScope.launch(Dispatchers.IO) {
            repo.setString(OptionsRepo.K.FIRST_CHAIN_STATE, "DONE")
        }
    }

    /**
     * The "Ente Photos only" card was read. The old choice is replaced by
     * Ente's id, which is what stops the card coming back.
     */
    fun dismissEnteOnlyNotice() {
        viewModelScope.launch(Dispatchers.IO) {
            repo.setString(OptionsRepo.K.CLOUD_SINGLE, EnteApp.ID)
        }
    }

    // ---- where copies go ------------------------------------------------------

    /**
     * An old folder that still holds copies waiting for Ente, and how many.
     * Shown on Home until it runs empty, so the person knows to keep it on in
     * Ente until then.
     */
    data class OldFolder(val path: String, val waiting: Int)

    val oldFolders = MutableStateFlow<List<OldFolder>>(emptyList())

    fun refreshOldFolders() {
        viewModelScope.launch(Dispatchers.IO) {
            val o = repo.current()
            val perFolder = db.items().releasedPerFolder().associate { it.outputRelPath to it.cnt }
            val inUse = o.layout.current + o.layout.otherMode
            oldFolders.value = OutputRoots.outermost(o.pastOutputRoots).mapNotNull { root ->
                val n = OutputRoots.waitingIn(root, perFolder, inUse)
                if (n > 0) OldFolder(root, n) else null
            }
        }
    }

    /**
     * The person tapped Move: new copies go to the default folder from now on.
     * Copies already waiting in the old one stay where they are and are
     * watched there until Ente has them - nothing is moved, nothing is lost.
     */
    fun moveToDefaultFolders() {
        viewModelScope.launch(Dispatchers.IO) {
            repo.setFolders(mapOf(OutFolder.SINGLE to "", OutFolder.PHOTOS to "", OutFolder.VIDEOS to ""))
            noteSettingChange(
                detail = ActivityWording.encode(
                    ActivityWording.Setting.FOLDER, OutputPaths.joined(repo.current().layout)
                )
            )
            refreshOldFolders()
        }
    }

    /** "Done" on the card that asks for the new folder to be turned on in Ente. */
    fun dismissNewFolderCard() {
        viewModelScope.launch(Dispatchers.IO) {
            repo.setBool(OptionsRepo.K.NEW_FOLDER_PENDING, false)
        }
    }

    fun dismissMoveCard() {
        viewModelScope.launch(Dispatchers.IO) {
            repo.setBool(OptionsRepo.K.MOVE_CARD_DISMISSED, true)
        }
    }

    /** Why a typed folder name cannot be used, or null; [taken] counts the person's own files in it. */
    data class FolderCheck(
        val problem: FolderName.Problem? = null,
        val taken: Int = 0,
        /** The gallery could not be asked; a name is never passed unasked. */
        val unchecked: Boolean = false
    ) {
        val ok: Boolean get() = problem == null && taken == 0 && !unchecked
    }

    /**
     * Checks a name typed for [folder]'s copies: the rules a folder name has
     * to meet, and that the folder does not already hold photos or videos of
     * the person's own - Ente Saver's copies must never be mixed in with them.
     */
    suspend fun checkFolderName(folder: OutFolder, name: String): FolderCheck =
        withContext(Dispatchers.IO) {
            val o = repo.current()
            val other = when (folder) {
                OutFolder.PHOTOS -> o.layout.path(OutFolder.VIDEOS)
                OutFolder.VIDEOS -> o.layout.path(OutFolder.PHOTOS)
                OutFolder.SINGLE -> null
            }
            FolderName.problem(name, other)?.let { return@withContext FolderCheck(it) }
            when (val theirs = OutputInventory(ctx).othersIn(FolderName.pathOf(name))) {
                null -> FolderCheck(unchecked = true)
                else -> FolderCheck(taken = theirs)
            }
        }

    /**
     * "" for the default, or a name of the person's own - checked again here,
     * at the moment it is saved, so no answer from a moment ago (the name has
     * changed since, or the gallery was busy) can let a folder through. True
     * when it was saved.
     */
    suspend fun saveFolder(folder: OutFolder, name: String?): FolderCheck {
        if (name != null) {
            val check = checkFolderName(folder, name)
            if (!check.ok) return check
        }
        setFolder(folder, if (name == null) "" else FolderName.pathOf(name))
        return FolderCheck()
    }

    private fun setFolder(folder: OutFolder, value: String) {
        viewModelScope.launch(Dispatchers.IO) {
            repo.setFolders(mapOf(folder to value))
            noteSettingChange(
                detail = ActivityWording.encode(
                    ActivityWording.Setting.FOLDER, repo.current().layout.path(folder)
                )
            )
            refreshOldFolders()
        }
    }
    /**
     * What optimising turns into on this phone, for the Optimisation card.
     * HEIC is known only once the background work has tried it.
     */
    data class EncodePlan(
        val heic: HeicSupport.State = HeicSupport.State.UNKNOWN,
        val videoCodec: VideoCodec = VideoCodec.H264,
        val hevcHardware: Boolean = false,
        /** This phone's photo ceiling in MP (its memory, and what it has taught the app). */
        val photoCeilingMp: Int = 0
    ) {
        /** Whether the photo ceiling is this phone's own, rather than the 50 MP every phone has. */
        val photoCeilingIsPhones: Boolean get() = photoCeilingMp in 1 until DeviceTier.ANY_PHONE_CEILING_MP
    }

    val encodePlan = MutableStateFlow(EncodePlan())

    fun refreshEncodePlan() {
        viewModelScope.launch(Dispatchers.Default) {
            encodePlan.value = EncodePlan(
                heic = HeicSupport.state(ctx),
                videoCodec = PlannedEncode.videoCodec(),
                hevcHardware = EncoderCaps.hardwareEncoders(EncoderCaps.MIME_HEVC).isNotEmpty(),
                photoCeilingMp = DeviceTier.lastingCeilingMp(ctx)
            )
        }
    }

    /** Where optimised files go from now on; files already done stay as they are. */
    fun setSaveMode(mode: SaveMode, note: Boolean = true) {
        viewModelScope.launch(Dispatchers.IO) {
            if (repo.current().saveMode == mode && note) return@launch
            repo.setString(OptionsRepo.K.SAVE_MODE, mode.name)
            // A choice made during setup is where it starts, not a change.
            if (note) noteSettingChange(detail = ActivityWording.encode(ActivityWording.Setting.SAVE_MODE, mode.name))
        }
    }

    /** Whether Android lets Ente Saver replace files in place; asked again on every resume. */
    val fileAccess = MutableStateFlow(InPlace.canReplace(ctx))

    fun refreshFileAccess() {
        fileAccess.value = InPlace.canReplace(ctx)
    }

    fun openFileAccess() {
        OemPages.openFileAccess(ctx)
    }

    fun setTheme(v: ThemeMode) {
        setStr(OptionsRepo.K.THEME, v.name)
        // Mirrored for the next process start, so the first frame is this colour.
        FirstFrame.remember(ctx, v)
        noteSettingChange(
            detail = ActivityWording.encode(ActivityWording.Setting.THEME, v.name)
        )
    }
    fun setDynamicColor(v: Boolean) = setBool(OptionsRepo.K.DYNAMIC_COLOR, v)
    /** Automatic sets the three limits from this phone at once; Custom keeps them as they are. */
    fun setSpaceAuto(on: Boolean) {
        viewModelScope.launch {
            repo.setSpaceAuto(on)
            refreshRecommended()
        }
    }

    fun setDailyCap(v: Int) = setInt(OptionsRepo.K.DAILY_CAP_MB, v)
    fun setMinFree(v: Int) = setInt(OptionsRepo.K.MIN_FREE_MB, v)
    fun setMaxExtra(v: Int) = setInt(OptionsRepo.K.MAX_EXTRA_MB, v)
    fun setAppLock(v: Boolean) = setBool(OptionsRepo.K.APP_LOCK, v)
    fun setWarningsNotif(v: Boolean) = setBool(OptionsRepo.K.WARNINGS_NOTIF, v)
    fun setFreeUpVerified30(v: Boolean) = setBool(OptionsRepo.K.FREE_UP_VERIFIED30, v)

    /** Ends a "Mute for 7 days" early, from Settings, where it is shown. */
    fun unmuteAlerts() {
        viewModelScope.launch { repo.setLong(OptionsRepo.K.ALERTS_MUTED_UNTIL, 0L) }
    }
    fun setReclaimUnderstood(v: Boolean) = setBool(OptionsRepo.K.RECLAIM_UNDERSTOOD, v)

    fun setPauseAll(v: Boolean) {
        setBool(OptionsRepo.K.PAUSE_ALL, v)
        refreshHealth()
        // Worth a line: "why did it stop" is the first question a week later,
        // and a switch flipped once is exactly what nobody remembers doing.
        noteSettingChange(if (v) ActivityLog.Kind.PAUSED else ActivityLog.Kind.RESUMED)
    }

    private fun noteSettingChange(
        kind: ActivityLog.Kind = ActivityLog.Kind.SETTINGS_CHANGED,
        detail: String? = null
    ) {
        viewModelScope.launch(Dispatchers.IO) {
            activityLog.record(kind, detail = detail)
        }
    }

    fun setSpeed(v: SpeedMode) {
        viewModelScope.launch {
            repo.setString(OptionsRepo.K.SPEED, v.name)
            Scheduler.ensure(ctx, repo.current())
        }
        noteSettingChange(
            detail = ActivityWording.encode(ActivityWording.Setting.SPEED, v.name)
        )
    }

    fun setStorageVolume(v: String) = setStr(OptionsRepo.K.STORAGE_VOLUME, v)

    fun setAlbumIncluded(name: String, include: Boolean) {
        viewModelScope.launch { repo.setBucketIncluded(name, include) }
    }

    fun setExcludedBuckets(v: Set<String>) {
        viewModelScope.launch { repo.setStringSet(OptionsRepo.K.EXCLUDED_BUCKETS, v) }
    }

    val buckets = MutableStateFlow<List<String>>(emptyList())

    /**
     * The same albums with their covers and counts, for the pickers. Filled
     * by the same single scan as [buckets] - two flows, one query.
     */
    val albums = MutableStateFlow<List<MediaScanner.Album>>(emptyList())

    /**
     * Whether the album list has actually been read yet.
     *
     * Without it an empty list has two meanings and the screen has to guess.
     * It guessed "still reading", so a phone with no photos on it at all sat
     * on "Loading albums..." for as long as anyone was willing to wait for a
     * list that was never going to arrive. The two states are different
     * sentences, so they need different facts behind them.
     */
    val bucketsLoaded = MutableStateFlow(false)

    /** Folders the app refuses to scan, with why - shown greyed out in the picker. */
    val lockedBuckets = MutableStateFlow<List<Pair<String, ScanSources.Reason>>>(emptyList())

    /**
     * What the ticked albums actually hold, in bytes.
     *
     * A count of albums is not a quantity anyone can reason about: "2 albums"
     * could be forty photos or eighteen gigabytes, and the decision being
     * made on that screen is exactly how much of the gallery to hand over.
     * Null until it has really been measured - a zero here would read as an
     * empty gallery.
     */
    val selectedAlbumBytes = MutableStateFlow<Long?>(null)

    fun refreshSelectedAlbumBytes() {
        viewModelScope.launch(Dispatchers.IO) {
            if (Permissions.mediaAccess(ctx) != Permissions.MediaAccess.FULL) {
                selectedAlbumBytes.value = null
                return@launch
            }
            val o = repo.current()
            if (buckets.value.isNotEmpty() &&
                buckets.value.all { it in o.excludedBuckets }
            ) {
                // Nothing ticked is a real answer, and a cheap one.
                selectedAlbumBytes.value = 0L
                return@launch
            }
            val totals = runCatching { MediaScanner(ctx, db).totals(o.excludedBuckets) }
                .getOrNull() ?: return@launch
            selectedAlbumBytes.value = totals.photoBytes + totals.videoBytes
        }
    }

    fun loadBuckets() {
        viewModelScope.launch(Dispatchers.IO) {
            val scanner = MediaScanner(ctx, db)
            val found = runCatching { scanner.albums() }.getOrDefault(emptyList())
            albums.value = found
            buckets.value = found.map { it.name }
            lockedBuckets.value = runCatching {
                scanner.excludedBucketReasons().toList().sortedBy { it.first }
            }.getOrDefault(emptyList())
            // Last, and set even when the scan came back with nothing: an
            // empty answer is still an answer, and it is the one the screen
            // needs in order to stop saying it is still looking.
            bucketsLoaded.value = true
        }
    }

    // ---- Ente Photos (A2, A3, A5) -------------------------------------------

    /**
     * Whether Ente is on this phone, re-read whenever a screen that depends on
     * it comes back into view - someone sent off to install it returns to a
     * screen that already knows.
     */
    val enteInstalled = MutableStateFlow(false)

    fun refreshEnte() {
        viewModelScope.launch(Dispatchers.IO) {
            enteInstalled.value = EnteApp.isInstalled(ctx)
        }
    }

    fun openEnte(): Boolean = EnteApp.launch(ctx)

    fun installEnte(source: EnteApp.Source): Boolean = EnteApp.openInstallPage(ctx, source)

    fun openEnteHelp(url: String): Boolean = EnteApp.openHelp(ctx, url)

    /**
     * Everything about the link that can actually be checked, checked.
     *
     * "Set it up in the other app and trust that it worked" is the step people
     * get wrong, and the app finds out days later. What is verifiable here is
     * verifiable now: the app is installed, the folder exists, and bytes have
     * moved recently. Anything else is reported as a specific next step rather
     * than a green tick.
     */
    enum class LinkState { CONNECTED, NO_APP, NO_FOLDER, NO_TRAFFIC, CANNOT_TELL }

    val linkState = MutableStateFlow<LinkState?>(null)

    fun verifyCloudLink() {
        viewModelScope.launch(Dispatchers.IO) {
            val pkg = EnteApp.installedPackage(ctx)
            val folderHasFiles = (OutputInventory(ctx).query() ?: emptyList()).isNotEmpty()
            linkState.value = when {
                !EnteApp.isInstalled(ctx) -> LinkState.NO_APP
                !folderHasFiles -> LinkState.NO_FOLDER
                pkg == null -> LinkState.CANNOT_TELL
                else -> {
                    val uid = EnteApp.uidOf(ctx, pkg)
                    val now = System.currentTimeMillis()
                    val tx = uid?.let {
                        UsageVerifier.txBytesForUid(ctx, it, now - 86_400_000L, now)
                    }
                    when {
                        tx == null -> LinkState.CANNOT_TELL
                        tx < 1_000_000 -> LinkState.NO_TRAFFIC
                        else -> LinkState.CONNECTED
                    }
                }
            }
        }
    }

    fun clearLinkState() {
        linkState.value = null
    }

    // ---- background-work requirements (B1) ----------------------------------

    val powerRequirements = MutableStateFlow<List<PowerPages.Requirement>>(emptyList())

    fun refreshPowerRequirements() {
        viewModelScope.launch(Dispatchers.Default) {
            powerRequirements.value = PowerPages.requirementsFor(
                vendor = PowerPages.vendor(),
                ignoringBatteryOptimizations = Permissions.isIgnoringBatteryOptimizations(ctx),
                backgroundRestricted = Permissions.isBackgroundRestricted(ctx),
                permissionsAutoReset = Permissions.permissionsAutoResetOn(ctx)
            )
        }
    }

    fun openPowerPage(id: String) {
        PowerPages.open(ctx, id)
    }

    // ---- onboarding ---------------------------------------------------------

    fun setOnboardingStep(step: Int) = setInt(OptionsRepo.K.ONBOARDING_STEP, step)

    fun finishOnboarding() {
        viewModelScope.launch {
            // Written down before setup counts as done: with nothing stored,
            // a finished setup reads as an install from before 14.
            repo.setString(OptionsRepo.K.SAVE_MODE, repo.current().saveMode.name)
            repo.setBool(OptionsRepo.K.ONBOARDING_DONE, true)
            Scheduler.ensure(ctx, repo.current())
            Scheduler.runNow(ctx)
        }
    }


    // ---- test run (onboarding step 6) ---------------------------------------

    data class TestItem(
        val name: String,
        val before: Long,
        val after: Long,
        /** Pixels kept, or null when the encoder did not record them. */
        val keptPercent: Int? = null,
        /**
         * The row as it stood after staging: the original's address for the
         * thumbnail, the staged copy's path for the comparison. The card
         * used to list three long file names and nothing to look at, on a
         * feature whose whole point is looking.
         */
        val row: ItemRow? = null
    )

    /**
     * How many photos the trial would actually do.
     *
     * The button used to promise "3 files" whatever was there, so a phone
     * with two waiting photos was told a number the app could not deliver.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    val trialSize: StateFlow<Int> = options
        .map { it.excludedBuckets }
        .distinctUntilChanged()
        .flatMapLatest { db.items().waitingPhotoCountFlow(it) }
        .map { it.coerceAtMost(TRIAL_SIZE) }
        .stateIn(viewModelScope, screenLocal, 0)

    /**
     * Detail kept across this phone's optimised files, and the sample it was
     * measured on. Zero files means no figure, and the UI says nothing rather
     * than showing 0%.
     */
    data class DetailKept(val percent: Int, val files: Int)

    val detailKept: StateFlow<DetailKept?> = combine(
        db.items().detailKeptPercentFlow(),
        db.items().detailKeptSampleFlow()
    ) { percent, files ->
        if (files <= 0) null else DetailKept(percent.toInt().coerceIn(1, 100), files)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** The files the trial made copies of; on disk, so a restart keeps the card. */
    private val trialIds = MutableStateFlow<Set<Long>>(emptySet()).also { ids ->
        // Read off the main thread: this view model is built before the
        // first frame, and a disk read there holds the frame up.
        viewModelScope.launch(Dispatchers.IO) { ids.value = TrialRecord.read(ctx) }
    }

    /**
     * The trial's results, for as long as its copies are still inside the app.
     *
     * Read from the rows themselves rather than remembered from the run: the
     * first real run moves these copies to the upload folder, and from then
     * on they are ordinary results in Files - the card has nothing left to
     * show, so it goes. A tap always opens the row as it is now.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    val testRun: StateFlow<List<TestItem>?> = trialIds
        .flatMapLatest { ids ->
            if (ids.isEmpty()) {
                flowOf(null)
            } else {
                db.items().byIdsFlow(ids.toList()).map { rows ->
                    rows.filter { it.state == ItemState.STAGED.name && it.stagePath != null }
                        .sortedByDescending { it.captureAt }
                        .map { row ->
                            TestItem(
                                name = row.displayName,
                                before = row.sizeBytes,
                                after = row.outputBytes ?: row.sizeBytes,
                                keptPercent = QualityKept.measuredDetailKeptPercent(row.srcPixels, row.outPixels),
                                row = row
                            )
                        }
                        .ifEmpty { null }
                }
            }
        }
        .onEach { live ->
            // A copy that has moved on is forgotten here for good, so that if
            // a lost copy is ever made again later it is not mistaken for the
            // trial's and brought back onto the card.
            val kept = live?.mapNotNull { it.row?.id }?.toSet().orEmpty()
            if (kept != trialIds.value) {
                TrialRecord.write(ctx, kept)
                trialIds.value = kept
            }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)
    val testRunning = MutableStateFlow(false)

    /** The last tap found a run making a copy, so the trial did not start. */
    val testBusy = MutableStateFlow(false)

    fun startTestRun() {
        // One trial at a time: a second run would pick three more photos and
        // leave the first three copies with nothing that could remove them.
        if (testRunning.value || trialIds.value.isNotEmpty()) return
        if (mediaAccess.value != Permissions.MediaAccess.FULL) return
        testRunning.value = true
        viewModelScope.launch(Dispatchers.Default) {
            try {
                // One copy is made at a time (Locks.stage), and a run in the
                // middle of a video holds that for up to twenty minutes - all
                // of it with this card on "Trying". Asked without waiting, and
                // held for the whole trial, scan included.
                if (!Locks.stage.tryLock()) {
                    testBusy.value = true
                    return@launch
                }
                testBusy.value = false
                try {
                    runTrial()
                } finally {
                    Locks.stage.unlock()
                }
            } finally {
                testRunning.value = false
            }
        }
    }

    /** The trial itself; the caller holds [Locks.stage]. */
    private suspend fun runTrial() {
        val o = repo.current()
        MediaScanner(ctx, db).scan(stageHeld = true)
        val stager = Stager(ctx, db)
        // The card promises photos "from the albums you chose". The scan
        // above just inventoried the whole phone, so the pick must not read
        // from beyond the ticked albums.
        val picked = db.items().newestNewPhotos(TRIAL_SIZE, o.excludedBuckets)
        val staged = picked.filter { stager.stageHeld(it, o) }
        val ids = staged.map { it.id }.toSet()
        TrialRecord.write(ctx, ids)
        trialIds.value = ids
        if (staged.isNotEmpty()) {
            val rows = SqlChunks.read(ids) { db.items().byIds(it) }
            activityLog.record(
                ActivityLog.Kind.OPTIMISED,
                detail = ctx.getString(R.string.trial_activity),
                count = rows.size,
                bytes = rows.sumOf { (it.sizeBytes - (it.outputBytes ?: it.sizeBytes)).coerceAtLeast(0) }
            )
        }
    }

    /**
     * Throws the trial's copies away and puts the photos back in the queue.
     *
     * The copies live inside the app, and the first real run publishes them
     * rather than remaking them - so keeping them costs nothing but a little
     * space and is the default. This is for the person who would rather not
     * keep them at all. Only a row that is still exactly the trial's staged
     * copy is touched, and under the release lock, so a run publishing it at
     * this moment cannot have the file taken from under it. Everything the
     * staging wrote goes, the pixel counts included - left behind they kept
     * counting in "detail kept" for copies that no longer exist.
     */
    fun discardTrial() {
        val ids = trialIds.value
        if (ids.isEmpty()) return
        viewModelScope.launch(Dispatchers.IO) {
            Locks.release.withLock {
                val now = System.currentTimeMillis()
                for (current in SqlChunks.read(ids) { db.items().byIds(it) }) {
                    val path = current.stagePath
                    if (current.state != ItemState.STAGED.name || path == null) continue
                    runCatching { File(path).delete() }
                    db.items().update(
                        current.copy(
                            state = ItemState.NEW.name,
                            stagePath = null,
                            outputName = null,
                            outputBytes = null,
                            outputSha256 = null,
                            outputFolder = null,
                            srcPixels = 0,
                            outPixels = 0,
                            presetUsed = null,
                            codecUsed = null,
                            predictedBytes = 0,
                            lastError = null,
                            updatedAt = now
                        )
                    )
                }
            }
            TrialRecord.write(ctx, emptySet())
            trialIds.value = emptySet()
        }
    }

    /**
     * Opens an item in whatever viewer the phone uses for it.
     *
     * Prefers the released copy when there is one - that is the file the user
     * is being told about - and falls back to the original. Read permission is
     * granted to the receiving app for that one uri only.
     *
     * A plain view intent, so the phone's default viewer opens - and where
     * none is set, Android asks once with "Just once" and "Always" and then
     * remembers. The forced chooser this used to send put the whole "open
     * with" sheet up on every tap and never let the choice stick; it is kept
     * only as the fallback for a phone with no viewer registered at all.
     */
    fun openInViewer(row: ItemRow): Boolean {
        val uriString = row.outputUri ?: row.contentUri ?: return false
        val uri = runCatching { Uri.parse(uriString) }.getOrNull() ?: return false
        val mime = row.mimeType.ifEmpty { if (row.isVideo) "video/*" else "image/*" }
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_ACTIVITY_NEW_TASK
            )
        }
        return try {
            Errand.begin()
            ctx.startActivity(view)
            true
        } catch (e: ActivityNotFoundException) {
            val chooser = Intent.createChooser(view, null).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            runCatching { ctx.startActivity(chooser) }.isSuccess.also { if (!it) Errand.cancel() }
        } catch (e: Exception) {
            Errand.cancel()
            false
        }
    }

    /** Clears the one-time notice about the removed legacy placeholder. */
    fun dismissPlaceholderNotice() {
        viewModelScope.launch {
            repo.setBool(OptionsRepo.K.PLACEHOLDER_REMOVED, false)
        }
    }


    // ---- delete flows -------------------------------------------------------
    // API 30+: one system batch dialog (MediaStore.createDeleteRequest).
    // API 29: sequential RecoverableSecurityException flow, one consent per file.

    /**
     * Emits when a flow already under way needs the UI to launch another
     * consent dialog: the next file on Android 10, or the next chunk of a
     * large selection on 11 and up. The first dialog of a batch comes back
     * from [requestDelete] instead, so this stays null until one is needed.
     */
    val deleteIntent = MutableStateFlow<IntentSender?>(null)

    /**
     * The system dialog already on screen. Turning the phone, folding it or
     * resizing the window rebuilds the screen, and the rebuilt screen sees
     * the same request still pending: without this it opened a second dialog
     * over the first, and the answer to one was counted for the other.
     */
    private var dialogOnScreen: IntentSender? = null

    /** True once per request: whether the screen should open its dialog now. */
    fun takeDialog(sender: IntentSender): Boolean {
        if (sender === dialogOnScreen) return false
        dialogOnScreen = sender
        return true
    }

    private var deleteOnDone: ((List<Uri>) -> Unit)? = null
    private var systemDialogUris: List<Uri> = emptyList()
    /**
     * Whatever is left of a large selection, and what has been agreed so far.
     *
     * The batch dialog is asked for one chunk at a time: every URI travels
     * into a PendingIntent through a size-limited binder transaction, and a
     * confirmation listing thousands of files is not one anybody can read.
     */
    private var deleteChunks: ArrayDeque<List<Uri>> = ArrayDeque()
    private val deleteAgreed = mutableListOf<Uri>()
    private val legacyQueue = ArrayDeque<Uri>()
    private val legacySucceeded = mutableListOf<Uri>()

    /**
     * Starts a delete of [uris]. Returns an IntentSender the UI must launch
     * (API 30+ batch dialog), or null when the API-29 sequential flow drives
     * itself via [deleteIntent]. [onDone] receives the deleted uris.
     */
    fun requestDelete(uris: List<Uri>, onDone: (List<Uri>) -> Unit): IntentSender? {
        // A modified build may not remove anything - see the gate in
        // ReclaimViewModel. This is the leftover-work-files path; its button is
        // already hidden on a modified build, but the refusal belongs here too
        // so hiding a control is not the only thing standing in the way.
        if (TamperCheck.isModified(ctx)) return null
        deleteOnDone = onDone
        // Nothing to ask about still owes the caller its answer, or the card
        // that started this waits for a callback that never arrives.
        if (uris.isEmpty()) {
            finishDelete(emptyList())
            return null
        }
        return if (Build.VERSION.SDK_INT >= 30) {
            deleteChunks = ArrayDeque(ReclaimRules.batches(uris))
            deleteAgreed.clear()
            nextDeleteChunk()
        } else {
            systemDialogUris = emptyList()
            legacyQueue.clear()
            legacyQueue.addAll(uris)
            legacySucceeded.clear()
            processLegacyQueue()
            null
        }
    }

    /** The next chunk's dialog, or null when there is nothing left to ask. */
    private fun nextDeleteChunk(): IntentSender? {
        // Both callers gate on this already; repeating it here is what makes
        // the guard true by reading rather than by tracing the callers.
        if (Build.VERSION.SDK_INT < 30) return null
        val next = deleteChunks.removeFirstOrNull() ?: return null
        systemDialogUris = next
        return MediaStore.createDeleteRequest(ctx.contentResolver, next).intentSender
    }

    /** UI reports the outcome of whichever consent dialog was shown. */
    fun onDeleteDialogResult(ok: Boolean) {
        dialogOnScreen = null
        // Cleared first, always. A sender left sitting in the flow is
        // relaunched the next time this screen is opened, and the user gets a
        // delete dialog they never asked for.
        deleteIntent.value = null
        if (Build.VERSION.SDK_INT >= 30) {
            val uris = systemDialogUris
            systemDialogUris = emptyList()
            if (ok) deleteAgreed += uris
            // Keep asking while the user keeps agreeing; a refusal ends it
            // with whatever was already allowed.
            if (ok && deleteChunks.isNotEmpty()) {
                deleteIntent.value = nextDeleteChunk()
                return
            }
            deleteChunks.clear()
            val agreed = deleteAgreed.toList()
            deleteAgreed.clear()
            finishDelete(agreed)
            return
        }
        if (legacyQueue.isNotEmpty()) {
            val uri = legacyQueue.removeFirst()
            if (ok) {
                viewModelScope.launch(Dispatchers.IO) {
                    runCatching {
                        if (ctx.contentResolver.delete(uri, null, null) > 0) {
                            legacySucceeded.add(uri)
                        }
                    }
                    processLegacyQueue()
                }
                return
            }
        }
        processLegacyQueue()
    }

    private fun processLegacyQueue() {
        viewModelScope.launch(Dispatchers.IO) {
            while (legacyQueue.isNotEmpty()) {
                val uri = legacyQueue.first()
                try {
                    if (ctx.contentResolver.delete(uri, null, null) > 0) {
                        legacySucceeded.add(uri)
                    }
                    legacyQueue.removeFirst()
                } catch (se: SecurityException) {
                    val sender = (se as? RecoverableSecurityException)
                        ?.userAction?.actionIntent?.intentSender
                    if (sender != null) {
                        deleteIntent.value = sender
                        return@launch
                    }
                    legacyQueue.removeFirst()
                } catch (e: Exception) {
                    legacyQueue.removeFirst()
                }
            }
            finishDelete(legacySucceeded.toList())
        }
    }

    private fun finishDelete(deleted: List<Uri>) {
        val callback = deleteOnDone
        deleteOnDone = null
        viewModelScope.launch { callback?.invoke(deleted) }
    }


    // ---- old-install cleanup ------------------------------------------------

    val leftoverUris = MutableStateFlow<List<Uri>>(emptyList())

    /**
     * Copies the maintenance pass chose to clear and Android would not let it
     * delete on its own - files an earlier install made, adopted after a
     * reinstall or a phone move. They count against the space the user
     * allowed, so with enough of them the resource gate stopped every run,
     * and nothing in the app could ever remove them. Home asks, once,
     * through Android's own dialog.
     */
    val consentCopies: StateFlow<List<ItemRow>> = options
        .map { o -> o.copiesNeedConsent.mapNotNull { it.toLongOrNull() } }
        .distinctUntilChanged()
        .map { ids ->
            // Nothing bounds how many ids collect here, so they are read a
            // slice at a time (SqlChunks), and a failed read shows no card
            // rather than closing the app every time Home opens.
            SqlChunks.read(ids) { db.items().byIds(it) }.filter { it.outputUri != null }
        }
        .catch { emit(emptyList()) }
        .flowOn(Dispatchers.IO)
        .stateIn(viewModelScope, screenLocal, emptyList())

    fun removeConsentCopies() {
        if (TamperCheck.isModified(ctx)) return
        viewModelScope.launch(Dispatchers.IO) {
            val rows = consentCopies.value
            val uris = rows.mapNotNull { r ->
                r.outputUri?.let { runCatching { Uri.parse(it) }.getOrNull() }
            }
            if (uris.isEmpty()) {
                repo.removeCopiesNeedingConsent(rows.map { it.id })
                return@launch
            }
            // Mark first: a copy that leaves through this dialog leaves because
            // the app asked, and the maintenance pass must not read its
            // absence as the cloud having collected it.
            val now = System.currentTimeMillis()
            for (r in rows) db.items().update(r.copy(appDeletedCopy = true, updatedAt = now))
            withContext(Dispatchers.Main) {
                val sender = requestDelete(uris) { deleted ->
                    finishConsentCopies(rows, deleted.map { it.toString() }.toSet())
                }
                if (sender != null) deleteIntent.value = sender
            }
        }
    }

    private fun finishConsentCopies(rows: List<ItemRow>, deleted: Set<String>) {
        viewModelScope.launch(Dispatchers.IO) {
            val now = System.currentTimeMillis()
            val gone = mutableListOf<Long>()
            for (r in rows) {
                val current = db.items().byId(r.id) ?: continue
                if (r.outputUri != null && r.outputUri in deleted) {
                    db.items().update(
                        current.copy(
                            state = ItemState.DONE.name,
                            goneReason = GoneReason.APP_DELETED.name,
                            outputUri = null,
                            leftFolderAt = current.leftFolderAtAfter(ItemState.DONE.name, now),
                            updatedAt = now
                        )
                    )
                    gone += r.id
                } else {
                    // Refused: the copy stays, and so does the row's claim
                    // on the list, for the next time the user is asked.
                    db.items().update(current.copy(appDeletedCopy = false, updatedAt = now))
                }
            }
            repo.removeCopiesNeedingConsent(gone)
        }
    }

    fun detectLeftoverFiles() {
        viewModelScope.launch(Dispatchers.IO) {
            val o = repo.current()
            // Until the first run has matched copies to their originals, every
            // copy of an earlier install looks like a leftover - including the
            // ones still waiting for Ente.
            if (o.oldFilesCleaned || !o.copiesReattached) {
                leftoverUris.value = emptyList()
                return@launch
            }
            // While the earlier Ente Saver is installed, its copies are its
            // own, still waiting for Ente.
            if (EarlierInstall.isInstalled(ctx)) {
                leftoverUris.value = emptyList()
                return@launch
            }
            // Only a file named the way this pipeline names its output can be
            // an earlier install's leftover. Anything else in the folder is
            // the user's own file: this card used to sweep those up too, and
            // its Remove button would then have offered the user's own photo
            // for deletion under the label "leftover". The user's files get a
            // notice, never a button.
            val named = (OutputInventory(ctx).query() ?: emptyList())
                .filterNot { it.ownedByUs }
                .mapNotNull { entry -> Fingerprint.fpFromOutputName(entry.name)?.let { entry to it } }
            // A copy whose original the ledger knows is never a leftover,
            // whatever its state: one restored from a history file may still
            // be waiting for Ente, and removing it would mean Ente never gets it.
            val known = SqlChunks.read(named.map { it.second }.distinct()) { db.items().knownFingerprints(it) }
                .toHashSet()
            leftoverUris.value = named.filter { it.second !in known }.map { it.first.uri }
        }
    }

    fun onLeftoversCleaned() {
        viewModelScope.launch {
            repo.setBool(OptionsRepo.K.OLD_FILES_CLEANED, true)
            leftoverUris.value = emptyList()
        }
    }

    /**
     * Android's answer to Remove. Cancel, or a partly approved delete, leaves
     * the card up for the files still there instead of hiding it for good.
     */
    fun onLeftoversRemoveResult(asked: List<Uri>, deleted: List<Uri>) {
        if (LeftoverRules.allRemoved(asked, deleted)) onLeftoversCleaned() else detectLeftoverFiles()
    }

    // ---- encrypted backup / restore -----------------------------------------

    val transferMessage = MutableStateFlow<String?>(null)

    /** Set when an import hit an encrypted file and needs the password. */
    val pendingImportUri = MutableStateFlow<Uri?>(null)
    val importPasswordWrong = MutableStateFlow(false)
    val transferBusy = MutableStateFlow(false)

    fun exportState(uri: Uri, password: String?, doneLabel: String, failLabel: String) {
        viewModelScope.launch(Dispatchers.IO) {
            transferBusy.value = true
            val ok = SnapshotStore(ctx, db, repo).exportTo(uri, password)
            transferBusy.value = false
            transferMessage.value = if (ok) doneLabel else failLabel
        }
    }

    /**
     * Restores a backup file. An encrypted file with no password parks the uri
     * in [pendingImportUri] so the UI can ask for one and call this again.
     */
    fun importState(
        uri: Uri,
        password: String?,
        doneLabel: String,
        failLabel: String,
        wrongPasswordLabel: String
    ) {
        viewModelScope.launch(Dispatchers.IO) {
            transferBusy.value = true
            val result = SnapshotStore(ctx, db, repo).importFrom(uri, password)
            transferBusy.value = false
            when (result) {
                is SnapshotStore.ImportResult.Success -> {
                    pendingImportUri.value = null
                    importPasswordWrong.value = false
                    transferMessage.value = "$doneLabel (${result.imported})"
                }
                SnapshotStore.ImportResult.NeedsPassword -> {
                    importPasswordWrong.value = false
                    pendingImportUri.value = uri
                }
                SnapshotStore.ImportResult.WrongPassword -> {
                    importPasswordWrong.value = true
                    pendingImportUri.value = uri
                    transferMessage.value = wrongPasswordLabel
                }
                SnapshotStore.ImportResult.Unreadable -> {
                    pendingImportUri.value = null
                    transferMessage.value = failLabel
                }
                SnapshotStore.ImportResult.TooLarge -> {
                    pendingImportUri.value = null
                    transferMessage.value = ctx.getString(R.string.transfer_too_large)
                }
            }
        }
    }

    fun cancelPendingImport() {
        pendingImportUri.value = null
        importPasswordWrong.value = false
    }

    fun dismissTransferMessage() {
        transferMessage.value = null
    }

    // ---- tiny helpers -------------------------------------------------------

    private fun setStr(key: Preferences.Key<String>, v: String) {
        viewModelScope.launch { repo.setString(key, v) }
    }

    private fun setInt(key: Preferences.Key<Int>, v: Int) {
        viewModelScope.launch { repo.setInt(key, v) }
    }

    private fun setBool(key: Preferences.Key<Boolean>, v: Boolean) {
        viewModelScope.launch { repo.setBool(key, v) }
    }
}
