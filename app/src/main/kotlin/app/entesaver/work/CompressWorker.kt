package app.entesaver.work

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import app.entesaver.R
import app.entesaver.core.logic.BackupScope
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.FgsBudget
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.MediaProfile
import app.entesaver.core.logic.Pacing
import app.entesaver.core.logic.RunDecider
import app.entesaver.core.logic.SaveMode
import app.entesaver.core.logic.SpeedMode
import app.entesaver.core.logic.Stops
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.prefs.Options
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.engine.ActivityLog
import app.entesaver.engine.DuplicateScanner
import app.entesaver.engine.InFlight
import app.entesaver.engine.MaintainEngine
import app.entesaver.engine.ProfileBuilder
import app.entesaver.engine.ReattachEngine
import app.entesaver.media.InPlace
import app.entesaver.media.MediaScanner
import app.entesaver.media.Stager
import app.entesaver.media.VideoCompressor
import app.entesaver.util.DeviceTier
import app.entesaver.util.Locks
import app.entesaver.util.Notifications
import app.entesaver.util.Permissions
import app.entesaver.util.SpaceLimits
import app.entesaver.util.Storage
import app.entesaver.util.TamperCheck
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * The compression worker. WorkManager only guarantees "battery not low"; every
 * real condition comes from [RunDecider], evaluated at start and between every
 * single item, so the run stops cleanly the moment the phone is picked up, the
 * battery drops, Battery Saver comes on or the daily budget runs out.
 *
 * Nothing here ever holds a wakelock while waiting: a blocked run simply ends
 * and the next periodic run re-evaluates.
 */
class CompressWorker(context: Context, params: WorkerParameters) :
    CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        // The periodic run, the FAST content trigger and "Run now" are three
        // different unique work names, so WorkManager will happily run them at
        // once. They share one staging directory and one temp directory, and
        // every run starts by clearing the temp directory - which would delete
        // a sibling's half-written encode out from under it. One at a time.
        if (!running.compareAndSet(false, true)) {
            return Result.success()
        }
        return try {
            runOnce()
        } finally {
            running.set(false)
        }
    }

    /**
     * Android started this pass and the app chose to wait - Battery Saver,
     * no charger in charging-only mode, the day's allowance spent. Stamped
     * only on these exits, never at the start of a pass: a run the phone
     * kills halfway must still read as the phone stopping the work.
     */
    private suspend fun waitedOnPurpose(repo: OptionsRepo) {
        repo.setLong(OptionsRepo.K.LAST_WAKE_AT, System.currentTimeMillis())
    }

    private suspend fun runOnce(): Result {
        val app = applicationContext
        val repo = OptionsRepo.get(app)
        var options = repo.current()
        val manual = inputData.getBoolean(KEY_MANUAL, false)

        if (!options.onboardingDone) return Result.success()
        // These two exits consumed the FAST content trigger without arming
        // the next one, so a phone coming back from a pause - or a
        // half-granted permission becoming full - reacted to new photos
        // only at the next half-hourly pass. Re-arm on the way out, as
        // every other exit does.
        if (options.pauseAll && !manual) {
            reschedule(app, repo)
            return Result.success()
        }
        // FULL only: under partial access the gallery MediaStore shows is a
        // lie, and a run would scan, queue and release against it (BB1.2).
        if (Permissions.mediaAccess(app) != Permissions.MediaAccess.FULL) {
            waitedOnPurpose(repo)
            reschedule(app, repo)
            return Result.success()
        }
        // Automatic limits follow the phone's storage as it is now.
        if (options.spaceAuto) {
            runCatching { SpaceLimits.refresh(app) }
            options = repo.current()
        }

        val db = AppDb.get(app)
        // A run that ended with the app itself - out of memory mid-photo -
        // left a note; the file gets its strike before anything else runs.
        runCatching { InFlight.recover(app, db) }
        val dayBudget = DayBudget(app)
        val startAt = System.currentTimeMillis()

        // First decision: is there any reason to spin up at all?
        var power = Gates.readPower(app, options.lastInteractiveAt, startAt)
        if (power.screenInteractive) repo.setLong(OptionsRepo.K.LAST_INTERACTIVE_AT, startAt)
        var plan = plan(options, power, dayBudget.read(startAt), manual)
        repo.setString(OptionsRepo.K.WAIT_REASON, plan.wait.name)
        if (!plan.canRun) {
            waitedOnPurpose(repo)
            reschedule(app, repo)
            return Result.success()
        }

        Storage.cleanTemp(app)
        val scanner = MediaScanner(app, db)
        val stager = Stager(app, db)
        // A replace in place the phone cut short is finished or undone
        // before anything else is touched.
        runCatching { stager.recoverInPlace() }

        val sessions = FgsBudget.decode(options.fgsSessions)
        val fgsLeft = FgsBudget.remaining(sessions, startAt)

        // With the day's foreground allowance spent, the run goes ahead as a
        // plain job, which that allowance does not cover.
        var foreground = false
        if (fgsLeft >= 5 * 60_000L) {
            try {
                setForeground(foregroundInfo(app))
                foreground = true
            } catch (e: Exception) {
                // Background-start restrictions: run inside plain JobScheduler limits.
            }
        }

        // Android 12 and later refuse a foreground service to a run that
        // starts in the background unless the battery is set to
        // Unrestricted, and stop a plain job after about ten minutes. So a
        // plain run stops taking files in time to finish its duplicate check
        // and maintenance before that, and takes only the videos it can
        // finish, instead of being cut off and starting them again every run.
        val deadline = startAt + if (foreground) min(Defaults.MAX_RUN_MIN * 60_000L, fgsLeft) else PLAIN_RUN_MS
        if (foreground) {
            // Charged up front, for the longest this session may last. A run
            // the system ends - low memory, Android 17's memory limit - never
            // reaches the clean-up below, and a ledger that lost those
            // sessions would let later runs overrun Android's six-hour limit.
            // The clean-up puts the real end in its place.
            val planned = FgsBudget.prune(sessions + (startAt to deadline), startAt)
            runCatching { repo.setString(OptionsRepo.K.FGS_SESSIONS, FgsBudget.encode(planned)) }
        }
        val deferred = HashSet<Long>()
        // Videos left for the next run: kept apart from [deferred], which
        // tells Home the phone is short of space.
        val later = HashSet<Long>()
        val profile = runCatching { ProfileBuilder(app).current(options) }
            .getOrDefault(MediaProfile.Profile())
        var processed = 0
        var videoMsOnBattery = 0L
        var photosOnBattery = 0
        try {
            // Each of these is wrapped because one failing step must not end
            // the run: the next pass tries again, and anything the person
            // needs to hear about is recorded by the step itself, in Activity.
            runCatching { scanner.scan() }

            // Copies that outlived the database. Runs once, and only after a
            // scan, because it matches against rows the scan has just created.
            runCatching { ReattachEngine(app).run() }

            loop@ while (System.currentTimeMillis() < deadline && !isStopped) {
                val now = System.currentTimeMillis()
                // Re-read options every round: Pause or a mode change must take
                // effect during a run, not only on the next one.
                val live = repo.current()
                power = Gates.readPower(app, live.lastInteractiveAt, now)
                if (power.screenInteractive) repo.setLong(OptionsRepo.K.LAST_INTERACTIVE_AT, now)

                val budget = dayBudget.read(now).let {
                    // Count what this run already spent before it is flushed.
                    it.copy(
                        videoEncodeMs = it.videoEncodeMs + videoMsOnBattery,
                        photosOnBattery = it.photosOnBattery + photosOnBattery
                    )
                }
                plan = plan(live, power, budget, manual)
                repo.setString(OptionsRepo.K.WAIT_REASON, plan.wait.name)
                if (!plan.canRun) {
                    break@loop
                }
                // Replacing in place needs Android's file access; without it
                // nothing is encoded that could not be written back. And a
                // modified build deletes nothing, which a replace does once
                // the original's 30 days are up.
                if (live.saveMode == SaveMode.IN_PLACE) {
                    val wait = when {
                        TamperCheck.isModified(app) -> RunDecider.Wait.MODIFIED_BUILD
                        !InPlace.canReplace(app) -> RunDecider.Wait.NEEDS_FILE_ACCESS
                        else -> null
                    }
                    if (wait != null) {
                        repo.setString(OptionsRepo.K.WAIT_REASON, wait.name)
                        break@loop
                    }
                }

                val resource = Gates.resourceGate(
                    app, live, Storage.totalStageBytes(app), db.items().releasedBytes()
                )
                if (resource != null) {
                    // Home reads this: a gate that stops the run has to
                    // give a reason on screen.
                    repo.setString(
                        OptionsRepo.K.WAIT_REASON, RunDecider.waitForResource(resource).name
                    )
                    break@loop
                }

                val videoMaxMs = if (foreground) {
                    -1L
                } else {
                    RunDecider.plainRunVideoMaxMs(deadline - now, VideoCompressor.MIN_TOTAL_MS)
                }
                // Files skipped for space this run are left out of the query;
                // past a couple of hundred of them the run has nothing useful
                // left to try (and the list stays far under SQLite's limit).
                if (deferred.size + later.size > MAX_DEFERRED) break@loop
                // A run without a foreground service takes a clip that already
                // ran out of time once only when nothing else is left: it
                // would most likely run out again, and first in line it held
                // up every file behind it in every such run. Even then, once
                // a day at most (Stager.plainTryDue): every idle run used to
                // spend its whole window on the same clip. One tried less
                // than a day ago waits for the next run.
                val passed = deferred + later
                val found = nextItems(db, live, plan, videoMaxMs, passed, 5, holdOverrun = !foreground)
                    .ifEmpty { if (foreground) emptyList() else nextItems(db, live, plan, videoMaxMs, passed, 5) }
                val resting = if (foreground) emptyList() else found.filterNot { Stager.plainTryDue(it, now) }
                if (resting.isNotEmpty()) {
                    later += resting.map { it.id }
                    continue@loop
                }
                val batch = found
                if (batch.isEmpty()) {
                    // Nothing left that this run can take; whatever is still
                    // waiting gets its reason on Home, found by asking again
                    // without the limit that held it back.
                    val why = when {
                        deferred.isNotEmpty() -> RunDecider.Wait.NEXT_TOO_BIG
                        videoMaxMs >= 0 && nextItems(db, live, plan, -1L, deferred, 1).isNotEmpty() ->
                            RunDecider.Wait.LONG_VIDEOS
                        !plan.photos && db.items().newInScopeCount(live.excludedBuckets) > 0 ->
                            RunDecider.Wait.PHOTO_CAP
                        else -> null
                    }
                    if (why != null) repo.setString(OptionsRepo.K.WAIT_REASON, why.name)
                    break@loop
                }
                var free = Storage.freeBytes(app, live.storageVolume)
                for (row in batch) {
                    if (System.currentTimeMillis() >= deadline || isStopped) break@loop
                    val itemStart = System.currentTimeMillis()
                    // Someone in front of Free up is waiting for the encoder
                    // to remake a light copy, or gave up waiting a moment
                    // ago. They asked for it; this run starts no new file,
                    // finishes as usual, and the next run carries on. Asked
                    // by its own clock, which setting the time cannot move.
                    if (Locks.runShouldYield()) break@loop
                    if (row.isVideo && !foreground &&
                        !RunDecider.fitsPlainRun(row.durationMs, deadline - itemStart, VideoCompressor.MIN_TOTAL_MS)
                    ) {
                        // Time has moved on since the query; the next one
                        // asks for shorter clips.
                        continue
                    }
                    if (row.isVideo && foreground &&
                        RunDecider.videoWaitsForLongerRun(
                            row.durationMs,
                            VideoCompressor.budgetFor(deadline - itemStart),
                            VideoCompressor.DEFAULT_TOTAL_MS
                        )
                    ) {
                        // Too long for what is left of this run, and a later
                        // run gives it more. Started anyway, it would only
                        // run out of time; it is first in line next run.
                        later += row.id
                        continue
                    }
                    val ratio = if (row.isVideo) profile.videos.ratio else profile.photos.ratio
                    val predicted = if (ratio > 0) (row.sizeBytes * ratio).toLong() else 0L
                    // In place there is no upload folder to pace: Ente uploads
                    // what is replaced, so the day's limit is kept here.
                    // "Optimise now" goes past it, as it does past the
                    // battery budget, and says so.
                    if (live.saveMode == SaveMode.IN_PLACE && !manual &&
                        !Pacing.replaceFitsToday(
                            live.dailyCapBytes,
                            dayBudget.replacedToday(itemStart),
                            if (predicted > 0) predicted else row.sizeBytes
                        )
                    ) {
                        repo.setString(OptionsRepo.K.WAIT_REASON, RunDecider.Wait.DAILY_LIMIT.name)
                        break@loop
                    }
                    // Checked for every file, not once per batch: the
                    // biggest files come first, and one large copy must not
                    // take the phone below the space it keeps free. A
                    // smaller file may still fit.
                    // In place, the original is copied into the trash first,
                    // so for a moment the phone holds it twice.
                    val copyNeed = if (predicted > 0) predicted * 6 / 5 else row.sizeBytes
                    val need = copyNeed + if (live.saveMode == SaveMode.IN_PLACE) row.sizeBytes else 0L
                    if (free - need < live.minFreeBytes) {
                        deferred += row.id
                        continue
                    }
                    // What is left of this run's deadline is handed to the
                    // encoder, so a single stubborn video can no longer sit
                    // there for three twenty-minute attempts while the
                    // deadline and the foreground-service allowance both run
                    // out underneath it. A clip that runs out of time counts
                    // a try only in a run with a foreground service; a plain
                    // run holds it back instead (Stager.heldBack). Measured
                    // once the encoder is free,
                    // and the file is asked again whether it still fits: a
                    // Free-up remake or a restore may have held it for
                    // minutes.
                    val staged = stager.stageInRun(row, live, predicted, deadline, overrunCounts = foreground) { left ->
                        RunDecider.canStart(
                            row.isVideo, row.durationMs, left, foreground,
                            VideoCompressor.budgetFor(left),
                            VideoCompressor.MIN_TOTAL_MS, VideoCompressor.DEFAULT_TOTAL_MS
                        )
                    }
                    if (!staged.started) {
                        // Not tried, so not counted; the next run takes it.
                        if (row.isVideo) later += row.id
                        continue
                    }
                    val ok = staged.ok
                    // Free space changes only when something was written.
                    free = Storage.freeBytes(app, live.storageVolume)
                    // Encoder time on battery is charged whether or not a copy
                    // came of it, so a clip that keeps failing still meets the
                    // day's limit - the encode's own time, not the wait for it.
                    val cost = RunDecider.batteryCost(power.plugged, row.isVideo, ok, staged.encodeMs)
                    videoMsOnBattery += cost.videoEncodeMs
                    photosOnBattery += cost.photosOnBattery
                    if (ok) {
                        processed++
                    } else if (row.isVideo) {
                        // A clip that did not finish - out of time, or a
                        // failed try - is not started again in this run with
                        // even less time left; the next run takes it.
                        later += row.id
                    }
                    // Re-check power between items, not just between batches.
                    val mid = System.currentTimeMillis()
                    power = Gates.readPower(app, repo.current().lastInteractiveAt, mid)
                    if (power.screenInteractive) {
                        repo.setLong(OptionsRepo.K.LAST_INTERACTIVE_AT, mid)
                    }
                    val midBudget = dayBudget.read(mid).let {
                        it.copy(
                            videoEncodeMs = it.videoEncodeMs + videoMsOnBattery,
                            photosOnBattery = it.photosOnBattery + photosOnBattery
                        )
                    }
                    val midPlan = plan(live, power, midBudget, manual)
                    repo.setString(OptionsRepo.K.WAIT_REASON, midPlan.wait.name)
                    if (!midPlan.canRun) {
                        break@loop
                    }
                }
            }

            if (processed > 0) {
                runCatching {
                    val saved = db.items().savedBytesSince(startAt)
                    ActivityLog(app).record(
                        ActivityLog.Kind.OPTIMISED,
                        count = processed,
                        bytes = saved,
                        filterState = ItemState.STAGED.name
                    )
                }
            }
            // Duplicate hashing rides the same window as compression: it is
            // disk work, so it belongs where the phone is already awake and
            // plugged in rather than in its own wakeup.
            runCatching {
                val scanner = DuplicateScanner(app)
                if (scanner.hashSome() > 0) scanner.markDuplicates()
            }

            // CC1.2: a run - manual or scheduled - chains straight into the
            // maintenance pass, which is what releases staged copies into the
            // upload folder.
            runCatching { MaintainEngine(app).run() }
            // Originals replaced in place that the trash has let go of.
            runCatching { stager.pruneKeptOriginals() }

            // The profile is what every estimate is derived from, so it is
            // rebuilt whenever there is new evidence to build it from.
            if (processed > 0) {
                runCatching { ProfileBuilder(app).rebuild(repo.current(), endOfRunNow()) }
            }
        } finally {
            // WorkManager stopping the run cancels this coroutine, and every
            // suspend call below would then throw at its first suspension
            // point instead of doing its job. That is the one case where the
            // cleanup matters most: the foreground session would go
            // unrecorded, so the next run would believe it still had its
            // whole daily allowance and would be refused by the system; the
            // "working" icon would stay in the status bar for good; and FAST
            // would never re-arm its one-shot content trigger, so new photos
            // would stop being noticed until the next half-hourly wake. The
            // cleanup therefore runs to the end whatever ended the run.
            withContext(NonCancellable) {
                val endAt = System.currentTimeMillis()
                runCatching {
                    dayBudget.addVideoEncode(endAt, videoMsOnBattery)
                    dayBudget.addPhotos(endAt, photosOnBattery)
                }
                if (foreground) {
                    val updated = FgsBudget.prune(sessions + (startAt to endAt), endAt)
                    repo.setString(OptionsRepo.K.FGS_SESSIONS, FgsBudget.encode(updated))
                }
                repo.setLong(OptionsRepo.K.LAST_RUN_AT, endAt)
                // Whether Android ended this run, and why.
                //
                // A run the system cuts short still reaches here and still
                // stamps LAST_RUN_AT, so every "has it run lately?" check read
                // green while the app was finishing a fraction of the work -
                // the exact failure the stall signal exists to catch, in a
                // variant it could not see. Android 16 made it the normal case:
                // a job running alongside a foreground service now sits inside
                // the JobScheduler runtime quota, so neither the 40-minute
                // window nor the foreground-service ledger is the real limit.
                val cut = if (!isStopped) {
                    ""
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    Stops.name(stopReason)
                } else {
                    Stops.UNKNOWN
                }
                repo.setString(OptionsRepo.K.LAST_STOP_REASON, cut)
                // Never leave a "working" icon in the status bar once the run
                // is over, whatever ended it.
                Notifications.clearWorking(app)
                // A run the app itself cancelled - setup reset, everything
                // stopped - arms nothing: a trigger armed now would outlive
                // the cancel and wake the app for the next new photo.
                if (!cancelledByApp()) reschedule(app, repo)
            }
        }
        return Result.success()
    }

    private fun endOfRunNow(): Long = System.currentTimeMillis()

    /** The smallest phones make videos only while charging; asked once per run. */
    private val smallestPhone by lazy { DeviceTier.tier(applicationContext) == DeviceTier.Tier.VERY_LOW }

    private fun plan(
        o: Options,
        power: RunDecider.Power,
        budget: RunDecider.Budget,
        manual: Boolean
    ): RunDecider.Plan = if (manual) {
        RunDecider.decideManual(power)
    } else {
        RunDecider.decide(o.speed, power, budget, paused = o.pauseAll, videosNeedCharger = smallestPhone)
    }

    /**
     * Whether this run ended because its own work was cancelled. WorkManager
     * marks the work cancelled before it stops the run, so the state says
     * so on every Android version, where the stop reason does only from 12.
     */
    private fun cancelledByApp(): Boolean = isStopped && runCatching {
        WorkManager.getInstance(applicationContext).getWorkInfoById(id)
            .get(5, TimeUnit.SECONDS)?.state == WorkInfo.State.CANCELLED
    }.getOrDefault(false)

    /** FAST re-arms its content trigger after every run (triggers are one-shot). */
    private suspend fun reschedule(context: Context, repo: OptionsRepo) {
        if (repo.current().speed == SpeedMode.FAST) {
            // This run consumed the trigger, so a fresh one must replace it.
            Scheduler.enqueueContentTrigger(context, force = true)
        }
    }

    /**
     * What to work on next: this month's photos first, then the biggest of the
     * backlog.
     *
     * Pure newest-first feels responsive - a photo taken this morning is
     * backed up by lunch - but on a phone with ten years of gallery it then
     * grinds through a thousand old screenshots for almost no space. Once the
     * recent window is clear, size ordering frees the most per minute of
     * encoding, so the numbers on Home start moving.
     */
    private suspend fun nextItems(
        db: AppDb,
        o: Options,
        plan: RunDecider.Plan,
        videoMaxMs: Long,
        skip: Collection<Long>,
        limit: Int,
        holdOverrun: Boolean = false
    ): List<ItemRow> {
        // What the user asked for, narrowed to what this power state allows.
        val photos = plan.photos && o.scope != BackupScope.VIDEOS
        val videos = plan.videos && o.scope != BackupScope.PHOTOS
        if (!photos && !videos) return emptyList()
        return db.items().nextByPriority(
            photos = photos,
            videos = videos,
            excludedBuckets = o.excludedBuckets,
            freshAfter = System.currentTimeMillis() - FRESH_WINDOW_MS,
            limit = limit,
            videoMaxMs = videoMaxMs,
            skipIds = skip,
            holdOverrun = holdOverrun
        )
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo(applicationContext)

    companion object {
        /** Guards the staging and temp directories against concurrent runs. */
        private val running = AtomicBoolean(false)

        /** Anything captured this recently counts as "what the user is thinking about". */
        const val FRESH_WINDOW_MS = 30L * 86_400_000L

        const val KEY_MANUAL = "manual"

        /**
         * How long a run without a foreground service takes files for. Android
         * stops a plain job after about ten minutes; the rest is for the
         * duplicate check (up to a minute) and maintenance after the loop.
         */
        const val PLAIN_RUN_MS = 7 * 60_000L

        /** Files skipped for space in one run before it stops looking. */
        private const val MAX_DEFERRED = 200

        fun foregroundInfo(context: Context): ForegroundInfo {
            val notification = Notifications.working(
                context, context.getString(R.string.notif_working_text)
            )
            return when {
                Build.VERSION.SDK_INT >= 35 -> ForegroundInfo(
                    Notifications.ID_WORKING, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
                )
                Build.VERSION.SDK_INT >= 34 -> ForegroundInfo(
                    Notifications.ID_WORKING, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
                else -> ForegroundInfo(Notifications.ID_WORKING, notification)
            }
        }
    }
}
