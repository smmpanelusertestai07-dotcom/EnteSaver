package app.entesaver.core.logic

import kotlin.math.abs

/**
 * What this phone's media actually is, measured rather than assumed.
 *
 * Every estimate the app shows - the calculator, the Home projection, the
 * "could save about" figures - reads from here, so there is one place to be
 * right and one place to say whether a number was measured or borrowed from
 * a constant. The app states no fact about cloud plans or providers; the only
 * numbers it offers are the ones it took off this device.
 */
object MediaProfile {

    /** Above this error, a single number stops being honest and becomes a range. */
    const val RANGE_THRESHOLD_PERCENT = 25.0

    /** How wide the range gets, as a share of the estimate. */
    const val RANGE_SPREAD = 0.25

    /** One media kind's measured behaviour. */
    data class TypeProfile(
        val count: Int = 0,
        val totalBytes: Long = 0,
        val medianBytes: Long = 0,
        /** output / original, 0..1. */
        val ratio: Double = 0.0,
        val samples: Int = 0,
        val asIsShare: Double = 0.0,
        val measured: Boolean = false,
        /** Videos only: output megabytes per minute. */
        val outMbPerMin: Double = 0.0,
        val minutes: Double = 0.0,
        /** Mean absolute percentage error of recent predictions. */
        val errorPercent: Double = 0.0
    ) {

        /**
         * How much smaller this phone's files really came out, or null when
         * nothing has been encoded yet.
         *
         * Nullable on purpose. A ratio of 0.0 means "no measurement", and the
         * old non-null version turned that into (1 - 0) * 100 = 100, so a
         * fresh install cheerfully announced "Photos come out about 100%
         * smaller". A missing measurement has to be missing, not maximal.
         */
        val shrinkPercent: Int?
            get() = if (ratio <= 0.0) {
                null
            } else {
                ((1 - ratio) * 100).toInt().coerceIn(0, 100)
            }
        /** True once the app should stop claiming a single figure. */
        val needsRange: Boolean get() = errorPercent > RANGE_THRESHOLD_PERCENT
    }

    data class Profile(
        val photos: TypeProfile = TypeProfile(),
        val videos: TypeProfile = TypeProfile(),
        /** Bytes added to the gallery in the last 30 days. */
        val monthlyBytes: Long = 0
    ) {
        val totalBytes: Long get() = photos.totalBytes + videos.totalBytes

        /** This phone's real photo:video split, for the calculator's mix. */
        val photoShare: Double
            get() = if (totalBytes <= 0) 0.5 else photos.totalBytes.toDouble() / totalBytes
    }

    /**
     * Whether a sample may speak for the gallery: enough of it, and not a
     * pile of screenshots standing in for photographs. Same two conditions
     * the calculator has always used, in one place now.
     */
    fun isMeasured(sampleCount: Int, sampleMedian: Long, galleryMedian: Long): Boolean {
        if (sampleCount < CapacityMath.MIN_SAMPLES) return false
        if (galleryMedian <= 0) return true
        return sampleMedian >= galleryMedian * CapacityMath.MIN_MEDIAN_SHARE
    }

    /**
     * Mean absolute percentage error over recent predictions.
     *
     * Stated to the user rather than hidden, because an estimate whose
     * accuracy is unknown is just a number with a confident font.
     */
    fun meanAbsolutePercentageError(predicted: List<Long>, actual: List<Long>): Double {
        require(predicted.size == actual.size) { "prediction pairs must line up" }
        val usable = predicted.indices.filter { actual[it] > 0 && predicted[it] > 0 }
        if (usable.isEmpty()) return 0.0
        val total = usable.sumOf { i ->
            abs(predicted[i] - actual[i]).toDouble() / actual[i]
        }
        return (total / usable.size) * 100
    }

    /** An estimate as a range, once the app knows it is often wrong. */
    data class Range(val low: Double, val high: Double, val single: Double) {
        val isRange: Boolean get() = low < high
    }

    fun estimateRange(value: Double, errorPercent: Double): Range =
        if (errorPercent <= RANGE_THRESHOLD_PERCENT) {
            Range(value, value, value)
        } else {
            Range(value * (1 - RANGE_SPREAD), value * (1 + RANGE_SPREAD), value)
        }

    /**
     * What-if for a different codec, from the ratio between their bitrate
     * targets rather than a second measurement: HEVC is asked for fewer bits
     * for the same picture, so the same footage lands smaller in that
     * proportion.
     */
    fun videoMbPerMinFor(current: TypeProfile, from: VideoCodec, to: VideoCodec): Double {
        if (from == to || current.outMbPerMin <= 0) return current.outMbPerMin
        val scale = BitrateCalc.codecFactor(to) / BitrateCalc.codecFactor(from)
        return current.outMbPerMin * scale
    }

    /** Months of headroom at the observed pace; negative means "cannot say". */
    fun monthsUntilFull(freeBytes: Long, monthlyBytes: Long): Double =
        if (monthlyBytes <= 0 || freeBytes < 0) -1.0 else freeBytes.toDouble() / monthlyBytes

    fun median(values: List<Long>): Long = CapacityMath.median(values)
}
