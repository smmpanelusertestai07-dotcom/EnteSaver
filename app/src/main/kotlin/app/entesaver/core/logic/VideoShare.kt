package app.entesaver.core.logic

/**
 * How many times its standard rate (BitrateCalc) a video is given, from what
 * is in its picture: how much it moves, how dark it is, and whether it is a
 * recording of a phone's screen.
 *
 * Motion is what costs bits. It is read as temporal information - TI, from
 * ITU-T P.910: the spread of the difference between two frames one output
 * frame apart - on small brightness copies of a few pairs of frames, which a
 * phone decodes in a second or two and which no encoder has to touch. The
 * share follows it, linearly between the points of [CURVE].
 *
 * Calibrated against VMAF's phone model on the savings benchmark's own clips,
 * encoded the way a phone's HEVC chip does: a talking head still looks like
 * the original at 0.7 of the standard rate and a daylight pan at about 1.1,
 * fast motion needs 2.4 to look good, and a night scene needs 1.5 whatever it
 * does, for its noise and its shadows - which TI, on a small copy, cannot
 * see. A screen recording's text and lines need at least 1.6. A reading of an
 * encode against a richer encode of itself, which the app used before, could
 * not tell these apart: it scored a still scene's grain as a loss and a dark
 * one's crushed shadows as kept.
 */
object VideoShare {

    /** (TI, share) points; linear between them, flat beyond the ends. */
    val CURVE: List<Pair<Double, Double>> = listOf(5.0 to 0.7, 12.0 to 0.9, 20.0 to 1.8, 30.0 to 2.4)

    /** The least and the most a video is given. */
    val MIN: Double get() = CURVE.first().second
    val MAX: Double get() = CURVE.last().second

    /** Mean brightness (0-255) below which a picture counts as night or indoors. */
    const val DARK_LUMA = 70.0
    const val DARK_SHARE = 1.5

    /** A phone's screen recorded: text, lines and games. */
    const val SCREEN_SHARE = 1.6

    /** A video whose frames could not be read. */
    const val UNMEASURED = 1.0

    /**
     * The share for a video whose frames read [ti] (TI, null when they could
     * not be read) and [meanLuma] (0-255), recorded from a screen or not.
     */
    fun of(ti: Double?, meanLuma: Double?, screenRecording: Boolean): Double {
        var share = if (ti == null || !ti.isFinite()) UNMEASURED else onCurve(ti)
        if (meanLuma != null && meanLuma < DARK_LUMA) share = maxOf(share, DARK_SHARE)
        if (screenRecording) share = maxOf(share, SCREEN_SHARE)
        return share.coerceIn(MIN, MAX)
    }

    private fun onCurve(ti: Double): Double {
        if (ti <= CURVE.first().first) return CURVE.first().second
        for (i in 1 until CURVE.size) {
            val (x0, y0) = CURVE[i - 1]
            val (x1, y1) = CURVE[i]
            if (ti <= x1) return y0 + (y1 - y0) * (ti - x0) / (x1 - x0)
        }
        return CURVE.last().second
    }

    /** Names and albums phones and apps give screen recordings. */
    private val SCREEN_WORDS = listOf("screen_recording", "screenrecord", "screen recording", "screen-recording", "screenshots")

    /** Whether a video, by its name and album, is a recording of a phone's screen. */
    fun isScreenRecording(displayName: String, bucket: String?): Boolean {
        val name = displayName.lowercase()
        val album = bucket.orEmpty().lowercase()
        return SCREEN_WORDS.any { name.contains(it) || album.contains(it) } ||
            name.startsWith("screen-") || name.startsWith("screenrecorder")
    }
}
