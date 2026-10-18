package app.entesaver.media

import android.graphics.Bitmap
import app.entesaver.core.logic.Ssim

/**
 * Pictures read back as brightness: for [Ssim] in the photo quality search
 * (PhotoCompressor), and for a video's motion (MotionProbe). Only brightness
 * is kept, one byte a pixel, so a 1080p frame costs 2 MB instead of the 8 MB
 * of its colour bitmap.
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
