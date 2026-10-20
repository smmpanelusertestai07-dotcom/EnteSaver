package app.entesaver.util

import android.app.usage.StorageStatsManager
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.MediaStore
import app.entesaver.core.logic.Defaults
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Storage volumes (internal + SD card). The user can pick where the stage dir
 * and the Pictures/CloudSaver output live; scanning always covers all volumes.
 */
object Volumes {

    data class Vol(
        /** MediaStore volume name ("external_primary" or an SD UUID like "1234-abcd"; "external" on Android 9). */
        val mediaVolumeName: String,
        val isPrimary: Boolean,
        val totalBytes: Long,
        val freeBytes: Long,
        val appDir: File?,
        /**
         * The figures to show a person, which are the ones Android's own
         * Settings shows. For the phone's storage that is the size on the
         * box - 128 GB - where [totalBytes] is the data partition alone,
         * about 119 GB on the same phone, so "of 119 GB used" read as a
         * phone smaller than the one bought. Display only: every decision
         * about space still uses [freeBytes], the stricter of the two.
         */
        val shownTotalBytes: Long = totalBytes,
        val shownFreeBytes: Long = freeBytes
    )

    /**
     * MediaStore's catch-all external volume. The SDK names the constant
     * only from Android 10, but every version answers to it, and on Android
     * 9 it is the only external volume there is.
     */
    const val EXTERNAL = "external"

    /**
     * The phone's own storage, as MediaStore names it: "external_primary"
     * from Android 10. Android 9 has no name for one volume apart from the
     * rest, so there it is "external", which also holds an SD card's photos.
     */
    val PRIMARY: String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.VOLUME_EXTERNAL_PRIMARY else EXTERNAL

    /** Every external volume MediaStore keeps photos and videos on; just [EXTERNAL] on Android 9. */
    fun mediaVolumeNames(context: Context): Set<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.getExternalVolumeNames(context) else setOf(EXTERNAL)

    /** The volume [uri] is on; [EXTERNAL] on Android 9, which has only that one. */
    fun volumeOf(uri: Uri): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.getVolumeName(uri) else EXTERNAL

    fun list(context: Context): List<Vol> {
        val names = try {
            mediaVolumeNames(context)
        } catch (e: Exception) {
            setOf(PRIMARY)
        }
        val extraDirs = try {
            context.getExternalFilesDirs(null).filterNotNull()
        } catch (e: Exception) {
            emptyList()
        }
        val out = mutableListOf<Vol>()
        for (name in names) {
            val isPrimary = name == PRIMARY
            val dir = if (isPrimary) {
                context.getExternalFilesDir(null)
            } else {
                // SD volume names are the card UUID; the app dir path contains it.
                extraDirs.firstOrNull { it.absolutePath.contains(name, ignoreCase = true) }
            }
            val stats = try {
                dir?.let { StatFs(it.absolutePath) }
            } catch (e: Exception) {
                null
            }
            out += Vol(
                mediaVolumeName = name,
                isPrimary = isPrimary,
                totalBytes = stats?.totalBytes ?: 0L,
                freeBytes = stats?.availableBytes ?: 0L,
                appDir = dir
            )
        }
        // Primary first, deterministic order after that.
        return out.sortedWith(compareByDescending<Vol> { it.isPrimary }.thenBy { it.mediaVolumeName })
    }

    fun primary(context: Context): Vol? = list(context).firstOrNull { it.isPrimary }

    /**
     * [list] with the figures a person is shown filled in, for the screens.
     * Separate because asking the system for them is slower than StatFs, and
     * the engine, which reads volumes on every run, never shows a number.
     */
    fun listForDisplay(context: Context): List<Vol> = list(context).map { vol ->
        val shown = if (vol.isPrimary) deviceFigures(context) else null
        if (shown == null) vol else vol.copy(shownTotalBytes = shown.first, shownFreeBytes = shown.second)
    }

    /** The phone's storage as Settings reports it: rounded size, and free including clearable cache. */
    private fun deviceFigures(context: Context): Pair<Long, Long>? = runCatching {
        val stats = context.getSystemService(StorageStatsManager::class.java)
        stats.getTotalBytes(StorageManager.UUID_DEFAULT) to stats.getFreeBytes(StorageManager.UUID_DEFAULT)
    }.getOrNull()?.takeIf { (total, free) -> total > 0 && free in 0..total }

    fun byName(context: Context, name: String): Vol? =
        list(context).firstOrNull { it.mediaVolumeName == name }

    /**
     * The volume selected in Options; null when that volume is currently missing
     * (SD card removed) - callers must pause safely instead of guessing.
     */
    fun selected(context: Context, storageVolume: String): Vol? {
        if (storageVolume.isEmpty()) return primary(context)
        return byName(context, storageVolume)
    }

    // ---- writability probe (BB2) -------------------------------------------

    private data class Probe(val writable: Boolean, val atMs: Long, val osFingerprint: String)

    private val probes = ConcurrentHashMap<String, Probe>()

    /** Re-probe after this long, or immediately after an OS update. */
    private const val PROBE_TTL_MS = 6L * 60 * 60 * 1000

    /**
     * Whether apps can really add gallery files to this volume.
     *
     * The documentation says non-primary volumes accept inserts; many phones
     * disagree, and the only way to know is to try. The probe creates one
     * pending MediaStore entry at the app's own relative path, writes a byte,
     * finalises it and deletes it - the full life of a real release, in
     * miniature. Anything failing along the way is a "no", and a "no" means
     * the option is never offered, because offering it would let every real
     * release fail quietly instead (BB2.2).
     *
     * Cached per volume: probing costs a MediaStore round-trip, and the
     * answer only changes on a remount or an OS update, so the cache expires
     * on a timer and on a fingerprint change.
     */
    fun probeWritable(context: Context, mediaVolumeName: String): Boolean {
        if (mediaVolumeName == PRIMARY) return true
        val now = System.currentTimeMillis()
        val os = Build.FINGERPRINT
        probes[mediaVolumeName]?.let { cached ->
            if (now - cached.atMs < PROBE_TTL_MS && cached.osFingerprint == os) {
                return cached.writable
            }
        }
        val writable = runProbe(context, mediaVolumeName)
        probes[mediaVolumeName] = Probe(writable, now, os)
        return writable
    }

    /** Forget cached answers - used after a volume remounts. */
    fun invalidateProbes() {
        probes.clear()
    }

    private fun runProbe(context: Context, mediaVolumeName: String): Boolean {
        // Android 9 lists no volume but its one catch-all, which [probeWritable]
        // answers before this. A card named in a history file from another
        // phone is a volume Android 9 cannot write to by that name.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val resolver = context.contentResolver
        val collection = try {
            MediaStore.Images.Media.getContentUri(mediaVolumeName)
        } catch (e: Exception) {
            return false
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "probe_${System.nanoTime()}.jpg")
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Defaults.OUTPUT_DIR + "/")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        var uri: Uri? = null
        return try {
            uri = resolver.insert(collection, values) ?: return false
            resolver.openOutputStream(uri)?.use { it.write(0) } ?: return false
            resolver.update(
                uri,
                ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                },
                null, null
            )
            true
        } catch (e: Exception) {
            false
        } finally {
            uri?.let { runCatching { resolver.delete(it, null, null) } }
        }
    }
}
