package app.entesaver.media

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import app.entesaver.R
import app.entesaver.core.logic.FormatResolver
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.OutFolder
import app.entesaver.core.logic.OutputPaths
import app.entesaver.core.logic.OutputRoots
import app.entesaver.core.logic.ReleasePlanner
import app.entesaver.core.logic.ReleaseVerdict
import app.entesaver.core.logic.VolumeRules
import app.entesaver.data.EnteApp
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.BatchRow
import app.entesaver.data.db.ItemRow
import app.entesaver.data.db.LedgerRow
import app.entesaver.data.db.record
import app.entesaver.data.prefs.Options
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.engine.ActivityLog
import app.entesaver.util.Formats
import app.entesaver.util.Locks
import app.entesaver.util.Volumes
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import kotlinx.coroutines.sync.withLock

/**
 * Moves staged copies into the public output folder(s) Pictures/CloudSaver via
 * MediaStore (IS_PENDING flow; on Android 9, which has none, as a file the
 * media scanner adds), sets DATE_TAKEN and lastModified to the original
 * capture date, then removes the stage file. The release cap IS the
 * cloud app's network cap: nothing can be uploaded that was never released.
 *
 * Releases are paced rather than dumped once a day - see [Pacing] for why a
 * copy that travels alone is the only kind the app can prove anything about.
 */
class Releaser(private val context: Context, private val db: AppDb) {

    /** Bytes already released today, against which the daily cap is measured. */
    suspend fun bytesReleasedToday(now: Long): Long =
        db.batches().bytesSince(Formats.startOfDay(now))

    /**
     * Releases staged files (newest first) up to capBytes. When [onlyFolder] is
     * set, only that folder's staged items are considered (anchor self-heal).
     * Returns the number of released files.
     */
    suspend fun releaseBatch(
        options: Options,
        now: Long,
        onlyFolder: OutFolder? = null,
        capBytesOverride: Long? = null,
        maxItems: Int? = null
        // AA3.3: one releaser at a time. The worker and "Optimise now" can
        // overlap, and two concurrent releases would double-count the batch
        // against the day's allowance.
    ): Int = Locks.release.withLock {
        val staged = db.items().staged()
            .filter { row -> row.stagePath?.let { File(it).exists() } == true }
            .filter { onlyFolder == null || it.outputFolder == onlyFolder.name }
            .filter { !alreadyDelivered(it) }
        if (staged.isEmpty()) return@withLock 0

        val capBytes = capBytesOverride ?: options.dailyCapBytes
        val plan = ReleasePlanner.plan(
            staged.map { ReleasePlanner.Staged(it.id, it.outputBytes ?: 0L, it.captureAt) },
            capBytes
        ).let { if (maxItems != null) it.take(maxItems) else it }
        if (plan.isEmpty()) return@withLock 0

        val rowsById = staged.associateBy { it.id }
        val batchIds = HashMap<OutFolder, Long>()
        val batchBytes = HashMap<OutFolder, Long>()
        // BB2.4: the chosen volume is honoured only while the probe says it
        // takes inserts; otherwise releases fall back to primary rather than
        // failing quietly, and Activity says so once per run. Silence would
        // read as an SD card that has stopped filling for no reason.
        val chosen = Volumes
            .selected(context, options.storageVolume)?.mediaVolumeName
            ?: Volumes.PRIMARY
        val decision = VolumeRules.releaseVolume(
            selectedVolume = if (chosen == Volumes.PRIMARY) "" else chosen,
            selectedWritable = Volumes.probeWritable(context, chosen)
        )
        val volumeName = decision.volumeName
        if (decision.fellBack) {
            ActivityLog(context).record(
                ActivityLog.Kind.PROBLEM,
                detail = context.getString(R.string.problem_volume_fallback)
            )
        }
        var released = 0
        for (id in plan) {
            val row = rowsById[id] ?: continue
            val folder = row.outputFolder?.let { runCatching { OutFolder.valueOf(it) }.getOrNull() }
                ?: OutFolder.SINGLE
            val batchId = batchIds.getOrPut(folder) {
                db.batches().insert(
                    BatchRow(
                        releasedAt = now,
                        totalBytes = 0,
                        folder = folder.name,
                        // The Ente build on this phone, whose traffic will
                        // later account for this batch.
                        cloudPackage = EnteApp.installedPackage(context)
                    )
                )
            }
            if (releaseOne(row, batchId, now, volumeName, options.layout.path(folder))) {
                released++
                batchBytes[folder] = (batchBytes[folder] ?: 0L) + (row.outputBytes ?: 0L)
            }
        }
        // Record real batch sizes. A batch where every file failed (a full
        // volume, say) must not survive: it would count against the day's
        // allowance while holding nothing, and verifyBatches skips zero-byte
        // batches, so it would sit in unverified() forever.
        for ((folder, id) in batchIds) {
            val bytes = batchBytes[folder] ?: 0L
            if (bytes > 0) db.batches().setTotalBytes(id, bytes) else db.batches().deleteById(id)
        }
        // CC1.4: nudge the media scanner so gallery apps and the cloud app
        // notice the new album now rather than whenever they next look. The
        // rows are already published; this only shortens the wait.
        if (released > 0) {
            notifyGallery(options)
        }
        // Z10.6: the 48-hour clock on the whole chain starts with the very
        // first copy that enters the upload folder.
        if (released > 0 && options.firstReleaseAt == 0L) {
            OptionsRepo.get(context)
                .setLong(OptionsRepo.K.FIRST_RELEASE_AT, now)
        }
        return@withLock released
    }

    /**
     * Ask the system to re-scan the upload folder (CC1.4).
     *
     * MediaStore already holds the rows, so this changes no state - it only
     * prompts the apps that cache their own view of the gallery to refresh,
     * which is the difference between the album appearing now and appearing
     * whenever the cloud app next happens to look.
     */
    private fun notifyGallery(options: Options) {
        val paths = OutputPaths.current(options.layout)
            .map { "${android.os.Environment.getExternalStorageDirectory()}/$it" }
        // A rescan the phone refuses is not a failure worth a word: the copy
        // is written and the cloud app finds it on its own next look.
        runCatching {
            MediaScannerConnection.scanFile(
                context, paths.toTypedArray(), null, null
            )
        }.onFailure {
        }
    }

    /**
     * True when this exact copy has already reached the cloud.
     *
     * Without this check a cloud that removes its own uploads looks identical
     * to a user deleting a file, and the app would send the same photo again
     * every time the folder was tidied - filling the account it was meant to
     * save. The ledger is the memory that stops that loop, and it survives
     * both the item row and a reinstall.
     */
    private suspend fun alreadyDelivered(row: ItemRow): Boolean {
        val sha = row.outputSha256 ?: return false
        val seen = db.ledger().bySha(sha) ?: return false
        db.items().update(
            row.copy(
                state = ItemState.DONE.name,
                evidence = seen.evidence,
                stagePath = null,
                updatedAt = System.currentTimeMillis()
            )
        )
        runCatching { File(row.stagePath!!).delete() }
        return true
    }

    /** Records a copy as delivered, once and for good. */
    // AA3.3: ledger writes are serialised - a delivery record and a snapshot
    // merge must never interleave on the same hash.
    suspend fun recordDelivered(row: ItemRow, evidence: String, now: Long): Unit =
        Locks.ledger.withLock {
            recordDeliveredLocked(row, evidence, now)
        }

    private suspend fun recordDeliveredLocked(row: ItemRow, evidence: String, now: Long) {
        val sha = row.outputSha256 ?: return
        db.ledger().record(
            LedgerRow(
                outputSha256 = sha,
                fingerprint = row.fingerprint,
                displayName = row.displayName,
                outputBytes = row.outputBytes ?: 0L,
                evidence = evidence,
                confirmedAt = now
            )
        )
    }

    /**
     * Moves one staged file into [folderPath] on [volumeName], and records
     * the folder MediaStore actually put it in - the row checks that folder,
     * and only that folder, for as long as the copy waits there.
     */
    suspend fun releaseOne(
        row: ItemRow,
        batchId: Long,
        now: Long,
        volumeName: String,
        folderPath: String
    ): Boolean {
        // Android 9 has no pending items to publish through: the copy is
        // written into the folder as a file instead, on the phone's own
        // storage, which is the only volume Android 9 lets an app write to.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return releaseOneAsFile(row, batchId, now, folderPath)
        val stagePath = row.stagePath ?: return false
        val stageFile = File(stagePath)
        if (!stageFile.exists()) return false
        // Z3.4: FAT32 cards top out just under 4 GB per file. Whether this
        // card is FAT32 cannot be asked, only discovered by failing - so a
        // file at the limit is routed to internal storage up front instead
        // of failing the copy halfway through.
        val effectiveVolume = if (
            volumeName != MediaStore.VOLUME_EXTERNAL_PRIMARY &&
            !VolumeRules.fitsOnFat32(stageFile.length())
        ) {
            MediaStore.VOLUME_EXTERNAL_PRIMARY
        } else {
            volumeName
        }
        val relPath = OutputRoots.normalize(folderPath) + "/"
        val outName = row.outputName ?: stageFile.name
        val resolver = context.contentResolver
        val collection = if (row.isVideo) {
            MediaStore.Video.Media.getContentUri(effectiveVolume)
        } else {
            MediaStore.Images.Media.getContentUri(effectiveVolume)
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, outName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeFor(outName, row.mimeType))
            put(MediaStore.MediaColumns.RELATIVE_PATH, relPath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            put(MediaStore.MediaColumns.DATE_TAKEN, row.captureAt)
        }
        var landedVolume = effectiveVolume
        var itemUri = try {
            resolver.insert(collection, values)
        } catch (e: Exception) {
            null
        }
        // BB2.4: an SD insert that fails - or lands somewhere other than the
        // card - retries once on the primary volume with the reason recorded,
        // instead of leaving the item staged forever.
        if (itemUri != null && effectiveVolume != MediaStore.VOLUME_EXTERNAL_PRIMARY) {
            val actual = runCatching { MediaStore.getVolumeName(itemUri) }.getOrNull()
            if (actual != null && !actual.equals(effectiveVolume, ignoreCase = true)) {
                landedVolume = actual
            }
        }
        if (itemUri == null && effectiveVolume != MediaStore.VOLUME_EXTERNAL_PRIMARY) {
            val primary = if (row.isVideo) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            }
            itemUri = try {
                resolver.insert(primary, values)
            } catch (e: Exception) {
                null
            }
            landedVolume = MediaStore.VOLUME_EXTERNAL_PRIMARY
        }
        if (itemUri == null) return false
        return try {
            resolver.openOutputStream(itemUri)?.use { out ->
                FileInputStream(stageFile).use { it.copyTo(out, 128 * 1024) }
            } ?: throw IOException("openOutputStream null")

            // Publishing makes MediaProvider scan the file and rewrite its
            // metadata, DATE_TAKEN included - from EXIF when there is any, to
            // null when there is not. Sending the date in the same update is a
            // race it usually loses, which would leave videos and screenshots
            // dated 1970 in the cloud app. Un-pend first, then stamp the date.
            resolver.update(
                itemUri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null, null
            )
            resolver.update(
                itemUri,
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DATE_TAKEN, row.captureAt)
                },
                null, null
            )

            // CC1.1: read the row back and prove it is really there before
            // calling it released. The un-pend above is a fire-and-forget
            // update; when it silently fails the file stays invisible to the
            // gallery and to every cloud app, and the old code marked the
            // item RELEASED anyway. Nothing could notice, because nothing
            // looked again. Now it looks.
            var actualName = outName
            var actualPath = relPath
            var verdict: ReleaseVerdict.Failure? = ReleaseVerdict.Failure.MISSING
            try {
                @Suppress("DEPRECATION")
                val projection = arrayOf(
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.DATA,
                    MediaStore.MediaColumns.SIZE,
                    MediaStore.MediaColumns.IS_PENDING,
                    MediaStore.MediaColumns.RELATIVE_PATH
                )
                resolver.query(itemUri, projection, null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        c.getString(0)?.let { actualName = it }
                        c.getString(4)?.takeIf { it.isNotBlank() }?.let { actualPath = it }
                        val data = c.getString(1)
                        if (!data.isNullOrEmpty()) {
                            runCatching { File(data).setLastModified(row.captureAt) }
                        }
                        verdict = ReleaseVerdict.check(
                            found = true,
                            isPending = c.getInt(3) == 1,
                            sizeBytes = c.getLong(2),
                            relativePath = c.getString(4),
                            expectedPath = relPath
                        )
                    }
                }
            } catch (e: Exception) {
            }
            if (!ReleaseVerdict.isVisible(verdict)) {
                // Nothing half-done survives: the broken row goes, the item
                // stays STAGED so the next pass tries again, and the reason
                // reaches Activity, where the person can read it.
                runCatching { resolver.delete(itemUri, null, null) }
                ActivityLog(context).record(
                    ActivityLog.Kind.PROBLEM,
                    detail = context.getString(R.string.problem_release_invisible, actualName)
                )
                return@releaseOne false
            }

            markReleased(row, itemUri, actualName, actualPath, batchId, now)
            stageFile.delete()
            true
        } catch (e: Exception) {
            runCatching { resolver.delete(itemUri, null, null) }
            false
        }
    }

    /**
     * [releaseOne] on Android 9: the copy written into [folderPath] as a
     * file and added by the media scanner ([LegacyMedia]), then read back
     * and judged by the same rule as a pending row from Android 10 (CC1.1).
     *
     * The file carries the capture date as its own modified time before the
     * scanner first reads it, so the date the gallery records is the
     * original's from the start; DATE_TAKEN is then stamped as well, because
     * the scanner takes that date only from EXIF it trusts.
     */
    private suspend fun releaseOneAsFile(row: ItemRow, batchId: Long, now: Long, folderPath: String): Boolean {
        val stageFile = row.stagePath?.let { File(it) }?.takeIf { it.exists() } ?: return false
        val relPath = OutputRoots.normalize(folderPath) + "/"
        val outName = row.outputName ?: stageFile.name
        val published = LegacyMedia.publish(
            context, relPath, outName, mimeFor(outName, row.mimeType), modifiedMs = row.captureAt
        ) { out ->
            FileInputStream(stageFile).use { it.copyTo(out, 128 * 1024) }
        } ?: return false
        val resolver = context.contentResolver
        val itemUri = published.uri
        var actualName = published.name
        var actualPath = relPath
        var verdict: ReleaseVerdict.Failure? = ReleaseVerdict.Failure.MISSING
        try {
            resolver.update(
                itemUri,
                ContentValues().apply { put(MediaStore.MediaColumns.DATE_TAKEN, row.captureAt) },
                null, null
            )
            @Suppress("DEPRECATION")
            val projection = arrayOf(
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.DATA,
                MediaStore.MediaColumns.SIZE
            )
            resolver.query(itemUri, projection, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.let { actualName = it }
                    val landedIn = MediaPaths.relativePathOfFile(c.getString(1))
                    landedIn?.takeIf { it.isNotBlank() }?.let { actualPath = it }
                    verdict = ReleaseVerdict.check(
                        found = true,
                        isPending = false,
                        sizeBytes = c.getLong(2),
                        relativePath = landedIn,
                        expectedPath = relPath
                    )
                }
            }
        } catch (e: Exception) {
        }
        if (!ReleaseVerdict.isVisible(verdict)) {
            runCatching { resolver.delete(itemUri, null, null) }
            published.file.delete()
            ActivityLog(context).record(
                ActivityLog.Kind.PROBLEM,
                detail = context.getString(R.string.problem_release_invisible, actualName)
            )
            return false
        }
        return try {
            markReleased(row, itemUri, actualName, actualPath, batchId, now)
            stageFile.delete()
            true
        } catch (e: Exception) {
            runCatching { resolver.delete(itemUri, null, null) }
            published.file.delete()
            false
        }
    }

    /** The one write that makes a row RELEASED: the copy, the name it landed under and the folder it is in. */
    private suspend fun markReleased(
        row: ItemRow,
        itemUri: Uri,
        actualName: String,
        actualPath: String,
        batchId: Long,
        now: Long
    ) {
        db.items().update(
            row.copy(
                state = ItemState.RELEASED.name,
                outputUri = itemUri.toString(),
                outputName = actualName,
                outputRelPath = OutputRoots.normalize(actualPath),
                releasedAt = now,
                // Out again: an earlier leave says nothing about this copy.
                leftFolderAt = null,
                batchId = batchId,
                stagePath = null,
                appDeletedCopy = false,
                updatedAt = now
            )
        )
    }

    companion object {
        fun mimeFor(name: String, fallback: String): String = FormatResolver.mimeOf(name, fallback)
    }
}
