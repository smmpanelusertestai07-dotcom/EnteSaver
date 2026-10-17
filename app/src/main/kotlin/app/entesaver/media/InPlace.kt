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
import androidx.annotation.RequiresApi
import app.entesaver.core.logic.Fingerprint
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
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
 * Every step is proved before the next. The original is copied into the
 * trash and read back; only then is it overwritten, and the overwrite is
 * read back too. A journal written before the overwrite lets the next run
 * finish or undo a replace the phone cut short, and the original stays in
 * the trash the whole time. Android 10 has no trash, so there the original
 * waits as a hidden file beside it, removed after the same 30 days.
 */
object InPlace {

    /** How long a replaced original is kept, as Android keeps its trash. */
    const val KEEP_DAYS = 30

    /** The hidden name an original waits under on Android 10. */
    private const val HIDDEN_PREFIX = ".entesaver-original-"

    private const val JOURNAL = "in-place.json"

    /** Room left over when an original goes back, so the phone is never filled to the byte. */
    private const val SPACE_MARGIN = 16L * 1024 * 1024

    /**
     * Whether this phone lets Ente Saver write into photos other apps made
     * without asking each time: All files access from Android 11, storage
     * write access before it.
     */
    fun canReplace(context: Context): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Environment.isExternalStorageManager()
    } else {
        @Suppress("DEPRECATION")
        Environment.isExternalStorageLegacy() &&
            context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    /** What one replace came to. */
    sealed interface Result {
        /** The item now holds the copy; the original is kept at [backup]. */
        data class Replaced(val backup: String, val bytes: Long, val sha256: String) : Result

        /** Nothing changed on the phone; [reason] says why. */
        data class Failed(val reason: String) : Result
    }

    /**
     * Writes [copy] into the item at [uri], which must still be the
     * [expectedBytes] the copy was made from. [rowId] goes into the journal.
     */
    fun replace(context: Context, uri: Uri, isVideo: Boolean, expectedBytes: Long, copy: File, rowId: Long): Result {
        val info = infoOf(context, uri) ?: return Result.Failed("original_unreadable")
        if (info.size != expectedBytes) return Result.Failed("original_changed")
        val originalSha = sha(context, uri) ?: return Result.Failed("original_unreadable")
        val copySha = runCatching { FileInputStream(copy).use { Fingerprint.sha256(it) } }.getOrNull()
            ?: return Result.Failed("copy_unreadable")
        val copyBytes = copy.length()
        if (copyBytes <= 0 || copyBytes >= info.size) return Result.Failed("not_smaller")

        val backup = keepOriginal(context, uri, info, isVideo, originalSha) ?: return Result.Failed("backup_failed")
        val journal = Journal(rowId, uri.toString(), originalSha, info.size, copySha, copyBytes, backup)
        if (!writeJournal(context, journal)) {
            deleteBackup(context, backup)
            return Result.Failed("journal_failed")
        }
        val written = runCatching { writeInto(context, uri, copy) }.getOrDefault(false)
        val nowSha = if (written) sha(context, uri) else null
        if (nowSha != copySha) {
            // Half written, or written wrong: the original goes back in.
            val restored = restoreFrom(context, backup, uri) && sha(context, uri) == originalSha
            if (restored) {
                deleteBackup(context, backup)
                clearJournal(context)
                return Result.Failed("write_failed")
            }
            // Left for the next run's recovery, original safe in the trash.
            return Result.Failed("write_failed_kept")
        }
        rescan(context, info.path)
        keepDateTaken(context, uri, info.dateTaken)
        return Result.Replaced(backup, copyBytes, copySha)
    }

    /** The journal of a replace whose row has now been written: nothing is left to recover. */
    fun settled(context: Context) = clearJournal(context)

    /** What [recover] found from a replace the phone cut short. */
    sealed interface Recovered {
        /** The copy is in place: row [rowId] is to be finished as replaced. */
        data class Finished(val rowId: Long, val backup: String, val bytes: Long, val sha256: String) : Recovered

        /** The original is in place, as before: row [rowId] waits for a new try. */
        data class Undone(val rowId: Long) : Recovered

        /** The original could not be put back; it is still in the trash at [backup]. */
        data class Stuck(val rowId: Long, val backup: String) : Recovered
    }

    /** Finishes or undoes the one replace a journal may describe; null when there is none. */
    fun recover(context: Context): Recovered? {
        val j = readJournal(context) ?: return null
        val uri = Uri.parse(j.uri)
        val now = sha(context, uri)
        val outcome = when (now) {
            j.copySha -> Recovered.Finished(j.rowId, j.backup, j.copyBytes, j.copySha)
            j.originalSha -> {
                deleteBackup(context, j.backup)
                Recovered.Undone(j.rowId)
            }
            else -> if (restoreFrom(context, j.backup, uri) && sha(context, uri) == j.originalSha) {
                deleteBackup(context, j.backup)
                Recovered.Undone(j.rowId)
            } else {
                Recovered.Stuck(j.rowId, j.backup)
            }
        }
        // A finished replace keeps its journal until its row is written.
        if (outcome !is Recovered.Finished) clearJournal(context)
        return outcome
    }

    /**
     * Puts the original kept at [backup] back into [uri], the item it was
     * replaced in - the same id, name and date, so Ente takes the original
     * back the way it took the copy - and removes the kept one.
     */
    fun putBack(context: Context, backup: String, uri: Uri): PutBack {
        val keptSha = runCatching { openBackup(context, backup).use { Fingerprint.sha256(it) } }.getOrNull()
            ?: return PutBack.NOT_KEPT
        val info = infoOf(context, uri) ?: return PutBack.FAILED
        // The original is the larger file, so writing it back needs the
        // difference free - asked first, never found out halfway.
        val keptBytes = keptSize(context, backup)
        val free = info.path?.let { File(it).parentFile?.usableSpace } ?: Long.MAX_VALUE
        if (keptBytes > 0 && free < keptBytes - info.size + SPACE_MARGIN) return PutBack.NO_SPACE
        // Written again once if the first read-back disagrees; the kept
        // original is removed only after the item reads back as it.
        val ok = (1..2).any { restoreFrom(context, backup, uri) && sha(context, uri) == keptSha }
        if (!ok) return PutBack.FAILED
        rescan(context, info.path)
        keepDateTaken(context, uri, info.dateTaken)
        deleteBackup(context, backup)
        return PutBack.DONE
    }

    /** What [putBack] came to. */
    enum class PutBack {
        /** The item holds the original again, and the kept one is gone. */
        DONE,

        /** The original is no longer kept: the trash was emptied, or 30 days passed. */
        NOT_KEPT,

        /** Too little free space for the larger original. Nothing was written. */
        NO_SPACE,

        /** It could not be written back; the original is still kept. */
        FAILED
    }

    private fun keptSize(context: Context, backup: String): Long = if (backup.startsWith("file:")) {
        File(Uri.parse(backup).path.orEmpty()).length()
    } else {
        runCatching {
            context.contentResolver.query(Uri.parse(backup), arrayOf(MediaStore.MediaColumns.SIZE), includeTrashed(), null)
                ?.use { c -> if (c.moveToFirst()) c.getLong(0) else 0L } ?: 0L
        }.getOrDefault(0L)
    }

    /** Whether the original kept at [backup] is still there. */
    fun backupExists(context: Context, backup: String): Boolean = if (backup.startsWith("file:")) {
        File(Uri.parse(backup).path.orEmpty()).exists()
    } else {
        runCatching {
            context.contentResolver.query(Uri.parse(backup), arrayOf(MediaStore.MediaColumns._ID), includeTrashed(), null)
                ?.use { it.moveToFirst() } ?: false
        }.getOrDefault(false)
    }

    /** Removes the original kept at [backup] for good. */
    fun deleteBackup(context: Context, backup: String): Boolean = runCatching {
        if (backup.startsWith("file:")) {
            File(Uri.parse(backup).path.orEmpty()).delete()
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.contentResolver.delete(Uri.parse(backup), includeTrashed()) > 0
        } else {
            context.contentResolver.delete(Uri.parse(backup), null, null) > 0
        }
    }.getOrDefault(false)

    /** Android 10's hidden originals older than [KEEP_DAYS], removed as the trash would. */
    fun purgeExpired(paths: List<String>, now: Long): Int = paths.count { path ->
        val f = File(path)
        f.name.startsWith(HIDDEN_PREFIX) && now - f.lastModified() > KEEP_DAYS * 24L * 3_600_000L && f.delete()
    }

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
                MediaStore.MediaColumns.RELATIVE_PATH,
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
                relativePath = c.getString(1),
                mime = c.getString(2),
                size = c.getLong(3),
                dateTaken = c.getLong(4),
                path = c.getString(5)
            )
        }
    }.getOrNull()

    private fun sha(context: Context, uri: Uri): String? = runCatching {
        context.contentResolver.openInputStream(uri)?.use { Fingerprint.sha256(it) }
    }.getOrNull()

    /**
     * The original copied somewhere it survives the overwrite, and read back:
     * a trashed item of Ente Saver's own (Android 11 and later), else a
     * hidden file beside it. Null when no copy could be made and proved.
     */
    private fun keepOriginal(context: Context, uri: Uri, info: Info, isVideo: Boolean, originalSha: String): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // In its own album where Android allows it, so the trash puts it
            // back beside its replacement; DCIM, which takes both, otherwise.
            val places = listOfNotNull(info.relativePath, Environment.DIRECTORY_DCIM + "/").distinct()
            for (place in places) {
                trashedCopy(context, uri, info, isVideo, place, originalSha)?.let { return it }
            }
            return null
        }
        val path = info.path ?: return null
        val source = File(path)
        val hidden = File(source.parentFile ?: return null, HIDDEN_PREFIX + info.name)
        return runCatching {
            context.contentResolver.openInputStream(uri)!!.use { input ->
                FileOutputStream(hidden).use { output ->
                    input.copyTo(output, 64 * 1024)
                    output.fd.sync()
                }
            }
            val ok = FileInputStream(hidden).use { Fingerprint.sha256(it) } == originalSha
            if (ok) Uri.fromFile(hidden).toString() else null.also { hidden.delete() }
        }.getOrElse {
            hidden.delete()
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
        originalSha: String
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
        val ok = runCatching {
            resolver.openInputStream(uri)!!.use { input ->
                resolver.openOutputStream(made, "w")!!.use { output -> input.copyTo(output, 64 * 1024) }
            }
            // Read back while it is still pending - and so still openable by
            // its owner - before anything depends on it.
            resolver.openInputStream(made)!!.use { Fingerprint.sha256(it) } == originalSha &&
                run {
                    // Trashed while still pending, so it never shows in a
                    // gallery - Ente's included - even for a moment.
                    resolver.update(made, ContentValues().apply { put(MediaStore.MediaColumns.IS_TRASHED, 1) }, null, null)
                    resolver.update(made, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, includeTrashed())
                    isTrashed(context, made)
                }
        }.getOrDefault(false)
        if (!ok) {
            runCatching { resolver.delete(made, includeTrashed()) }
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

    private fun isTrashed(context: Context, item: Uri): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && runCatching {
        context.contentResolver.query(item, arrayOf(MediaStore.MediaColumns.IS_TRASHED), includeTrashed(), null)
            ?.use { c -> c.moveToFirst() && c.getInt(0) == 1 } ?: false
    }.getOrDefault(false)

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

    /**
     * The bytes of the original kept at [backup]. A trashed item is read
     * through MediaStore where Android allows it, and from its file - which
     * All files access may read - where it does not.
     */
    @Suppress("DEPRECATION")
    private fun openBackup(context: Context, backup: String): java.io.InputStream {
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

    /** Android re-reads the file, so its size, dimensions and date are the new file's. */
    private fun rescan(context: Context, path: String?) {
        if (path == null) return
        val done = java.util.concurrent.CountDownLatch(1)
        runCatching {
            android.media.MediaScannerConnection.scanFile(context, arrayOf(path), null) { _, _ -> done.countDown() }
            done.await(10, java.util.concurrent.TimeUnit.SECONDS)
        }
    }

    /**
     * The date the photo was taken stays the date it was taken. A copy
     * carries it in its own metadata, which Android reads back; where the
     * new file says otherwise, the old date is written back.
     */
    private fun keepDateTaken(context: Context, uri: Uri, dateTaken: Long) {
        if (dateTaken <= 0) return
        val now = runCatching {
            context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATE_TAKEN), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
        }.getOrNull()
        if (now != null && now != dateTaken) {
            runCatching {
                context.contentResolver.update(
                    uri, ContentValues().apply { put(MediaStore.MediaColumns.DATE_TAKEN, dateTaken) }, null, null
                )
            }
        }
    }

    // ---- the journal ---------------------------------------------------------

    private data class Journal(
        val rowId: Long,
        val uri: String,
        val originalSha: String,
        val originalBytes: Long,
        val copySha: String,
        val copyBytes: Long,
        val backup: String
    )

    private fun journalFile(context: Context) = File(context.noBackupFilesDir, JOURNAL)

    /** Written whole or not at all: a temp file renamed into place. */
    private fun writeJournal(context: Context, j: Journal): Boolean = runCatching {
        val json = JSONObject()
            .put("rowId", j.rowId).put("uri", j.uri)
            .put("originalSha", j.originalSha).put("originalBytes", j.originalBytes)
            .put("copySha", j.copySha).put("copyBytes", j.copyBytes)
            .put("backup", j.backup)
        val tmp = File(context.noBackupFilesDir, "$JOURNAL.tmp")
        FileOutputStream(tmp).use {
            it.write(json.toString().toByteArray(Charsets.UTF_8))
            it.fd.sync()
        }
        tmp.renameTo(journalFile(context))
    }.getOrDefault(false)

    private fun readJournal(context: Context): Journal? = runCatching {
        val f = journalFile(context)
        if (!f.exists()) return null
        val o = JSONObject(f.readText(Charsets.UTF_8))
        Journal(
            o.getLong("rowId"), o.getString("uri"), o.getString("originalSha"), o.getLong("originalBytes"),
            o.getString("copySha"), o.getLong("copyBytes"), o.getString("backup")
        )
    }.getOrNull()

    private fun clearJournal(context: Context) {
        journalFile(context).delete()
    }
}
