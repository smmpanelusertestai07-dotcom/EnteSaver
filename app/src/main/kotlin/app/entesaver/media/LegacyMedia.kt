package app.entesaver.media

import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * A new file in a shared folder on Android 9, which has neither pending
 * items nor RELATIVE_PATH: the gallery learns of a file there only once it
 * is written, by the media scanner.
 *
 * The promises the pending flow makes from Android 10 are kept the old way.
 * The bytes go into a hidden folder inside the folder first ([workFolder]),
 * so no gallery and no cloud app ever sees half a photo, and are synced to
 * disk. Only then is the file renamed to its own name, and to a name nothing
 * in the folder has yet: the " (1)" MediaProvider adds on Android 10 is
 * added here, so a file already there, whoever made it, is never written
 * over. Then the scanner is asked for its entry, and waited for, and the
 * entry must be a photo or a video. A step that fails takes everything this
 * made with it, so a failure leaves the folder as it found it.
 */
object LegacyMedia {

    /** How long a scan may take before the file is taken back as not added. */
    private const val SCAN_TIMEOUT_MS = 30_000L

    /** MediaProvider's own limit on " (n)" before it gives up on a name. */
    private const val MAX_RENAMES = 32

    /** How long a hidden file may wait before it counts as abandoned ([sweepAbandoned]). */
    private const val ABANDONED_MS = 24L * 60 * 60_000L

    /** The hidden name a file is written under, with the time it was begun. */
    private val PENDING_NAME = Regex("""\.pending-(\d+)-.+""")

    /** The hidden folder a file is made in ([workFolder]). */
    const val WORK_DIR = ".entesaver"

    /** A file added to the gallery: its MediaStore [uri], the [file] itself, and the [name] it landed under. */
    data class Published(val uri: Uri, val file: File, val name: String)

    /** The folder [relativePath] ("Pictures/EnteSaver/") on the phone's own storage. */
    @Suppress("DEPRECATION")
    fun folder(relativePath: String): File =
        File(Environment.getExternalStorageDirectory(), relativePath.trim('/'))

    /**
     * The hidden folder inside [dir] a file is made in before it gets its
     * name, and an original kept after a replace waits in; null when it
     * cannot be made. A file whose own name starts with a dot is not enough:
     * when Android 9 reads the whole of storage again - each time the phone
     * starts - its scanner passes over hidden folders only, and lists a
     * hidden photo beside the others like any other photo.
     */
    fun workFolder(dir: File): File? = File(dir, WORK_DIR).takeIf { it.isDirectory || it.mkdirs() }

    /** Removes [dir]'s [workFolder] once nothing is left in it. */
    fun tidyWorkFolder(dir: File) {
        File(dir, WORK_DIR).delete()
    }

    /** True for a file on the phone's own storage, which Android 9 lets an app with storage access change. */
    @Suppress("DEPRECATION")
    fun onPhoneStorage(path: String): Boolean = runCatching {
        val root = Environment.getExternalStorageDirectory().canonicalPath
        File(path).canonicalPath.startsWith("$root/")
    }.getOrDefault(false)

    /**
     * Writes [name] into [relativePath] with [write] and adds it to the
     * gallery; null, with nothing left behind, when any step fails.
     *
     * [verify] reads the written file back before it gets its name, and false
     * there abandons it. [modifiedMs] is set as the file's own modified time
     * before the scanner reads it, so the date the gallery records is that
     * one - stamped afterwards, it would disagree with the entry and the next
     * scan would put it back.
     */
    fun publish(
        context: Context,
        relativePath: String,
        name: String,
        mime: String?,
        modifiedMs: Long? = null,
        verify: (File) -> Boolean = { true },
        write: (OutputStream) -> Unit
    ): Published? {
        val dir = folder(relativePath)
        if (!dir.isDirectory && !dir.mkdirs()) return null
        val now = System.currentTimeMillis()
        val work = workFolder(dir) ?: return null
        sweep(work, now)
        val hidden = File(work, ".pending-$now-$name")
        var landed: File? = null
        return try {
            if (!hidden.createNewFile()) return null
            FileOutputStream(hidden).use { out ->
                write(out)
                out.flush()
                out.fd.sync()
            }
            if (hidden.length() <= 0 || !verify(hidden)) error("the written file did not verify")
            if (modifiedMs != null && modifiedMs > 0) hidden.setLastModified(modifiedMs)
            val target = claimName(dir, name) ?: error("no free name for $name")
            landed = target
            if (!hidden.renameTo(target)) error("could not name the file")
            val uri = scan(context, target, mime) ?: error("the media scanner did not add the file")
            // A folder with .nomedia in it, or a file the scanner could not
            // read, is filed as a plain file: on the phone, but in no gallery
            // and never uploaded.
            if (isMedia(mime) && !isMediaEntry(uri)) error("the scanner did not list the file as a photo or video")
            Published(uri, target, target.name)
        } catch (e: Exception) {
            hidden.delete()
            landed?.let { withdraw(context, it) }
            null
        } finally {
            tidyWorkFolder(dir)
        }
    }

    /**
     * Takes [file] back: off the disk, then out of the gallery, should the
     * scanner have listed it after all - a scan that answers after
     * [SCAN_TIMEOUT_MS], or one that filed it as a plain file. Asked again
     * about a path whose file is gone, the scanner drops its entry, and it
     * answers in the order it was asked, so this comes after any scan still
     * on its way.
     */
    private fun withdraw(context: Context, file: File) {
        file.delete()
        runCatching { MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), null, null) }
    }

    private fun isMedia(mime: String?): Boolean =
        mime != null && (mime.startsWith("image/") || mime.startsWith("video/"))

    /** True for an entry in the gallery's photos or videos: content://media/external/images/media/12. */
    private fun isMediaEntry(uri: Uri): Boolean = uri.pathSegments.getOrNull(1) in setOf("images", "video")

    /**
     * Deletes [uri]'s file through MediaStore and says whether it went. On
     * Android 9 the media provider removes the entry of a file it is not
     * allowed to delete - one on a memory card - and counts it deleted all
     * the same, while the file stays where it was. There a delete counts only
     * once the file is gone, and the entry of a file still there is given
     * back by the scanner. Throws as the provider does.
     */
    fun delete(context: Context, uri: Uri): Boolean {
        val path = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) dataPath(context, uri) else null
        if (context.contentResolver.delete(uri, null, null) <= 0) return false
        if (path == null || !File(path).exists()) return true
        runCatching { MediaScannerConnection.scanFile(context, arrayOf(path), null, null) }
        return false
    }

    /** Where [uri]'s file is, by its entry; null when that cannot be read. */
    @Suppress("DEPRECATION")
    fun dataPath(context: Context, uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    }.getOrNull()

    /**
     * Hands [file] to the media scanner and waits for its entry: the
     * MediaStore uri, or null when the scanner did not add it in time.
     */
    fun scan(context: Context, file: File, mime: String?): Uri? {
        val done = CountDownLatch(1)
        val result = AtomicReference<Uri?>(null)
        return runCatching {
            MediaScannerConnection.scanFile(
                context, arrayOf(file.absolutePath), mime?.let { arrayOf(it) }
            ) { _, uri ->
                result.set(uri)
                done.countDown()
            }
            done.await(SCAN_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            result.get()
        }.getOrNull()
    }

    /**
     * Removes the hidden files writes the phone cut short left in
     * [relativePaths] - a process killed mid-copy never renames its file -
     * once a day has passed since each was begun, as Android 10 removes a
     * pending item nobody finished. Only names this object makes are
     * touched, and the time is read from the name, which nothing rewrites.
     */
    fun sweepAbandoned(relativePaths: Collection<String>, now: Long): Int {
        var removed = 0
        for (relativePath in relativePaths) {
            val dir = folder(relativePath)
            removed += sweep(dir, now) + sweep(File(dir, WORK_DIR), now)
            tidyWorkFolder(dir)
        }
        return removed
    }

    /** [sweepAbandoned] for the one folder [dir]. */
    internal fun sweep(dir: File, now: Long): Int {
        val files = runCatching { dir.listFiles() }.getOrNull() ?: return 0
        return files.count { file ->
            val begun = PENDING_NAME.matchEntire(file.name)?.groupValues?.get(1)?.toLongOrNull()
            begun != null && now - begun > ABANDONED_MS && file.isFile && file.delete()
        }
    }

    /**
     * Claims [name] in [dir], or the first free "name (n).ext" the way
     * MediaProvider names it, by creating it empty; null when every name up
     * to " (32)" is taken. Creating a file fails when its name is in use, so
     * the claim and the check are one step: a file another app writes there
     * a moment later is never the one the rename replaces, because the rename
     * replaces only this empty file.
     */
    fun claimName(dir: File, name: String): File? {
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        for (n in 0..MAX_RENAMES) {
            val candidate = File(dir, if (n == 0) name else "$stem ($n)$ext")
            if (candidate.createNewFile()) return candidate
        }
        return null
    }
}
