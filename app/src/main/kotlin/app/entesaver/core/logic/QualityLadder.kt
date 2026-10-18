package app.entesaver.core.logic

import kotlin.math.abs

/**
 * How hard a photo is compressed: found per photo, by measuring.
 *
 * One fixed setting is wrong for nearly every photo. A plain one - a sky, a
 * wall, a document - looks perfect at a low quality, and a detailed one -
 * leaves, a crowd, fabric - needs more. So before the real encode, a mosaic
 * of the photo is encoded at a candidate setting and compared with the
 * original ([Ssim]); the photo gets the cheapest rung that still looks like
 * the original, and only a picture that needs more gets more.
 *
 * The walk starts at [first], goes down while the rungs pass and up while
 * they fail, and stops after [maxProbes] measurements. A photo's rungs
 * ([forPhoto]) are encoder qualities. A video's share is read from its
 * motion instead (VideoShare): measured this way, a still scene's grain
 * looked like a loss and a dark scene's crushed shadows like detail kept.
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
