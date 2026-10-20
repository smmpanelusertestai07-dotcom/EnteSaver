package app.entesaver.ui

import android.app.Application
import android.app.RecoverableSecurityException
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import app.entesaver.R
import app.entesaver.core.logic.DuplicateRules
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.FreeUpFlow
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.ListFilters
import app.entesaver.core.logic.Platform
import app.entesaver.core.logic.ReclaimRules
import app.entesaver.core.logic.Suggestions
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.db.ReclaimBatchRow
import app.entesaver.data.db.ReclaimItemRow
import app.entesaver.data.db.leftFolderAtAfter
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.engine.ActivityLog
import app.entesaver.engine.DuplicateScanner
import app.entesaver.engine.ReclaimEligibility
import app.entesaver.engine.ReclaimEngine
import app.entesaver.media.MediaScanner
import app.entesaver.media.Stager
import app.entesaver.util.Formats
import app.entesaver.util.TamperCheck
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The one screen in the app that can destroy a user's photo.
 *
 * Its own view model, with a SavedStateHandle, because a selection of four
 * hundred files must survive a rotation or a process death - losing it and
 * silently starting again is how someone deletes the wrong batch.
 */
class ReclaimViewModel(
    app: Application,
    private val saved: SavedStateHandle
) : AndroidViewModel(app) {

    private val ctx get() = getApplication<Application>()
    private val db = AppDb.get(ctx)
    private val repo = OptionsRepo.get(ctx)
    private val engine = ReclaimEngine(ctx)

    companion object {
        /** The two kinds of proof, kept visibly apart (v3.0 C1). */
        const val GROUP_EXACT = "exact"
        const val GROUP_BY_SIZE = "by_size"

        private const val KEY_SELECTED = "reclaim.selected"
        private const val KEY_MODE = "reclaim.mode"
        private const val KEY_TARGET = "reclaim.target"
        private const val KEY_SORT = "reclaim.sort"
        private const val KEY_GROUP = "reclaim.group"
    }

    enum class Sort { LARGEST, OLDEST, ALBUM }
    enum class Grouping { EVIDENCE, ALBUM, MONTH, YEAR, TYPE }



    /** One row as the screen needs it: the rules' view plus what to draw. */
    data class Entry(
        val row: ItemRow,
        val candidate: ReclaimRules.Candidate
    ) {
        val id: Long get() = row.id
        val saving: Long get() = (row.sizeBytes - (row.outputBytes ?: 0L)).coerceAtLeast(0L)
    }

    val entries = MutableStateFlow<List<Entry>>(emptyList())

    /**
     * Where a replacement copy lands, live from the stored options so the
     * choice reads the same here as it does anywhere else it is shown.
     */
    val keptInPlace: StateFlow<Boolean> = repo.flow
        .map { it.keptInPlace }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), false)

    fun setKeptInPlace(value: Boolean) {
        viewModelScope.launch { repo.setBool(OptionsRepo.K.KEPT_IN_PLACE, value) }
    }

    /**
     * Which cloud app holds each batch's copies (Z10.1). Proof belongs to the
     * app that was selected when the file was sent, so the confirmation sheet
     * names that app - not whichever app is selected today.
     */
    val holdingApps = MutableStateFlow<Map<Long, String>>(emptyMap())
    val loading = MutableStateFlow(false)

    /** Selection, mode, target and view options all survive a rotation. */
    val selected = MutableStateFlow(saved.get<LongArray>(KEY_SELECTED)?.toSet() ?: emptySet())
    val mode = MutableStateFlow(
        saved.get<String>(KEY_MODE)?.let { runCatching { ReclaimRules.Mode.valueOf(it) }.getOrNull() }
            ?: ReclaimRules.Mode.REPLACE_WITH_LIGHT
    )
    val targetBytes = MutableStateFlow(saved.get<Long>(KEY_TARGET) ?: 0L)
    val sort = MutableStateFlow(
        saved.get<String>(KEY_SORT)?.let { runCatching { Sort.valueOf(it) }.getOrNull() }
            ?: Sort.LARGEST
    )
    val grouping = MutableStateFlow(
        saved.get<String>(KEY_GROUP)?.let { runCatching { Grouping.valueOf(it) }.getOrNull() }
            ?: Grouping.EVIDENCE
    )
    val suggestion = MutableStateFlow<Suggestions.Kind?>(null)
    val videosOnly = MutableStateFlow(false)
    val minSizeFilter = MutableStateFlow(0L)

    val skipFavourites = MutableStateFlow(true)
    val skipSmall = MutableStateFlow(true)

    /**
     * Whether this phone can undo a removal.
     *
     * Android 9 and 10 have no media trash. Offering "Move to trash" there and then
     * permanently deleting would be the worst thing this screen could do, so
     * the screen asks this and words itself accordingly.
     */
    val canUndoRemoval: Boolean = Platform.canTrash(Build.VERSION.SDK_INT)

    /** Result of the last batch, and of a dry run. */
    val lastResult = MutableStateFlow<ReclaimEngine.Result?>(null)
    val dryRun = MutableStateFlow<DryRun?>(null)
    val pendingIntent = MutableStateFlow<IntentSender?>(null)

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
        kindOnScreen = pendingKind
        return true
    }

    /**
     * Which flow the pending request, and the one on screen, belong to.
     *
     * Free up, Duplicates and History all open whatever request is pending,
     * and each used to send the answer to its own handler. Someone who left
     * Free up while a batch was being prepared and opened History was shown
     * the trash dialog there; History's handler was the restore one, so the
     * originals went to the trash and the batch was never written down - no
     * history, no restore, and copies left behind as new photos. The answer
     * now goes to the flow that asked, whichever screen opened the dialog.
     */
    @Volatile private var pendingKind: FreeUpFlow.Dialog? = null
    private var kindOnScreen: FreeUpFlow.Dialog? = null

    /** The one place a request is handed to the screens, tagged with its flow. */
    private fun ask(sender: IntentSender?, kind: FreeUpFlow.Dialog) {
        pendingKind = if (sender != null) kind else null
        pendingIntent.value = sender
    }

    /** Every screen's dialog launcher answers here, and only here. */
    fun onSystemDialogResult(granted: Boolean) {
        val kind = kindOnScreen ?: pendingKind
        kindOnScreen = null
        when (FreeUpFlow.answerGoesTo(kind)) {
            FreeUpFlow.Answer.REMOVAL -> onDialogResult(granted)
            FreeUpFlow.Answer.RESTORE -> onRestoreResult(granted)
            FreeUpFlow.Answer.NOBODY -> {
                dialogOnScreen = null
                pendingIntent.value = null
            }
        }
    }

    /**
     * True from the tap that starts a batch until the batch is written down,
     * including while Android's dialog is open. The screen disables its
     * buttons and shows progress on it: preparing light copies can take
     * minutes, and a screen that looked idle got a second tap, which ran a
     * second batch over the first.
     */
    val busy = MutableStateFlow(false)

    /**
     * True while a batch waits for the file the background run is
     * optimising, before it can remake light copies. A minute at most
     * (ReclaimEngine.STAGE_WAIT_MS), and the screen says what it is waiting
     * for rather than spin.
     */
    val waitingForStage = MutableStateFlow(false)

    /**
     * Whether any removal or restore is still under way. One flow at a time:
     * each keeps its own state between dialogs, and a second one started
     * part way through overwrote it.
     */
    private fun flowOpen(): Boolean =
        busy.value || prepared != null || pendingIntent.value != null ||
            legacyQueue.isNotEmpty() || pendingDuplicateIds.isNotEmpty() ||
            restoring.isNotEmpty()

    private var prepared: ReclaimEngine.Prepared? = null
    private var pendingMode: ReclaimRules.Mode = ReclaimRules.Mode.REPLACE_WITH_LIGHT
    private var pendingTrash = true

    /**
     * A large selection is confirmed in chunks, one system dialog each.
     *
     * The whole selection used to go into a single request. Nothing in the
     * platform documents a maximum, but every URI rides into a PendingIntent
     * through a size-limited binder transaction, and a dialog listing a
     * thousand files is not something anyone can read before agreeing to it.
     * What the user actually approves is recorded chunk by chunk, so the
     * result reflects the taps rather than assuming the whole batch went.
     */
    private var consentChunks: ArrayDeque<List<Uri>> = ArrayDeque()
    private var consentCurrent: List<Uri> = emptyList()
    private val consentConfirmed = mutableSetOf<String>()
    private var consentPermanent = false

    data class DryRun(
        val count: Int,
        val freedBytes: Long,
        val dropped: List<Pair<String, ReclaimRules.Refusal>>
    )

    // ---- loading -------------------------------------------------------------

    fun load() {
        viewModelScope.launch(Dispatchers.IO) {
            loading.value = true
            val o = repo.current()
            val now = System.currentTimeMillis()
            // Both grades are offered, always. The old switch asked the user
            // to configure their own safety, which is a question nobody can
            // answer; the list simply separates the two and says what each
            // one means, and nothing in the weaker group starts selected.
            //
            // Through ReclaimEligibility, which is also what the Free up space
            // hub adds up - so the figure on the card and the rows on this
            // screen cannot say different things.
            val judged = ReclaimEligibility.judged(
                ctx, db, o, now,
                skipFavourites = skipFavourites.value, skipSmall = skipSmall.value
            )
            holdingApps.value = judged.mapNotNull { it.row.batchId }.distinct()
                .mapNotNull { id ->
                    db.batches().byId(id)?.cloudPackage?.let { pkg -> id to pkg }
                }
                .toMap()
            entries.value = judged.map { Entry(it.row, it.candidate) }
            explainHandOver(judged, now)
            loading.value = false
        }
    }

    private suspend fun cloudHealthy(): Boolean =
        ReclaimEligibility.cloudHealthy(ctx, repo.current())

    /**
     * The shared list filters, so Reclaim narrows the same way as every other
     * list rather than through its own private set of chips.
     */
    val listFilter = MutableStateFlow(ListFilters.State())

    /** The list after filters, sorting and any active suggestion. */
    fun visible(): List<Entry> {
        val now = System.currentTimeMillis()
        var list = entries.value
        val shared = listFilter.value
        if (!shared.isDefault || shared.query.isNotBlank()) {
            list = list.filter {
                ListFilters.matches(
                    ListFilters.Candidate(
                        id = it.id,
                        name = it.row.displayName,
                        album = it.row.bucket,
                        sizeBytes = it.row.sizeBytes,
                        isVideo = it.row.isVideo
                    ),
                    shared
                )
            }
        }
        suggestion.value?.let { kind ->
            val filter = Suggestions.ALL.first { it.kind == kind }
            val keep = Suggestions.apply(
                list.map { it.candidate }, filter,
                ageDaysOf = { c -> Formats.daysBetween(c.capturedAtMs, now) },
                nameOf = { c -> list.first { e -> e.id == c.id }.row.displayName }
            ).map { it.id }.toSet()
            list = list.filter { it.id in keep }
        }
        if (videosOnly.value) list = list.filter { it.row.isVideo }
        if (minSizeFilter.value > 0) list = list.filter { it.row.sizeBytes >= minSizeFilter.value }
        return when (sort.value) {
            Sort.LARGEST -> list.sortedByDescending { it.row.sizeBytes }
            Sort.OLDEST -> list.sortedBy { it.row.captureAt }
            Sort.ALBUM -> list.sortedWith(
                compareBy({ it.row.bucket ?: "" }, { -it.row.sizeBytes })
            )
        }
    }

    fun groups(): Map<String, List<Entry>> {
        val list = visible()
        return when (grouping.value) {
            Grouping.EVIDENCE -> list.groupBy {
                if (it.candidate.evidence == Evidence.VERIFIED) GROUP_BY_SIZE else GROUP_EXACT
            }
            Grouping.ALBUM -> list.groupBy { it.row.bucket ?: "" }
            Grouping.MONTH -> list.groupBy { Formats.monthKey(it.row.captureAt) }
            Grouping.YEAR -> list.groupBy { Formats.yearKey(it.row.captureAt) }
            Grouping.TYPE -> list.groupBy { if (it.row.isVideo) "video" else "photo" }
        }
    }

    // ---- selection -----------------------------------------------------------

    fun toggle(id: Long) {
        selected.value = selected.value.toMutableSet().apply {
            if (!add(id)) remove(id)
        }
        persistSelection()
    }

    fun selectAllVisible() {
        selected.value = selected.value + visible().map { it.id }
        persistSelection()
    }

    /** Ticks a whole group, or unticks it, as its box says. */
    fun tickGroup(key: String, tick: Boolean) {
        val ids = groups()[key]?.map { it.id } ?: return
        selected.value = FreeUpFlow.tickGroup(selected.value, ids, tick)
        persistSelection()
    }

    fun clearSelection() {
        selected.value = emptySet()
        persistSelection()
    }

    /**
     * Hands one file to Reclaim, ticked and alone.
     *
     * Removing an original from anywhere else in the app goes through here
     * rather than doing its own deletion: Reclaim is where the eligibility
     * gate, the mode choice and the trash-first rule live, and a second path
     * that skipped any of them would be the one that eventually loses a photo.
     */
    /**
     * A file another list handed over, that this screen cannot offer, and
     * why - with the day it can be, when the only thing in the way is the
     * 30-day wait.
     */
    data class HandOver(val name: String, val refusal: ReclaimRules.Refusal, val readyOn: Long?)

    val handOver = MutableStateFlow<HandOver?>(null)
    private var handedOverId: Long? = null

    /**
     * Opens this screen on one file, from "Remove from phone" elsewhere.
     *
     * Every narrowing is cleared on the way in - album, type, size and
     * suggestion: they live as long as the app does, and one left over from
     * the last visit hid the very file being handed over, or showed a
     * different album's photos under it. And when the file
     * is not one this screen can offer, [load] says why rather than showing
     * "0 of 12 selected" and the rest of the phone.
     */
    fun selectOnly(id: Long) {
        listFilter.value = ListFilters.State()
        suggestion.value = null
        videosOnly.value = false
        minSizeFilter.value = 0L
        selected.value = setOf(id)
        persistSelection()
        handedOverId = id
        handOver.value = null
    }

    /** Why a handed-over file is not in [entries], or null when it is. */
    private suspend fun explainHandOver(judged: List<ReclaimEligibility.Judged>, now: Long) {
        val id = handedOverId ?: return
        handedOverId = null
        if (judged.any { it.row.id == id }) return
        val row = db.items().byId(id) ?: return
        val o = repo.current()
        val inLedger = row.outputSha256 != null &&
            db.ledger().all().any { it.outputSha256 == row.outputSha256 }
        val favourites = if (skipFavourites.value) MediaScanner(ctx, db).favouriteUris() else emptySet()
        val candidate = ReclaimEligibility.candidateOf(
            row, now, inLedger, favourite = ReclaimEligibility.isFavourite(row, favourites)
        )
        val healthy = ReclaimEligibility.cloudHealthy(ctx, o)
        fun refuse(c: ReclaimRules.Candidate) = ReclaimRules.refuse(
            c, healthy, o.freeUpAllowVerified30,
            skipFavourites = skipFavourites.value, skipSmall = skipSmall.value
        )
        var refusal = refuse(candidate) ?: return
        var readyOn: Long? = null
        if (refusal == ReclaimRules.Refusal.TOO_RECENT) {
            // A date only when the wait is all that stands in the way; if
            // something else would refuse it afterwards, that is the answer.
            val waited = ReclaimRules.MIN_CONFIRM_AGE_DAYS
            val after = refuse(candidate.copy(confirmedAgeDays = waited, addedDaysAgo = waited))
            if (after == null) {
                readyOn = Formats.dayAfter(
                    maxOf(row.confirmedAt ?: row.releasedAt ?: now, row.dateAdded * 1000),
                    waited
                )
            } else {
                refusal = after
            }
        }
        selected.value = selected.value - id
        persistSelection()
        handOver.value = HandOver(row.displayName, refusal, readyOn)
    }

    /** The screen was left, not turned: a note about a handed-over file is done. */
    fun clearHandOver() {
        handOver.value = null
    }

    /** "Free 5 GB": pick largest-first until the number is met. */
    fun selectForTarget(bytes: Long) {
        targetBytes.value = bytes
        saved[KEY_TARGET] = bytes
        val chosen = ReclaimRules.selectForTarget(
            visible().map { it.candidate }, bytes, mode.value
        )
        selected.value = chosen.map { it.id }.toSet()
        persistSelection()
    }

    fun setMode(value: ReclaimRules.Mode) {
        mode.value = value
        saved[KEY_MODE] = value.name
    }

    fun setSort(value: Sort) {
        sort.value = value
        saved[KEY_SORT] = value.name
    }

    fun setGrouping(value: Grouping) {
        grouping.value = value
        saved[KEY_GROUP] = value.name
    }

    private fun persistSelection() {
        saved[KEY_SELECTED] = selected.value.toLongArray()
    }

    fun selectedEntries(): List<Entry> = visible().filter { it.id in selected.value }


    fun needsSecondConfirmation(permanent: Boolean): Boolean =
        ReclaimRules.needsSecondConfirmation(
            selectedEntries().map { it.candidate },
            entries.value.size,
            mode.value,
            // Without a trash to fall back on, every removal of an original is
            // permanent, whatever the button was called.
            permanent = permanent || (!canUndoRemoval && mode.value != ReclaimRules.Mode.COPIES_ONLY)
        )

    // ---- dry run and export --------------------------------------------------

    /** Says exactly what would happen, and touches nothing. */
    fun previewResult() {
        viewModelScope.launch(Dispatchers.IO) {
            val o = repo.current()
            val healthy = cloudHealthy()
            val chosen = selectedEntries()
            val dropped = chosen.mapNotNull { entry ->
                ReclaimRules.refuse(
                    entry.candidate, healthy,
                    allowVerifiedBySize = o.freeUpAllowVerified30,
                    skipFavourites = skipFavourites.value, skipSmall = skipSmall.value
                )?.let { entry.row.displayName to it }
            }
            val keptIds = dropped.map { it.first }.toSet()
            val surviving = chosen.filter { it.row.displayName !in keptIds }
            dryRun.value = DryRun(
                count = surviving.size,
                freedBytes = ReclaimRules.savedBytes(surviving.map { it.candidate }, mode.value),
                dropped = dropped
            )
        }
    }

    fun dismissDryRun() {
        dryRun.value = null
    }

    fun exportSelection(uri: Uri, doneLabel: String, failLabel: String) {
        viewModelScope.launch(Dispatchers.IO) {
            val ok = runCatching {
                val text = buildString {
                    appendLine("name,album,original,optimised,confirmation,confirmed")
                    for (entry in selectedEntries()) {
                        val row = entry.row
                        appendLine(
                            listOf(
                                row.displayName.replace(',', ' '),
                                (row.bucket ?: "").replace(',', ' '),
                                Formats.bytes(row.sizeBytes),
                                Formats.bytes(row.outputBytes ?: 0L),
                                Evidence.parse(row.evidence).name,
                                Formats.date(row.confirmedAt ?: 0)
                            ).joinToString(",")
                        )
                    }
                }
                ctx.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) }
                    ?: error("no stream")
            }.isSuccess
            message.value = if (ok) doneLabel else failLabel
        }
    }

    val message = MutableStateFlow<String?>(null)

    fun dismissMessage() {
        message.value = null
    }

    // ---- the batch itself ----------------------------------------------------

    /**
     * Runs the batch. Copies-only never needs Android's dialog, because those
     * files belong to the app; anything touching an original always does.
     */
    fun start(permanent: Boolean) {
        // A modified build may not remove anything.
        //
        // TamperCheck's own contract says a mismatched signing certificate
        // "disables the Free-up tool and all deletions", and the banner on
        // Home tells the user deleting is turned off. Neither was true: the
        // flag reached a banner and one button, and every path that removes a
        // file ran exactly as before. Gated here, at the entry point, so no
        // screen route can get past it.
        if (TamperCheck.isModified(ctx)) return
        val chosen = selectedEntries()
        if (chosen.isEmpty()) return
        // Checked and set here, on the tap, not inside the coroutine: a
        // second tap before the coroutine started would have got through.
        if (flowOpen()) return
        busy.value = true
        viewModelScope.launch(Dispatchers.IO) {
            // Whether the batch went on to Android's dialog. Until then it
            // ends here; after, it ends when the last answer is written down.
            var handedOn = false
            try {
                val now = System.currentTimeMillis()
                if (mode.value == ReclaimRules.Mode.COPIES_ONLY) {
                    lastResult.value = engine.removeCopiesOnly(chosen.map { it.row }, now)
                    clearSelection()
                    load()
                    return@launch
                }
                // Re-check at the moment of action: a list can sit open while
                // the cloud app is uninstalled underneath it.
                val o = repo.current()
                val healthy = cloudHealthy()
                val stillGood = chosen.filter {
                    ReclaimRules.isEligible(
                        it.candidate, healthy,
                        allowVerifiedBySize = o.freeUpAllowVerified30,
                        skipFavourites = skipFavourites.value, skipSmall = skipSmall.value
                    )
                }
                // Anything that stopped qualifying while the list sat open is
                // named, not silently dropped: a batch that quietly does less
                // than it said it would is worse than one that explains.
                droppedAtAction = (chosen - stillGood.toSet()).map { it.row.displayName }
                val ready = try {
                    engine.prepare(stillGood.map { it.row }, mode.value, o, now) { waitingForStage.value = it }
                } finally {
                    waitingForStage.value = false
                }
                prepared = ready
                pendingMode = mode.value
                pendingTrash = !permanent
                if (ready.uris.isEmpty()) {
                    lastResult.value = engine.finish(ready, emptySet(), mode.value, !permanent, now)
                    return@launch
                }
                if (!beginConsent(ready.uris, permanent)) {
                    pendingTrash = false
                    startLegacy(ready.uris)
                }
                handedOn = true
            } finally {
                if (!handedOn) {
                    prepared = null
                    busy.value = false
                }
            }
        }
    }

    /**
     * Starts the walk through the confirmations for a selection.
     *
     * False when this phone has no batch dialog at all, which is the Android
     * 10 case: there the caller falls back to one consent per file.
     */
    private fun beginConsent(uris: List<Uri>, permanent: Boolean): Boolean {
        consentChunks = ArrayDeque(ReclaimRules.batches(uris))
        consentCurrent = emptyList()
        consentConfirmed.clear()
        consentPermanent = permanent
        return requestNextConsent()
    }

    /** Shows the next chunk's dialog; false when none is left to ask about. */
    private fun requestNextConsent(): Boolean {
        val next = consentChunks.removeFirstOrNull() ?: return false
        val request = requestFor(next, consentPermanent) ?: return false
        consentCurrent = next
        ask(request, FreeUpFlow.Dialog.RECLAIM)
        return true
    }

    /**
     * Trash first. A trashed file comes back from the gallery for 30 days;
     * a deleted one never does, and this is a batch operation on someone's
     * photographs.
     *
     * Returns null on Android 9 and 10, which have neither batch request:
     * there the caller falls back to one file at a time.
     */
    private fun requestFor(uris: List<Uri>, permanent: Boolean): IntentSender? {
        if (Build.VERSION.SDK_INT < 30) return null
        val resolver = ctx.contentResolver
        return if (permanent) {
            MediaStore.createDeleteRequest(resolver, uris).intentSender
        } else {
            MediaStore.createTrashRequest(resolver, uris, true).intentSender
        }
    }

    // ---- Android 9 and 10: one file at a time ---------------------------------

    /**
     * Android 10 has no batch delete request and no trash, so each file is
     * attempted directly and the system's own recoverable-security prompt is
     * shown for the ones that need it. Slower, and the only thing that works
     * there. Android 9 has no such prompt either: with storage write access
     * each delete simply happens, after the confirmation on this screen.
     */
    private val legacyQueue = ArrayDeque<Uri>()
    private val legacyDeleted = mutableSetOf<String>()

    private fun startLegacy(uris: List<Uri>) {
        legacyQueue.clear()
        legacyQueue.addAll(uris)
        legacyDeleted.clear()
        pumpLegacy()
    }

    private fun pumpLegacy() {
        viewModelScope.launch(Dispatchers.IO) {
            while (legacyQueue.isNotEmpty()) {
                val uri = legacyQueue.first()
                try {
                    if (ctx.contentResolver.delete(uri, null, null) > 0) {
                        legacyDeleted += uri.toString()
                    }
                    legacyQueue.removeFirst()
                } catch (se: SecurityException) {
                    // Android 9 has no recoverable refusal: there storage
                    // write access is all there is, and without it the file
                    // stays where it is.
                    val sender = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        (se as? RecoverableSecurityException)?.userAction?.actionIntent?.intentSender
                    } else {
                        null
                    }
                    if (sender != null) {
                        ask(sender, FreeUpFlow.Dialog.LEGACY)
                        return@launch
                    }
                    legacyQueue.removeFirst()
                } catch (e: Exception) {
                    legacyQueue.removeFirst()
                }
            }
            finishLegacy()
        }
    }

    private fun finishLegacy() {
        if (pendingDuplicateIds.isNotEmpty()) {
            pendingDuplicateIds = emptySet()
            dupeChunks.clear()
            dupeCurrent = emptyList()
            dupeIdByUri = emptyMap()
            dupeGranted.clear()
            finishDuplicateRemoval(legacyDeleted.size)
            return
        }
        val ready = prepared ?: return
        prepared = null
        finishConsented(ready, legacyDeleted.toSet(), trashed = false)
    }

    /**
     * Writes down a batch Android has already answered for.
     *
     * Past the dialog the originals are gone with the person's consent, so
     * the bookkeeping runs to its end even if this screen closes meanwhile,
     * and a failure in it is named in Activity instead of ending the app.
     */
    private fun finishConsented(ready: ReclaimEngine.Prepared, deleted: Set<String>, trashed: Boolean) {
        val mode = pendingMode
        viewModelScope.launch(Dispatchers.IO) {
            try {
                lastResult.value = withContext(NonCancellable) {
                    engine.finish(ready, deleted, mode, trashed, System.currentTimeMillis())
                }
                clearSelection()
            } catch (ce: CancellationException) {
                throw ce
            } catch (e: Exception) {
                ActivityLog(ctx).record(
                    ActivityLog.Kind.PROBLEM,
                    detail = ctx.getString(R.string.activity_reclaim_unrecorded)
                )
            } finally {
                busy.value = false
                load()
            }
        }
    }

    private fun onDialogResult(granted: Boolean) {
        dialogOnScreen = null
        pendingIntent.value = null
        if (Build.VERSION.SDK_INT < 30 && legacyQueue.isNotEmpty()) {
            // One file's consent came back; take it and move to the next.
            val uri = legacyQueue.removeFirst()
            if (granted) {
                viewModelScope.launch(Dispatchers.IO) {
                    runCatching {
                        if (ctx.contentResolver.delete(uri, null, null) > 0) {
                            legacyDeleted += uri.toString()
                        }
                    }
                    pumpLegacy()
                }
            } else {
                pumpLegacy()
            }
            return
        }
        if (pendingDuplicateIds.isNotEmpty()) {
            if (granted) dupeGranted += dupeCurrent.mapNotNull { dupeIdByUri[it.toString()] }
            dupeCurrent = emptyList()
            if (granted && nextDuplicateChunk()) return
            dupeChunks.clear()
            pendingDuplicateIds = emptySet()
            dupeIdByUri = emptyMap()
            val count = dupeGranted.size
            dupeGranted.clear()
            finishDuplicateRemoval(count)
            return
        }
        val ready = prepared ?: return
        if (granted) consentConfirmed += consentCurrent.map { it.toString() }
        consentCurrent = emptyList()
        // More of the selection still to confirm: ask for the next chunk
        // before anything is written down. A refusal ends the batch there,
        // with whatever was already agreed to.
        if (granted && requestNextConsent()) return
        consentChunks.clear()
        prepared = null
        val deleted = consentConfirmed.toSet()
        consentConfirmed.clear()
        finishConsented(ready, deleted, pendingTrash)
    }

    /**
     * A duplicate removal has no reclaim batch behind it.
     *
     * Nothing was freed on the strength of upload evidence, so there is
     * nothing for the app to undo: the identical file is still on the phone,
     * and the extras are in the gallery trash for 30 days.
     */
    private fun finishDuplicateRemoval(removed: Int) {
        viewModelScope.launch(Dispatchers.IO) {
            if (removed > 0) {
                duplicatesRemoved.value = removed
                ActivityLog(ctx).record(
                    ActivityLog.Kind.RECLAIMED,
                    count = removed,
                    detail = ctx.getString(R.string.dupes_removed_detail)
                )
            }
            loadDuplicates()
        }
    }

    fun dismissResult() {
        lastResult.value = null
    }

    // ---- history and restore -------------------------------------------------

    /**
     * Only batches whose files can still be in the trash. Old batches were
     * pruned only when a new one was written, so someone who freed space
     * once and came back after a month was offered a restore of files
     * Android had already emptied out.
     */
    val history = db.reclaim().recentBatchesFlow(50).map { batches ->
        val now = System.currentTimeMillis()
        batches.filterNot { FreeUpFlow.trashExpired(it.atMs, now) }
    }

    init {
        viewModelScope.launch(Dispatchers.IO) { engine.prune() }
    }

    val historyItems = MutableStateFlow<List<ReclaimItemRow>>(emptyList())

    fun loadBatch(batch: ReclaimBatchRow) {
        viewModelScope.launch(Dispatchers.IO) {
            historyItems.value = db.reclaim().itemsOf(batch.id)
        }
    }

    private var restoring: List<ReclaimItemRow> = emptyList()

    /** Chunks of a batch still waiting to be untrashed, and what came back. */
    private var restoreChunks: ArrayDeque<List<Uri>> = ArrayDeque()
    private var restoreCurrent: List<Uri> = emptyList()
    private val restoreGranted = mutableSetOf<String>()

    /** Untrash, with the system dialog: the files are the gallery's, not ours. */
    fun restore(batch: ReclaimBatchRow, items: List<ReclaimItemRow>) {
        // A modified build may not remove anything.
        //
        // TamperCheck's own contract says a mismatched signing certificate
        // "disables the Free-up tool and all deletions", and the banner on
        // Home tells the user deleting is turned off. Neither was true: the
        // flag reached a banner and one button, and every path that removes a
        // file ran exactly as before. Gated here, at the entry point, so no
        // screen route can get past it.
        if (TamperCheck.isModified(ctx)) return
        if (flowOpen()) return
        // Android empties its trash after thirty days. A restore after that
        // has nothing to bring back, and a "yes" to it marked originals that
        // no longer exist as back on the phone.
        if (!batch.trashed || FreeUpFlow.trashExpired(batch.atMs, System.currentTimeMillis())) return
        val uris = items.mapNotNull { row -> row.contentUri?.let { Uri.parse(it) } }
        // Nothing to restore from on Android 9 and 10: no trash, so those
        // batches were permanent and the history says so.
        if (uris.isEmpty() || Build.VERSION.SDK_INT < 30) return
        restoring = items
        // A restored batch is as large as the batch that created it, so it
        // goes back through the same chunked confirmation as the removal did.
        restoreChunks = ArrayDeque(ReclaimRules.batches(uris))
        restoreGranted.clear()
        ask(nextRestoreChunk(), FreeUpFlow.Dialog.RESTORE)
    }

    private fun nextRestoreChunk(): IntentSender? {
        // Android 9 and 10 have no trash to put anything back into, and restore()
        // has already turned back on that phone. Stated again here so the
        // guard holds wherever this is called from.
        if (Build.VERSION.SDK_INT < 30) return null
        val next = restoreChunks.removeFirstOrNull() ?: return null
        restoreCurrent = next
        return MediaStore.createTrashRequest(ctx.contentResolver, next, false).intentSender
    }

    private fun onRestoreResult(granted: Boolean) {
        dialogOnScreen = null
        pendingIntent.value = null
        if (granted) restoreGranted += restoreCurrent.map { it.toString() }
        restoreCurrent = emptyList()
        if (granted && restoreChunks.isNotEmpty()) {
            ask(nextRestoreChunk(), FreeUpFlow.Dialog.RESTORE)
            return
        }
        restoreChunks.clear()
        val items = restoring
        restoring = emptyList()
        // Only the chunks the user actually allowed came back out of the
        // trash. Marking the rest as restored would put a lie in the history
        // for files that are still sitting in the gallery's bin.
        val back = items.filter { it.contentUri in restoreGranted }
        restoreGranted.clear()
        if (back.isEmpty()) return
        viewModelScope.launch(Dispatchers.IO) {
            for (item in back) engine.onRestored(item)
            historyItems.value = db.reclaim().itemsOf(back.first().batchId)
            load()
        }
    }

    // ---- find space ----------------------------------------------------------

    val duplicateGroups = MutableStateFlow<List<DuplicateRules.Group>>(emptyList())
    val largest = MutableStateFlow<List<ItemRow>>(emptyList())

    /**
     * True while the first scan is running, so the screen can show skeleton
     * rows instead of an empty state that is about to be wrong.
     */
    val duplicatesLoading = MutableStateFlow(false)

    fun loadDuplicates() {
        viewModelScope.launch(Dispatchers.IO) {
            duplicatesLoading.value = true
            try {
                duplicateGroups.value = withChosenKeepers(DuplicateScanner(ctx).groups())
            } finally {
                duplicatesLoading.value = false
            }
        }
    }

    /**
     * Makes a different file in the group the one that stays.
     *
     * The automatic choice is the oldest capture in the fullest album, which
     * is right nearly always and wrong when someone has deliberately filed a
     * copy somewhere. Swapping is local to this screen: the group is rebuilt
     * around the new keeper and the old keeper becomes a removable extra.
     */
    fun keepInstead(sha256: String, id: Long) {
        keeperChoice[sha256] = id
        duplicateGroups.value = withChosenKeepers(duplicateGroups.value)
    }

    /**
     * The keeper the user picked per group, by content hash.
     *
     * Held apart from the group list because that list is rebuilt from a fresh
     * scan the moment anything is removed - and the rebuild used to throw the
     * choice away. Someone who swapped the keeper and ticked the old one then
     * confirmed a removal that quietly did nothing: the fresh scan had put the
     * automatic keeper back, so the file they ticked was no longer an extra
     * and was filtered out. The control looked like it worked and did not.
     *
     * The hash is the group's identity and does not change, so the choice
     * survives every rescan. It is per screen, like the swap itself.
     */
    private val keeperChoice = mutableMapOf<String, Long>()

    private fun withChosenKeepers(groups: List<DuplicateRules.Group>): List<DuplicateRules.Group> =
        groups.map { group ->
            val wanted = keeperChoice[group.sha256] ?: return@map group
            val next = group.all.firstOrNull { it.id == wanted } ?: return@map group
            group.copy(keeper = next, extras = group.all.filter { it.id != next.id })
        }

    /**
     * Moves the ticked extras to the gallery trash.
     *
     * Safe by definition and not by evidence: an identical file stays on the
     * phone, so nothing is lost even if the copy never reached any cloud. It
     * still goes through Android's own dialog, and to the trash rather than
     * straight out, so 30 days of undo apply.
     */
    fun removeDuplicateExtras(chosen: Set<Long>) {
        // A modified build may not remove anything.
        //
        // TamperCheck's own contract says a mismatched signing certificate
        // "disables the Free-up tool and all deletions", and the banner on
        // Home tells the user deleting is turned off. Neither was true: the
        // flag reached a banner and one button, and every path that removes a
        // file ran exactly as before. Gated here, at the entry point, so no
        // screen route can get past it.
        if (TamperCheck.isModified(ctx)) return
        if (flowOpen()) return
        if (chosen.isEmpty()) return
        busy.value = true
        viewModelScope.launch(Dispatchers.IO) {
            try {
                // Re-read now, not when the list was drawn: a file can be gone
                // or a group can have changed between the tap and the action.
                // Re-applied, not discarded: the user may have chosen which
                // copy stays, and a rescan must not silently put the automatic
                // one back and drop the file they ticked.
                val fresh = withChosenKeepers(DuplicateScanner(ctx).groups())
                duplicateGroups.value = fresh
                val stillExtras = fresh.flatMap { g -> g.extras }
                    .filter { it.id in chosen }
                val rows = stillExtras.mapNotNull { db.items().byId(it.id) }
                val uris = rows.mapNotNull { row ->
                    row.contentUri?.let { runCatching { Uri.parse(it) }.getOrNull() }
                }
                if (uris.isEmpty()) return@launch
                pendingDuplicateIds = rows.map { it.id }.toSet()
                pendingTrash = true
                // A gallery full of copies produces thousands of extras, so
                // this goes through the same chunked confirmation as every
                // other removal rather than one dialog nobody can read.
                dupeIdByUri = rows.mapNotNull { row ->
                    row.contentUri?.let { it to row.id }
                }.toMap()
                dupeChunks = ArrayDeque(ReclaimRules.batches(uris))
                dupeGranted.clear()
                if (!nextDuplicateChunk()) startLegacy(uris)
            } finally {
                busy.value = false
            }
        }
    }

    /** Names that stopped qualifying between the tap and the action. */
    var droppedAtAction: List<String> = emptyList()
        private set

    fun clearDropped() {
        droppedAtAction = emptyList()
    }

    /** Ids awaiting Android's answer for a duplicate removal. */
    private var pendingDuplicateIds: Set<Long> = emptySet()

    /** The same chunked walk, for the extras: what is left, and what was allowed. */
    private var dupeChunks: ArrayDeque<List<Uri>> = ArrayDeque()
    private var dupeCurrent: List<Uri> = emptyList()
    private var dupeIdByUri: Map<String, Long> = emptyMap()
    private val dupeGranted = mutableSetOf<Long>()

    /** Shows the next chunk of extras; false when none is left to ask about. */
    private fun nextDuplicateChunk(): Boolean {
        val next = dupeChunks.removeFirstOrNull() ?: return false
        val request = requestFor(next, permanent = false) ?: return false
        dupeCurrent = next
        ask(request, FreeUpFlow.Dialog.DUPLICATES)
        return true
    }

    /** How many extras the last removal actually took, for the result line. */
    val duplicatesRemoved = MutableStateFlow<Int?>(null)

    fun dismissDuplicatesResult() {
        duplicatesRemoved.value = null
    }

    fun loadLargest() {
        viewModelScope.launch(Dispatchers.IO) {
            largest.value = db.items().largest(50)
        }
    }

    /** Moves chosen items to the front of the queue. */
    fun optimiseFirst(ids: List<Long>) {
        viewModelScope.launch(Dispatchers.IO) {
            val now = System.currentTimeMillis()
            for (id in ids) {
                val row = db.items().byId(id) ?: continue
                if (row.state != ItemState.SKIP.name && row.state != ItemState.NEW.name) continue
                // The same jump as AppViewModel.optimiseNow: asked for with
                // priorityAt, never by faking the date. captureAt is what the
                // camera recorded and is stamped onto the copy Ente files by
                // date, so writing `now` there moved a 2019 video to today.
                db.items().update(Stager.askedFirst(row, now))
            }
        }
    }

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
}
