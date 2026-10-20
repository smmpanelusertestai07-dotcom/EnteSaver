package app.entesaver.media

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.system.Os
import android.system.OsConstants
import androidx.annotation.RequiresApi
import app.entesaver.core.logic.Fingerprint
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import org.json.JSONObject

/**
 * Replaces an original with its optimised version where it is: the same
 * file, under the same name, in the same album - the same MediaStore item -
 * with the original kept in the phone's trash for 30 days.
 *
 * The same item is the point. Ente Photos, like every gallery, follows a
 * photo by its MediaStore id. A new file in the original's place is a new
 * photo to it, uploaded beside the original it already holds; written into
 * the same item, it is the same photo with new bytes, and Ente swaps the
 * original it holds for the smaller one.
 *
 * Every step is proved before the next, and every step is on record before
 * it starts. A journal is written before the original is copied, again once
 * the copy is proved and before the item is overwritten, and before an
 * original is put back - so whatever the phone cuts short, the next run
 * finishes it or undoes it, and the original is never referenced by
 * nothing. A step that cannot be finished now (the file unreadable, the
 * card out) is tried again later rather than given up. Android 9 and 10
 * have no trash, so there the original waits in a hidden folder beside it
 * ([LegacyMedia.workFolder]), under a name no other file has, removed after
 * the same 30 days.
 */
object InPlace {

    /** How long a replaced original is kept, as Android keeps its trash. */
    const val KEEP_DAYS = 30

    /** Why [replace] refused: a replace or put back the phone cut short is not settled yet. */
    const val JOURNAL_PENDING = "journal_pending"

    /** The write failed and the original could not be written back yet; recovery tries again. */
    const val WRITE_FAILED_KEPT = "write_failed_kept"

    /** The original is on a memory card, which Android 9 lets no app change. */
    const val ON_CARD = "on_card"

    /** The hidden name an original waits under on Android 9 and 10. */
    private const val HIDDEN_PREFIX = ".entesaver-original-"

    private const val JOURNAL = "in-place.json"

    /** Room left over when an original goes back, so the phone is never filled to the byte. */
    private const val SPACE_MARGIN = 16L * 1024 * 1024

    /** Recovery gives a journal up only after this many tries, and [GIVE_UP_AFTER_MS] at least. */
    private const val GIVE_UP_TRIES = 5
    private const val GIVE_UP_AFTER_MS = 24L * 60 * 60_000L

    /**
     * A file last changed this long after a write into it began was changed
     * by someone else since - not by the write the phone cut short.
     */
    private const val EDIT_MARGIN_MS = 15L * 60_000L

    private const val REPLACE = "replace"
    private const val PUT_BACK = "putback"
    private const val KEEPING = "keeping"
    private const val WRITING = "writing"

    /**
     * Whether this phone lets Ente Saver write into photos other apps made
     * without asking each time: All files access from Android 11, storage
     * write access before it - on Android 10 in its legacy storage, which
     * Android 9, having no other kind, always is.
     */
    fun canReplace(context: Context): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Environment.isExternalStorageManager()
    } else {
        @Suppress("DEPRECATION")
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || Environment.isExternalStorageLegacy()) &&
            context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    /** Whether a replace or put back is on record, waiting to be finished or undone ([recover]). */
    fun pending(context: Context): Boolean = journalFile(context).exists()

    /** What one replace came to. */
    sealed interface Result {
        /**
         * The item now holds the copy ([bytes], hashing to [sha256]); the
         * original, hashing to [originalSha256], is kept at [backup].
         */
        data class Replaced(val backup: String, val bytes: Long, val sha256: String, val originalSha256: String) : Result

        /** Nothing changed on the phone, or recovery will finish it; [reason] says why. */
        data class Failed(val reason: String) : Result
    }

    /**
     * Writes [copy] into the item at [uri], which must still be the
     * [expectedBytes] the copy was made from. [rowId] goes into the journal.
     */
    fun replace(context: Context, uri: Uri, isVideo: Boolean, expectedBytes: Long, copy: File, rowId: Long): Result {
        // One on record at a time: a journal still here belongs to a replace
        // the phone cut short, and writing over it would lose where that
        // original is kept.
        if (pending(context)) return Result.Failed(JOURNAL_PENDING)
        val info = infoOf(context, uri) ?: return Result.Failed("original_unreadable")
        if (info.size != expectedBytes) return Result.Failed("original_changed")
        // Android 9 lets an app write only to the phone's own storage: an
        // original on a memory card can be neither kept nor written over.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && info.path?.let(LegacyMedia::onPhoneStorage) == false) {
            return Result.Failed(ON_CARD)
        }
        val originalSha = sha(context, uri) ?: return Result.Failed("original_unreadable")
        val copySha = runCatching { FileInputStream(copy).use { Fingerprint.sha256(it) } }.getOrNull()
            ?: return Result.Failed("copy_unreadable")
        val copyBytes = copy.length()
        if (copyBytes <= 0 || copyBytes >= info.size) return Result.Failed("not_smaller")

        // On record before the original is copied, and again the moment the
        // copy exists: a run cut short while copying leaves a half-made
        // backup the next run knows to remove.
        val keeping = Journal(
            REPLACE, KEEPING, rowId, uri.toString(), originalSha, info.size, copySha, copyBytes,
            backup = "", startedAt = System.currentTimeMillis()
        )
        if (!writeJournal(context, keeping)) return Result.Failed("journal_failed")
        val backup = keepOriginal(context, uri, info, isVideo, originalSha, rowId) { made ->
            writeJournal(context, keeping.copy(backup = made))
        }
        if (backup == null) {
            clearJournal(context)
            return Result.Failed("backup_failed")
        }
        val writing = keeping.copy(stage = WRITING, backup = backup, startedAt = System.currentTimeMillis())
        if (!writeJournal(context, writing)) {
            deleteBackup(context, backup)
            clearJournal(context)
            return Result.Failed("journal_failed")
        }
        val written = runCatching { writeInto(context, uri, copy) }.getOrDefault(false)
        val nowSha = if (written) sha(context, uri) else null
        if (nowSha != copySha) {
            // Half written, or written wrong: the original goes back in.
            if (restoreFrom(context, backup, uri) && sha(context, uri) == originalSha) {
                rescan(context, uri, info.path)
                deleteBackup(context, backup)
                clearJournal(context)
                return Result.Failed("write_failed")
            }
            // On record for recovery, which writes it back later; the
            // original stays kept the whole time.
            return Result.Failed(WRITE_FAILED_KEPT)
        }
        rescan(context, uri, info.path)
        return Result.Replaced(backup, copyBytes, copySha, originalSha)
    }

    /** The journal of a replace whose row has now been written: nothing is left to recover. */
    fun settled(context: Context) = clearJournal(context)

    /** What [recover] found from a replace or put back the phone cut short. */
    sealed interface Recovered {
        val rowId: Long

        /**
         * The copy is in place: row [rowId] is to be finished as replaced.
         * The journal stays until it is ([settled]).
         */
        data class Finished(
            override val rowId: Long,
            val backup: String,
            val bytes: Long,
            val sha256: String,
            val originalSha256: String
        ) : Recovered

        /** The original is in place, as before: the replace counts as a try that failed. */
        data class Undone(override val rowId: Long) : Recovered

        /** A put back is finished: the original is in its item and no longer kept apart. */
        data class PutBackDone(override val rowId: Long) : Recovered

        /** Not now - the file or the kept original could not be reached; tried again next time. */
        data class Later(override val rowId: Long) : Recovered

        /**
         * Given up: the file is left as it is, and the original stays kept
         * at [backup] - for Put back, and for Android's 30 days.
         */
        data class Stuck(
            override val rowId: Long,
            val backup: String,
            val originalSha256: String,
            val reason: String
        ) : Recovered
    }

    /** Finishes, undoes or puts off the one step a journal may describe; null when there is none. */
    fun recover(context: Context, now: Long = System.currentTimeMillis()): Recovered? {
        if (!pending(context)) return null
        // A file that cannot be read now is read next time. One that reads
        // but makes no sense can never be acted on - and left in place it
        // would hold every replace back for good.
        val text = runCatching { journalFile(context).readText(Charsets.UTF_8) }.getOrNull() ?: return null
        val j = parseJournal(text, journalFile(context).lastModified()) ?: return null.also { clearJournal(context) }
        if (j.kind == REPLACE && j.stage == KEEPING) {
            // Cut short while the original was being copied: the item itself
            // was never written. What was begun of the copy goes.
            if (j.backup.isNotEmpty()) deleteBackup(context, j.backup)
            clearJournal(context)
            return Recovered.Undone(j.rowId)
        }
        val uri = Uri.parse(j.uri)
        val current = sha(context, uri)
        if (current == null && itemGone(context, uri)) {
            // Deleted since: there is nothing to write into. The original
            // stays kept, for Android's 30 days.
            clearJournal(context)
            return Recovered.Stuck(j.rowId, j.backup, j.originalSha, "item_gone")
        }
        val outcome: Recovered? = when {
            current == null -> null
            j.kind == REPLACE && current == j.copySha ->
                return Recovered.Finished(j.rowId, j.backup, j.copyBytes, j.copySha, j.originalSha)
            current == j.originalSha -> {
                deleteBackup(context, j.backup)
                if (j.kind == PUT_BACK) Recovered.PutBackDone(j.rowId) else Recovered.Undone(j.rowId)
            }
            editedSince(context, uri, j) -> {
                // Neither the copy nor the original, and changed long after
                // the write began: someone else's edit, which is never
                // written over. The original stays kept for Put back.
                clearJournal(context)
                return Recovered.Stuck(j.rowId, j.backup, j.originalSha, "edited_since")
            }
            restoreFrom(context, j.backup, uri) && sha(context, uri) == j.originalSha -> {
                rescan(context, uri, infoOf(context, uri)?.path)
                deleteBackup(context, j.backup)
                if (j.kind == PUT_BACK) Recovered.PutBackDone(j.rowId) else Recovered.Undone(j.rowId)
            }
            else -> null
        }
        if (outcome == null) {
            val next = j.copy(tries = j.tries + 1)
            if (next.tries >= GIVE_UP_TRIES && now - j.startedAt >= GIVE_UP_AFTER_MS) {
                clearJournal(context)
                return Recovered.Stuck(j.rowId, j.backup, j.originalSha, if (current == null) "unreadable" else "restore_failed")
            }
            writeJournal(context, next)
            return Recovered.Later(j.rowId)
        }
        clearJournal(context)
        return outcome
    }

    /**
     * Puts the original kept at [backup] back into [uri], the item it was
     * replaced in - the same id and name, so Ente takes the original back
     * the way it took the copy - and removes the kept one.
     *
     * Only the original row [rowId] kept, and only into the file it was
     * replaced in: the original must still be in the trash and, when
     * [originalSha] is known, still hash to it; the item must still be
     * called [name] and, when [copySha] is known, still hold exactly that
     * copy - an edit made since, or another photo at an address a re-index
     * handed on, is never written over. On record before a byte is written,
     * so a put back the phone cuts short is finished by the next run
     * ([recover]).
     */
    fun putBack(
        context: Context,
        backup: String,
        uri: Uri,
        originalSha: String?,
        name: String,
        copySha: String?,
        rowId: Long
    ): PutBack {
        if (pending(context)) return PutBack.FAILED
        when (backupState(context, backup)) {
            Kept.KEPT -> Unit
            Kept.GONE, Kept.LEFT_TRASH -> return PutBack.NOT_KEPT
            Kept.UNKNOWN -> return PutBack.FAILED
        }
        val keptSha = runCatching { openBackup(context, backup).use { Fingerprint.sha256(it) } }.getOrNull()
            ?: return PutBack.FAILED
        if (originalSha != null && keptSha != originalSha) return PutBack.NOT_KEPT
        val info = infoOf(context, uri) ?: return PutBack.FAILED
        val currentSha = sha(context, uri) ?: return PutBack.FAILED
        if (info.name != name || (copySha != null && currentSha != copySha)) return PutBack.CHANGED
        // The original is the larger file, so writing it back needs the
        // difference free - asked first, never found out halfway.
        val keptBytes = keptSize(context, backup)
        val free = info.path?.let { File(it).parentFile?.usableSpace } ?: Long.MAX_VALUE
        if (keptBytes > 0 && free < keptBytes - info.size + SPACE_MARGIN) return PutBack.NO_SPACE
        val journal = Journal(
            PUT_BACK, WRITING, rowId, uri.toString(), keptSha, keptBytes, currentSha, info.size,
            backup = backup, startedAt = System.currentTimeMillis()
        )
        if (!writeJournal(context, journal)) return PutBack.FAILED
        // Written again once if the first read-back disagrees; the kept
        // original is removed only after the item reads back as it.
        val ok = (1..2).any { restoreFrom(context, backup, uri) && sha(context, uri) == keptSha }
        if (!ok) {
            // Still on record: the next run writes it again.
            return PutBack.FAILED
        }
        rescan(context, uri, info.path)
        deleteBackup(context, backup)
        clearJournal(context)
        return PutBack.DONE
    }

    /** What [putBack] came to. */
    enum class PutBack {
        /** The item holds the original again, and the kept one is gone. */
        DONE,

        /** The original is no longer kept: the trash was emptied, 30 days passed, or it was taken out. */
        NOT_KEPT,

        /** Too little free space for the larger original. Nothing was written. */
        NO_SPACE,

        /** The file is no longer the one replaced - edited since, or another file. Nothing was written. */
        CHANGED,

        /** It could not be written back now; the original is still kept. */
        FAILED
    }

    /** Where an original kept after a replace stands now (see [backupState]). */
    enum class Kept {
        /** Still Ente Saver's: in the trash, or the hidden file of Android 9 and 10. */
        KEPT,

        /** No longer there: the trash was emptied, or 30 days passed. */
        GONE,

        /** Taken back out of the trash - a photo of the person's own now, never touched again. */
        LEFT_TRASH,

        /** Android could not say: an unmounted card, a busy media store. Nothing is decided on it. */
        UNKNOWN
    }

    /**
     * Where the original kept at [backup] stands. Only an answer Android
     * actually gave is GONE: a failed or unmounted read is UNKNOWN, so an
     * original is never forgotten while it may still be there.
     */
    fun backupState(context: Context, backup: String): Kept {
        if (backup.isEmpty()) return Kept.GONE
        if (backup.startsWith("file:")) {
            val file = File(Uri.parse(backup).path.orEmpty())
            if (file.exists()) return Kept.KEPT
            val mounted = runCatching { Environment.getExternalStorageState(file) == Environment.MEDIA_MOUNTED }
                .getOrDefault(false)
            // Judged by its album: the hidden folder it waits in goes once it is empty.
            return if (mounted && albumOf(file)?.exists() == true) Kept.GONE else Kept.UNKNOWN
        }
        // Kept in the trash only from Android 11, which has one.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return Kept.UNKNOWN
        return runCatching {
            context.contentResolver.query(
                Uri.parse(backup),
                arrayOf(MediaStore.MediaColumns.IS_TRASHED, MediaStore.MediaColumns.IS_PENDING),
                includeAll(),
                null
            )?.use { c ->
                when {
                    !c.moveToFirst() -> Kept.GONE
                    c.getInt(1) == 1 -> Kept.UNKNOWN
                    c.getInt(0) == 1 -> Kept.KEPT
                    else -> Kept.LEFT_TRASH
                }
            } ?: Kept.UNKNOWN
        }.getOrDefault(Kept.UNKNOWN)
    }

    /**
     * Removes the original kept at [backup] for good - only while it is
     * still Ente Saver's: in the trash, or still being made. One the person
     * took back out of the trash is theirs, and is left alone.
     */
    fun deleteBackup(context: Context, backup: String): Boolean = runCatching {
        if (backup.isEmpty()) return@runCatching false
        if (backup.startsWith("file:")) return@runCatching removeHidden(File(Uri.parse(backup).path.orEmpty()))
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return@runCatching false
        val item = Uri.parse(backup)
        val ours = context.contentResolver.query(
            item,
            arrayOf(MediaStore.MediaColumns.IS_TRASHED, MediaStore.MediaColumns.IS_PENDING),
            includeAll(),
            null
        )?.use { c -> c.moveToFirst() && (c.getInt(0) == 1 || c.getInt(1) == 1) } ?: false
        ours && context.contentResolver.delete(item, includeAll()) > 0
    }.getOrDefault(false)

    /** The hidden originals of Android 9 and 10 older than [KEEP_DAYS], removed as the trash would. */
    fun purgeExpired(paths: List<String>, now: Long): Int = paths.count { path ->
        val f = File(path)
        f.name.startsWith(HIDDEN_PREFIX) && now - f.lastModified() > KEEP_DAYS * 24L * 3_600_000L && removeHidden(f)
    }

    /** Deletes a hidden original, and the hidden folder it was in once that is empty. */
    private fun removeHidden(file: File): Boolean {
        val removed = file.delete()
        if (file.parentFile?.name == LegacyMedia.WORK_DIR) albumOf(file)?.let(LegacyMedia::tidyWorkFolder)
        return removed
    }

    /**
     * The album a hidden original belongs to: the folder of its hidden
     * folder, or, for one an earlier version kept beside the photo, its own.
     */
    private fun albumOf(file: File): File? =
        file.parentFile?.let { if (it.name == LegacyMedia.WORK_DIR) it.parentFile else it }

    // ---- the steps -----------------------------------------------------------

    private class Info(
        val name: String,
        val relativePath: String?,
        val mime: String?,
        val size: Long,
        val dateTaken: Long,
        val path: String?
    )

    @Suppress("DEPRECATION")
    private fun infoOf(context: Context, uri: Uri): Info? = runCatching {
        context.contentResolver.query(
            uri,
            arrayOf(
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaPaths.FOLDER_COLUMN,
                MediaStore.MediaColumns.MIME_TYPE,
                MediaStore.MediaColumns.SIZE,
                MediaStore.MediaColumns.DATE_TAKEN,
                MediaStore.MediaColumns.DATA
            ),
            null, null, null
        )?.use { c ->
            if (!c.moveToFirst()) return@use null
            Info(
                name = c.getString(0) ?: return@use null,
                relativePath = MediaPaths.relativePath(c.getString(1)),
                mime = c.getString(2),
                size = c.getLong(3),
                dateTaken = c.getLong(4),
                path = c.getString(5)
            )
        }
    }.getOrNull()

    /** True only when Android answered that the item is no longer there. */
    private fun itemGone(context: Context, uri: Uri): Boolean = runCatching {
        context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)
            ?.use { !it.moveToFirst() } ?: false
    }.getOrDefault(false)

    /**
     * The item's bytes as they are on disk, where it was taken included.
     * Read without asking for the original, another app's photo comes back
     * with its location blanked out; hashed, kept or put back from that, the
     * original would lose it. Without media-location access this throws, and
     * nothing is replaced (the run waits for that access). Android 9 blanks
     * nothing, so there the item is read as it is.
     */
    private fun openOriginal(context: Context, uri: Uri): InputStream? =
        context.contentResolver.openInputStream(MediaPaths.original(uri))

    private fun sha(context: Context, uri: Uri): String? = runCatching {
        openOriginal(context, uri)?.use { Fingerprint.sha256(it) }
    }.getOrNull()

    /** When the file at [uri] last changed, by its file; null when that cannot be read. */
    private fun modifiedAt(context: Context, uri: Uri): Long? =
        infoOf(context, uri)?.path?.let { path -> File(path).lastModified().takeIf { it > 0 } }

    private fun editedSince(context: Context, uri: Uri, j: Journal): Boolean {
        val modified = modifiedAt(context, uri) ?: return false
        return modified > j.startedAt + EDIT_MARGIN_MS
    }

    /**
     * The original copied somewhere it survives the overwrite, and read back:
     * a trashed item of Ente Saver's own (Android 11 and later), else a
     * hidden file beside it. [onMade] puts the backup on record the moment
     * it exists, before a byte is in it; false there abandons it. Null when
     * no copy could be made and proved.
     */
    private fun keepOriginal(
        context: Context,
        uri: Uri,
        info: Info,
        isVideo: Boolean,
        originalSha: String,
        rowId: Long,
        onMade: (String) -> Boolean
    ): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // In its own album where Android allows it, so the trash puts it
            // back beside its replacement; DCIM, which takes both, otherwise.
            val places = listOfNotNull(info.relativePath, Environment.DIRECTORY_DCIM + "/").distinct()
            for (place in places) {
                trashedCopy(context, uri, info, isVideo, place, originalSha, onMade)?.let { return it }
            }
            return null
        }
        val path = info.path ?: return null
        val folder = File(path).parentFile ?: return null
        // In the album's hidden folder, which no scan of the gallery lists,
        // under a name no other file has - this row's, at this moment - made
        // new, never opened over a file already there: an original still
        // kept for another replace is never written over.
        val work = LegacyMedia.workFolder(folder) ?: return null
        val hidden = File(work, "$HIDDEN_PREFIX$rowId-${System.currentTimeMillis()}-${info.name}")
        val made = Uri.fromFile(hidden).toString()
        if (!onMade(made)) {
            LegacyMedia.tidyWorkFolder(folder)
            return null
        }
        return runCatching {
            if (!hidden.createNewFile()) return@runCatching null
            openOriginal(context, uri)!!.use { input ->
                FileOutputStream(hidden).use { output ->
                    input.copyTo(output, 64 * 1024)
                    output.fd.sync()
                }
            }
            val ok = FileInputStream(hidden).use { Fingerprint.sha256(it) } == originalSha
            if (ok) made else null.also { removeHidden(hidden) }
        }.getOrElse {
            removeHidden(hidden)
            null
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun trashedCopy(
        context: Context,
        uri: Uri,
        info: Info,
        isVideo: Boolean,
        place: String,
        originalSha: String,
        onMade: (String) -> Boolean
    ): String? {
        val resolver = context.contentResolver
        val volume = runCatching { MediaStore.getVolumeName(uri) }.getOrDefault(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val collection = if (isVideo) MediaStore.Video.Media.getContentUri(volume) else MediaStore.Images.Media.getContentUri(volume)
        val stem = info.name.substringBeforeLast('.', info.name)
        val ext = info.name.substringAfterLast('.', "")
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, if (ext.isEmpty()) "$stem.original" else "$stem.original.$ext")
            put(MediaStore.MediaColumns.RELATIVE_PATH, place)
            info.mime?.let { put(MediaStore.MediaColumns.MIME_TYPE, it) }
            if (info.dateTaken > 0) put(MediaStore.MediaColumns.DATE_TAKEN, info.dateTaken)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val made = runCatching { resolver.insert(collection, values) }.getOrNull() ?: return null
        val ok = onMade(made.toString()) && runCatching {
            openOriginal(context, uri)!!.use { input ->
                resolver.openOutputStream(made, "w")!!.use { output -> input.copyTo(output, 64 * 1024) }
            }
            // Read back while it is still pending - and so still openable by
            // its owner - before anything depends on it.
            resolver.openInputStream(made)!!.use { Fingerprint.sha256(it) } == originalSha &&
                moveToTrash(context, made)
        }.getOrDefault(false)
        if (!ok) {
            runCatching { resolver.delete(made, includeAll()) }
            return null
        }
        return made.toString()
    }

    /** Query arguments that include trashed items, which a plain query leaves out. */
    private fun includeTrashed(): Bundle? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Bundle().apply { putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE) }
    } else {
        null
    }

    /** Pending and trashed items both, so an item can be followed through every state. */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun includeAll(): Bundle = Bundle().apply {
        putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_INCLUDE)
        putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
    }

    /**
     * A pending copy moved into the trash: out of pending and into the trash
     * in one update, so it never shows in a gallery - Ente's included - even
     * for a moment. Only ever one update: Android works both states out from
     * the file's name, so the trash flag set while the copy is still pending
     * is dropped, and publishing it after would leave a visible duplicate.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun moveToTrash(context: Context, item: Uri): Boolean {
        runCatching {
            context.contentResolver.update(
                item,
                ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                    put(MediaStore.MediaColumns.IS_TRASHED, 1)
                },
                includeAll()
            )
        }
        return backupState(context, item.toString()) == Kept.KEPT
    }

    /** [source]'s bytes into the item at [uri], the old ones dropped. */
    private fun writeInto(context: Context, uri: Uri, source: File): Boolean {
        context.contentResolver.openFileDescriptor(uri, "rwt")!!.use { pfd ->
            FileOutputStream(pfd.fileDescriptor).use { out ->
                FileInputStream(source).use { it.copyTo(out, 64 * 1024) }
                out.flush()
                // Some providers ignore the truncate in "rwt": cut it here.
                out.channel.truncate(source.length())
                out.fd.sync()
            }
        }
        return true
    }

    private fun keptSize(context: Context, backup: String): Long = if (backup.startsWith("file:")) {
        File(Uri.parse(backup).path.orEmpty()).length()
    } else {
        runCatching {
            context.contentResolver.query(Uri.parse(backup), arrayOf(MediaStore.MediaColumns.SIZE), includeTrashed(), null)
                ?.use { c -> if (c.moveToFirst()) c.getLong(0) else 0L } ?: 0L
        }.getOrDefault(0L)
    }

    /**
     * The bytes of the original kept at [backup]. Ente Saver's own item, so
     * nothing of it is held back; read through MediaStore where Android
     * allows it, and from its file - which All files access may read -
     * where it does not.
     */
    @Suppress("DEPRECATION")
    private fun openBackup(context: Context, backup: String): InputStream {
        if (backup.startsWith("file:")) return FileInputStream(File(Uri.parse(backup).path!!))
        val item = Uri.parse(backup)
        runCatching { context.contentResolver.openInputStream(item) }.getOrNull()?.let { return it }
        val path = context.contentResolver.query(item, arrayOf(MediaStore.MediaColumns.DATA), includeTrashed(), null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
            ?: error("kept original not found")
        return FileInputStream(File(path))
    }

    /** The original kept at [backup] written back into [uri]. */
    private fun restoreFrom(context: Context, backup: String, uri: Uri): Boolean = runCatching {
        openBackup(context, backup).use { from ->
            context.contentResolver.openFileDescriptor(uri, "rwt")!!.use { pfd ->
                FileOutputStream(pfd.fileDescriptor).use { out ->
                    val n = from.copyTo(out, 64 * 1024)
                    out.flush()
                    out.channel.truncate(n)
                    out.fd.sync()
                }
            }
        }
        true
    }.getOrDefault(false)

    /**
     * Android re-reads the file, so its size, dimensions and dates are the
     * new file's. The date it was taken comes from the file's own metadata,
     * which every copy carries over; Android takes no other word for it.
     *
     * Android 9's scanner does: unless that metadata carries a GPS time, it
     * may take the file's modified time instead, which writing has just made
     * now - the photo would move to today in every gallery, Ente's too. There
     * the item's own dates are read before the scan, while it still holds
     * them, and put back: the modified time on the file, before the scanner
     * reads it, and the date it was taken on the item, after.
     */
    private fun rescan(context: Context, uri: Uri, path: String?) {
        if (path == null) return
        val dates = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) datesOf(context, uri) else null
        dates?.let { (_, modifiedSec) -> if (modifiedSec > 0) File(path).setLastModified(modifiedSec * 1000) }
        val done = java.util.concurrent.CountDownLatch(1)
        runCatching {
            android.media.MediaScannerConnection.scanFile(context, arrayOf(path), null) { _, _ -> done.countDown() }
            done.await(10, java.util.concurrent.TimeUnit.SECONDS)
        }
        dates?.let { (taken, _) ->
            if (taken > 0) {
                runCatching {
                    context.contentResolver.update(
                        uri, ContentValues().apply { put(MediaStore.MediaColumns.DATE_TAKEN, taken) }, null, null
                    )
                }
            }
        }
    }

    /** The date [uri] was taken (milliseconds) and last modified (seconds), as the item holds them now. */
    private fun datesOf(context: Context, uri: Uri): Pair<Long, Long>? = runCatching {
        context.contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DATE_TAKEN, MediaStore.MediaColumns.DATE_MODIFIED),
            null, null, null
        )?.use { c -> if (c.moveToFirst()) c.getLong(0) to c.getLong(1) else null }
    }.getOrNull()

    // ---- the journal ---------------------------------------------------------

    private data class Journal(
        /** [REPLACE] or [PUT_BACK]. */
        val kind: String,
        /** A replace is [KEEPING] while its original is copied, [WRITING] once it is kept; a put back is [WRITING]. */
        val stage: String,
        val rowId: Long,
        val uri: String,
        /** What the item is to hold if the step is undone - or, for a put back, finished. */
        val originalSha: String,
        val originalBytes: Long,
        /** What the item holds once a replace is done - or, for a put back, before it began. */
        val copySha: String,
        val copyBytes: Long,
        /** Where the original is kept; empty until it exists. */
        val backup: String,
        /** When the step began writing. */
        val startedAt: Long,
        /** Recovery runs that could not finish it ([recover]). */
        val tries: Int = 0
    )

    private fun journalFile(context: Context) = File(context.noBackupFilesDir, JOURNAL)

    /**
     * Written whole or not at all, and still there after a power cut: a temp
     * file synced and renamed into place, then the folder synced, so the
     * rename itself is on disk.
     */
    private fun writeJournal(context: Context, j: Journal): Boolean = runCatching {
        val json = JSONObject()
            .put("kind", j.kind).put("stage", j.stage)
            .put("rowId", j.rowId).put("uri", j.uri)
            .put("originalSha", j.originalSha).put("originalBytes", j.originalBytes)
            .put("copySha", j.copySha).put("copyBytes", j.copyBytes)
            .put("backup", j.backup).put("startedAt", j.startedAt).put("tries", j.tries)
        val dir = context.noBackupFilesDir
        val tmp = File(dir, "$JOURNAL.tmp")
        FileOutputStream(tmp).use {
            it.write(json.toString().toByteArray(Charsets.UTF_8))
            it.fd.sync()
        }
        val moved = tmp.renameTo(journalFile(context))
        if (moved) syncFolder(dir)
        moved
    }.getOrDefault(false)

    private fun syncFolder(dir: File) {
        runCatching {
            val fd = Os.open(dir.path, OsConstants.O_RDONLY, 0)
            try {
                Os.fsync(fd)
            } finally {
                Os.close(fd)
            }
        }
    }

    private fun parseJournal(text: String, writtenAt: Long): Journal? = runCatching {
        val o = JSONObject(text)
        Journal(
            kind = o.optString("kind", REPLACE),
            // A journal from before the stages were recorded was written
            // only once the original was kept.
            stage = o.optString("stage", WRITING),
            rowId = o.getLong("rowId"),
            uri = o.getString("uri"),
            originalSha = o.getString("originalSha"),
            originalBytes = o.getLong("originalBytes"),
            copySha = o.getString("copySha"),
            copyBytes = o.getLong("copyBytes"),
            backup = o.getString("backup"),
            startedAt = o.optLong("startedAt", writtenAt),
            tries = o.optInt("tries", 0)
        )
    }.getOrNull()

    private fun clearJournal(context: Context) {
        journalFile(context).delete()
        syncFolder(context.noBackupFilesDir)
    }
}
