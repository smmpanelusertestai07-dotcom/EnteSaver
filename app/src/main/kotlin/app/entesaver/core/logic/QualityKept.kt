package app.entesaver.core.logic

/**
 * How much of the original survives optimising, stated as facts rather than
 * as a slogan.
 *
 * "About 90-95% quality" is the kind of number an app asserts and nobody can
 * check. Everything here is either read straight off the encoder settings the
 * pipeline really uses, or is arithmetic on pixel counts - so every figure the
 * app shows can be traced back to something.
 *
 * Two separate things get called "quality", and conflating them is what makes
 * the subject confusing:
 *
 *  - **Detail kept** is resolution: what share of the original's pixels are
 *    still there. Exactly computable, and 100% for anything already under the
 *    setting's cap - which on the default setting is most photos.
 *  - **Encoder quality** is the quality factor used when re-saving. A
 *    setting, not an opinion.
 */
object QualityKept {

    /**
     * Pixels a typical phone screen can actually show, in megapixels.
     *
     * 1080 x 2400 is about 2.6 MP. It is here because "16 MP" means nothing on
     * its own, and "five times more than your screen can show" means quite a
     * lot.
     */
    const val PHONE_SCREEN_MP = 2.6

    /** The megapixel ceiling for photos; 0 keeps every pixel. */
    fun photoCapMp(spec: PhotoSpec): Int = spec.maxMp

    /** The long-side ceiling for video; 0 keeps the clip's own size. */
    fun videoCapLongSide(spec: VideoSpec): Int = spec.longSide

    /**
     * Share of the original's pixels that survive, as a percentage.
     *
     * A file already under the cap keeps all of them: the app only re-saves
     * it, it does not shrink it. Never above 100 - nothing is ever upscaled.
     */
    fun detailKeptPercent(originalPixels: Long, capPixels: Long): Int {
        if (originalPixels <= 0 || capPixels <= 0) return 100
        if (originalPixels <= capPixels) return 100
        return ((capPixels.toDouble() / originalPixels) * 100).toInt().coerceIn(1, 100)
    }

    /** Detail kept for a photo of [originalMp] megapixels. */
    fun photoDetailKeptPercent(originalMp: Double, spec: PhotoSpec): Int =
        if (spec.maxMp <= 0) {
            100
        } else {
            detailKeptPercent((originalMp * 1_000_000).toLong(), spec.maxMp * 1_000_000L)
        }

    /**
     * Detail kept for a video, from its long side.
     *
     * Pixels scale with the square of the long side, so a 4K clip capped at
     * 1080p keeps a quarter of them - which is why video saves so much more
     * space than photos do.
     */
    fun videoDetailKeptPercent(originalLongSide: Int, spec: VideoSpec): Int {
        if (originalLongSide <= 0) return 100
        val cap = spec.longSide
        if (cap <= 0 || originalLongSide <= cap) return 100
        val ratio = cap.toDouble() / originalLongSide
        return (ratio * ratio * 100).toInt().coerceIn(1, 100)
    }

    /**
     * How many times more detail the capped photo still has than a phone
     * screen can display. Below 1 the cap is genuinely visible on the phone.
     * Null when nothing is capped: every pixel the camera took is kept.
     */
    fun screenHeadroom(spec: PhotoSpec): Double? =
        if (spec.maxMp <= 0) null else spec.maxMp / PHONE_SCREEN_MP

    /**
     * Detail kept for one file the app really encoded, from the pixel counts
     * the encoder recorded.
     *
     * Null when either count is zero - an as-is copy, a format never decoded,
     * or a row written before the app started recording this. Null means "no
     * figure", and callers must show nothing rather than guess a number.
     */
    fun measuredDetailKeptPercent(srcPixels: Long, outPixels: Long): Int? {
        if (srcPixels <= 0 || outPixels <= 0) return null
        return ((outPixels.toDouble() / srcPixels) * 100).toInt().coerceIn(1, 100)
    }

    /**
     * The share of the original size that a measured result kept.
     *
     * The complement of "how much smaller": if a copy is 30% smaller it kept
     * 70% of the bytes. Stated because the two get mixed up constantly.
     */
    fun sizeKeptPercent(originalBytes: Long, outputBytes: Long): Int {
        if (originalBytes <= 0) return 100
        return ((outputBytes.toDouble() / originalBytes) * 100)
            .toInt()
            .coerceIn(0, 100)
    }
}
