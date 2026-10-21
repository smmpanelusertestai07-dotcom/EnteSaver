package app.entesaver.core.logic

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.pow

/**
 * How a video's bitrate is found: the least that still looks like its
 * original, measured on the phone rather than guessed.
 *
 * Each try is a whole copy, made at a rate and then scored against its
 * original with VMAF ([Vmaf], Netflix's measure of how a viewer sees a
 * picture) on frames from across the clip. The next rate comes from what the
 * tries so far measured. Between two that straddle the target it is read off
 * the line through them: VMAF against the logarithm of the rate, which is
 * close to straight over the range a copy is made in. Otherwise it is a step
 * along the slope between the two tries nearest the target on the same side,
 * or, from one try alone, along the slope VMAF has there - between 6 and 20
 * points for every doubling, on the savings benchmark's clips with Android's
 * own AVC encoder - taking the cautious end each way: [UP_SLOPE] going up, so
 * the next copy lands above the target rather than short of it again, and
 * [DOWN_SLOPE] going down, so it does not fall below it.
 *
 * Of the copies that reach the target and weigh no more than the caller
 * allows, the smallest is kept. A clip whose target lies above the most a copy
 * may carry - a forward another app already squeezed - stays as it is.
 *
 * Rates here are what the copies' pictures came out at, not what the encoder
 * was asked for: many encoders land above or below the request, by much the
 * same factor each time, so the next request is scaled by the nearest try's.
 */
object QualitySearch {

    /** One copy made: what the encoder was asked for, what its picture came out at, its size, its score. */
    data class Try(val askedBps: Int, val videoBps: Long, val bytes: Long, val score: Double)

    /** What to do next. */
    sealed interface Step {
        /** Make another copy, asking the encoder for [askedBps]. */
        data class Encode(val askedBps: Int) : Step

        /** Keep the copy of try [index]: it reached the target, and no try could beat it by enough. */
        data class Keep(val index: Int) : Step

        /** No copy is worth having: the original stays as it is. */
        data object Original : Step
    }

    /** VMAF points gained per doubling of the rate, assumed when going up from one try. */
    const val UP_SLOPE = 7.0

    /** VMAF points lost per halving of the rate, assumed when going down from one try. */
    const val DOWN_SLOPE = 14.0

    /** How far above the target the next copy is aimed, so it lands at or over it. */
    const val AIM_ABOVE = 0.5

    /** A smaller copy is only tried for when it should be at least this much lighter. */
    const val MIN_GAIN = 0.10

    /** One step never goes further than this, either way. */
    const val MAX_STEP = 3.0

    /** A slope measured between two tries is taken within these bounds. */
    const val MIN_SLOPE = 2.0
    const val MAX_SLOPE = 30.0

    /** A rate this close to one already tried would only make the same copy again. */
    private const val SAME_RATE = 0.07

    /**
     * The step after [tries], for a [target] VMAF. A copy counts when it scores
     * at least the target and weighs at most [maxBytes]; [maxVideoBps] is the
     * most picture a copy may carry, and [minAskBps] the least an encoder is
     * asked for. After [maxTries] copies the best one so far is kept, if any is.
     */
    fun next(
        tries: List<Try>,
        target: Double,
        maxBytes: Long,
        maxVideoBps: Long,
        minAskBps: Int,
        maxTries: Int
    ): Step {
        require(tries.isNotEmpty()) { "the first copy's rate is the caller's" }
        val best = tries.indices.filter { passes(tries[it], target, maxBytes) }.minByOrNull { tries[it].bytes }
        if (tries.size >= maxTries) return best?.let { Step.Keep(it) } ?: Step.Original
        val (rate, near) = rateFor(tries, target + AIM_ABOVE)
        if (best != null && rate >= tries[best].videoBps * (1 - MIN_GAIN)) return Step.Keep(best)
        var next = rate
        if (next > maxVideoBps) {
            // The target lies above the most a copy may carry: one try at that
            // most, unless a try has been made close to it already.
            val top = tries.maxOf { it.videoBps }
            if (best != null) return Step.Keep(best)
            if (top >= maxVideoBps * (1 - SAME_RATE)) return Step.Original
            next = maxVideoBps.toDouble()
        }
        if (tries.any { abs(it.videoBps - next) <= it.videoBps * SAME_RATE }) {
            return best?.let { Step.Keep(it) } ?: Step.Original
        }
        // The encoder lands where it lands: ask in proportion to the try whose
        // rate is nearest, so the copy comes out at the rate wanted. One that
        // came out above its request may have met its own floor rather than
        // overshot in proportion, so above that rate it is asked for the rate
        // itself.
        val landed = (near.videoBps.toDouble() / near.askedBps.coerceAtLeast(1)).coerceIn(0.25, 4.0)
        val ask = (if (next > near.videoBps && landed > 1) next else next / landed).coerceAtLeast(minAskBps.toDouble())
        return Step.Encode(ask.coerceAtMost(Int.MAX_VALUE.toDouble()).toInt())
    }

    /** Whether [t] is a copy worth keeping at [target]. */
    fun passes(t: Try, target: Double, maxBytes: Long): Boolean = t.score >= target && t.bytes <= maxBytes

    /**
     * The picture rate that should score [goal], and the try it was read
     * from: between the two tries that straddle it, or a step from the one
     * nearest it.
     */
    private fun rateFor(tries: List<Try>, goal: Double): Pair<Double, Try> {
        val sorted = tries.filter { it.videoBps > 0 }.sortedBy { it.videoBps }
        require(sorted.isNotEmpty()) { "no copy had a rate" }
        for (i in 1 until sorted.size) {
            val a = sorted[i - 1]
            val b = sorted[i]
            if (a.score < goal && b.score >= goal && b.score > a.score) {
                val f = (goal - a.score) / (b.score - a.score)
                val la = ln(a.videoBps.toDouble())
                val lb = ln(b.videoBps.toDouble())
                val rate = exp(la + f * (lb - la))
                return rate to (if (f < 0.5) a else b)
            }
        }
        // Not straddled: every try is below the goal, so step up from the
        // richest; or every try is above it, so step down from the leanest.
        // Tries whose scores run against their rates leave the same choice.
        val above = sorted.filter { it.score >= goal }
        return if (above.isEmpty()) {
            val from = sorted.last()
            val slope = slopeOf(sorted.takeLast(2))?.coerceIn(MIN_SLOPE, MAX_SLOPE) ?: UP_SLOPE
            val factor = 2.0.pow((goal - from.score) / slope).coerceAtMost(MAX_STEP)
            from.videoBps * factor to from
        } else {
            val from = above.first()
            val slope = slopeOf(above.take(2))?.coerceIn(MIN_SLOPE, MAX_SLOPE) ?: DOWN_SLOPE
            val factor = 2.0.pow(-(from.score - goal) / slope).coerceAtLeast(1 / MAX_STEP)
            from.videoBps * factor to from
        }
    }

    /**
     * VMAF points per doubling between two tries, leanest first; null unless
     * their rates are far enough apart to say and the richer scored higher.
     */
    private fun slopeOf(pair: List<Try>): Double? {
        if (pair.size < 2) return null
        val (a, b) = pair
        if (b.videoBps < a.videoBps * 1.05 || b.score <= a.score) return null
        return (b.score - a.score) / (ln(b.videoBps.toDouble() / a.videoBps) / ln(2.0))
    }
}
