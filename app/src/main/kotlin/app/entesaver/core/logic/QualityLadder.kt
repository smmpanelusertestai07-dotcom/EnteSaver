package app.entesaver.core.logic

/**
 * How many bits a video is given: found per video, by measuring.
 *
 * A fixed bitrate is wrong for nearly every video. A still scene - a speech,
 * a sleeping baby - looks perfect on half of it, and a night-time crowd in
 * motion needs all of it and more. So before the full encode a short piece
 * of the video is encoded at a candidate rate and compared with the
 * original ([Ssim]); the video gets the lowest rung that still looks like
 * the original, and only a picture that needs it gets more.
 *
 * Rungs are shares of the codec's standard rate (BitrateCalc.bppFor). At
 * most two probes are made: the middle rung first, then the one below it
 * when the middle looks right, or the one above when it does not. A clip
 * too short to be worth probing goes straight to [UNPROBED].
 */
object QualityLadder {

    /** Shares of the standard rate, cheapest first. */
    val RUNGS = doubleArrayOf(0.5, 0.7, 1.0, 1.3)

    /** The first rung measured. */
    const val FIRST = 0.7

    /** The share used when a video is not probed. */
    const val UNPROBED = 1.0

    /** Shorter than this, a probe costs more than it could save. */
    const val MIN_PROBE_DURATION_MS = 15_000L

    /** One measured rung: its share and the SSIM it reached. */
    data class Point(val share: Double, val ssim: Double)

    /** What to do next after [points]: measure another rung, or encode at one. */
    sealed interface Step {
        data class Probe(val share: Double) : Step
        data class Encode(val share: Double) : Step
    }

    /**
     * The next step for a video measured at [points] so far, aiming at [target].
     * Never more than two probes; an unmeasured video starts at [FIRST].
     */
    fun next(points: List<Point>, target: Double): Step {
        if (points.isEmpty()) return Step.Probe(FIRST)
        val passed = points.filter { it.ssim >= target }.minByOrNull { it.share }
        val failed = points.filter { it.ssim < target }.maxByOrNull { it.share }
        if (points.size >= 2) {
            return Step.Encode(
                when {
                    passed != null -> passed.share
                    else -> above(failed!!.share) ?: RUNGS.last()
                }
            )
        }
        val only = points.single()
        return if (only.ssim >= target) {
            below(only.share)?.let { Step.Probe(it) } ?: Step.Encode(only.share)
        } else {
            above(only.share)?.let { Step.Probe(it) } ?: Step.Encode(only.share)
        }
    }

    /**
     * The share to encode at when measuring stops early - out of time, or a
     * probe the phone could not make: the cheapest rung that passed, else the
     * one above the dearest that failed, else [UNPROBED].
     */
    fun settle(points: List<Point>, target: Double): Double {
        points.filter { it.ssim >= target }.minByOrNull { it.share }?.let { return it.share }
        val failed = points.maxByOrNull { it.share } ?: return UNPROBED
        return above(failed.share) ?: RUNGS.last()
    }

    private fun below(share: Double): Double? = RUNGS.filter { it < share - 1e-9 }.maxOrNull()

    private fun above(share: Double): Double? = RUNGS.filter { it > share + 1e-9 }.minOrNull()
}
