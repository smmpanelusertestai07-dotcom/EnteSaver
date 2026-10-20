package app.entesaver.media

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import kotlin.math.sqrt

/**
 * How much a video moves and how dark it is (VideoShare), read from a few
 * pairs of its frames.
 *
 * Each pair is two frames one output frame apart - at 30 fps for a clip
 * written at 30, whatever it was filmed at - taken at [POSITIONS] of the clip
 * and decoded straight to a small size ([LONG_SIDE] on the long side), so a
 * 4K clip costs no more memory than a WhatsApp forward. Nothing is encoded:
 * reading a clip this way takes a phone a second or two.
 */
internal object MotionProbe {

    /** What the frames say: temporal information (TI) and mean brightness, 0-255. */
    data class Reading(val ti: Double, val meanLuma: Double)

    /** Where in the clip the pairs are read, as shares of its length. */
    private val POSITIONS = doubleArrayOf(0.2, 0.4, 0.6, 0.8)

    /** The long side the frames are decoded to. */
    private const val LONG_SIDE = 480

    /** Null when no pair could be read. */
    fun read(context: Context, uri: Uri, durationMs: Long, outFps: Float): Reading? {
        if (durationMs <= 0) return null
        val stepUs = (1_000_000.0 / (if (outFps.isFinite() && outFps > 1f) outFps else 30f)).toLong()
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(context, uri)
            val tis = mutableListOf<Double>()
            val lumas = mutableListOf<Double>()
            for (p in POSITIONS) {
                val t0 = (durationMs * 1000 * p).toLong()
                val t1 = t0 + stepUs
                if (t1 >= durationMs * 1000) continue
                val a = lumaAt(mmr, t0) ?: continue
                val b = lumaAt(mmr, t1) ?: continue
                if (a.width != b.width || a.height != b.height) continue
                tis += spreadOfDifference(a.plane, b.plane)
                lumas += a.plane.sumOf { it.toInt() and 0xFF }.toDouble() / a.plane.size
            }
            if (tis.isEmpty()) null else Reading(tis.average(), lumas.average())
        } catch (e: Exception) {
            null
        } catch (e: OutOfMemoryError) {
            null
        } finally {
            runCatching { mmr.release() }
        }
    }

    private fun lumaAt(mmr: MediaMetadataRetriever, timeUs: Long): FrameQuality.Luma? {
        val bitmap = mmr.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST, LONG_SIDE, LONG_SIDE)
            ?: return null
        return try {
            FrameQuality.lumaOf(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    /** The standard deviation of the pixel-by-pixel difference of two brightness planes. */
    private fun spreadOfDifference(a: ByteArray, b: ByteArray): Double {
        var sum = 0.0
        var sumSq = 0.0
        for (i in a.indices) {
            val d = ((a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)).toDouble()
            sum += d
            sumSq += d * d
        }
        val n = a.size.toDouble()
        val mean = sum / n
        return sqrt((sumSq / n - mean * mean).coerceAtLeast(0.0))
    }
}
