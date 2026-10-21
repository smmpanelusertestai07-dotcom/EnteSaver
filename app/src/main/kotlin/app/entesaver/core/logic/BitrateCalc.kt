package app.entesaver.core.logic

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Video bitrates: where the search for a clip's rate starts, and the bounds it
 * stays within. The rate a copy ends at is not set here but measured - the
 * least at which it still looks like its original (QualitySearch).
 *
 * The start grows with the picture's pixel rate (width x height x frames a
 * second) to the power [SCALE_EXPONENT], not in proportion: a bigger picture
 * has more pixels alike, so each needs fewer bits - what streaming services'
 * per-title ladders measure. 1080p30 in HEVC is [REF_HEVC_BPS]; H.264 starts
 * [H264_FACTOR] times as high for the same look, since every video stays in
 * its own codec. So a 1080p30 clip starts at 4.5 Mbps in HEVC and 6.5 in
 * H.264 - about what Android's own AVC encoder needs to look like the
 * original on a daylight pan from a phone's camera - and a clip is started at
 * 0.7 to 2.4 times that by what its frames show (VideoShare).
 */
object BitrateCalc {

    /** 1080p at 30 frames a second, in HEVC. */
    const val REF_HEVC_BPS = 4_500_000

    /** H.264 needs this much more than HEVC for the same picture. */
    const val H264_FACTOR = 1.45

    /** The pixel rate [REF_HEVC_BPS] is for: 1080p30. */
    const val REF_PIXEL_RATE = 1920.0 * 1080.0 * 30.0

    /** How the rate grows with the pixel rate. */
    const val SCALE_EXPONENT = 0.75

    const val FLOOR_BPS = 150_000

    /** The most any clip is asked for: room for 4K at 60 fps in fast motion, which a video keeps. */
    const val CAP_BPS = 80_000_000

    /**
     * The most picture a copy may carry, as a share of what its source's own
     * picture holds. Above it a copy saves too little to be worth stepping
     * down from the original, and the clip stays as it is.
     */
    const val MAX_OF_SOURCE = 0.85

    /** The most a copy may weigh, as a share of its original, to be kept at all. */
    const val MAX_COPY_SHARE = 0.9

    const val DURATION_TOLERANCE_MS = 2_000L

    /** How many times HEVC's rate a codec is asked for. */
    fun codecFactor(codec: VideoCodec): Double = when (codec) {
        VideoCodec.H264 -> H264_FACTOR
        VideoCodec.HEVC -> 1.0
    }

    fun targetBps(outWidth: Int, outHeight: Int, fps: Float, codec: VideoCodec): Int {
        val safeFps = if (fps.isFinite() && fps > 1f) fps else 30f
        val pixelRate = outWidth.toDouble() * outHeight.toDouble() * safeFps
        val raw = REF_HEVC_BPS * (pixelRate / REF_PIXEL_RATE).pow(SCALE_EXPONENT) * codecFactor(codec)
        return raw.toLong().coerceIn(FLOOR_BPS.toLong(), CAP_BPS.toLong()).toInt()
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

    /** Whether a copy of [outMs] is as long as its original of [srcMs], within [DURATION_TOLERANCE_MS]. */
    fun sameLength(srcMs: Long, outMs: Long): Boolean = srcMs <= 0 || abs(srcMs - outMs) <= DURATION_TOLERANCE_MS

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
