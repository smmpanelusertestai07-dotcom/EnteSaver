package app.entesaver.engine

import android.content.ContentValues
import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.room.withTransaction
import app.entesaver.R
import app.entesaver.core.logic.Defaults
import app.entesaver.core.logic.Evidence
import app.entesaver.core.logic.Fingerprint
import app.entesaver.core.logic.FormatResolver
import app.entesaver.core.logic.GoneReason
import app.entesaver.core.logic.ItemState
import app.entesaver.core.logic.KeptCopies
import app.entesaver.core.logic.MediaSettings
import app.entesaver.core.logic.OriginalCheck
import app.entesaver.core.logic.ReclaimRules
import app.entesaver.data.db.AppDb
import app.entesaver.data.db.ItemRow
import app.entesaver.data.db.ReclaimBatchRow
import app.entesaver.data.db.ReclaimItemRow
import app.entesaver.data.db.leftFolderAtAfter
import app.entesaver.data.prefs.Options
import app.entesaver.data.prefs.OptionsRepo
import app.entesaver.media.HeicSupport
import app.entesaver.media.LegacyMedia
import app.entesaver.media.MediaPaths
import app.entesaver.media.PhotoCompressor
import app.entesaver.media.VideoCompressor
import app.entesaver.util.DeviceTier
import app.entesaver.util.Locks
import app.entesaver.util.StageTurn
import app.entesaver.util.Storage
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import kotlinx.coroutines.sync.withLock

/**
 * Carries out a reclaim batch.
 *
 * The ordering here is the whole safety story: the copy is proved good, then
 * pinned, then and only then is the original's removal requested. Doing it the
 * other way round - delete, then discover the copy was truncated - is the one
 * failure this app must never have.
 */
class ReclaimEngine(private val context: Context) {

    companion object {
        /** SHA-256 of zero bytes: a hash "match" of two empty files is not proof. */
        private const val EMPTY_SHA256 =
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

        /** The longest a batch waits for the file the background run is on. */
        const val STAGE_WAIT_MS = 60_000L

        /** Why a remake was left out: the encoder was busy with another file. */
        const val STAGE_BUSY = "stage_busy"
    }

    private val db = AppDb.get(context)
    private val activity = ActivityLog(context)

    /** What happened to one item, so the summary can be specific. */
    data class Outcome(
        val fingerprint: String,
        val displayName: String,
        val done: Boolean,
        val reason: String? = null
    )

    data class Result(
        val freedBytes: Long,
        val done: List<Outcome>,
        val skipped: List<Outcome>,
        val trashed: Boolean,
        val batchId: Long
    )

    /**
     * Proves the optimised copy is really there and really intact.
     *
     * A hash that matches the ledger says the bytes are the ones the cloud
     * took. Reading the first bytes back says the file is not a zero-length
     * stub left by a failed write - which a hash of a missing file would
     * never catch, because there would be nothing to hash.
     */
    suspend fun copyIsIntact(row: ItemRow): Boolean {
        val recorded = row.outputSha256 ?: return false
        val ledger = db.ledger().bySha(recorded)
        // No local copy left: the ledger and the evidence grade are all there
        // is, and the stricter rule in ReclaimRules already demanded both.
        val local = localCopyFile(row) ?: return ledger != null
        return try {
            val actual = FileInputStream(local).use { Fingerprint.sha256(it) }
            actual == recorded && local.length() > 0
        } catch (e: Exception) {
            false
        }
    }

    private fun localCopyFile(row: ItemRow): File? {
        val path = row.stagePath ?: return null
        val file = File(path)
        return if (file.exists()) file else null
    }

    /**
     * Where a pinned copy landed: its uri, and whether it sits in the
     * original's own album. [reused] is a copy an earlier batch made, which a
     * refusal in Android's dialog must leave exactly where it was.
     */
    data class Pinned(val uri: Uri, val inPlace: Boolean, val reused: Boolean = false)

    /**
     * Puts a verified light copy into the user's own album before the
     * original is touched, remaking it when nothing usable is left locally.
     *
     * It goes to Pictures/Light copies rather than anywhere under the app's
     * folder: this is the user's photo now, it has to stay in the gallery, and
     * it must not read as something to delete when Ente Saver goes.
     *
     * The bytes come from the best source still on the phone - the hidden
     * stage file, then the copy in the upload folder - each accepted only if
     * it still hashes to what was recorded. When neither survives (the normal
     * case once a cloud app has collected and removed the copy), the light
     * copy is remade from the original with the current quality setting. A
     * remade copy exists only here: it is never staged, never queued for the
     * upload folder, never sent anywhere, and the Light copies album is
     * outside everything the scanner may touch.
     *
     * Whatever the source, nothing returns non-null until the landed file has
     * been read back, hashed against the bytes that were written, and opened
     * as an image or video. The original's removal is requested only after
     * this returns - a copy that cannot be proved keeps its original.
     */
    suspend fun pinLightCopy(
        row: ItemRow,
        options: Options,
        now: Long,
        remakeDiedOn: Long? = null,
        turn: StageTurn? = null
    ): Pinned? {
        // A caller with no batch of its own takes a turn for this one copy.
        val own = turn ?: stageTurn()
        try {
            val src = pinSource(row, options, remakeDiedOn, own) ?: return null
            return try {
                writeVerified(row, src, now, options.keptInPlace)
            } finally {
                src.temp?.delete()
            }
        } finally {
            if (turn == null) own.close()
        }
    }

    /**
     * Free up's turn at the encoder: a minute at most for the file under
     * way, and then the background run waits as long as one file can take,
     * so a second try finds it free.
     */
    private fun stageTurn(onWaiting: (Boolean) -> Unit = {}) =
        StageTurn(STAGE_WAIT_MS, VideoCompressor.DEFAULT_TOTAL_MS, onWaiting)

    /** One provable byte source for a light copy. [temp] is deleted after use. */
    private class PinSource(
        val name: String,
        val sha256: String,
        val open: () -> InputStream?,
        val temp: File? = null
    )

    private suspend fun pinSource(
        row: ItemRow,
        options: Options,
        remakeDiedOn: Long?,
        turn: StageTurn
    ): PinSource? {
        val resolver = context.contentResolver
        val recorded = row.outputSha256

        val stage = localCopyFile(row)
        if (stage != null && recorded != null) {
            val sha = runCatching {
                FileInputStream(stage).use { Fingerprint.sha256(it) }
            }.getOrNull()
            if (sha == recorded && stage.length() > 0) {
                val name = row.outputName ?: return null
                return PinSource(name, sha, { FileInputStream(stage) })
            }
        }

        val output = row.outputUri?.let { runCatching { Uri.parse(it) }.getOrNull() }
        if (output != null && recorded != null) {
            val sha = runCatching {
                resolver.openInputStream(output)?.use { Fingerprint.sha256(it) }
            }.getOrNull()
            if (sha == recorded && sha != EMPTY_SHA256) {
                val name = row.outputName ?: return null
                return PinSource(name, sha, { resolver.openInputStream(output) })
            }
        }

        // Nothing provable is left on the phone; remake from the original.
        if (row.originalMissing) return null
        // The last remake of this very file took the app down. It sits this
        // batch out - named as a failed light copy, its original kept - and
        // the next try meets the lower ceiling that crash has just set.
        if (row.id == remakeDiedOn) return null
        val original = row.contentUri?.let { runCatching { Uri.parse(it) }.getOrNull() }
            ?: return null
        val tempDir = Storage.tempDir(context, options.storageVolume)
        // One encode at a time, the background run's included: two full-size
        // decodes on a phone sized for one is how both get killed. The batch
        // takes its turn once and keeps it (StageTurn); a remake that cannot
        // have it keeps its original, named, rather than hold the screen up
        // behind a clip. The memory ceiling is read once the turn is held,
        // after the other decode has let go.
        if (!turn.take()) return null
        // A note first, written before the work: running out of memory
        // ends the process without an exception, and only the note
        // survives it.
        InFlight.beginRemake(context, row.id, row.isVideo)
        val result = try {
            if (row.isVideo) {
                VideoCompressor.compress(
                    context, original, row.displayName, row.mimeType, row.sizeBytes,
                    MediaSettings.VIDEO, tempDir
                )
            } else {
                // HEIC only where this phone has already passed its test;
                // a screen is waiting on this, so the test is not run
                // here. Held to this phone's memory ceiling exactly as
                // the background pass is: "keep every pixel" on a 200 MP
                // photo is 800 MB of bitmap, and the low-memory killer,
                // not a catchable error, is what answers that.
                PhotoCompressor.compress(
                    context, original, row.displayName, row.sizeBytes,
                    DeviceTier.fit(context, MediaSettings.PHOTO), HeicSupport.works(context), tempDir
                )
            }
        } catch (ce: kotlin.coroutines.cancellation.CancellationException) {
            throw ce
        } catch (e: Throwable) {
            null
        } finally {
            InFlight.endRemake(context, row.id)
        } ?: return null
        if (result.file.length() <= 0) {
            result.file.delete()
            return null
        }
        val sha = runCatching {
            FileInputStream(result.file).use { Fingerprint.sha256(it) }
        }.getOrNull()
        if (sha == null) {
            result.file.delete()
            return null
        }
        val name = Fingerprint.outputName(row.displayName, row.fingerprint, result.ext)
        return PinSource(name, sha, { FileInputStream(result.file) }, temp = result.file)
    }

    private suspend fun writeVerified(
        row: ItemRow,
        src: PinSource,
        now: Long,
        inPlace: Boolean
    ): Pinned? {
        // Android 9 has no pending items: there the copy is written as a file.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return writeVerifiedAsFile(row, src, now, inPlace)
        val resolver = context.contentResolver
        val collection = if (row.isVideo) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        // In place means: the album the original is in, under the original's
        // own name, so the gallery shows the same photo in the same place -
        // only smaller. Where that album cannot be read the copy falls back
        // to its own album rather than guessing at a folder, and says so by
        // reporting inPlace = false.
        val folder = if (inPlace) originalFolder(row) else null
        val landing = folder ?: "${Defaults.KEPT_DIR}/"
        val name = if (folder != null) {
            KeptCopies.inPlaceRequest(folder, inPlaceName(row, src.name))
        } else {
            src.name
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeForName(name, row.mimeType))
            put(MediaStore.MediaColumns.RELATIVE_PATH, landing)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val target = try {
            resolver.insert(collection, values) ?: return null
        } catch (e: Exception) {
            return null
        }
        return try {
            src.open()?.use { input ->
                resolver.openOutputStream(target)?.use { output ->
                    input.copyTo(output, 128 * 1024)
                } ?: error("no output stream")
            } ?: error("no input stream")
            // Read the landed bytes back before anything else believes in
            // them. A write that "succeeded" into a full disk or a dying SD
            // card is precisely the case this copy exists to survive.
            val landed = resolver.openInputStream(target)?.use { Fingerprint.sha256(it) }
            if (landed != src.sha256 || landed == EMPTY_SHA256) error("landed bytes differ")
            if (!looksDecodable(target, src.name, row.isVideo)) error("landed file unreadable")
            // Publish, then stamp the date: MediaProvider rewrites metadata
            // during its publish scan and would lose it otherwise.
            resolver.update(
                target,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null, null
            )
            // The name the provider actually gave the file, which need not be
            // the one asked for. Everything that later looks for this copy -
            // the scanner's skip, "Remove the light copy" - knows it by that
            // name, so a copy under a name they cannot recognise would be a
            // photo nobody tracks. It is taken back, and the original stays.
            val landedName = resolver.query(
                target, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
            if (landedName == null ||
                !KeptCopies.belongsTo(landedName, row.displayName, row.fingerprint)
            ) {
                error("landed name differs")
            }
            resolver.update(
                target,
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DATE_TAKEN, row.captureAt)
                    // In place, the copy has to sit exactly where the original
                    // sat in the timeline. DATE_TAKEN alone is not enough: a
                    // gallery with no date-taken on a file - which is most
                    // video - falls back to the modified date, and a fresh
                    // one would jump the photo to today, at the top of the
                    // roll, which is not "the same album, the same place".
                    if (folder != null) {
                        put(MediaStore.MediaColumns.DATE_MODIFIED, row.dateModified)
                    }
                },
                null, null
            )
            // Make the filesystem agree with the row.
            //
            // The two updates above set DATE_MODIFIED in MediaStore, but a
            // ContentValues write does not touch the file's own mtime - so the
            // row said one date and the file said another, and the next volume
            // scan resolves that disagreement in the file's favour. The
            // anti-re-optimise fingerprint was pinned to the row's value, so
            // the correction silently unpinned it. Releaser does the same
            // thing for its own output, one file over.
            if (folder != null) {
                @Suppress("DEPRECATION")
                runCatching {
                    resolver.query(
                        target, arrayOf(MediaStore.MediaColumns.DATA), null, null, null
                    )?.use { c ->
                        if (c.moveToFirst()) {
                            c.getString(0)?.takeIf { it.isNotEmpty() }?.let { data ->
                                // DATE_MODIFIED is seconds; setLastModified is millis.
                                File(data).setLastModified(row.dateModified * 1000)
                            }
                        }
                    }
                }
            }
            db.items().update(row.copy(keptUri = target.toString(), updatedAt = now))
            Pinned(target, inPlace = folder != null)
        } catch (e: Exception) {
            runCatching { resolver.delete(target, null, null) }
            null
        }
    }

    /**
     * The album the original actually lives in, as MediaStore spells it.
     *
     * Read from the original itself rather than assembled from its bucket
     * name: two folders on a phone can carry the same bucket name, and a
     * copy written into the wrong one of them would be a photo that moved.
     * Null when the path cannot be read, or when it belongs to this app -
     * "in place" must never mean "into our own output folder", which the
     * scanner treats as a returned copy.
     */
    private fun originalFolder(row: ItemRow): String? {
        val uri = row.contentUri?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return null
        val path = runCatching {
            context.contentResolver.query(
                uri, arrayOf(MediaPaths.FOLDER_COLUMN), null, null, null
            )?.use { c -> if (c.moveToFirst()) MediaPaths.relativePath(c.getString(0)) else null }
        }.getOrNull()
        if (path.isNullOrBlank()) return null
        if (Defaults.isAppOwnedPath(path)) return null
        return if (path.endsWith("/")) path else "$path/"
    }

    /**
     * The name an in-place copy carries: the original's own.
     *
     * The extension is the one the encoder actually produced, because a HEIC
     * that came out as JPEG cannot keep a .heic name - a gallery reading the
     * extension would show a broken thumbnail. Everything before the dot is
     * the original's, so the file a person finds in their album is still the
     * file they remember.
     */
    private fun inPlaceName(row: ItemRow, produced: String): String {
        val ext = produced.substringAfterLast('.', "")
        if (ext.isEmpty()) return row.displayName
        val current = row.displayName.substringAfterLast('.', "")
        if (current.equals(ext, ignoreCase = true)) return row.displayName
        val base = row.displayName.substringBeforeLast('.', row.displayName)
        return "$base.$ext"
    }

    /**
     * The copy's own type, from the name it will carry. The row's MIME is the
     * original's: after a HEIC-to-JPEG conversion the two disagree, and a
     * gallery that trusts the declared type over the extension shows nothing.
     * The full table, not just JPEG and MP4: a HEIC or WebP copy declared as
     * the original's JPEG landed as "name.heic.jpg", which neither the
     * scanner's skip nor "Remove the light copy" could recognise.
     */
    private fun mimeForName(name: String, fallback: String): String =
        FormatResolver.mimeOf(name, fallback)

    /**
     * Cheap decode probe on the formats this app itself encodes. Anything
     * else was copied as-is, where the hash already proves the bytes and a
     * probe would wrongly fail on formats this device cannot decode.
     */
    private fun looksDecodable(uri: Uri, name: String, isVideo: Boolean): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase()
        return try {
            when {
                !isVideo && (ext == "jpg" || ext == "jpeg") -> {
                    val opts = BitmapFactory.Options()
                        .apply { inJustDecodeBounds = true }
                    context.contentResolver.openInputStream(uri)?.use {
                        BitmapFactory.decodeStream(it, null, opts)
                    }
                    opts.outWidth > 0 && opts.outHeight > 0
                }
                isVideo && ext == "mp4" -> {
                    val mmr = MediaMetadataRetriever()
                    try {
                        mmr.setDataSource(context, uri)
                        mmr.extractMetadata(
                            MediaMetadataRetriever.METADATA_KEY_DURATION
                        ) != null
                    } finally {
                        runCatching { mmr.release() }
                    }
                }
                else -> true
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * The light copy this row already has, when it is still the row's own
     * file and still opens. Null sends the row through pinLightCopy as usual.
     * A row that stands for its copy offers that copy as the original, and
     * the file about to be removed can never be the one kept.
     */
    private fun keptCopyToReuse(row: ItemRow): Pinned? {
        if (row.keptUri == row.contentUri) return null
        val uri = row.keptUri?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return null
        val (name, path, size) = runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaPaths.FOLDER_COLUMN,
                    MediaStore.MediaColumns.SIZE
                ),
                null, null, null
            )?.use { c ->
                if (!c.moveToFirst() || c.getLong(2) <= 0) return@use null
                val name = c.getString(0) ?: return@use null
                Triple(name, MediaPaths.relativePath(c.getString(1)), c.getLong(2))
            }
        }.getOrNull() ?: return null
        if (!KeptCopies.isRowsCopy(name, size, row.displayName, row.fingerprint, row.outputBytes)) return null
        if (!looksDecodable(uri, name, row.isVideo)) return null
        val folder = originalFolder(row)
        val here = path?.let { if (it.endsWith("/")) it else "$it/" }
        return Pinned(uri, inPlace = folder != null && here == folder, reused = true)
    }

    /** Undoes a pinned copy, for when the original's removal was refused. */
    fun unpinLightCopy(uri: Uri) {
        runCatching { context.contentResolver.delete(uri, null, null) }
    }

    /**
     * Removes only the optimised copies from the upload folder. Originals are
     * never touched here, which is what makes this the zero-risk option.
     */
    suspend fun removeCopiesOnly(rows: List<ItemRow>, now: Long): Result =
        Locks.reclaim.withLock {
            removeCopiesOnlyLocked(rows, now)
        }

    private suspend fun removeCopiesOnlyLocked(rows: List<ItemRow>, now: Long): Result {
        val done = mutableListOf<Outcome>()
        val skipped = mutableListOf<Outcome>()
        var freed = 0L
        for (row in rows) {
            val uri = row.outputUri?.let { runCatching { Uri.parse(it) }.getOrNull() }
            if (uri == null) {
                skipped += Outcome(row.fingerprint, row.displayName, false, "no_copy")
                continue
            }
            // Mark first, so a copy that vanishes is attributed to us and not
            // read as the user deleting it.
            db.items().update(row.copy(appDeletedCopy = true, updatedAt = now))
            var refused = false
            val ok = try {
                context.contentResolver.delete(uri, null, null) > 0
            } catch (e: SecurityException) {
                // Another install's file: only Android's dialog can remove
                // it, and Home offers that once the row is on the list.
                refused = true
                false
            } catch (e: Exception) {
                false
            }
            if (refused) OptionsRepo.get(context).addCopiesNeedingConsent(listOf(row.id))
            // The row is re-read because it was just updated; if it has gone
            // there is nothing to write back and nothing to crash over.
            val current = db.items().byId(row.id)
            if (ok) {
                freed += row.outputBytes ?: 0L
                current?.let {
                    db.items().update(it.copy(outputUri = null, updatedAt = now))
                }
                done += Outcome(row.fingerprint, row.displayName, true)
            } else {
                current?.let {
                    db.items().update(it.copy(appDeletedCopy = false, updatedAt = now))
                }
                skipped += Outcome(row.fingerprint, row.displayName, false, "delete_refused")
            }
        }
        val batchId = recordBatch(ReclaimRules.Mode.COPIES_ONLY, done.size, freed, false, rows, done)
        activity.recordIfAny(ActivityLog.Kind.RECLAIMED, done.size, freed)
        return Result(freed, done, skipped, trashed = false, batchId = batchId)
    }

    /**
     * How the scanner will see a file that is already on the phone.
     *
     * The fingerprint is name + size + modified date, exactly as
     * [app.entesaver.media.MediaScanner] computes it, and it is read back
     * from MediaStore rather than predicted: the provider rewrites both the
     * name (a collision becomes "IMG_1234 (1).jpg") and the modified date
     * while publishing, and a fingerprint computed from what was asked for
     * would not match the file that actually exists.
     */
    private data class Identity(
        val uri: Uri,
        val mediaStoreId: Long,
        val displayName: String,
        val sizeBytes: Long,
        val dateModified: Long,
        val fingerprint: String
    )

    private fun identityOf(uri: Uri): Identity? = runCatching {
        context.contentResolver.query(
            uri,
            arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_MODIFIED
            ),
            null, null, null
        )?.use { c ->
            if (!c.moveToFirst()) return@use null
            val name = c.getString(1) ?: return@use null
            val size = c.getLong(2)
            val modified = c.getLong(3)
            if (size <= 0) return@use null
            Identity(
                uri = uri,
                mediaStoreId = c.getLong(0),
                displayName = name,
                sizeBytes = size,
                dateModified = modified,
                fingerprint = Fingerprint.fp16(name, size, modified)
            )
        }
    }.getOrNull()

    /**
     * Prepares a batch that removes originals: proves every copy, pins where
     * the mode asks for it, and returns the uris the UI must put through
     * Android's own dialog.
     */
    data class Prepared(
        val uris: List<Uri>,
        val rows: List<ItemRow>,
        val pinned: Map<Long, Pinned>,
        val skipped: List<Outcome>
    )

    suspend fun prepare(
        rows: List<ItemRow>,
        mode: ReclaimRules.Mode,
        options: Options,
        now: Long,
        onWaiting: (Boolean) -> Unit = {}
    ): Prepared {
        val uris = mutableListOf<Uri>()
        val ready = mutableListOf<ItemRow>()
        val pinned = mutableMapOf<Long, Pinned>()
        val skipped = mutableListOf<Outcome>()
        // Read before the first remake of this batch overwrites it.
        val remakeDiedOn = if (mode == ReclaimRules.Mode.REPLACE_WITH_LIGHT) {
            InFlight.recoverRemake(context)
        } else {
            null
        }
        // Taken at the first remake, if any, and kept to the end of the batch.
        val turn = stageTurn(onWaiting)
        try {
            prepareRows(rows, mode, options, now, remakeDiedOn, turn, uris, ready, pinned, skipped)
        } finally {
            turn.close()
        }
        return Prepared(uris, ready, pinned, skipped)
    }

    private suspend fun prepareRows(
        rows: List<ItemRow>,
        mode: ReclaimRules.Mode,
        options: Options,
        now: Long,
        remakeDiedOn: Long?,
        turn: StageTurn,
        uris: MutableList<Uri>,
        ready: MutableList<ItemRow>,
        pinned: MutableMap<Long, Pinned>,
        skipped: MutableList<Outcome>
    ) {
        for (row in rows) {
            val original = row.contentUri?.let { runCatching { Uri.parse(it) }.getOrNull() }
            if (original == null) {
                skipped += Outcome(row.fingerprint, row.displayName, false, "no_original")
                continue
            }
            // The file behind the address must still be the original the
            // cloud has - see OriginalCheck. A file that cannot be read now
            // simply stays; one that has changed is retired from this row for
            // good, because the bytes the cloud holds no longer exist on the
            // phone and the edited photo has a row of its own.
            val identity = identityOf(original)
            if (identity == null) {
                skipped += Outcome(row.fingerprint, row.displayName, false, "original_changed")
                continue
            }
            if (!OriginalCheck.unchanged(
                    row.displayName, row.sizeBytes, identity.displayName, identity.sizeBytes
                )
            ) {
                db.items().update(
                    row.copy(
                        originalMissing = true,
                        mediaStoreId = null,
                        contentUri = null,
                        updatedAt = now
                    )
                )
                skipped += Outcome(row.fingerprint, row.displayName, false, "original_changed")
                continue
            }
            if (!copyIsIntact(row)) {
                // A copy that cannot be proved good means the original stays,
                // and the item goes back for another pass.
                db.items().update(
                    row.copy(
                        state = ItemState.NEW.name,
                        evidence = Evidence.NONE.name,
                        leftFolderAt = row.leftFolderAtAfter(ItemState.NEW.name, now),
                        updatedAt = now
                    )
                )
                skipped += Outcome(row.fingerprint, row.displayName, false, "integrity_failed")
                continue
            }
            if (mode == ReclaimRules.Mode.REPLACE_WITH_LIGHT) {
                // The verified light copy exists before the removal is even
                // requested; a row that cannot get one drops out here, named,
                // and its original is never put in front of Android's dialog.
                //
                // A row restored from History still has the light copy its
                // first batch made. A second copy would take over keptUri and
                // leave the first one to the scanner as a new photo, to be
                // optimised and uploaded again; that one is used instead.
                val refusedBefore = turn.refusals
                val kept = keptCopyToReuse(row) ?: pinLightCopy(row, options, now, remakeDiedOn, turn)
                if (kept == null) {
                    val why = if (turn.refusals > refusedBefore) STAGE_BUSY else "light_copy_failed"
                    skipped += Outcome(row.fingerprint, row.displayName, false, why)
                    continue
                }
                pinned[row.id] = kept
            }
            uris += original
            ready += row
        }
    }

    /**
     * Records the outcome once Android has reported what the user allowed.
     * [deleted] is the set of uris that actually went.
     */
    // AA3.3: one deletion finishing at a time - Reclaim, Duplicates and the
    // legacy per-file path all end here, and their bookkeeping must not
    // interleave.
    suspend fun finish(
        prepared: Prepared,
        deleted: Set<String>,
        mode: ReclaimRules.Mode,
        trashed: Boolean,
        now: Long
    ): Result = Locks.reclaim.withLock {
        finishLocked(prepared, deleted, mode, trashed, now)
    }

    private suspend fun finishLocked(
        prepared: Prepared,
        deleted: Set<String>,
        mode: ReclaimRules.Mode,
        trashed: Boolean,
        now: Long
    ): Result {
        val done = mutableListOf<Outcome>()
        val skipped = prepared.skipped.toMutableList()
        var freed = 0L
        val recorded = mutableListOf<ItemRow>()

        for (row in prepared.rows) {
            val uri = row.contentUri
            if (uri == null || uri !in deleted) {
                // Refused in the dialog: the pinned copy would otherwise be a
                // second file of the same photo sitting in the gallery. A
                // reused copy was there before this batch and stays.
                val pin = prepared.pinned[row.id]?.takeIf { !it.reused }
                pin?.let { unpinLightCopy(it.uri) }
                // Guarded like the settling below: the rows after this one
                // may have been agreed to.
                if (pin != null) {
                    try {
                        db.items().byId(row.id)?.let {
                            db.items().update(it.copy(keptUri = null, updatedAt = now))
                        }
                    } catch (ce: kotlin.coroutines.cancellation.CancellationException) {
                        throw ce
                    } catch (e: Exception) {
                        // The copy is gone, so a keptUri left on it names
                        // no file any more and protects nothing.
                    }
                }
                skipped += Outcome(row.fingerprint, row.displayName, false, "not_confirmed")
                continue
            }
            val kept = mode == ReclaimRules.Mode.REPLACE_WITH_LIGHT
            freed += if (kept) {
                (row.sizeBytes - (row.outputBytes ?: 0L)).coerceAtLeast(0L)
            } else {
                row.sizeBytes
            }
            val inPlace = prepared.pinned[row.id]?.takeIf { it.inPlace }
            // Android has already removed the original, with the person's
            // consent, so from here on this row is done whatever its
            // bookkeeping does. A database error on one row used to throw out
            // of the whole batch: the rows after it were never marked, and
            // the history - the in-app undo - was never written.
            val settled = try {
                settleFreed(row, kept, inPlace, now)
            } catch (ce: kotlin.coroutines.cancellation.CancellationException) {
                throw ce
            } catch (e: Exception) {
                null
            }
            freed += settled?.copyBytesFreed ?: 0L
            // History remembers the row by the fingerprint it now carries, so
            // a restore can find it again (onRestored); the name, size and
            // address stay the original's, because that is what comes back.
            val historyKey = settled?.fingerprint ?: row.fingerprint
            done += Outcome(historyKey, row.displayName, true)
            recorded += row.copy(fingerprint = historyKey)
        }

        val batchId = recordBatch(mode, done.size, freed, trashed, recorded, done)
        activity.recordIfAny(ActivityLog.Kind.RECLAIMED, done.size, freed)
        for (outcome in skipped) {
            // No silent failures: anything that did not happen is written down
            // with the reason, in the same place everything else is.
            activity.record(
                ActivityLog.Kind.SKIPPED,
                detail = context.getString(
                    R.string.activity_reclaim_skipped, outcome.displayName
                )
            )
        }
        return Result(freed, done, skipped, trashed, batchId)
    }

    /** What finishing one row left behind: its fingerprint now, and upload-copy bytes freed. */
    private data class Settled(val fingerprint: String, val copyBytesFreed: Long)

    /**
     * Marks one row whose original Android removed.
     *
     * A copy still in the upload folder goes too. Every pass that minds that
     * folder - the space limit, lazy delete, gone detection - only looks at
     * RELEASED rows, so once this row is FREED a copy left there would be a
     * file nothing ever counts, watches or removes: "nothing kept locally"
     * with a copy kept, or a second light copy beside the pinned one. Its
     * bytes are in the cloud (ReclaimRules demanded that proof before the
     * original was offered), and the pinned copy, where there is one, was
     * made before this point.
     */
    private suspend fun settleFreed(
        row: ItemRow,
        kept: Boolean,
        inPlace: Pinned?,
        now: Long
    ): Settled? {
        val start = db.items().byId(row.id) ?: return null
        var copyGone = false
        val copy = start.outputUri
        val clearCopy = ReclaimRules.leavesUploadCopy(start.state, copy)
        if (clearCopy) {
            // Marked first, so the copy's absence reads as ours.
            db.items().update(start.copy(appDeletedCopy = true, updatedAt = now))
            // A refusal (another install's file) leaves it where it was, as it
            // always did: Home's consent list would finish the row as DONE and
            // lose the FREED record of its original.
            copyGone = runCatching {
                context.contentResolver.delete(Uri.parse(copy), null, null) > 0
            }.getOrDefault(false)
        }
        // A copy that landed in the original's own album is a file the
        // scanner will meet again on its next pass, in a folder it is meant
        // to read. Left as it is, that pass would fingerprint it as something
        // new, queue it, and optimise an already optimised photo - losing
        // quality on every round and sending a second copy of a file the
        // cloud already holds. Re-pointing the row at the new file, under the
        // fingerprint the scanner will compute for it, is what makes the two
        // meet as the same photo. The state stays a finished one, so nothing
        // re-queues.
        val identity = inPlace?.let { p -> identityOf(p.uri) }
        return db.withTransaction {
            val cur = db.items().byId(row.id) ?: return@withTransaction null
            val claimed = identity != null && claimFingerprint(cur.id, identity.fingerprint)
            val fingerprint = identity?.fingerprint?.takeIf { claimed } ?: cur.fingerprint
            val freed = if (kept) ItemState.FREED_KEPT.name else ItemState.FREED.name
            db.items().update(
                cur.copy(
                    state = freed,
                    // A copy still waiting in its folder leaves it now, as
                    // far as every pass that reads the folder is concerned.
                    leftFolderAt = cur.leftFolderAtAfter(freed, now),
                    // The original is gone either way. In place, the file
                    // standing in for it is present, which is what stops the
                    // maintenance pass reading this as a deletion - but only
                    // when that file could actually be read back. An identity
                    // we failed to read is not a file we may call present.
                    originalMissing = identity == null,
                    // The scanner's own value for the file - unless another
                    // row holds it and may not be moved (claimFingerprint).
                    fingerprint = fingerprint,
                    contentUri = identity?.uri?.toString() ?: cur.contentUri,
                    mediaStoreId = identity?.mediaStoreId ?: cur.mediaStoreId,
                    displayName = identity?.displayName ?: cur.displayName,
                    sizeBytes = identity?.sizeBytes ?: cur.sizeBytes,
                    dateModified = identity?.dateModified ?: cur.dateModified,
                    outputUri = if (copyGone) null else cur.outputUri,
                    goneReason = if (copyGone) GoneReason.APP_DELETED.name else cur.goneReason,
                    appDeletedCopy = if (clearCopy) copyGone else cur.appDeletedCopy,
                    updatedAt = now
                )
            )
            Settled(fingerprint, copyBytesFreed = if (copyGone) start.outputBytes ?: 0L else 0L)
        }
    }

    /**
     * Whether row [rowId] may take [fingerprint], which the unique index
     * lets only one row hold.
     *
     * Another holder is the scanner having met a light copy first - in the
     * window between the copy landing and the person answering Android's
     * dialog. A row nothing was ever done with is that stray, and goes: the
     * copy is this row's file. A row that has been worked on is left alone,
     * and this one keeps the fingerprint it had; it is still pinned to its
     * file by keptUri, so the scanner skips the copy either way.
     */
    private suspend fun claimFingerprint(rowId: Long, fingerprint: String): Boolean {
        val other = db.items().byFingerprint(fingerprint) ?: return true
        if (other.id == rowId) return true
        if (!ReclaimRules.isUntouchedStray(
                other.state, other.outputUri, other.stagePath, other.releasedAt, other.keptUri
            )
        ) {
            return false
        }
        db.items().delete(other)
        return true
    }

    private suspend fun recordBatch(
        mode: ReclaimRules.Mode,
        count: Int,
        freed: Long,
        trashed: Boolean,
        rows: List<ItemRow>,
        done: List<Outcome>
    ): Long {
        if (count <= 0) return 0
        val doneKeys = done.map { it.fingerprint }.toSet()
        // The batch and its files together, or neither: a batch with no files
        // under it is a History entry that cannot undo anything.
        val batchId = db.withTransaction {
            val id = db.reclaim().insertBatch(
                ReclaimBatchRow(
                    atMs = System.currentTimeMillis(),
                    mode = mode.name,
                    itemCount = count,
                    freedBytes = freed,
                    trashed = trashed
                )
            )
            db.reclaim().insertItems(
                rows.filter { it.fingerprint in doneKeys }.map { row ->
                    ReclaimItemRow(
                        batchId = id,
                        fingerprint = row.fingerprint,
                        displayName = row.displayName,
                        album = row.bucket,
                        originalBytes = row.sizeBytes,
                        optimisedBytes = row.outputBytes ?: 0L,
                        contentUri = row.contentUri,
                        trashed = trashed
                    )
                }
            )
            id
        }
        // Tidying old history must never cost the batch just written.
        try {
            prune()
        } catch (ce: kotlin.coroutines.cancellation.CancellationException) {
            throw ce
        } catch (e: Exception) {
            // The next batch prunes again.
        }
        return batchId
    }

    /** History lives exactly as long as the trash it describes. */
    suspend fun prune(now: Long = System.currentTimeMillis()) {
        db.reclaim().pruneBatches(now - 30L * 86_400_000L)
        db.reclaim().pruneOrphanItems()
    }

    /** A restored original is an original again, and goes back to the queue. */
    suspend fun onRestored(item: ReclaimItemRow, now: Long = System.currentTimeMillis()) {
        db.reclaim().markRestored(item.id, now)
        val row = db.items().byFingerprint(item.fingerprint) ?: legacyInPlaceRow(item)
        if (row == null) {
            // No row to point back at the original, so the next scan meets
            // it as a new photo. That is written down, not left to happen
            // quietly.
            activity.record(
                ActivityLog.Kind.PROBLEM,
                detail = context.getString(R.string.activity_restore_unmatched, item.displayName)
            )
            return
        }
        // A row freed in place stands for its light copy: finish re-pointed
        // it there so the scanner would not optimise the copy. The original
        // that has just come back is then a file no row describes, and the
        // next scan queued it as new - optimised again and uploaded twice.
        // It is pointed back at the original. keptUri stays, so the scanner
        // still knows the copy beside it for what it is.
        //
        // keptUri alone does not say the row moved: "Remove the light copy"
        // clears it and leaves the row on the deleted copy's address. The
        // history holds the original's address, and a row that no longer
        // has it was moved.
        val pinned = row.keptUri != null && row.contentUri == row.keptUri
        val moved = item.contentUri != null && row.contentUri != item.contentUri
        val inPlace = pinned || moved
        val original = if (inPlace) {
            item.contentUri?.let { runCatching { Uri.parse(it) }.getOrNull() }?.let { identityOf(it) }
        } else {
            null
        }
        // The file the row stood for. A 12.1 copy numbered under DCIM is
        // known after this only by its number and size, and a copy remade
        // from the original is not the size first staged.
        val copy = if (pinned && original != null) {
            row.keptUri?.let { runCatching { Uri.parse(it) }.getOrNull() }?.let { identityOf(it) }
        } else {
            null
        }
        db.withTransaction {
            val cur = db.items().byId(row.id) ?: return@withTransaction
            val claimed = original != null && claimFingerprint(cur.id, original.fingerprint)
            // Not pointed back - the original cannot be read, or a row with a
            // past already describes it - the row still stands for its kept
            // copy, or for one already removed, and marking it DONE would
            // offer that file for removal as if it were an original. It stays
            // as it is.
            if (inPlace && !claimed) return@withTransaction
            val back = if (claimed && original != null) {
                val kept = copy?.takeIf { it.uri.toString() == cur.keptUri && cur.contentUri == cur.keptUri }
                cur.copy(
                    outputBytes = kept?.let {
                        KeptCopies.outputBytesAfterRestore(
                            cur.outputBytes, cur.displayName,
                            it.displayName, it.sizeBytes, it.dateModified,
                            original.displayName, original.dateModified
                        )
                    } ?: cur.outputBytes,
                    fingerprint = original.fingerprint,
                    contentUri = original.uri.toString(),
                    mediaStoreId = original.mediaStoreId,
                    displayName = original.displayName,
                    sizeBytes = original.sizeBytes,
                    dateModified = original.dateModified
                )
            } else {
                cur
            }
            db.items().update(
                back.copy(
                    // Its copy is still evidenced, so it is finished, not new
                    // work: re-optimising a file the cloud already has would
                    // upload it twice.
                    state = ItemState.DONE.name,
                    originalMissing = false,
                    leftFolderAt = cur.leftFolderAtAfter(ItemState.DONE.name, now),
                    updatedAt = now
                )
            )
        }
    }

    /**
     * The row a 12.1 in-place history entry stands for.
     *
     * 12.1 wrote that history under the original's fingerprint, taken before
     * the row moved to its light copy, so no row carries it now. The row is
     * still the one freed in place in the same album, with the same copy size,
     * whose copy carries the original's name - or, under DCIM, the number the
     * provider counted up to, with the original's modified time. Anything but
     * exactly one such row is left alone: a guess could point the wrong row at
     * this original.
     */
    private suspend fun legacyInPlaceRow(item: ReclaimItemRow): ItemRow? {
        // Read only when a numbered name needs the original's time.
        val restored by lazy {
            item.contentUri?.let { runCatching { Uri.parse(it) }.getOrNull() }?.let { identityOf(it) }
        }
        fun countedUp(r: ItemRow) = KeptCopies.isLegacyCountUp(
            r.displayName, item.displayName, r.dateModified, restored?.dateModified ?: 0L
        )
        return db.items().keptCopies().filter { r ->
            r.state == ItemState.FREED_KEPT.name &&
                r.contentUri == r.keptUri &&
                r.bucket == item.album &&
                (r.outputBytes ?: 0L) == item.optimisedBytes &&
                (KeptCopies.belongsTo(r.displayName, item.displayName, r.fingerprint) || countedUp(r))
        }.singleOrNull()
    }

    // ---- Android 9 -----------------------------------------------------------

    /**
     * [writeVerified] on Android 9, which has no pending items: the copy is
     * written into its album as a file ([LegacyMedia]) and is read back,
     * hashed and opened before it is given its name - the same checks, in
     * the same order, as before a copy is published from Android 10. In
     * place, the original's modified time is the file's own before the
     * scanner first reads it, so the copy sits where the original sat in the
     * timeline; DATE_TAKEN is stamped afterwards, because the scanner takes
     * that date only from EXIF it trusts.
     */
    private suspend fun writeVerifiedAsFile(row: ItemRow, src: PinSource, now: Long, inPlace: Boolean): Pinned? {
        val folder = if (inPlace) originalFolder(row) else null
        val landing = folder ?: "${Defaults.KEPT_DIR}/"
        val name = if (folder != null) KeptCopies.inPlaceRequest(folder, inPlaceName(row, src.name)) else src.name
        val published = LegacyMedia.publish(
            context,
            landing,
            name,
            mimeForName(name, row.mimeType),
            modifiedMs = if (folder != null) row.dateModified * 1000 else null,
            verify = { file ->
                val landed = runCatching { FileInputStream(file).use { Fingerprint.sha256(it) } }.getOrNull()
                landed == src.sha256 && landed != EMPTY_SHA256 &&
                    looksDecodable(Uri.fromFile(file), src.name, row.isVideo)
            }
        ) { output ->
            src.open()?.use { input -> input.copyTo(output, 128 * 1024) } ?: error("no input stream")
        } ?: return null
        val resolver = context.contentResolver
        val target = published.uri
        return try {
            // Everything that later looks for this copy knows it by its name,
            // so a name nothing would recognise is taken back with the copy.
            if (!KeptCopies.belongsTo(published.name, row.displayName, row.fingerprint)) error("landed name differs")
            resolver.update(
                target,
                ContentValues().apply { put(MediaStore.MediaColumns.DATE_TAKEN, row.captureAt) },
                null, null
            )
            db.items().update(row.copy(keptUri = target.toString(), updatedAt = now))
            Pinned(target, inPlace = folder != null)
        } catch (e: Exception) {
            runCatching { resolver.delete(target, null, null) }
            published.file.delete()
            null
        }
    }
}
