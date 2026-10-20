package app.entesaver.media

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.Fingerprint
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.KeptCopies
import app.entesaver.core.logic.KnownClouds
import app.entesaver.core.logic.ScanSources
import app.entesaver.core.logic.StageRules
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.util.Locks
import app.entesaver.util.Permissions
import app.entesaver.util.Volumes
import kotlinx.coroutines.sync.withLock

/**
 * Scans MediaStore images + videos on every external volume (incl. SD card) -
 * exactly what the Gallery shows. Our own output folders are excluded.
 */
class MediaScanner(private val context: Context, private val db: AppDb) {

    data class Found(
        val mediaStoreId: Long,
        val uri: String,
        val displayName: String,
        val sizeBytes: Long,
        val dateModified: Long,
        val dateTaken: Long,
        val dateAdded: Long,
        val durationMs: Long,
        val mimeType: String,
        val bucket: String?,
        val relativePath: String?,
        val isVideo: Boolean
    )

    /**
     * Upserts everything into the DB; returns the number of new items.
     *
     * [stageHeld] is for a caller already holding [Locks.stage] - the Home
     * trial, which takes it without waiting so it never queues behind a long
     * encode. The lock is not re-entrant.
     */
    suspend fun scan(stageHeld: Boolean = false): Int {
        // Under partial access ("Select photos") MediaStore answers every
        // query as if the handful the user picked were the whole gallery.
        // Scanning would record that handful as a complete inventory, and
        // every count and projection downstream would state it as fact. The
        // refusal lives here, at the bottom, so no caller can forget it.
        if (Permissions.mediaAccess(context) != Permissions.MediaAccess.FULL) {
            return 0
        }
        val found = excludeOutputFolders(queryAll())
        var newItems = 0
        val now = System.currentTimeMillis()
        // Light copies that replaced an original, by the identity Android
        // gives them rather than by anything the app wrote down.
        //
        // An in-place light copy carries the original's own name and sits in
        // the original's own album, so neither the pipeline-name check below
        // nor the output-folder exclusion above can see it. What kept it out
        // was its row's fingerprint, and a fingerprint is name+size+modified
        // date - a value MediaProvider rewrites the first time it re-stats
        // the file. When that happened the copy read as a brand-new photo,
        // was optimised a second time, and a worse copy of a photo the cloud
        // already held went back up. A content URI does not drift.
        //
        // The URI is trusted only for the file it names. A row restored from
        // a snapshot can carry another phone's number (KeptCopies explains),
        // and a stale number must not hide a real photo from the queue.
        val kept = db.items().keptCopies()
        val keptByUri = kept.associateBy { it.keptUri }
        val keptById = kept.mapNotNull { r ->
            r.keptUri?.substringAfterLast('/')?.toLongOrNull()?.let { it to r }
        }.toMap()
        // What each address holds now, for retireReplaced below.
        val onPhone = HashMap<String, String>()
        for (f in found) {
            val keptRow = keptByUri[f.uri] ?: keptById[f.mediaStoreId]
            if (keptRow != null &&
                KeptCopies.isRowsCopy(
                    f.displayName, f.sizeBytes, keptRow.displayName, keptRow.fingerprint, keptRow.outputBytes
                )
            ) continue
            // Z4.1: a file named like the app's own output is a copy that
            // came back - from the cloud into Download, from a share, from
            // anywhere. It is recognised by its name, matched to the ledger
            // by the identifier the name carries, and never optimised again.
            // A filename match never grants upload proof (ReattachRules).
            if (ScanSources.isPipelineName(f.displayName)) {
                if (recordReturnedCopy(f, now)) newItems++
                continue
            }
            val fp = Fingerprint.fp16(f.displayName, f.sizeBytes, f.dateModified)
            onPhone[f.uri] = fp
            val existing = db.items().byFingerprint(fp)
            if (existing == null) {
                val row = ItemRow(
                    fingerprint = fp,
                    mediaStoreId = f.mediaStoreId,
                    contentUri = f.uri,
                    displayName = f.displayName,
                    sizeBytes = f.sizeBytes,
                    dateModified = f.dateModified,
                    captureAt = if (f.dateTaken > 0) f.dateTaken else f.dateModified * 1000,
                    dateAdded = f.dateAdded,
                    durationMs = f.durationMs,
                    mimeType = f.mimeType,
                    isVideo = f.isVideo,
                    bucket = f.bucket,
                    state = ItemState.NEW.name,
                    updatedAt = now
                )
                if (db.items().insert(row) != -1L) newItems++
            } else if (existing.mediaStoreId != f.mediaStoreId ||
                existing.contentUri != f.uri ||
                existing.bucket != f.bucket ||
                existing.originalMissing
            ) {
                // Moved/renamed folder: same fingerprint, refresh location.
                // An item parked in DONE only because its original had vanished
                // (nothing was ever staged or released for it) would otherwise
                // stay there forever, since DONE is terminal - put it back in
                // the queue now that the original is here again.
                val neverProcessed = existing.outputUri == null &&
                    existing.releasedAt == null &&
                    existing.stagePath == null
                val revived = existing.state == ItemState.DONE.name &&
                    existing.originalMissing &&
                    neverProcessed
                db.items().update(
                    existing.copy(
                        mediaStoreId = f.mediaStoreId,
                        contentUri = f.uri,
                        bucket = f.bucket,
                        originalMissing = false,
                        state = if (revived) ItemState.NEW.name else existing.state,
                        goneReason = if (revived) null else existing.goneReason,
                        updatedAt = now
                    )
                )
            }
        }
        retireReplaced(onPhone, now, stageHeld)
        return newItems
    }

    /**
     * A photo edited in place keeps its address and gets a new fingerprint,
     * so the loop above gave it a row of its own - and the old row, still
     * waiting, pointed at the same file. Both were encoded from the edited
     * bytes and both copies went to Ente. The old row describes bytes that
     * are gone, so it is retired here. Under [Locks.stage], so a row being
     * staged right now finishes first and is then left alone.
     */
    private suspend fun retireReplaced(onPhone: Map<String, String>, now: Long, stageHeld: Boolean) {
        if (onPhone.isEmpty()) return
        suspend fun retire() {
            val stale = StageRules.replaced(db.items().waitingAddresses(), onPhone)
            for (chunk in stale.chunked(500)) db.items().retireReplaced(chunk, now)
        }
        if (stageHeld) retire() else Locks.stage.withLock { retire() }
    }

    /**
     * Records one returned copy so Files can show it, without ever queueing
     * it (Z4.1, Z4.3).
     *
     * Matching an existing backed-up ledger entry proves this is our own
     * output come back - it is shown as such and never re-released. Matching
     * nothing means it was probably made by another install or another tool:
     * it is left exactly where it is and never uploaded, because sending a
     * file we cannot account for would put an unaccountable copy in the
     * user's cloud.
     */
    private suspend fun recordReturnedCopy(f: Found, now: Long): Boolean {
        val fp = Fingerprint.fp16(f.displayName, f.sizeBytes, f.dateModified)
        if (db.items().byFingerprint(fp) != null) return false
        val row = ItemRow(
            fingerprint = fp,
            mediaStoreId = f.mediaStoreId,
            contentUri = f.uri,
            displayName = f.displayName,
            sizeBytes = f.sizeBytes,
            dateModified = f.dateModified,
            captureAt = if (f.dateTaken > 0) f.dateTaken else f.dateModified * 1000,
            dateAdded = f.dateAdded,
            durationMs = f.durationMs,
            mimeType = f.mimeType,
            isVideo = f.isVideo,
            bucket = f.bucket,
            state = ItemState.SKIP.name,
            skipReason = SKIP_RETURNED_COPY,
            // The name proves a copy was made, never that a cloud collected
            // it - so no evidence, exactly like the reattach path.
            evidence = Evidence.NONE.name,
            updatedAt = now
        )
        return db.items().insert(row) != -1L
    }

    fun queryAll(): List<Found> {
        val out = mutableListOf<Found>()
        val volumes = try {
            Volumes.mediaVolumeNames(context)
        } catch (e: Exception) {
            setOf(Volumes.PRIMARY)
        }
        for (volume in volumes) {
            // A volume that refuses to be read - an SD card pulled out
            // mid-scan, a provider that throws on one collection - must not
            // take the other volumes down with it, so each is asked on its
            // own. Nothing is claimed about what was not read: this list is
            // only ever added to, and the next pass asks again.
            try {
                queryCollection(MediaStore.Images.Media.getContentUri(volume), isVideo = false, out)
            } catch (e: Exception) {
            }
            try {
                queryCollection(MediaStore.Video.Media.getContentUri(volume), isVideo = true, out)
            } catch (e: Exception) {
            }
        }
        return out
    }

    /** Gallery totals for the calculator: what is there, and what is new. */
    data class Totals(
        var photoBytes: Long = 0,
        var videoBytes: Long = 0,
        var videoMinutes: Double = 0.0,
        var monthlyPhotoBytes: Long = 0,
        var monthlyVideoBytes: Long = 0,
        var photoCount: Int = 0,
        var videoCount: Int = 0,
        /**
         * False when any collection could not be read.
         *
         * A failed query and an empty gallery both produce zeros, and the two
         * mean opposite things: one is "you have no photos", the other is "we
         * do not know yet". Showing "0.00 GB" for a phone holding 22 GB - and
         * then drawing conclusions from it - came from conflating them.
         */
        var complete: Boolean = true
    ) {
    }

    /**
     * Sums the gallery without building a list of it.
     *
     * The calculator only ever needed five numbers, but the old path
     * materialised every photo in the library to get them - tens of thousands
     * of objects on a full phone, for a screen the user opens for ten seconds.
     * This walks the same cursor and adds up as it goes.
     *
     * The claim used to be false the moment it was made: the very first thing
     * this did was ask excludedBucketReasons() which albums to skip, and that
     * built the whole gallery as [Found] objects to answer. So opening the
     * calculator still allocated everything the comment promised it would not,
     * and on a 22 GB phone that is what made the screen sit there. The album
     * decision now comes from [folderTallies], which keeps a few counters per
     * folder and nothing per photo.
     *
     * [excludedBuckets] is the user's album exclusion set, applied here so the
     * estimate matches what will actually be backed up.
     */
    fun totals(excludedBuckets: Set<String>, nowMs: Long = System.currentTimeMillis()): Totals {
        val totals = Totals()
        val skipBuckets = excludedBuckets + excludedBucketReasons().keys
        val monthAgoSeconds = nowMs / 1000 - 30L * 86_400
        val volumes = try {
            Volumes.mediaVolumeNames(context)
        } catch (e: Exception) {
            setOf(Volumes.PRIMARY)
        }
        // DURATION is asked for only where it exists. Several devices reject
        // it on the Images collection with "Invalid column duration", and that
        // one exception used to take every photo on the phone down with it -
        // the whole cursor was abandoned and the gallery totalled zero.
        val baseProjection = arrayOf(
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaPaths.FOLDER_COLUMN
        )
        val videoProjection = baseProjection + MediaStore.MediaColumns.DURATION
        for (volume in volumes) {
            for (isVideo in listOf(false, true)) {
                val collection = if (isVideo) {
                    MediaStore.Video.Media.getContentUri(volume)
                } else {
                    MediaStore.Images.Media.getContentUri(volume)
                }
                val projection = if (isVideo) videoProjection else baseProjection
                try {
                    context.contentResolver.query(collection, projection, null, null, null)
                        ?.use { c ->
                            val iSize = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                            val iAdded = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
                            val iDur = if (isVideo) {
                                c.getColumnIndex(MediaStore.MediaColumns.DURATION)
                            } else {
                                -1
                            }
                            val iBucket =
                                c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
                            val iRel =
                                c.getColumnIndexOrThrow(MediaPaths.FOLDER_COLUMN)
                            while (c.moveToNext()) {
                                if (Defaults.isAppOwnedPath(MediaPaths.relativePath(c.getString(iRel)))) continue
                                val bucket = c.getString(iBucket)
                                if (bucket != null && bucket in skipBuckets) continue
                                val size = c.getLong(iSize)
                                if (size <= 0) continue
                                val fresh = c.getLong(iAdded) >= monthAgoSeconds
                                if (isVideo) {
                                    totals.videoBytes += size
                                    totals.videoCount++
                                    if (iDur >= 0) {
                                        totals.videoMinutes += c.getLong(iDur) / 60_000.0
                                    }
                                    if (fresh) totals.monthlyVideoBytes += size
                                } else {
                                    totals.photoBytes += size
                                    totals.photoCount++
                                    if (fresh) totals.monthlyPhotoBytes += size
                                }
                            }
                        }
                } catch (e: Exception) {
                    // Partial numbers must never be presented as a total.
                    totals.complete = false
                }
            }
        }
        return totals
    }

    private fun queryCollection(
        collection: Uri,
        isVideo: Boolean,
        out: MutableList<Found>
    ) {
        // DURATION is asked for on the video collection only, for the same
        // reason totals() learned above: several devices answer "Invalid
        // column duration" on Images, and that one exception was caught a
        // level up in queryAll() - which meant every photo on the phone
        // silently disappeared from the scan, so nothing was ever queued.
        val baseProjection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaPaths.FOLDER_COLUMN
        )
        val projection = if (isVideo) {
            baseProjection + MediaStore.MediaColumns.DURATION
        } else {
            baseProjection
        }
        context.contentResolver.query(collection, projection, null, null, null)?.use { c ->
            val iId = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val iName = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val iSize = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val iMod = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val iTaken = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
            val iAdded = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            // -1 for a photo, and for any device that does not carry the
            // column at all; a still simply has no duration to report.
            val iDur = c.getColumnIndex(MediaStore.MediaColumns.DURATION)
            val iMime = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val iBucket = c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            val iRel = c.getColumnIndexOrThrow(MediaPaths.FOLDER_COLUMN)
            while (c.moveToNext()) {
                val rel = MediaPaths.relativePath(c.getString(iRel))
                // Our own output, hidden folders and other pipelines' output
                // are dropped later by excludeOutputFolders(), which can also
                // judge a folder by its contents. Only the cheap, certain case
                // is short-circuited here.
                if (Defaults.isAppOwnedPath(rel)) continue
                val name = c.getString(iName) ?: continue
                // A hidden file is no photo of the person's: galleries pass
                // over one, and Android 9 lists one only when it reads the
                // whole of storage again - half-written files among them.
                if (name.startsWith(".")) continue
                val size = c.getLong(iSize)
                if (size <= 0) continue
                val id = c.getLong(iId)
                out += Found(
                    mediaStoreId = id,
                    uri = ContentUris.withAppendedId(collection, id).toString(),
                    displayName = name,
                    sizeBytes = size,
                    dateModified = c.getLong(iMod),
                    dateTaken = c.getLong(iTaken),
                    dateAdded = c.getLong(iAdded),
                    durationMs = if (iDur >= 0) c.getLong(iDur) else 0L,
                    mimeType = c.getString(iMime) ?: if (isVideo) "video/*" else "image/*",
                    bucket = c.getString(iBucket),
                    relativePath = rel,
                    isVideo = isVideo
                )
            }
        }
    }

    /**
     * Every original currently present, as volume-qualified keys.
     *
     * Returns null when any volume could not be read. Callers use this to
     * decide that originals have been deleted, and a partial answer looks
     * exactly like a mass deletion: eject an SD card mid-query and every
     * photo on it would be written off. Incomplete means "do not judge".
     */
    fun presentKeys(): Set<String>? {
        val volumes = try {
            Volumes.mediaVolumeNames(context)
        } catch (e: Exception) {
            return null
        }
        if (volumes.isEmpty()) return null
        val keys = HashSet<String>(4096)
        val projection = arrayOf(MediaStore.MediaColumns._ID)
        for (volume in volumes) {
            for (collection in listOf(
                MediaStore.Images.Media.getContentUri(volume),
                MediaStore.Video.Media.getContentUri(volume)
            )) {
                try {
                    val cursor = context.contentResolver
                        .query(collection, projection, null, null, null)
                        ?: return null
                    cursor.use { c ->
                        val iId = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                        while (c.moveToNext()) keys.add(presenceKey(volume, c.getLong(iId)))
                    }
                } catch (e: Exception) {
                    return null
                }
            }
        }
        return keys
    }

    /**
     * Every photo and video starred as a favourite in the gallery, as the
     * same addresses the rows carry. Empty on Android 9 and 10, which have no
     * shared favourite. Null when any volume could not be read: an incomplete list
     * would make the missing favourites look like ordinary photos, and Free
     * up space promises to leave favourites alone.
     */
    fun favouriteUris(): Set<String>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptySet()
        val volumes = try {
            MediaStore.getExternalVolumeNames(context)
        } catch (e: Exception) {
            return null
        }
        val out = HashSet<String>()
        for (volume in volumes) {
            for (collection in listOf(
                MediaStore.Images.Media.getContentUri(volume),
                MediaStore.Video.Media.getContentUri(volume)
            )) {
                try {
                    val cursor = context.contentResolver.query(
                        collection,
                        arrayOf(MediaStore.MediaColumns._ID),
                        "${MediaStore.MediaColumns.IS_FAVORITE} = 1",
                        null,
                        null
                    ) ?: return null
                    cursor.use { c ->
                        val iId = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                        while (c.moveToNext()) {
                            out += ContentUris.withAppendedId(collection, c.getLong(iId)).toString()
                        }
                    }
                } catch (e: Exception) {
                    return null
                }
            }
        }
        return out
    }

    companion object {
        /** How many of an album's newest files its peek shows. */
        const val PEEK_SIZE = 12

        /** skipReason for a copy that came back from the cloud (Z4.1). */
        const val SKIP_RETURNED_COPY = "returned_copy"

        /**
         * MediaStore _ID is unique per volume, not globally, so presence has to
         * be keyed by both - otherwise a deleted SD-card photo can look present
         * because an unrelated internal file happens to share its id.
         */
        fun presenceKey(volume: String, id: Long): String = "$volume:$id"

        /** The presence key for a stored row, taking the volume from its uri. */
        fun presenceKeyOf(contentUri: String?, mediaStoreId: Long): String {
            val volume = contentUri
                ?.let { runCatching { Uri.parse(it).pathSegments.firstOrNull() }
                    .getOrNull() }
                ?: Volumes.PRIMARY
            // A row written against the catch-all "external" volume - what an
            // older build stored, and what a hand-built uri still says - can
            // never match a presence key, because getExternalVolumeNames()
            // deliberately leaves that name out. Its originals would all read
            // as deleted. It has only ever meant internal storage. On Android
            // 9 "external" is the one volume there is, and PRIMARY is that
            // very name, so the key stays as it is.
            val resolved = if (volume.equals(Volumes.EXTERNAL, ignoreCase = true)) {
                Volumes.PRIMARY
            } else {
                volume
            }
            return presenceKey(resolved, mediaStoreId)
        }
    }

    /**
     * Drops folders the app must never process: its own output, hidden
     * folders, folders named after a known pipeline, and folders whose
     * contents look like compressed copies. The content check needs the whole
     * folder in hand, which is why it happens here rather than per row.
     */
    fun excludeOutputFolders(found: List<Found>): List<Found> {
        val looksLikeOutput = found
            .groupBy { folderKey(it) }
            .filterValues { rows -> ScanSources.looksLikePipelineOutput(rows.map { it.displayName }) }
            .keys
        val cloudPackages = KnownClouds.ALL_PACKAGES
        return found.filter { f ->
            ScanSources.exclusionReason(
                relativePath = f.relativePath,
                bucketName = f.bucket,
                looksLikeOutput = folderKey(f) in looksLikeOutput
            ) == null && !ScanSources.isCloudLocalPath(f.relativePath, cloudPackages)
        }
    }

    /**
     * Folders the picker must show as excluded, with the reason.
     *
     * This asks a question about a few dozen folders, and it used to answer it
     * by building the entire gallery - a [Found] object per photo and per
     * video, every one of them with five strings hanging off it - and then
     * throwing all of it away. Everything the rules actually need is a count
     * per folder, so that is all that is kept now. It matters because
     * [totals], which runs whenever the calculator is opened, waits on this.
     */
    fun excludedBucketReasons(): Map<String, ScanSources.Reason> {
        val out = HashMap<String, ScanSources.Reason>()
        for (folder in folderTallies().values) {
            val bucket = folder.bucket ?: continue
            val reason = ScanSources.exclusionReason(
                relativePath = folder.relativePath,
                bucketName = bucket,
                looksLikeOutput = folder.looksLikeOutput
            ) ?: continue
            out[bucket] = reason
        }
        return out
    }

    /**
     * What the folder rules need to know about one folder, and nothing else.
     *
     * The "looks like another pipeline's output" rule is a share of the
     * folder's file names, so it needs every name in the folder counted - but
     * not one of them kept. Two counters do that. The rule itself is still
     * ScanSources': its own two published constants are what is compared here,
     * so the numbers can never drift apart.
     */
    private class FolderTally(val bucket: String?, val relativePath: String?) {
        var files = 0
        var pipelineNames = 0

        val looksLikeOutput: Boolean
            get() = files >= ScanSources.HEURISTIC_MIN_FILES &&
                pipelineNames.toDouble() / files >= ScanSources.HEURISTIC_THRESHOLD
    }

    /**
     * One cheap walk of every collection, tallied by folder.
     *
     * Three columns and a size, in the same order the full scan sees them, so
     * the same rows are skipped for the same reasons and the picker cannot
     * start disagreeing with the scanner about what is eligible.
     */
    private fun folderTallies(): Map<String, FolderTally> {
        val out = LinkedHashMap<String, FolderTally>()
        val volumes = try {
            Volumes.mediaVolumeNames(context)
        } catch (e: Exception) {
            setOf(Volumes.PRIMARY)
        }
        val projection = arrayOf(
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaPaths.FOLDER_COLUMN
        )
        for (volume in volumes) {
            for (collection in listOf(
                MediaStore.Images.Media.getContentUri(volume),
                MediaStore.Video.Media.getContentUri(volume)
            )) {
                try {
                    context.contentResolver.query(collection, projection, null, null, null)
                        ?.use { c ->
                            val iName =
                                c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                            val iSize = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                            val iBucket =
                                c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
                            val iRel =
                                c.getColumnIndexOrThrow(MediaPaths.FOLDER_COLUMN)
                            while (c.moveToNext()) {
                                val rel = MediaPaths.relativePath(c.getString(iRel))
                                if (Defaults.isAppOwnedPath(rel)) continue
                                val name = c.getString(iName) ?: continue
                                if (c.getLong(iSize) <= 0) continue
                                val bucket = c.getString(iBucket)
                                val tally = out.getOrPut(rel ?: bucket ?: "") {
                                    FolderTally(bucket, rel)
                                }
                                tally.files++
                                if (ScanSources.isPipelineName(name)) tally.pipelineNames++
                            }
                        }
                } catch (e: Exception) {
                    // One volume's folders are missing from the tally rather
                    // than the whole tally being lost. The tally decides what
                    // to offer, never what to delete.
                }
            }
        }
        return out
    }

    private fun folderKey(f: Found): String = f.relativePath ?: f.bucket ?: ""

    /** Distinct gallery folders the user may actually choose between. */
    fun buckets(): List<String> = albums().map { it.name }

    /**
     * One entry per gallery album: its name, how many files it holds, and the
     * newest file in it to stand as the cover. The cover is what turns the
     * album picker from a list of words into the gallery someone actually
     * recognises - "Camera" is a name, the photo taken this morning is the
     * album.
     */
    data class Album(
        val name: String,
        val coverUri: String?,
        val count: Int,
        /** The newest few, newest first, for a look inside without leaving the picker. */
        val recentUris: List<String> = emptyList()
    )

    fun albums(): List<Album> =
        excludeOutputFolders(queryAll())
            .filter { it.bucket != null }
            .groupBy { it.bucket!! }
            .map { (name, files) ->
                val newest = files.sortedByDescending { it.dateModified }
                Album(
                    name = name,
                    coverUri = newest.firstOrNull()?.uri,
                    count = files.size,
                    recentUris = newest.take(PEEK_SIZE).map { it.uri }
                )
            }
            .sortedBy { it.name.lowercase() }
}
