package app.entesaver.media

import android.content.Context
import android.net.Uri
import android.os.Process
import android.provider.MediaStore
import androidx.room.withTransaction
import app.entesaver.core.logic.Fingerprint
import app.entesaver.core.logic.FormatResolver
import app.entesaver.core.logic.ImportMerge
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.OutFolder
import app.entesaver.core.logic.OutputMode
import app.entesaver.core.logic.PhotoFormat
import app.entesaver.core.logic.StageRules
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.prefs.Options
import app.entesaver.engine.InFlight
import app.entesaver.util.DeviceTier
import app.entesaver.util.Locks
import app.entesaver.util.Storage
import java.io.File
import java.io.FileInputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.withLock

/**
 * Creates the compressed copy of one item in the hidden stage dir
 * (app-specific external files dir - never indexed by MediaStore).
 * Retries with backoff are tracked per item; after 3 failures -> SKIP(reason).
 */
class Stager(private val context: Context, private val db: AppDb) {

    /**
     * Returns true when the item is now STAGED.
     *
     * [predictedBytes] is what the profile expected this file to come out at.
     * Storing it next to the real result is what lets the app tell the user
     * how wrong its estimates have been, instead of implying they are exact.
     *
     * [overrunCounts] is false for a run without a foreground service: a
     * clip that runs out of time there is held back without a counted try
     * ([heldBack]), since a run with the whole budget may still come.
     *
     * One file at a time across the scheduled run and the Home trial
     * ([Locks.stage]), and only a row that is still waiting for the file it
     * describes ([StageRules]). A caller with a deadline uses [stageInRun].
     */
    suspend fun stageOne(
        row: ItemRow,
        options: Options,
        predictedBytes: Long = 0,
        overrunCounts: Boolean = true
    ): Boolean = Locks.stage.withLock {
        // stageHeld reads the row again under the lock: the one the caller
        // holds came from a list read before it started, and the other path
        // may have staged it since.
        stageHeld(row, options, predictedBytes, overrunCounts = overrunCounts)
    }

    /**
     * What [stageInRun] did: whether the file was started at all, whether
     * it is now STAGED, and how long the encode itself took.
     */
    data class RunStage(val started: Boolean, val ok: Boolean, val encodeMs: Long)

    /**
     * [stageOne] for the scheduled run, which has a deadline ([deadlineAt]).
     *
     * A video encode used to be allowed to take as long as it liked - three
     * attempts, twenty minutes each - which is how a run came back an hour
     * after the deadline it had set itself. The time left is handed to the
     * encoder, so the deadline actually governs.
     *
     * It is measured once the lock is held, not before: a Free-up remake, a
     * restore or the start-up repair can hold it for minutes, and a budget
     * read before that wait ran past the job's limit, where Android stops it
     * mid-encode. A file that no longer [fits] what is left is not started
     * - no try counted, nothing written - and the run leaves it for the
     * next one. [RunStage.encodeMs] leaves the wait out too, so time spent
     * waiting is never charged to the day's battery allowance.
     */
    suspend fun stageInRun(
        row: ItemRow,
        options: Options,
        predictedBytes: Long,
        deadlineAt: Long,
        overrunCounts: Boolean = true,
        fits: (remainingMs: Long) -> Boolean
    ): RunStage = Locks.stage.withLock {
        val lockedAt = System.currentTimeMillis()
        val remaining = deadlineAt - lockedAt
        if (!fits(remaining)) return@withLock RunStage(started = false, ok = false, encodeMs = 0L)
        val ok = stageHeld(row, options, predictedBytes, remaining, overrunCounts)
        RunStage(started = true, ok = ok, encodeMs = System.currentTimeMillis() - lockedAt)
    }

    /**
     * [stageOne] for a caller that already holds [Locks.stage]: the Home
     * trial, which takes it without waiting, so it never sits on "Trying"
     * behind a video the run is encoding. [runRemainingMs] is the caller's
     * own time left, measured with the lock held (see [stageInRun]).
     */
    suspend fun stageHeld(
        row: ItemRow,
        options: Options,
        predictedBytes: Long = 0,
        runRemainingMs: Long = Long.MAX_VALUE,
        overrunCounts: Boolean = true
    ): Boolean {
        check(Locks.stage.isLocked) { "Locks.stage must be held" }
        val fresh = db.items().byId(row.id) ?: return false
        val uriString = fresh.contentUri
        if (uriString == null) {
            if (fresh.state == ItemState.NEW.name) skip(fresh, "no_uri")
            return false
        }
        // The queue reads the state, so a row still waiting with the flag
        // set (a restore by 12.1 wrote those) is parked here as the person
        // asked, never encoded.
        if (fresh.neverOptimise) {
            if (fresh.state == ItemState.NEW.name) skip(fresh, ImportMerge.USER_EXCLUDED)
            return false
        }
        val uri = Uri.parse(uriString)
        val now = identityOf(uri)
        when (
            StageRules.verdict(
                fresh.state, fresh.originalMissing, fresh.displayName, fresh.sizeBytes,
                now?.first, now?.second
            )
        ) {
            StageRules.Verdict.TAKEN -> return false
            StageRules.Verdict.CHANGED -> {
                // Edited in place while it waited. The bytes this row
                // describes are gone, and the edited file has a row of its
                // own (or will at the next scan), so this one is retired the
                // way Free up retires it - never encoded under the old name.
                db.items().update(
                    fresh.copy(
                        state = ItemState.DONE.name,
                        originalMissing = true,
                        mediaStoreId = null,
                        contentUri = null,
                        updatedAt = System.currentTimeMillis()
                    )
                )
                return false
            }
            StageRules.Verdict.STAGE ->
                return stageLocked(fresh, uri, options, predictedBytes, runRemainingMs, overrunCounts)
        }
    }

    /** Name and size of the file behind [uri] right now; null when unreadable. */
    private fun identityOf(uri: Uri): Pair<String, Long>? = runCatching {
        context.contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE),
            null, null, null
        )?.use { c ->
            if (!c.moveToFirst()) return@use null
            val name = c.getString(0) ?: return@use null
            // MediaStore reports 0 for a file it has not measured yet; that
            // is not knowing, not a change.
            val size = c.getLong(1)
            if (size <= 0) return@use null
            name to size
        }
    }.getOrNull()

    private suspend fun stageLocked(
        row: ItemRow,
        uri: Uri,
        options: Options,
        predictedBytes: Long,
        runRemainingMs: Long,
        overrunCounts: Boolean
    ): Boolean {
        val tempDir = Storage.tempDir(context, options.storageVolume)
        // Held to what this phone can decode without running out of memory;
        // asked only for a photo, since it reads the memory free right now.
        val photoSpec = if (row.isVideo) MediaSettings.PHOTO else DeviceTier.fit(context, MediaSettings.PHOTO)
        val videoSpec = MediaSettings.VIDEO
        // A HEIC is written back as HEIC only once this phone has passed its
        // own test; the test runs here, in background work, the first time
        // a HEIC photo comes up.
        val heicWorks = !row.isVideo &&
            FormatResolver.sourceFormat(row.displayName) == PhotoFormat.HEIC &&
            HeicSupport.probeIfNeeded(context, tempDir) == HeicSupport.State.OK
        // Compression must never make the phone feel slow, even with the
        // screen on while charging. The thread doing it belongs to a shared
        // coroutine pool, though, so the priority has to be handed back
        // afterwards: left lowered, that thread would quietly demote whatever
        // ran on it next - including the database read a screen is waiting
        // on - for the rest of the process's life.
        val tid = Process.myTid()
        val priorPriority = runCatching { Process.getThreadPriority(tid) }.getOrNull()
        runCatching {
            Process.setThreadPriority(tid, Process.THREAD_PRIORITY_BACKGROUND)
        }
        // Written down first: an encode that takes the whole app down throws
        // nothing, and the next run must still know which file it was.
        InFlight.begin(context, row.id)
        val result = try {
            if (row.isVideo) {
                VideoCompressor.compress(
                    context, uri, row.displayName, row.mimeType, row.sizeBytes, videoSpec, tempDir,
                    maxTotalMs = VideoCompressor.budgetFor(runRemainingMs)
                )
            } else {
                PhotoCompressor.compress(
                    context, uri, row.displayName, row.sizeBytes, photoSpec, heicWorks, tempDir
                )
            }
        } catch (ce: CancellationException) {
            throw ce
        } catch (late: VideoCompressor.OutOfTime) {
            // The run had too little left for this clip. It stays in the
            // queue for a run with the whole budget, rather than going out
            // full size as an as-is copy for good. In a run that had a
            // foreground service the try is counted, and after the usual
            // three the clip is set aside with its own reason. A plain run
            // - the day's foreground allowance spent, say - does not count
            // it, because tomorrow's run may well finish the clip; it is
            // held back instead, and set aside once plain runs alone have
            // tried it for a week, so a phone that never gives the whole
            // budget does not start it for ever. Either way the original
            // stays and no copy is made.
            if (overrunCounts) {
                fail(row, OUT_OF_TIME)
            } else {
                val now = System.currentTimeMillis()
                settle(row) { cur -> heldBack(cur, now) }
            }
            return false
        } catch (e: Exception) {
            fail(row, ENCODE_FAILED, e.message ?: e.javaClass.simpleName)
            return false
        } catch (oom: OutOfMemoryError) {
            // A huge photo can exhaust the heap while being scaled or rotated.
            // Left uncaught this escapes the worker without counting an
            // attempt, so the same file is retried first on every run and
            // nothing behind it is ever processed. Treat it as a failure so
            // the item reaches SKIP after the usual three tries.
            fail(row, OUT_OF_MEMORY)
            return false
        } finally {
            InFlight.end(context)
            priorPriority?.let { runCatching { Process.setThreadPriority(tid, it) } }
        }

        var stageFile: File? = null
        return try {
            val stageName = Fingerprint.outputName(row.displayName, row.fingerprint, result.ext)
            stageFile = File(Storage.stageDir(context, options.storageVolume), stageName)
            stageFile.delete()
            if (!result.file.renameTo(stageFile)) {
                result.file.copyTo(stageFile, overwrite = true)
                result.file.delete()
            }
            val sha = FileInputStream(stageFile).use { Fingerprint.sha256(it) }
            val folder = folderFor(row.isVideo, options.outputMode)
            val written = settle(row) { cur ->
                cur.copy(
                    state = ItemState.STAGED.name,
                    stagePath = stageFile.absolutePath,
                    outputName = stageFile.name,
                    outputBytes = stageFile.length(),
                    srcPixels = result.srcPixels,
                    outPixels = result.outPixels,
                    outputSha256 = sha,
                    outputFolder = folder.name,
                    // Grouped under how it was made, the key estimates are
                    // read back by.
                    presetUsed = if (row.isVideo) {
                        MediaSettings.videoKey(result.codec ?: PlannedEncode.videoCodec())
                    } else {
                        MediaSettings.photoKey(FormatResolver.sourceFormat(row.displayName) ?: PhotoFormat.JPEG)
                    },
                    codecUsed = result.codec?.name,
                    predictedBytes = predictedBytes,
                    skipReason = null,
                    lastError = if (result.asIs) result.reason else null,
                    updatedAt = System.currentTimeMillis()
                )
            }
            // Settled some other way while it encoded: taken over or parked
            // by a restore, excluded, or its original gone. The copy is not
            // wanted, and staged it would be published.
            if (!written) stageFile.delete()
            written
        } catch (ce: CancellationException) {
            throw ce
        } catch (e: Exception) {
            // By this point the temp file may already have been renamed, so
            // clean up both names rather than only the one we started with.
            result.file.delete()
            stageFile?.delete()
            fail(row, ENCODE_FAILED, e.message ?: e.javaClass.simpleName)
            false
        }
    }

    private suspend fun skip(row: ItemRow, reason: String) {
        db.items().update(
            row.copy(
                state = ItemState.SKIP.name,
                skipReason = reason,
                updatedAt = System.currentTimeMillis()
            )
        )
    }

    /**
     * Counts a failed attempt; the third sets the file aside. [reason] is a
     * fixed code, which Home and Files turn into words and Home groups by;
     * [detail] is what actually went wrong, kept for the record. An exception
     * message used as the reason was shown to people as it stood, and every
     * different message made its own line on Home.
     */
    private suspend fun fail(row: ItemRow, reason: String, detail: String = reason) {
        // Counted on the row as it is now, and only while it still waits
        // for this file (see settle).
        val now = System.currentTimeMillis()
        settle(row) { cur -> struck(cur, reason, detail, now) }
    }

    /**
     * Writes [change] onto the row as it is now, and only while it still
     * waits for the file that was just encoded; false when it does not.
     *
     * An encode takes seconds, a video up to twenty minutes, and the row
     * read before it is stale by the end. Written back whole, it undid
     * whatever happened meanwhile - "Never optimise", the original going -
     * and the copy was published anyway. The check and the write share one
     * transaction, so nothing lands between them.
     */
    private suspend fun settle(row: ItemRow, change: (ItemRow) -> ItemRow): Boolean =
        db.withTransaction {
            val cur = db.items().byId(row.id)
            if (cur == null ||
                !StageRules.stillWaiting(
                    cur.state, cur.neverOptimise, cur.originalMissing, cur.fingerprint, row.fingerprint
                )
            ) {
                false
            } else {
                db.items().update(change(cur))
                true
            }
        }

    companion object {
        /** Why a file was set aside after three tries (see [fail]). */
        const val ENCODE_FAILED = "encode_failed"
        const val OUT_OF_MEMORY = "out_of_memory"

        /**
         * A clip left waiting because the run ran short (see [stageOne]);
         * also why it is set aside once that has happened three times.
         */
        const val OUT_OF_TIME = "out_of_time"

        /** Tries a file gets before it is set aside (see [fail]). */
        const val MAX_TRIES = 3

        /**
         * How long plain runs alone may keep running out of time on a clip,
         * with no try counted, before it is set aside (see [heldBack]).
         */
        const val PLAIN_OVERRUN_LIMIT_MS = 7L * 24 * 60 * 60_000L

        /**
         * How long a clip held back by a plain run waits before another
         * plain run tries it again (see [plainTryDue]).
         */
        const val PLAIN_RETRY_GAP_MS = 24L * 60 * 60_000L

        /**
         * The mark a plain run's overrun leaves in lastError: [OUT_OF_TIME],
         * so the queue holds the clip back the same way, then the time of the
         * first such overrun, then "@" and the time of the latest.
         */
        private const val HELD_SINCE = "$OUT_OF_TIME@"

        /** True when [lastError] holds a clip back for running out of time. */
        fun overran(lastError: String?): Boolean = lastError?.startsWith(OUT_OF_TIME) == true

        /**
         * [row] after running out of time at [now] in a run without a
         * foreground service: still waiting, at the back of a plain run's
         * queue, with no try counted - until plain runs have done that for
         * [PLAIN_OVERRUN_LIMIT_MS], when it is set aside like a third try.
         */
        fun heldBack(row: ItemRow, now: Long): ItemRow {
            // A date ahead of now (the clock was set back) starts the week
            // again rather than stretching it.
            val since = heldTimes(row.lastError)?.first?.takeIf { it <= now } ?: now
            return if (now - since >= PLAIN_OVERRUN_LIMIT_MS) {
                row.copy(
                    state = ItemState.SKIP.name,
                    skipReason = OUT_OF_TIME,
                    lastError = OUT_OF_TIME,
                    updatedAt = now
                )
            } else {
                row.copy(lastError = "$HELD_SINCE$since@$now", updatedAt = now)
            }
        }

        /**
         * Whether a run without a foreground service may try [row] at [now].
         *
         * Such a run takes a held clip only when nothing else is left, and
         * on a phone that never gives the whole budget that was every idle
         * run: the same clip encoded for the whole window, and out of time
         * again, every half hour for a week. A held clip now waits
         * [PLAIN_RETRY_GAP_MS] after its latest plain try. A run with a
         * foreground service takes it at once.
         */
        fun plainTryDue(row: ItemRow, now: Long): Boolean {
            val last = heldTimes(row.lastError)?.second ?: return true
            // A time ahead of now is a clock set back: tried again, and the
            // mark then carries the new time.
            return last > now || now - last >= PLAIN_RETRY_GAP_MS
        }

        /** The first and the latest plain overrun a mark holds; the latest is the first in an older mark. */
        private fun heldTimes(lastError: String?): Pair<Long, Long>? {
            val times = lastError?.takeIf { it.startsWith(HELD_SINCE) }?.removePrefix(HELD_SINCE) ?: return null
            val since = times.substringBefore('@').toLongOrNull() ?: return null
            val last = times.substringAfter('@', "").toLongOrNull() ?: since
            return since to last
        }

        /**
         * [row] once the person asks for it first ("Optimise first", "Try
         * again"): waiting again with its tries back, at the front of the
         * queue by priorityAt. The out-of-time mark goes too: left in place,
         * a plain run's queue held the clip back behind every other file,
         * against what the button says. If it runs out of time again, the
         * mark comes back with that try.
         */
        fun askedFirst(row: ItemRow, now: Long): ItemRow = row.copy(
            state = ItemState.NEW.name,
            skipReason = null,
            attempts = 0,
            lastError = row.lastError.takeUnless { overran(it) },
            priorityAt = now,
            updatedAt = now
        )

        /** [row] after one more failed try at [now] (see [fail]). */
        fun struck(row: ItemRow, reason: String, detail: String, now: Long): ItemRow {
            val attempts = row.attempts + 1
            return if (attempts >= MAX_TRIES) {
                row.copy(
                    state = ItemState.SKIP.name,
                    skipReason = reason,
                    attempts = attempts,
                    lastError = detail,
                    updatedAt = now
                )
            } else {
                row.copy(attempts = attempts, lastError = detail, updatedAt = now)
            }
        }

        fun folderFor(isVideo: Boolean, mode: OutputMode): OutFolder = when {
            mode == OutputMode.SINGLE -> OutFolder.SINGLE
            isVideo -> OutFolder.VIDEOS
            else -> OutFolder.PHOTOS
        }
    }
}
