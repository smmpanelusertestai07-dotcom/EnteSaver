package app.entesaver.core.logic

import kotlin.math.roundToInt

/**
 * What a video copy must look like to be kept: like its original on a
 * phone's screen, and as good there as Google Photos' Storage saver.
 *
 * Measured, not guessed: each copy is scored against its own original with
 * VMAF ([Vmaf]), Netflix's model of what a viewer sees, which reads the same
 * way for a talking head, a night scene or a fast pan - so one target serves
 * every kind of video. [VMAF] on its own scale is 98 on its phone model,
 * which is VMAF trained for a phone held at arm's length, where 100 is a copy
 * nobody could tell from the original. On the savings benchmark's camera
 * clips, the Storage saver stand-in - Google publishes no figures, so H.264
 * at 8 Mbps for 1080p30 from x264, the best software encoder - scores 98.4 to
 * 100 on the phone model, and a copy at the target sits within those
 * fractions of a point, which no one sees.
 *
 * The phone reads a dozen frames of a clip, not every one, so the search aims
 * [MARGIN] above the target ([SEARCH_VMAF]): what the benchmark then measures
 * over every frame lands at the target or over it.
 */
object QualityTarget {

    /** The VMAF a copy must reach: 98 on VMAF's phone model. */
    const val VMAF = 86.0

    /** How far above [VMAF] the search aims, for reading only some of the frames. */
    const val MARGIN = 1.0

    /** The score the search holds a copy to. */
    const val SEARCH_VMAF = VMAF + MARGIN

    /** The most copies made of one clip on the way to its rate. */
    const val MAX_TRIES = 3

    /**
     * How a kept copy measured, for its item's record and the benchmark:
     * mean and lowest VMAF over the moments read, the phone model's mean, the
     * try it came from, and how many tries of a long clip's stretches went
     * before it (Excerpts). Plain digits, the same in every language.
     */
    fun describe(vmaf: Double, lowest: Double, phone: Double, tryNumber: Int, excerptTries: Int = 0): String =
        "vmaf=${tenths(vmaf)};low=${tenths(lowest)};phone=${tenths(phone)};try=$tryNumber" +
            if (excerptTries > 0) ";excerpts=$excerptTries" else ""

    private fun tenths(v: Double): String {
        val t = (v * 10).roundToInt()
        return "${t / 10}.${t % 10}"
    }
}
