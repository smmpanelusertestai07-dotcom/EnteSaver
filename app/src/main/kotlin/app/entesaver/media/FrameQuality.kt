package app.entesaver.media

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import app.entesaver.core.logic.Ssim
import java.io.File

/**
 * Pictures read back for [Ssim]: the measuring half of the video quality
 * probe (VideoCompressor) and of the photo quality search (PhotoCompressor).
 * Only brightness is kept, one byte a pixel, so a 1080p frame costs 2 MB
 * while it is compared instead of the 8 MB of its colour bitmap.
 */
internal object FrameQuality {

    /** One brightness plane and its size. */
    class Luma(val plane: ByteArray, val width: Int, val height: Int)

    /** The brightness of [bitmap], read a row at a time. */
    fun lumaOf(bitmap: Bitmap): Luma {
        val w = bitmap.width
        val h = bitmap.height
        val out = ByteArray(w * h)
        val row = IntArray(w)
        for (y in 0 until h) {
            bitmap.getPixels(row, 0, w, 0, y, w, 1)
            Ssim.lumaInto(row, w, out, y * w)
        }
        return Luma(out, w, h)
    }

    /** The frames of [file] closest to [timesUs], or null if any one cannot be read. */
    fun framesOf(file: File, timesUs: LongArray): List<Luma>? {
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(file.absolutePath)
            timesUs.map { t ->
                val bitmap = mmr.getFrameAtTime(t, MediaMetadataRetriever.OPTION_CLOSEST) ?: return null
                try {
                    lumaOf(bitmap)
                } finally {
                    bitmap.recycle()
                }
            }
        } catch (e: Exception) {
            null
        } finally {
            runCatching { mmr.release() }
        }
    }

    /**
     * Mean SSIM of [test] against [reference], frame by frame; null when the
     * two do not line up, which is never read as a pass.
     */
    fun score(reference: List<Luma>, test: List<Luma>): Double? {
        if (reference.isEmpty() || reference.size != test.size) return null
        var total = 0.0
        for (i in reference.indices) {
            val a = reference[i]
            val b = test[i]
            if (a.width != b.width || a.height != b.height) return null
            total += Ssim.of(a.plane, b.plane, a.width, a.height)
        }
        return total / reference.size
    }
}
