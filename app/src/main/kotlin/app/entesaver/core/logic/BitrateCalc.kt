package app.entesaver.core.logic

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Video bitrate policy: the standard rate a clip's share (VideoShare, read
 * from how much its picture moves) is taken of.
 *
 * It grows with the picture's pixel rate (width x height x frames a second)
 * to the power [SCALE_EXPONENT], not in proportion: a bigger picture has
 * more pixels alike, so each needs fewer bits - what streaming services'
 * per-title ladders measure. 1080p30 in HEVC is [REF_HEVC_BPS]; H.264 is
 * asked for [H264_FACTOR] times as much for the same look. So 1080p30 is
 * 0.95 Mbps in HEVC and 1.38 Mbps in H.264, 720p30 0.52 and 0.75, a
 * WhatsApp 480p clip 0.28 and 0.41 - and a clip gets 0.7 to 2.4 times that
 * by what it shows, never more than [SOURCE_SHARE] of what its source holds.
 * A camera writes 20 Mbps: the savings benchmark's 46 GB library comes down
 * to about a seventh (6.5 GB), which is what it takes to last in Ente's free
 * 10 GB.
 */
object BitrateCalc {

    /** 1080p at 30 frames a second, in HEVC. */
    const val REF_HEVC_BPS = 950_000

    /** H.264 needs this much more than HEVC for the same picture. */
    const val H264_FACTOR = 1.45

    /** The pixel rate [REF_HEVC_BPS] is for: 1080p30. */
    const val REF_PIXEL_RATE = 1920.0 * 1080.0 * 30.0

    /** How the rate grows with the pixel rate. */
    const val SCALE_EXPONENT = 0.75

    const val FLOOR_BPS = 150_000
    const val CAP_BPS = 8_000_000

    /**
     * The most of what its source's own picture holds a copy is asked for
     * ([sourceCapBps]): a file another app already compressed - a Telegram
     * episode, a YouTube download - still comes down by two fifths at least,
     * instead of being written again for next to nothing. Set with the
     * standard rate on the savings benchmark: the 46 GB library lands at
     * 6.5 GB, and a camera's own videos keep their full rate.
     */
    const val SOURCE_SHARE = 0.6

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

    /**
     * The most a copy is asked for: [SOURCE_SHARE] of what its source's own
     * picture holds, in the copy's codec and at the copy's size and frame
     * rate. A Telegram episode in H.264 at 1 Mbps holds about what HEVC keeps
     * at 0.69; asked for more, the extra bits would carry nothing the source
     * had, and the episode would be kept whole for want of a saving. Null when
     * the source's codec or bitrate is not known.
     */
    fun sourceCapBps(
        sourceVideoBps: Long,
        sourceMime: String?,
        srcWidth: Int,
        srcHeight: Int,
        srcFps: Float,
        outWidth: Int,
        outHeight: Int,
        outFps: Float,
        codec: VideoCodec
    ): Int? {
        val factor = sourceFactor(sourceMime) ?: return null
        if (sourceVideoBps <= 0) return null
        val src = srcWidth.toDouble() * srcHeight * (if (srcFps.isFinite() && srcFps > 1f) srcFps else 30f)
        val out = outWidth.toDouble() * outHeight * (if (outFps.isFinite() && outFps > 1f) outFps else 30f)
        if (src <= 0 || out <= 0) return null
        val scale = (out / src).coerceAtMost(1.0).pow(SCALE_EXPONENT)
        return (sourceVideoBps * scale * codecFactor(codec) / factor * SOURCE_SHARE)
            .coerceIn(FLOOR_BPS.toDouble(), CAP_BPS.toDouble()).toInt()
    }

    /** How many times HEVC's rate a source codec spends on the same picture. */
    private fun sourceFactor(mime: String?): Double? = when (mime?.lowercase()) {
        "video/hevc", "video/x-vnd.on2.vp9" -> 1.0
        "video/avc" -> H264_FACTOR
        "video/av01" -> 0.8
        "video/mp4v-es", "video/3gpp" -> 2.0
        else -> null
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

    /** How far under the target the next encode aims, after one that overshot. */
    const val CORRECTION_MARGIN = 0.95

    /** The least the next encode is asked for, as a share of the target. */
    const val MIN_CORRECTION = 1.0 / 3

    /**
     * What to ask the next encode for, after one asked for [askedBps] wrote
     * [measuredVideoBps] of picture when the clip needs [targetBps].
     *
     * An encoder that overshoots does it by much the same factor at a lower
     * request - the emulator's software H.264 by half again on a lean
     * WhatsApp forward, which is why such files were kept whole. Lowered by
     * that factor, the next encode lands near the target instead of over it
     * a second time. Null when the encoder kept to the target, so there is
     * nothing to correct. Never under a third of the target: an encoder that
     * overshoots by more than that is not keeping to a rate at all.
     */
    fun correctedRequestBps(askedBps: Int, measuredVideoBps: Long, targetBps: Int): Int? {
        if (askedBps <= 0 || measuredVideoBps <= 0 || targetBps <= 0) return null
        if (measuredVideoBps <= targetBps) return null
        val next = askedBps.toDouble() * targetBps / measuredVideoBps * CORRECTION_MARGIN
        return maxOf(next, targetBps * MIN_CORRECTION).toInt().takeIf { it < askedBps }
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
