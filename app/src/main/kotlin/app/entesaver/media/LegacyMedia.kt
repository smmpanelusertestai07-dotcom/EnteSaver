package app.entesaver.media

import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Environment
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
 * The bytes go into a hidden file in the folder first - the scanner passes
 * over any name that starts with a dot, so no gallery and no cloud app ever
 * sees half a photo - and are synced to disk. Only then is the file renamed
 * to its own name, and to a name nothing in the folder has yet: the " (1)"
 * MediaProvider adds on Android 10 is added here, so a file already there,
 * whoever made it, is never written over. Then the scanner is asked for its
 * entry, and waited for. A step that fails takes everything this made with
 * it, so a failure leaves the folder as it found it.
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

    /** A file added to the gallery: its MediaStore [uri], the [file] itself, and the [name] it landed under. */
    data class Published(val uri: Uri, val file: File, val name: String)

    /** The folder [relativePath] ("Pictures/EnteSaver/") on the phone's own storage. */
    @Suppress("DEPRECATION")
    fun folder(relativePath: String): File =
        File(Environment.getExternalStorageDirectory(), relativePath.trim('/'))

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
        val hidden = File(dir, ".pending-${System.currentTimeMillis()}-$name")
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
            Published(uri, target, target.name)
        } catch (e: Exception) {
            hidden.delete()
            landed?.delete()
            null
        }
    }

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
            val files = runCatching { folder(relativePath).listFiles() }.getOrNull() ?: continue
            for (file in files) {
                val begun = PENDING_NAME.matchEntire(file.name)?.groupValues?.get(1)?.toLongOrNull() ?: continue
                if (now - begun > ABANDONED_MS && file.isFile && file.delete()) removed++
            }
        }
        return removed
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
