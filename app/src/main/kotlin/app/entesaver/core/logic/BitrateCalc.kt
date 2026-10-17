package app.entesaver.core.logic

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Video bitrate policy: the standard rate is OUTPUT pixels x fps x
 * bits-per-pixel-per-frame by codec (H.264 0.10, HEVC 0.065), clamped to
 * [1 Mbps, 12 Mbps] - 20 Mbps above 1440p, where 12 would starve a 4K
 * picture: about 6 Mbps for 1080p30 H.264 and 4 Mbps HEVC. A clip is given a
 * measured share of it (QualityLadder.VIDEO).
 */
object BitrateCalc {

    const val BPP_H264 = 0.10
    const val BPP_HEVC = 0.065
    const val CAP_BPS = 12_000_000
    const val CAP_BPS_UHD = 20_000_000
    const val FLOOR_BPS = 1_000_000

    /** Above this long side a picture is 4K-class and gets [CAP_BPS_UHD]. */
    const val UHD_LONG_SIDE = 2560

    /** Copy as-is when source bitrate <= 1.15 x target (and size/container fit). */
    const val COPY_BITRATE_FACTOR = 1.15

    /** Result rejected when output bitrate > 1.3 x target (encoder ignored settings). */
    const val RESULT_BITRATE_FACTOR = 1.3

    const val DURATION_TOLERANCE_MS = 2_000L

    /**
     * The most a copy may weigh, as a share of the original, to be kept when
     * no encoder on the phone kept to its target bitrate.
     */
    const val FALLBACK_MAX_RATIO = 0.9

    fun bppFor(codec: VideoCodec): Double = when (codec) {
        VideoCodec.H264 -> BPP_H264
        VideoCodec.HEVC -> BPP_HEVC
    }

    fun capFor(outWidth: Int, outHeight: Int): Int =
        if (maxOf(outWidth, outHeight) > UHD_LONG_SIDE) CAP_BPS_UHD else CAP_BPS

    fun targetBps(outWidth: Int, outHeight: Int, fps: Float, codec: VideoCodec): Int {
        val safeFps = if (fps.isFinite() && fps > 1f) fps else 30f
        val raw = outWidth.toDouble() * outHeight.toDouble() * safeFps * bppFor(codec)
        return raw.toLong().coerceIn(FLOOR_BPS.toLong(), capFor(outWidth, outHeight).toLong()).toInt()
    }

    /** Keep aspect ratio, clamp long side, force even dimensions. */
    fun outputDims(srcWidth: Int, srcHeight: Int, longSideLimit: Int): Pair<Int, Int> {
        val w = max(2, srcWidth)
        val h = max(2, srcHeight)
        val longSide = max(w, h)
        if (longSide <= longSideLimit) return even(w) to even(h)
        val scale = longSideLimit.toDouble() / longSide
        return even((w * scale).roundToInt()) to even((h * scale).roundToInt())
    }

    private fun even(v: Int): Int = max(2, v - (v % 2))

    fun shouldCopyAsIs(
        srcLongSide: Int,
        longSideLimit: Int,
        srcBps: Long,
        targetBps: Int,
        containerOk: Boolean
    ): Boolean = containerOk &&
        srcLongSide <= longSideLimit &&
        srcBps > 0 &&
        srcBps <= (targetBps * COPY_BITRATE_FACTOR).toLong()

    /** Mandatory result check: smaller than source, sane bitrate, duration within +/-2 s. */
    fun resultAcceptable(
        srcBytes: Long,
        outBytes: Long,
        outBps: Long,
        targetBps: Int,
        srcDurationMs: Long,
        outDurationMs: Long
    ): Boolean {
        if (outBytes <= 0 || outBytes >= srcBytes) return false
        if (outBps > (targetBps * RESULT_BITRATE_FACTOR).toLong()) return false
        if (srcDurationMs > 0 && abs(srcDurationMs - outDurationMs) > DURATION_TOLERANCE_MS) return false
        return true
    }

    /**
     * A copy every rung overshot its target with, but that is still a real
     * saving of the whole clip. Some encoders - an emulator's, a budget
     * chip's on detailed footage - will not come down to the bitrate asked
     * for at all; a copy at half the size is still half the space, and
     * throwing it away for an untouched original saves nothing.
     */
    fun worthKeeping(srcBytes: Long, outBytes: Long, srcDurationMs: Long, outDurationMs: Long): Boolean {
        if (outBytes <= 0 || outBytes > (srcBytes * FALLBACK_MAX_RATIO).toLong()) return false
        if (srcDurationMs > 0 && abs(srcDurationMs - outDurationMs) > DURATION_TOLERANCE_MS) return false
        return true
    }

    /**
     * Power-of-two BitmapFactory inSampleSize: decode within 2x of the pixel
     * budget (memory safety), the exact downscale then lands on the budget.
     */
    fun sampleSizeFor(width: Int, height: Int, maxPixels: Long): Int {
        var sample = 1
        var pixels = width.toLong() * height.toLong()
        while (pixels > maxPixels * 2) {
            sample *= 2
            pixels /= 4
        }
        return sample
    }
}
