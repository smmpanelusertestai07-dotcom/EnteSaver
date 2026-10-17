package app.entesaver.core.logic

import kotlin.math.abs

/**
 * How hard a file is compressed: found per file, by measuring.
 *
 * One fixed setting is wrong for nearly every file. A still scene - a
 * speech, a sleeping baby, a sky - looks perfect on half the bits, and a
 * night-time crowd in motion needs all of them and more. So before the real
 * encode, a piece of the file is encoded at a candidate setting and compared
 * with the original ([Ssim]); the file gets the cheapest rung that still
 * looks like the original, and only a picture that needs more gets more.
 *
 * The walk starts at [first], goes down while the rungs pass and up while
 * they fail, and stops after [maxProbes] measurements. [VIDEO]'s rungs are
 * shares of a codec's standard rate (BitrateCalc.bppFor); a photo's
 * ([forPhoto]) are encoder qualities.
 */
class QualityLadder(rungs: List<Double>, first: Double, val maxProbes: Int, private val unmeasured: Double) {

    /** The settings, cheapest first. */
    val rungs: List<Double> = rungs.distinct().sorted()

    /** The first rung measured: the one nearest to what was asked. */
    val first: Double

    init {
        require(this.rungs.isNotEmpty()) { "a ladder needs a rung" }
        require(maxProbes >= 1) { "a ladder measures at least once" }
        this.first = this.rungs.minBy { abs(it - first) }
    }

    /** One measured rung: its setting and the SSIM it reached. */
    data class Point(val share: Double, val ssim: Double)

    /** What to do next: measure another rung, or encode at one. */
    sealed interface Step {
        data class Probe(val share: Double) : Step
        data class Encode(val share: Double) : Step
    }

    /** The next step for a file measured at [points] so far, aiming at [target]. */
    fun next(points: List<Point>, target: Double): Step {
        if (points.isEmpty()) return Step.Probe(first)
        if (points.size < maxProbes) {
            val passed = cheapestPass(points, target)
            val failed = dearestFail(points, target)
            if (passed != null) {
                val down = below(passed)
                if (down != null && (failed == null || down > failed + EPSILON)) return Step.Probe(down)
            } else if (failed != null) {
                above(failed)?.let { return Step.Probe(it) }
            }
        }
        return Step.Encode(settle(points, target))
    }

    /**
     * The rung to encode at with what is known - also when measuring stops
     * early, out of time or on a probe the phone could not make: the
     * cheapest rung that passed, else the one above the dearest that failed,
     * else the top; with nothing measured, the unmeasured default.
     */
    fun settle(points: List<Point>, target: Double): Double {
        cheapestPass(points, target)?.let { return it }
        val failed = points.maxOfOrNull { it.share } ?: return unmeasured
        return above(failed) ?: rungs.last()
    }

    private fun cheapestPass(points: List<Point>, target: Double): Double? =
        points.filter { it.ssim >= target }.minOfOrNull { it.share }

    private fun dearestFail(points: List<Point>, target: Double): Double? =
        points.filter { it.ssim < target }.maxOfOrNull { it.share }

    private fun below(share: Double): Double? = rungs.lastOrNull { it < share - EPSILON }

    private fun above(share: Double): Double? = rungs.firstOrNull { it > share + EPSILON }

    companion object {
        private const val EPSILON = 1e-9

        /**
         * Videos: shares of the standard rate, measured from the standard
         * rate itself in up to three short probes; a clip that is not
         * measured gets the standard rate. Calibrated against VMAF on real
         * camera footage: a still street scene passes at half the rate, a
         * river or leaves in the wind need twice it.
         */
        val VIDEO = QualityLadder(listOf(0.5, 0.7, 1.0, 1.4, 2.0), first = 1.0, maxProbes = 3, unmeasured = 1.0)

        /** Shorter than this, a video's probes cost more than they could save. */
        const val MIN_PROBE_DURATION_MS = 15_000L

        /** Encoder qualities a photo is tried at. */
        val PHOTO_QUALITIES = listOf(62.0, 70.0, 78.0, 85.0, 92.0)

        /** Where a photo's walk starts, and what an unmeasured one gets. */
        const val PHOTO_FIRST = 78.0
        const val PHOTO_UNMEASURED = 82.0

        /**
         * A photo's ladder: never above the quality the original was saved
         * at ([sourceQuality], when its file says), because a copy written
         * finer than its original only spends bytes on the original's own
         * blur. Null when the original is already below every rung. A photo
         * probe is a small mosaic of the photo, cheap enough for three.
         */
        fun forPhoto(sourceQuality: Int?): QualityLadder? {
            val allowed = if (sourceQuality == null) PHOTO_QUALITIES else PHOTO_QUALITIES.filter { it <= sourceQuality }
            if (allowed.isEmpty()) return null
            return QualityLadder(
                allowed,
                first = PHOTO_FIRST,
                maxProbes = 3,
                unmeasured = allowed.lastOrNull { it <= PHOTO_UNMEASURED } ?: allowed.first()
            )
        }
    }
}
