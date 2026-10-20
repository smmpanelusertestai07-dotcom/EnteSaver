package app.entesaver.engine

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.room.withTransaction
import app.entesaver.R
import app.entesaver.core.logic.CloudCapability
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.DeletePlanner
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.EvidenceRules
import app.entesaver.core.logic.FirstChain
import app.entesaver.core.logic.FreeableNote
import app.entesaver.core.logic.GoneReason
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.OutFolder
import app.entesaver.core.logic.OutputLayout
import app.entesaver.core.logic.OutputRoots
import app.entesaver.core.logic.Pacing
import app.entesaver.core.logic.ReclaimRules
import app.entesaver.core.logic.SaveMode
import app.entesaver.core.logic.ScanSources
import app.entesaver.core.logic.StallAlert
import app.entesaver.core.logic.StateMachine
import app.entesaver.core.logic.Stops
import app.entesaver.data.EnteApp
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.db.leftFolderAtAfter
import app.entesaver.data.prefs.Options
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.media.LegacyMedia
import app.entesaver.media.MediaPaths
import app.entesaver.media.MediaScanner
import app.entesaver.media.OutputInventory
import app.entesaver.media.Releaser
import app.entesaver.media.Stager
import app.entesaver.util.Formats
import app.entesaver.util.Locks
import app.entesaver.util.Notifications
import app.entesaver.util.Storage
import app.entesaver.util.TamperCheck
import app.entesaver.util.Volumes
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.withLock

/**
 * MaintainWorker body (also runs on app open and on output-folder changes while
 * foreground):
 *  a) anchor rule + self-heal   b) paced release   c) per-file evidence
 *  d) batch evidence            e) lazy delete     f) self-heal transitions
 *  g) cloud health watchdog     h) daily state snapshot
 */
class MaintainEngine(private val context: Context) {

    companion object {
        /**
         * How long a pending output row may sit before it is repaired.
         *
         * Short on purpose: while a row is pending nothing else on the phone
         * can see the file, so every minute of it is a minute the backup
         * looks stopped.
         */
        const val STALE_PENDING_MS = 15L * 60 * 1000

        /** How long a copy that looks gone is given to turn up after a move. */
        const val GONE_RECHECK_MS = 1_500L
    }

    private val db = AppDb.get(context)
    private val repo = OptionsRepo.get(context)
    private val inventory = OutputInventory(context)
    private val releaser = Releaser(context, db)
    private val scanner = MediaScanner(context, db)
    private val snapshots = SnapshotStore(context, db, repo)
    private val watchdog = CloudWatchdog(context)
    private val activity = ActivityLog(context)

    data class Summary(
        var confirmed: Int = 0,
        var released: Int = 0,
        var deleted: Int = 0,
        var healed: Int = 0
    )

    /**
     * One maintenance pass at a time.
     *
     * Two paths start this - the hourly worker and the end of every
     * compression run - under different unique work names, so nothing was
     * serialising them, and the UI could ask for a confirm pass on top. Two
     * passes over the same rows is how self-heal sends a file twice.
     */
    suspend fun run(): Summary = Locks.maintain.withLock { runLocked() }

    private suspend fun runLocked(): Summary {
        val o = repo.current()
        val now = System.currentTimeMillis()
        val summary = Summary()

        // Z10.6: the whole chain is proven by the first confirmation and
        // disproven by 48 hours of silence after the first release. Either
        // way it becomes exactly one card on Home.
        step {
            val confirmed = db.items().confirmedCount()
            val next = FirstChain.next(o.firstChainState, o.firstReleaseAt, confirmed, now)
            if (next != o.firstChainState) {
                repo.setString(OptionsRepo.K.FIRST_CHAIN_STATE, next)
            }
        }

        // The phone has been stopping the compress runs: say so, once, from
        // the one run that did get through. A week apart, three times at
        // most, then the chip on Home is the only notice (StallAlert).
        step {
            val waiting = db.items().newInScopeCount(o.excludedBuckets)
            val stalled = !o.pauseAll && StallAlert.stalled(
                now, StallAlert.lastSeen(o.lastRunAt, o.lastWakeAt), waiting, Stops.isRationed(o.lastStopReason)
            )
            if (StallAlert.due(stalled, o.stallAlerts, o.stallAlertAt, now)) {
                val shown = Notifications.alert(
                    context, Notifications.ID_WARN_STALLED,
                    context.getString(R.string.warn_stalled_title),
                    context.getString(R.string.warn_stalled_text),
                    o, dedupKey = "stalled", route = "permissions"
                )
                // One of the three reminders is spent only by a reminder
                // somebody could see - not by one that was muted or blocked.
                // The week's wait starts either way, so a reminder that
                // cannot be shown is tried weekly, not on every pass.
                if (shown) repo.setInt(OptionsRepo.K.STALL_ALERTS, o.stallAlerts + 1)
                repo.setLong(OptionsRepo.K.STALL_ALERT_AT, now)
                activity.record(
                    ActivityLog.Kind.PROBLEM,
                    detail = context.getString(R.string.warn_stalled_title)
                )
            }
        }

        // 13.D: selected volume (SD card) gone -> pause file work safely, keep
        // verification/bookkeeping running, never lose state.
        val volumeMissing = o.storageVolume.isNotEmpty() &&
            Volumes.byName(context, o.storageVolume) == null
        if (volumeMissing) {
            step { verifyBatches(now) }
            step { ageEvidence(now) }
            step { dailySnapshot(o, now) }
            if (now - o.volumeWarnedAt > 86_400_000L) {
                Notifications.alert(
                    context, Notifications.ID_WARN_SPACE,
                    context.getString(R.string.warn_volume_title),
                    context.getString(R.string.warn_volume_text),
                    o, route = "storage"
                )
                repo.setLong(OptionsRepo.K.VOLUME_WARNED_AT, now)
                activity.record(
                    ActivityLog.Kind.PAUSED,
                    detail = context.getString(R.string.warn_volume_title)
                )
            }
            return summary
        }

        // A null listing means MediaStore could not be read. Absence is
        // evidence here, so a failed read must not be mistaken for an empty
        // folder; skip the passes that interpret it and retry next hour.
        val entries = listOutputs(o)
        if (entries == null) {
            return summary
        }

        step { repairStalePending(now) }
        step { detectGone(o, now, entries, summary) }
        step { promoteGone(now) }
        step { pruneRoots(o) }
        step { foreignFiles(o, entries) }
        step { pacedEvidence(now) }
        step { verifyBatches(now) }
        step { ageEvidence(now) }
        step { selfHealStage(now) }
        step { originalsPresence(now) }
        var pauseDeletions = false
        step { pauseDeletions = cloudHealth(o, now, entries) }
        if (!o.pauseAll) {
            if (o.saveMode == SaveMode.IN_PLACE) {
                // Replace on this phone publishes nothing - no folder of
                // Ente Saver's own, no anchor file. A copy staged before it
                // was on, or by the trial, is dropped, and its original is
                // replaced in place instead.
                step { unstageForInPlace(now) }
            } else {
                step { pacedRelease(o, now, summary) }
                // Again straight after releasing: a row that failed to finalise
                // in this very pass should not wait an hour to be noticed.
                step { repairStalePending(now) }
            }
        }
        if (!pauseDeletions) {
            step { lazyDelete(o, now, summary) }
        }
        step { freeableNote(now) }
        step { dailySnapshot(o, now) }
        step { logSummary(summary) }
        return summary
    }

    /**
     * Runs one maintenance step, swallowing a failure instead of abandoning
     * the rest of the pass: one step that cannot run is not a reason for the
     * other twenty-three not to. Anything a person needs to hear about is
     * recorded by the step itself, in Activity. Cancellation is rethrown:
     * runCatching would swallow it (CancellationException is an Exception in
     * Kotlin), so a stopped worker would grind through every remaining step
     * and then report success.
     */
    private inline fun step(body: () -> Unit) {
        try {
            body()
        } catch (ce: kotlin.coroutines.cancellation.CancellationException) {
            throw ce
        } catch (e: Throwable) {
        }
    }

    private suspend fun logSummary(summary: Summary) {
        activity.recordIfAny(ActivityLog.Kind.RELEASED, summary.released)
        activity.recordIfAny(ActivityLog.Kind.BACKED_UP, summary.confirmed)
    }

    /**
     * Quick pass for app open and folder changes; returns the confirmed count.
     *
     * Only [returnPass] passes [window]: it is the single pass allowed to
     * read a missing copy as Ente having collected it. Every other pass - the
     * hourly worker included - judges by the normal rules, and leaves the
     * copies an open window covers for the return to judge.
     */
    suspend fun confirmPass(window: EvidenceRules.ConfirmWindow? = null): Int = Locks.maintain.withLock {
        confirmPassLocked(window) ?: 0
    }

    /**
     * Opens the "Confirm uploads" window, stamped [openedAt] at the tap, and
     * stores it before Ente is launched - so it outlives this process, which
     * a phone short of memory may well end while Ente is in front.
     *
     * Only copies in their folders right now are remembered. Ente's free-up
     * can only collect what is there when the person gets to it; a copy
     * cleared earlier by hand or by a cleaner app is simply left out, and the
     * normal rules judge it. That needs one read of the folders and nothing
     * else, so it does not wait behind a running pass: the button answers at
     * once. A pass running meanwhile can only make the set smaller, never
     * larger. Null, and nothing stored, when the folders cannot be read.
     */
    suspend fun openConfirmWindow(openedAt: Long = System.currentTimeMillis()): EvidenceRules.ConfirmWindow? {
        val o = repo.current()
        val entries = listOutputs(o)
        if (entries == null) {
            repo.setConfirmWindow(null)
            return null
        }
        val names = namesByFolder(entries)
        val present = db.items().released().filter { row ->
            val name = row.outputName ?: return@filter false
            name in (names[folderKey(pathOf(row))] ?: emptySet<String>())
        }.map { it.id }.toSet()
        val window = EvidenceRules.ConfirmWindow(openedAt = openedAt, presentAtTap = present)
        repo.setConfirmWindow(window)
        return window
    }

    /** Forgets the window [openedAt] opened, when Ente never came up. */
    suspend fun dropConfirmWindow(openedAt: Long) = repo.clearConfirmWindow(openedAt)

    /**
     * The pass the first return to the app runs after "Confirm uploads", in
     * this process or a new one: it credits the copies that were there at the
     * tap and are gone now, and then the window is spent. Null when there was
     * no window to judge, or it had closed - then it is cleared, and the
     * normal rules judge those copies on the next pass.
     */
    suspend fun returnPass(): Int? = Locks.maintain.withLock {
        val window = repo.current().confirmWindow ?: return@withLock null
        if (!EvidenceRules.isOpen(window, System.currentTimeMillis())) {
            repo.clearConfirmWindow(window.openedAt)
            return@withLock null
        }
        // Kept when the folders could not be read: the next return, still
        // inside the hour, tries again.
        val n = confirmPassLocked(window) ?: return@withLock null
        repo.clearConfirmWindow(window.openedAt)
        n
    }

    /** Null when the folders could not be read, so nothing was judged. */
    private suspend fun confirmPassLocked(window: EvidenceRules.ConfirmWindow?): Int? {
        val o = repo.current()
        val now = System.currentTimeMillis()
        val summary = Summary()
        val entries = listOutputs(o) ?: return null
        step { repairStalePending(now) }
        step { detectGone(o, now, entries, summary, window) }
        step { promoteGone(now) }
        step { pacedEvidence(now) }
        activity.recordIfAny(ActivityLog.Kind.BACKED_UP, summary.confirmed)
        return summary.confirmed
    }

    // ---- c) per-file evidence ----------------------------------------------------

    /**
     * A released copy left the upload folder. Deciding what that means is the
     * single most consequential judgement the app makes, because the strong
     * answer eventually offers the user's original for deletion and the wrong
     * weak answer uploads the same photo twice.
     */
    private suspend fun detectGone(
        o: Options,
        now: Long,
        entries: List<OutputInventory.Entry>,
        summary: Summary,
        window: EvidenceRules.ConfirmWindow? = null
    ) {
        val presentNames = namesByFolder(entries)
        val caps = watchdog.caps()
        val quietMs = CloudCapability.resendQuietPeriodMs(caps)
        // Only the return from "Confirm uploads" reads a count per copy, as
        // an extra hurdle. A whole folder can vanish at once and rows released
        // together share a window, so the count is read once per window, not
        // in hundreds of identical binder calls.
        val txCache = HashMap<Long, Long?>()

        // Not in its folder is not the same as gone. A folder renamed or
        // moved in a file manager takes the copy with it, and the copy still
        // exists - so it is followed to where it is now and keeps waiting
        // there, never counted as collected. Only a copy the gallery no
        // longer has at all is judged below.
        suspend fun follow(row: ItemRow, place: Whereabouts): Boolean {
            if (place is Whereabouts.Moved) {
                db.items().update(
                    row.copy(
                        outputRelPath = place.relPath,
                        outputName = place.name,
                        outputUri = place.uri ?: row.outputUri,
                        updatedAt = now
                    )
                )
            }
            return place == Whereabouts.Gone
        }
        val missing = db.items().released().filter { row ->
            val names = presentNames[folderKey(pathOf(row))] ?: emptySet<String>()
            val outputName = row.outputName ?: return@filter false
            outputName !in names && follow(row, whereNow(row))
        }
        // A move is finished by the gallery in its own time: for a moment the
        // copy can answer neither at its old address nor at its new one. So
        // whatever looks gone is asked once more, a moment later, before
        // anything is judged - one short wait per pass, however many copies.
        val gone = if (missing.isEmpty()) {
            missing
        } else {
            delay(GONE_RECHECK_MS)
            missing.filter { follow(it, whereNow(it)) }
        }
        if (gone.isEmpty()) return

        // Ente's byte count is everything it sent: camera photos, and every
        // other copy of ours, waiting or already gone. So the copies without
        // evidence share one count from the oldest of them, settled oldest
        // first, and only a copy that was alone in flight - no other copy of
        // ours in the folder at any time in its window - can call the bytes
        // its own.
        val goneIds = gone.map { it.id }.toSet()
        val waiting = unprovenWaiting(now, goneIds)
        val settled = waiting.filter { !it.graded }
        val txShared = if (settled.any { it.gone }) {
            txSinceRelease(settled.minOf { it.releasedAt }, now)
        } else {
            null
        }
        val attribution = EvidenceRules.attributeTraffic(waiting, leftDuring(waiting), txShared, now).let {
            if (EvidenceRules.Attribution.PER_FILE !in it.values || stillInFlight(waiting)) {
                it
            } else {
                it.mapValues { (_, a) ->
                    if (a == EvidenceRules.Attribution.PER_FILE) EvidenceRules.Attribution.BYTES_SENT else a
                }
            }
        }

        // A "Confirm uploads" tap still open, read now rather than at the
        // start of the pass: the person may have tapped since - which is also
        // why it is timed by the clock now, not by the pass. Every pass but
        // the return leaves the copies it covers alone; once it has closed it
        // is cleared, and they are judged normally.
        val held = if (window == null) repo.current().confirmWindow else null
        val heldAt = System.currentTimeMillis()
        if (held != null && !EvidenceRules.isOpen(held, heldAt)) repo.clearConfirmWindow(held.openedAt)

        for (row in gone) {
            val evidence = evidenceOf(row)
            if (EvidenceRules.heldForReturn(held, row.id, heldAt, evidence, row.appDeletedCopy)) continue
            val releasedAt = row.releasedAt ?: now
            val fileBytes = row.outputBytes ?: 0L
            val collected = window != null && EvidenceRules.collectedByFreeUp(
                window, row.id, now, evidence, row.appDeletedCopy,
                txCache.getOrPut(releasedAt) { txSinceRelease(releasedAt, now) },
                fileBytes
            )

            // A copy that already carried evidence and then vanished is simply
            // finished. Re-sending it would say the app trusts its own earlier
            // finding less than an empty folder.
            if (!row.appDeletedCopy && evidence != Evidence.NONE && !collected) {
                db.items().update(
                    row.copy(
                        state = ItemState.GONE.name,
                        goneReason = GoneReason.USER_DELETED.name,
                        leftFolderAt = now,
                        updatedAt = now
                    )
                )
                continue
            }

            val verdict = if (collected) {
                // The person just came back from Ente's own free-up screen,
                // and this copy was still in its folder when they left.
                EvidenceRules.MissingVerdict.PROOF_OF_UPLOAD
            } else {
                EvidenceRules.onCopyMissing(
                    appDeletedIt = row.appDeletedCopy,
                    attribution = attribution[row.id] ?: EvidenceRules.Attribution.UNPROVEN,
                    resendCount = row.resendCount
                )
            }
            val tx = txCache[releasedAt] ?: txShared ?: 0L

            when (verdict) {
                EvidenceRules.MissingVerdict.WE_DELETED_IT ->
                    db.items().update(
                        row.copy(
                            state = ItemState.GONE.name,
                            goneReason = GoneReason.APP_DELETED.name,
                            leftFolderAt = now,
                            updatedAt = now
                        )
                    )

                EvidenceRules.MissingVerdict.PROOF_OF_UPLOAD -> {
                    db.items().update(
                        row.copy(
                            state = ItemState.GONE.name,
                            goneReason = GoneReason.CONFIRMED.name,
                            evidence = StateMachine.strongest(
                                evidence, Evidence.CONFIRMED_EXACT
                            ).name,
                            confirmedAt = now,
                            txObserved = tx,
                            leftFolderAt = now,
                            updatedAt = now
                        )
                    )
                    releaser.recordDelivered(row, Evidence.CONFIRMED_EXACT.name, now)
                    noteCleanConfirmation()
                    // Only a cloud that removes its own uploads behaves this
                    // way, so this is also how the app learns what it is
                    // talking to - without ever asking the user.
                    watchdog.learnFreeUp(now)
                    summary.confirmed++
                }

                EvidenceRules.MissingVerdict.BYTES_SENT -> {
                    // Enough went out to cover it, but not provably this file:
                    // it may have been camera photos. Not sent again, and no
                    // stronger than a batch's grade - which offers an original
                    // only behind the person's own opt-in. Nor is it a sign
                    // that Ente frees up space: a person may have deleted it.
                    db.items().update(
                        row.copy(
                            state = ItemState.GONE.name,
                            goneReason = GoneReason.USER_DELETED.name,
                            evidence = StateMachine.strongest(
                                evidence, Evidence.VERIFIED
                            ).name,
                            txObserved = tx,
                            leftFolderAt = now,
                            updatedAt = now
                        )
                    )
                    releaser.recordDelivered(row, Evidence.VERIFIED.name, now)
                }

                EvidenceRules.MissingVerdict.RESEND -> {
                    // A slow upload that has not finished yet looks exactly
                    // like a lost file. Where a re-send would cost the user a
                    // duplicate, wait a day before believing the folder.
                    if (now - releasedAt < quietMs) continue
                    // Nothing to re-make it from. Sending it back to the queue
                    // would park it in "waiting to optimise" for good, and
                    // Home would count a file that can never move.
                    if (row.originalMissing) {
                        db.items().update(
                            row.copy(state = ItemState.DONE.name, leftFolderAt = now, updatedAt = now)
                        )
                        continue
                    }
                    if (alreadyInLedger(row)) {
                        db.items().update(
                            row.copy(state = ItemState.DONE.name, leftFolderAt = now, updatedAt = now)
                        )
                        continue
                    }
                    db.items().update(
                        row.copy(
                            state = ItemState.NEW.name,
                            evidence = Evidence.NONE.name,
                            goneReason = GoneReason.USER_DELETED.name,
                            outputUri = null,
                            // Its release time goes, so the queue sees new
                            // work; when it left stays, for the copy that
                            // went out beside it.
                            releasedAt = null,
                            leftFolderAt = now,
                            batchId = null,
                            appDeletedCopy = false,
                            resendCount = row.resendCount + 1,
                            updatedAt = now
                        )
                    )
                    summary.healed++
                }

                EvidenceRules.MissingVerdict.GIVE_UP -> {
                    // Twice is enough. Something removes this copy before the
                    // cloud ever gets it, and a third round would only be the
                    // same loop with more battery spent.
                    db.items().update(
                        row.copy(
                            state = ItemState.SKIP.name,
                            skipReason = "removed_before_upload",
                            outputUri = null,
                            leftFolderAt = now,
                            updatedAt = now
                        )
                    )
                    activity.record(
                        ActivityLog.Kind.SKIPPED,
                        detail = context.getString(R.string.activity_removed_early, row.displayName),
                        count = 1,
                        filterState = ItemState.SKIP.name
                    )
                }
            }
        }
    }

    /**
     * Finishes or removes anything left half-published.
     *
     * A row stuck with IS_PENDING=1 is invisible to the cloud app and Android
     * erases it after about a week - which arrives at the user as a file that
     * silently never uploaded and then vanished. Anything older than a day is
     * either published properly or cleared away, and either way it is written
     * to Activity rather than fixed in silence.
     */
    private suspend fun repairStalePending(now: Long) {
        // Android 9 has no pending rows: a copy there is written in full
        // before the gallery ever hears of it. What a write cut short leaves
        // behind is a hidden file, and those are cleared away instead.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val folders = OutputRoots.owned + Defaults.KEPT_DIR + Defaults.SNAPSHOT_TARGETS.map { it.first }
            LegacyMedia.sweepAbandoned(folders, now)
            return
        }
        // CC1.2: fifteen minutes, not a day. A pending row is invisible to
        // the gallery and to every cloud app, so a whole day of it reads as
        // a backup that silently stopped - and Android eventually deletes
        // stale pending rows itself, which would read as data loss.
        val cutoff = now - STALE_PENDING_MS
        var repaired = 0
        for (row in db.items().released()) {
            val uriString = row.outputUri ?: continue
            if ((row.releasedAt ?: now) > cutoff) continue
            val uri = runCatching { Uri.parse(uriString) }.getOrNull() ?: continue
            val pending = runCatching {
                context.contentResolver.query(
                    uri, arrayOf(MediaStore.MediaColumns.IS_PENDING),
                    null, null, null
                )?.use { c -> if (c.moveToFirst()) c.getInt(0) == 1 else false } ?: false
            }.getOrDefault(false)
            if (!pending) continue
            val fixed = runCatching {
                context.contentResolver.update(
                    uri,
                    ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    },
                    null, null
                ) > 0
            }.getOrDefault(false)
            if (!fixed) {
                runCatching { context.contentResolver.delete(uri, null, null) }
                db.items().update(
                    row.copy(
                        state = ItemState.NEW.name,
                        outputUri = null,
                        releasedAt = null,
                        leftFolderAt = now,
                        updatedAt = now
                    )
                )
            }
            repaired++
        }
        if (repaired > 0) {
            activity.record(
                ActivityLog.Kind.RECOVERED,
                detail = context.getString(R.string.activity_pending_repaired),
                count = repaired
            )
        }
    }

    private suspend fun promoteGone(now: Long) {
        for (row in db.items().gone()) {
            db.items().update(row.copy(state = ItemState.DONE.name, updatedAt = now))
        }
    }

    /**
     * Lets go of a folder the person moved away from, once no copy waits
     * there any more.
     *
     * Until then it is listed on every pass like a current folder: a copy
     * still waiting in it must be seen to leave, not be read as gone. Once
     * the last one has gone the folder is no longer the app's business, and
     * the person is told once that Ente can stop backing it up - leaving it
     * on costs nothing, but it is one more folder in Ente's list to wonder
     * about.
     */
    private suspend fun pruneRoots(o: Options) {
        if (o.pastOutputRoots.isEmpty()) return
        val inUse = o.layout.current + o.layout.otherMode
        val perFolder = db.items().releasedPerFolder().associate { it.outputRelPath to it.cnt }
        val emptied = o.pastOutputRoots.filter { root ->
            val path = OutputRoots.normalize(root)
            inUse.none { OutputRoots.same(it, path) } && OutputRoots.waitingIn(path, perFolder, inUse) == 0
        }
        if (emptied.isEmpty()) return
        repo.removePastOutputRoots(emptied)
        for (root in emptied) {
            val path = OutputRoots.normalize(root)
            activity.record(
                ActivityLog.Kind.SETTINGS_CHANGED,
                detail = context.getString(R.string.old_folder_empty_text, path)
            )
            Notifications.alert(
                context, Notifications.ID_NOTE_FOLDER,
                context.getString(R.string.old_folder_empty_title),
                context.getString(R.string.old_folder_empty_text, path),
                o, dedupKey = "oldfolder $path", route = "options"
            )
        }
    }

    /**
     * Files in the upload folder that Ente Saver did not create.
     *
     * Someone drops a screenshot into Pictures/CloudSaver believing that is
     * how a file gets backed up, or a cloud client mirrors something back
     * into it. These files are the user's, in a folder the user owns, so the
     * app never moves, renames or removes them - but silence has a price
     * too: the cloud app will upload them at full size, which quietly
     * defeats the folder's whole point. So they are counted, noted once in
     * Activity when the count grows, and shown as a chip on Home while any
     * remain. Nothing here holds a reference to the files themselves;
     * there is deliberately no way for this to act on them.
     */
    private suspend fun foreignFiles(o: Options, entries: List<OutputInventory.Entry>) {
        val count = entries.count { !ScanSources.isPipelineName(it.name) }
        if (count > o.foreignFiles) {
            activity.record(
                ActivityLog.Kind.PROBLEM,
                detail = context.resources.getQuantityString(
                    R.plurals.foreign_files_note, count, count
                )
            )
        }
        if (count != o.foreignFiles) {
            repo.setInt(OptionsRepo.K.FOREIGN_FILES, count)
        }
    }

    /**
     * The copy travelled alone and the cloud app sent about its size.
     *
     * This is only ever attempted with exactly one copy in flight. With two,
     * a byte total says something about the pair and nothing about either, and
     * a claim about the wrong file is worse than no claim at all.
     */
    private suspend fun pacedEvidence(now: Long) {
        if (!UsageVerifier.hasUsageAccess(context)) return
        // Every copy without per-file proof counts, timed out, AGED or
        // VERIFIED however long ago: each is still in the folder, and Ente
        // sending it later must not be credited to a newer copy that went out
        // "alone" beside it. So does every copy that left during the window.
        val waiting = unprovenWaiting(now)
        // A copy that sat there for six hours without its bytes appearing is
        // the accounting failing, not succeeding slowly. The ladder drops.
        if (waiting.any { !it.graded && Pacing.isTimedOut(it.releasedAt, now) }) {
            notePacingFailure("a released copy timed out without confirmation")
        }
        val candidate = waiting.singleOrNull { !it.graded } ?: return
        if (Pacing.isTimedOut(candidate.releasedAt, now)) return
        val tx = txSinceRelease(candidate.releasedAt, now) ?: return
        val alone = EvidenceRules.aloneInFlight(waiting, leftDuring(waiting), now, tx) ?: return
        if (!stillInFlight(waiting)) return
        // Only a copy with no grade at all is ever upgraded by a byte match.
        val row = db.items().byId(alone.id)?.takeIf { evidenceOf(it) == Evidence.NONE } ?: return
        db.items().update(
            row.copy(
                evidence = Evidence.CONFIRMED_PACED.name,
                confirmedAt = now,
                txObserved = tx,
                updatedAt = now
            )
        )
        releaser.recordDelivered(row, Evidence.CONFIRMED_PACED.name, now)
        noteCleanConfirmation()
    }

    /**
     * Every released copy without per-file proof, as paced proof, attribution
     * and release pacing all weigh it - one definition, so the three cannot
     * disagree about what is in flight. Time never takes a copy out: a
     * graded one competes for Ente's traffic for as long as it is released.
     * A copy whose release time is not known counts as graded: it competes,
     * but it has no window to read.
     *
     * A VERIFIED copy is dated by its batch's verification, which only
     * decides how long it holds a release slot. Where that is
     * not recorded - a row adopted or restored from a history file - by the
     * row's last change instead, which is never earlier; and never before
     * the copy's own release.
     */
    private suspend fun unprovenWaiting(now: Long, goneIds: Set<Long> = emptySet()): List<EvidenceRules.Waiting> {
        val rows = db.items().released().filter { !evidenceOf(it).isPerFile }
        val verifiedAt = if (rows.any { evidenceOf(it) == Evidence.VERIFIED }) {
            db.batches().verifiedOfReleased().associate { it.id to it.verifiedAt }
        } else {
            emptyMap()
        }
        val waiting = rows.map { row ->
            val evidence = evidenceOf(row)
            EvidenceRules.Waiting(
                id = row.id,
                releasedAt = row.releasedAt ?: now,
                bytes = row.outputBytes ?: 0L,
                gone = row.id in goneIds,
                graded = evidence != Evidence.NONE || row.releasedAt == null,
                verifiedAt = if (evidence == Evidence.VERIFIED) {
                    maxOf(verifiedAt[row.batchId] ?: row.updatedAt, row.releasedAt ?: 0L)
                } else {
                    null
                }
            )
        }
        return waiting
    }

    /**
     * Every copy of ours that left the folder since the one copy in [waiting]
     * went out, whatever it is now: Ente may have been sending it, all of it
     * or any part, while it was there. Dated by when it left - which no later
     * write to the row moves, and a copy sent back to the queue keeps; per-file
     * proof only counts from when it was granted. With more than one copy
     * waiting nothing is alone anyway, so nothing is read.
     */
    private suspend fun leftDuring(waiting: List<EvidenceRules.Waiting>): List<EvidenceRules.Left> {
        val since = waiting.singleOrNull()?.releasedAt ?: return emptyList()
        // A restore lands mid-run, and its copies are matched to the folder
        // only on the next run - and looked for again on every run while the
        // restore is watched. Until then any of them may be there, sending,
        // so each counts as in the folder for the whole window. Read before
        // the copies that left: the reattach pass dates those it does not
        // find before it marks the restore matched, so a pass finishing in
        // between leaves each in one list or the other.
        val restored = if (!ReattachEngine.pending(context)) {
            emptyList()
        } else {
            val stillThere = maxOf(System.currentTimeMillis(), since)
            db.items().restoredUnmatched().map { id ->
                EvidenceRules.Left(id = id, leftAt = stillThere, provenAt = null)
            }
        }
        return restored + db.items().leftReleasedSince(since).map { row ->
            EvidenceRules.Left(
                id = row.id,
                leftAt = row.leftAt,
                provenAt = row.confirmedAt?.takeIf { Evidence.parse(row.evidence).isPerFile }
            )
        }
    }

    /**
     * Whether the copies in flight are still [waiting]. A copy released, or
     * found again by the reattach pass, while the copies that left were read
     * is in neither list, so no single copy can claim the traffic then.
     */
    private suspend fun stillInFlight(waiting: List<EvidenceRules.Waiting>): Boolean =
        db.items().released().filter { !evidenceOf(it).isPerFile }.mapTo(HashSet()) { it.id } ==
            waiting.mapTo(HashSet()) { it.id }

    // ---- d) VERIFIED (data-count) ------------------------------------------------

    /**
     * Marks batches VERIFIED once the cloud app has actually transmitted
     * enough bytes to account for them.
     *
     * Every unverified batch's window ends at now, so the windows all overlap.
     * Checking each batch on its own would let a single upload burst satisfy
     * all of them at once - five 250 MB batches "verified" by 300 MB of
     * traffic - and VERIFIED is what puts an original in front of the user for
     * deletion. So the batches are settled oldest first against one cumulative
     * total: a transmitted byte can only pay for one batch.
     */
    private suspend fun verifyBatches(now: Long) {
        if (!UsageVerifier.hasUsageAccess(context)) return
        // Only batches a row belongs to. Earlier builds restored a history
        // file's batches with no rows: an old phone's unverified one, dated
        // before this install, would start the traffic window on its date and
        // let Ente's earlier uploads pay for this phone's real batches.
        val linked = db.items().linkedBatchIds().toHashSet()
        val pending = db.batches().unverified()
            .filter { it.totalBytes > 0 && it.cloudPackage != null && it.id in linked }
            .sortedBy { it.releasedAt }
        if (pending.isEmpty()) return
        // Every released row, once, indexed by the batch it belongs to.
        //
        // This read used to sit inside the loop below, so a pass with ten
        // unverified batches read the whole released set ten times and threw
        // nine tenths of each read away filtering it in Kotlin. On a phone
        // that has been running for a while that set is every original ever
        // sent, and the pass is on the worker's clock - time spent re-reading
        // it is time not spent encoding. Each batch is settled exactly once
        // here and a row belongs to one batch, so nothing this loop writes can
        // make an entry of this map stale.
        val releasedByBatch = db.items().released().groupBy { it.batchId }
        for ((pkg, batches) in pending.groupBy { it.cloudPackage!! }) {
            val uid = EnteApp.uidOf(context, pkg) ?: continue
            val since = batches.first().releasedAt
            val tx = UsageVerifier.txBytesForUid(context, uid, since, now) ?: continue
            var required = 0L
            for (batch in batches) {
                required += batch.totalBytes
                if (!EvidenceRules.batchVerified(tx, required)) break
                db.batches().markVerified(batch.id, now)
                for (row in releasedByBatch[batch.id].orEmpty()) {
                    if (evidenceOf(row).ordinal >= Evidence.VERIFIED.ordinal) continue
                    db.items().update(
                        row.copy(evidence = Evidence.VERIFIED.name, updatedAt = now)
                    )
                    // Batch-level proof is weaker than the per-file grades, but
                    // it is still proof that these bytes left the phone, so the
                    // copy must not be sent a second time.
                    releaser.recordDelivered(row, Evidence.VERIFIED.name, now)
                }
            }
        }
    }

    private suspend fun ageEvidence(now: Long) {
        val cutoff = now - Defaults.AGED_DAYS * 86_400_000L
        for (row in db.items().released()) {
            val releasedAt = row.releasedAt ?: continue
            if (evidenceOf(row) == Evidence.NONE && releasedAt <= cutoff) {
                db.items().update(row.copy(evidence = Evidence.AGED.name, updatedAt = now))
            }
        }
    }

    // ---- f) self-heal ------------------------------------------------------------

    private suspend fun selfHealStage(now: Long) {
        for (row in db.items().staged()) {
            val path = row.stagePath
            if (path == null || !File(path).exists()) {
                // Conditional, not the row read above written back: a restore
                // taking this row over, or parking it as never optimise,
                // deletes its staged file mid-transaction, and the stale row
                // put back as NEW undid that - the excluded photo encoded and
                // published, or one Ente had sent a second time. This pass
                // holds Locks.maintain, so it may not wait for the restore's
                // locks; the write checks instead.
                db.items().unstageIfStill(row.id, path, now)
            }
        }
    }

    private suspend fun originalsPresence(now: Long) {
        // Null means the read was incomplete (permission missing, MediaStore
        // down, a volume unmounted mid-query). Judging on a partial answer
        // would write off every original it failed to see.
        val present = scanner.presentKeys() ?: return
        if (present.isEmpty()) return
        for (row in db.items().all()) {
            val msId = row.mediaStoreId ?: continue
            val missing = MediaScanner.presenceKeyOf(row.contentUri, msId) !in present
            if (missing == row.originalMissing) continue
            if (missing && row.state == ItemState.NEW.name) {
                // Nothing was processed and the original is gone: nothing to do.
                db.items().update(
                    row.copy(state = ItemState.DONE.name, originalMissing = true, updatedAt = now)
                )
            } else {
                db.items().update(row.copy(originalMissing = missing, updatedAt = now))
            }
        }
    }

    // ---- g) cloud health ---------------------------------------------------------

    /**
     * Checks that the cloud app is still doing its half of the job, and
     * returns whether deletions must be held.
     *
     * The whole product rests on some other app quietly uploading a folder.
     * When that stops being true the danger is not that copies pile up - it is
     * that the app keeps reclaiming space against evidence that has stopped
     * arriving.
     */
    private suspend fun cloudHealth(
        o: Options,
        now: Long,
        entries: List<OutputInventory.Entry>
    ): Boolean {
        val waiting = db.items().awaitingEvidence()
        val waitingBytes = waiting.sumOf { it.outputBytes ?: 0L }
        val tx = txSinceRelease(now - CloudWatchdog.SILENCE_MS, now)
        val shrank = o.lastOutputCount > 0 && entries.size < o.lastOutputCount
        repo.setInt(OptionsRepo.K.LAST_OUTPUT_COUNT, entries.size)

        val verdict = watchdog.check(
            waitingCopies = waiting.size,
            waitingBytes = waitingBytes,
            txLastWindow = tx,
            folderShrank = shrank,
            now = now
        )

        if (verdict.healthy) {
            if (o.cloudProblem.isNotEmpty()) {
                repo.setString(OptionsRepo.K.CLOUD_PROBLEM, "")
                activity.record(
                    ActivityLog.Kind.RESUMED,
                    detail = context.getString(R.string.activity_cloud_ok)
                )
            }
            return false
        }

        val problem = verdict.problem!!.name
        if (o.cloudProblem != problem) {
            repo.setString(OptionsRepo.K.CLOUD_PROBLEM, problem)
            activity.record(
                ActivityLog.Kind.CLOUD_PROBLEM,
                detail = verdict.message
            )
        }
        Notifications.alert(
            context, Notifications.ID_WARN_CLOUD,
            context.getString(R.string.warn_cloud_title),
            verdict.message ?: context.getString(R.string.warn_safety_text),
            o, dedupKey = problem, route = "activity"
        )
        return true
    }

    /**
     * One more confirmation with nothing gone wrong: the pacing ladder climbs.
     */
    private suspend fun noteCleanConfirmation() {
        val current = repo.current()
        repo.setInt(OptionsRepo.K.CLEAN_STREAK, current.cleanConfirmStreak + 1)
        if (current.recentPacingFailure) {
            repo.setBool(OptionsRepo.K.RECENT_PACING_FAILURE, false)
        }
    }

    /**
     * A confirmation did not arrive, or did not match. The streak resets, so
     * the in-flight limit drops back down and proof samples double in
     * frequency until the accounting is trusted again.
     */
    private suspend fun notePacingFailure(reason: String) {
        val current = repo.current()
        if (current.cleanConfirmStreak == 0 && current.recentPacingFailure) return
        repo.setInt(OptionsRepo.K.CLEAN_STREAK, 0)
        repo.setBool(OptionsRepo.K.RECENT_PACING_FAILURE, true)
    }

    // ---- b) paced release + a) anchor self-heal ---------------------------------

    /**
     * Releases a slice of the day's allowance, not the whole day at once.
     *
     * A day's worth of copies leaving together makes per-file proof
     * impossible: the cloud app's byte counter cannot then say which of them
     * arrived. Sending a few at a time - usually one - is what turns a byte
     * count into evidence about a specific file.
     */
    private suspend fun pacedRelease(o: Options, now: Long, summary: Summary) {
        val caps = watchdog.caps()
        val oracle = CloudCapability.hasDisappearanceOracle(caps)
        // The same copies paced proof weighs. A VERIFIED copy holds the next
        // one back only for its own window, so that one can then go out and
        // be judged beside it; an AGED copy holds nothing back. Neither ever
        // lifts the limit.
        // Only a copy that timed out without a grade does: holding the queue
        // for it would stall it for days, so copies go out at the byte slice,
        // and simply are not paced-proved.
        val maxItems = Pacing.releaseLimit(
            waiting = unprovenWaiting(now),
            now = now,
            canMeasure = UsageVerifier.hasUsageAccess(context),
            cloudHasFreeUpOracle = oracle,
            cleanStreak = o.cleanConfirmStreak,
            stagedWaiting = db.items().countByState(ItemState.STAGED.name)
        )
        val releasedToday = releaser.bytesReleasedToday(now)
        val budget = Pacing.dailyBudgetWithCatchUp(o.dailyCapBytes, carryForward(o, now))
        val allowance = Pacing.allowanceNow(budget, releasedToday)
        if (maxItems != 0 && allowance != 0L) {
            summary.released += releaser.releaseBatch(
                o, now,
                capBytesOverride = allowance,
                maxItems = maxItems
            )
        }

        // Anchor rule / never-empty: if an active output folder has no files but
        // staged content exists for it, restore content immediately (no dummies).
        val entries = listOutputs(o) ?: return
        val byFolder = namesByFolder(entries)
        for (folder in OutputLayout.folders(o.outputMode)) {
            val has = byFolder[folderKey(o.layout.path(folder))]?.isNotEmpty() == true
            if (!has) {
                // Exactly one file, so the folder stops being empty without
                // shipping the whole staging backlog past the daily cap the
                // user set. The byte cap is lifted only so a single large file
                // can still anchor the folder.
                val n = releaser.releaseBatch(
                    o, now, onlyFolder = folder,
                    capBytesOverride = -1L,
                    maxItems = 1
                )
                if (n > 0) {
                    summary.released += n
                    summary.healed++
                }
            }
        }
    }

    /** Staged copies dropped and their files put back in the queue (see [runLocked]). */
    private suspend fun unstageForInPlace(now: Long) {
        for (row in db.items().staged()) {
            // Only a row still staged with this very file, checked and
            // written in one transaction: this pass takes no other lock, and
            // the trial or its discard may be writing the same rows.
            val dropped = db.withTransaction {
                val cur = db.items().byId(row.id)
                if (cur != null && cur.state == ItemState.STAGED.name && cur.stagePath == row.stagePath) {
                    db.items().update(Stager.unstaged(cur, now))
                    true
                } else {
                    false
                }
            }
            if (dropped) row.stagePath?.let { runCatching { File(it).delete() } }
        }
    }

    // ---- e) lazy delete ----------------------------------------------------------

    private suspend fun lazyDelete(o: Options, now: Long, summary: Summary) {
        // 13.A: a modified (re-signed) copy must never delete anything.
        if (TamperCheck.isModified(context)) return
        val stageBytes = Storage.totalStageBytes(context)
        val outputBytes = db.items().releasedBytes()
        val extra = stageBytes + outputBytes
        val free = Storage.freeBytes(context, o.storageVolume)

        var bytesToFree = 0L
        if (o.maxExtraBytes >= 0 && extra > o.maxExtraBytes) {
            bytesToFree = maxOf(bytesToFree, extra - o.maxExtraBytes)
        }
        if (free < o.minFreeBytes) {
            bytesToFree = maxOf(bytesToFree, o.minFreeBytes - free)
        }
        if (bytesToFree <= 0) return

        val released = db.items().released()
        val waiting = released.count { evidenceOf(it).ordinal < Evidence.VERIFIED.ordinal }
        val cloudPkg = EnteApp.installedPackage(context)
        // Availability follows the same rule the health check uses. Where
        // Ente's traffic cannot be measured (no Usage Access), deletion falls
        // back to the age rule in DeletePlanner rather than stopping for good
        // - copies piling up past the space limit would stop compression too.
        val cloudAvailable = EnteApp.isInstalled(context)
        val tx3d = cloudPkg?.let { pkg ->
            EnteApp.uidOf(context, pkg)?.let { uid ->
                UsageVerifier.txBytesForUid(
                    context, uid, now - Defaults.SAFETY_TX_DAYS * 86_400_000L, now
                )
            }
        }
        if (DeletePlanner.safetyPause(cloudAvailable, tx3d, waiting)) {
            if (now - o.safetyPauseWarnedAt > 86_400_000L) {
                Notifications.alert(
                    context, Notifications.ID_WARN_SAFETY,
                    context.getString(R.string.warn_safety_title),
                    context.getString(R.string.warn_safety_text),
                    o, dedupKey = "safety", route = "activity"
                )
                repo.setLong(OptionsRepo.K.SAFETY_WARNED_AT, now)
            }
            return
        }

        val entries = listOutputs(o) ?: return
        val presentNames = namesByFolder(entries)
        val current = o.layout.current.map { folderKey(it) }.toSet()
        val copies = released.mapNotNull { row ->
            val name = row.outputName ?: return@mapNotNull null
            val folder = folderOf(row)
            val place = folderKey(pathOf(row))
            if (name !in (presentNames[place] ?: emptySet<String>())) {
                return@mapNotNull null
            }
            DeletePlanner.Copy(
                id = row.id,
                bytes = row.outputBytes ?: 0L,
                evidence = evidenceOf(row),
                ageDays = ((now - (row.releasedAt ?: now)) / 86_400_000L).toInt(),
                folder = folder,
                captureAt = row.captureAt,
                place = place,
                anchorable = place in current
            )
        }
        val plan = DeletePlanner.plan(copies, bytesToFree)
        if (plan.ids.isEmpty()) return

        for (id in plan.ids) {
            val row = db.items().byId(id) ?: continue
            val uriString = row.outputUri ?: continue
            // Mark first so a missing file is attributed to us, never to the user.
            db.items().update(row.copy(appDeletedCopy = true, updatedAt = now))
            // A refusal is not a failure to retry every hour: Android will not
            // let an app silently delete a file another install made, and a
            // copy adopted after a reinstall is exactly that. It goes on the
            // list Home asks about, through Android's own dialog.
            var refused = false
            val ok = try {
                context.contentResolver.delete(Uri.parse(uriString), null, null) > 0
            } catch (e: SecurityException) {
                refused = true
                false
            } catch (e: Exception) {
                false
            }
            if (refused) repo.addCopiesNeedingConsent(listOf(id))
            // Re-read rather than reuse: the row was updated a moment ago.
            // If it has gone in the meantime there is nothing to write back,
            // and a background pass must not die of it.
            val current = db.items().byId(id) ?: continue
            if (ok) {
                db.items().update(
                    current.copy(
                        state = ItemState.DONE.name,
                        goneReason = GoneReason.APP_DELETED.name,
                        outputUri = null,
                        leftFolderAt = current.leftFolderAtAfter(ItemState.DONE.name, now),
                        updatedAt = now
                    )
                )
                summary.deleted++
            } else {
                db.items().update(current.copy(appDeletedCopy = false, updatedAt = now))
            }
        }
        if (plan.agedUsed && !o.agedWarned) {
            val shown = Notifications.alert(
                context, Notifications.ID_WARN_AGED,
                context.getString(R.string.warn_aged_title),
                context.getString(R.string.warn_aged_text),
                o, dedupKey = "aged", route = "files"
            )
            // Said once - so only once it has actually been said.
            if (shown) repo.setBool(OptionsRepo.K.AGED_WARNED, true)
        }
    }

    /**
     * Says that space can be freed, when that first passes a gigabyte and
     * again only once it has doubled (FreeableNote). The same total the
     * Storage tab marks, asked the same way, and nothing at all while Ente is
     * missing or flagged, or this copy of the app is not the real one -
     * freeing would refuse every file, and the note would lead nowhere.
     */
    private suspend fun freeableNote(now: Long) {
        val o = repo.current()
        if (o.cloudProblem.isNotEmpty() || !EnteApp.isInstalled(context) || TamperCheck.isModified(context)) return
        val freeable = db.items().reclaimableBytes(
            settledBefore = now - EvidenceRules.RECLAIM_MIN_DAYS * 86_400_000L,
            addedBeforeSeconds = (now - ReclaimRules.MIN_CONFIRM_AGE_DAYS * 86_400_000L) / 1000L,
            minSizeBytes = ReclaimRules.MIN_SIZE_BYTES,
            includeVerified = o.freeUpAllowVerified30
        )
        val said = FreeableNote.remembered(freeable, o.freeableSaidBytes)
        if (said != o.freeableSaidBytes) repo.setLong(OptionsRepo.K.FREEABLE_SAID_BYTES, said)
        if (!FreeableNote.due(freeable, said)) return
        val shown = Notifications.alert(
            context, Notifications.ID_NOTE_FREEABLE,
            context.getString(R.string.note_freeable_title, Formats.bytes(freeable)),
            context.getString(R.string.note_freeable_text),
            o, dedupKey = "freeable", route = "free_space_hub", now = now
        )
        if (shown) repo.setLong(OptionsRepo.K.FREEABLE_SAID_BYTES, freeable)
    }

    // ---- h) daily snapshot -------------------------------------------------------

    private suspend fun dailySnapshot(o: Options, now: Long) {
        val today = Formats.dayKey(now)
        // CC9.3: "already written today" only counts while the files still
        // exist. A deleted .entesaver folder heals on the next pass, the
        // same day, silently.
        if (o.lastSnapshotDay == today && snapshots.sharedTargetsPresent()) return
        if (snapshots.writeSafetySnapshot()) {
            repo.setString(OptionsRepo.K.LAST_SNAPSHOT_DAY, today)
        }
    }



    // ---- helpers -----------------------------------------------------------------

    /**
     * What yesterday's unused allowance leaves for today.
     *
     * A phone that was off, paused or out of range for a day should not lose
     * that day's uploads for good, or a user who travels never catches up.
     * The carry is capped at one day, because the point of the cap is the
     * mobile-data bill, not tidiness.
     */
    private suspend fun carryForward(o: Options, now: Long): Long {
        if (o.dailyCapBytes < 0) return 0L
        val today = Formats.dayKey(now)
        if (o.catchUpDay == today) return o.catchUpBytes
        val startOfToday = Formats.startOfDay(now)
        val startOfYesterday = startOfToday - 86_400_000L
        val yesterday = db.batches().bytesSince(startOfYesterday) -
            db.batches().bytesSince(startOfToday)
        val carried = Pacing.carryForward(o.dailyCapBytes, yesterday.coerceAtLeast(0L))
        repo.setString(OptionsRepo.K.CATCH_UP_DAY, today)
        repo.setLong(OptionsRepo.K.CATCH_UP_BYTES, carried)
        return carried
    }

    /** Bytes Ente transmitted since [from]; null if unmeasurable. */
    private fun txSinceRelease(from: Long, now: Long): Long? {
        val uid = EnteApp.uid(context) ?: return null
        return UsageVerifier.txBytesForUid(context, uid, from, now)
    }

    private suspend fun alreadyInLedger(row: ItemRow): Boolean {
        val sha = row.outputSha256 ?: return false
        return db.ledger().bySha(sha) != null
    }

    private fun folderOf(row: ItemRow): OutFolder =
        row.outputFolder?.let { runCatching { OutFolder.valueOf(it) }.getOrNull() }
            ?: OutFolder.SINGLE

    /**
     * The folder this row's copy was released into. Every released row
     * records it; one restored from a snapshot written before rows did went
     * to the folder its layout named under the old name.
     */
    private fun pathOf(row: ItemRow): String =
        row.outputRelPath ?: Defaults.legacyRelPath(folderOf(row))

    /**
     * Every folder a copy may wait in, listed in one go - or null when any
     * part of it could not be read, which callers treat as "learn nothing",
     * never as "everything left".
     */
    private suspend fun listOutputs(o: Options): List<OutputInventory.Entry>? =
        inventory.query(OutputRoots.watched(o.layout, o.pastOutputRoots, db.items().releasedRoots()))

    private fun namesByFolder(entries: List<OutputInventory.Entry>): Map<String, Set<String>> =
        entries.groupBy { folderKey(it.relPath) }.mapValues { (_, v) -> v.map { it.name }.toHashSet() }

    /** One spelling per folder: MediaStore's paths end in a slash and FAT ignores case. */
    private fun folderKey(rel: String): String = OutputRoots.normalize(rel).lowercase()

    private sealed interface Whereabouts {
        /** At [relPath] under [name]; [uri] is set when the gallery gave the copy a new address. */
        data class Moved(val relPath: String, val name: String, val uri: String? = null) : Whereabouts
        data object Gone : Whereabouts
        /** The gallery could not be asked: learn nothing this pass. */
        data object Unknown : Whereabouts
    }

    /** Where a copy missing from its folder is now, asked by its own address. */
    private fun whereNow(row: ItemRow): Whereabouts {
        val uri = row.outputUri?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return byNameAndSize(row)
        return try {
            context.contentResolver.query(
                uri,
                arrayOf(MediaPaths.FOLDER_COLUMN, MediaStore.MediaColumns.DISPLAY_NAME),
                null, null, null
            )?.use { c ->
                if (!c.moveToFirst()) return byNameAndSize(row)
                val rel = MediaPaths.relativePath(c.getString(0))
                val name = c.getString(1)
                if (rel.isNullOrEmpty() || name.isNullOrEmpty()) byNameAndSize(row) else Whereabouts.Moved(rel, name)
            } ?: Whereabouts.Unknown
        } catch (e: Exception) {
            Whereabouts.Unknown
        }
    }

    /**
     * A copy whose own address no longer answers, looked for by its name and
     * size across the gallery. A file moved can come back under a new address
     * once the media scanner has seen it (Android 12 does this), and judging
     * it gone would count a copy that still exists as collected. Exactly one
     * match that is not the original is followed; several are a question this
     * pass cannot answer; none means the copy really is gone.
     */
    private fun byNameAndSize(row: ItemRow): Whereabouts {
        val name = row.outputName ?: return Whereabouts.Gone
        val size = row.outputBytes ?: return Whereabouts.Gone
        val collection = if (row.isVideo) {
            MediaStore.Video.Media.getContentUri(Volumes.EXTERNAL)
        } else {
            MediaStore.Images.Media.getContentUri(Volumes.EXTERNAL)
        }
        return try {
            context.contentResolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID, MediaPaths.FOLDER_COLUMN),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.SIZE} = ?",
                arrayOf(name, size.toString()),
                null
            )?.use { c ->
                val found = ArrayList<Whereabouts.Moved>()
                while (c.moveToNext()) {
                    val id = c.getLong(0)
                    // An as-is copy has the original's name and size; the
                    // original itself is never taken for the copy.
                    if (id == row.mediaStoreId) continue
                    val rel = MediaPaths.relativePath(c.getString(1))?.takeIf { it.isNotEmpty() } ?: continue
                    found += Whereabouts.Moved(rel, name, ContentUris.withAppendedId(collection, id).toString())
                }
                when (found.size) {
                    0 -> Whereabouts.Gone
                    1 -> found.single()
                    else -> Whereabouts.Unknown
                }
            } ?: Whereabouts.Unknown
        } catch (e: Exception) {
            Whereabouts.Unknown
        }
    }

    private fun evidenceOf(row: ItemRow): Evidence = Evidence.parse(row.evidence)
}
