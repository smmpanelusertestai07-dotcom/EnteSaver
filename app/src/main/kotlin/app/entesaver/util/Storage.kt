package app.entesaver.util

import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.StatFs
import java.io.File

object Storage {

    /** Free bytes on the volume the app is configured to use ("" = internal). */
    fun freeBytes(context: Context, storageVolume: String = ""): Long = try {
        val vol = Volumes.selected(context, storageVolume)
        val base = vol?.appDir ?: context.getExternalFilesDir(null) ?: Environment.getDataDirectory()
        StatFs(base.absolutePath).availableBytes
    } catch (e: Exception) {
        Long.MAX_VALUE
    }

    /** Total size of the volume the app is configured to use. */
    fun totalBytes(context: Context, storageVolume: String = ""): Long = try {
        val vol = Volumes.selected(context, storageVolume)
        val base = vol?.appDir ?: context.getExternalFilesDir(null) ?: Environment.getDataDirectory()
        StatFs(base.absolutePath).totalBytes
    } catch (e: Exception) {
        0L
    }

    /** Stage dir on the selected volume; falls back to internal if missing. */
    fun stageDir(context: Context, storageVolume: String = ""): File {
        val vol = Volumes.selected(context, storageVolume)
        val base = vol?.appDir ?: context.getExternalFilesDir(null) ?: context.filesDir
        val dir = File(base, "stage")
        if (!dir.exists()) dir.mkdirs()
        // Android 9's media scanner indexes every folder on shared storage,
        // the app's own included, and a copy waiting here would show in the
        // gallery - and in Ente - as a photo in a folder called "stage".
        // A .nomedia file keeps it, and the work files under it, out.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            runCatching { File(dir, ".nomedia").takeIf { !it.exists() }?.createNewFile() }
        }
        return dir
    }

    fun tempDir(context: Context, storageVolume: String = ""): File {
        val dir = File(stageDir(context, storageVolume), "tmp")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    /** Stage size across ALL volumes (files staged before a volume switch count too). */
    fun totalStageBytes(context: Context): Long =
        Volumes.list(context).sumOf { vol ->
            vol.appDir?.let { dirSize(File(it, "stage")) } ?: 0L
        }

    fun dirSize(dir: File): Long {
        if (!dir.exists()) return 0
        var size = 0L
        val stack = ArrayDeque<File>()
        stack.add(dir)
        while (stack.isNotEmpty()) {
            val f = stack.removeLast()
            val children = f.listFiles() ?: continue
            for (c in children) {
                if (c.isDirectory) stack.add(c) else size += c.length()
            }
        }
        return size
    }

    /** Half-finished work files left by interrupted runs, across all volumes. */
    fun totalTempBytes(context: Context): Long =
        Volumes.list(context).sumOf { vol ->
            vol.appDir?.let { dirSize(File(File(it, "stage"), "tmp")) } ?: 0L
        }

    /**
     * How old a work file must be before it counts as abandoned.
     *
     * A run is capped well below this, so anything older than an hour was
     * left by a crash or a killed process - and anything younger may be the
     * file a compression is writing into at this very moment. Deleting that
     * one costs the user the item they asked for: the stager retries it, and
     * a light copy being remade for a free-up simply drops out of the batch.
     */
    private const val TEMP_ABANDONED_MS = 60L * 60 * 1000

    /**
     * Deletes leftover work files on every volume, skipping anything still
     * being written. Cheap: there is at most one temp file per run.
     */
    fun cleanTemp(
        context: Context,
        now: Long = System.currentTimeMillis()
    ): Long {
        var freed = 0L
        for (vol in Volumes.list(context)) {
            try {
                val tmp = File(File(vol.appDir ?: continue, "stage"), "tmp")
                tmp.listFiles()?.forEach { f ->
                    if (now - f.lastModified() < TEMP_ABANDONED_MS) return@forEach
                    freed += f.length()
                    f.delete()
                }
            } catch (e: Exception) {
                // ignore
            }
        }
        return freed
    }
}
