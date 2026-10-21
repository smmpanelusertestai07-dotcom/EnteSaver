package app.entesaver.core.logic

/**
 * Where a long clip's rate is first looked for: a few short stretches of it.
 *
 * A wedding or a school function can run for half an hour, and copying it
 * whole can take most of the time a clip is given. So its rate is searched
 * for on [COUNT] stretches of [LENGTH_MS] each from across it - each copied
 * and scored against the same stretch of the original, in seconds - and the
 * whole clip is then copied once, at the rate they found, and scored itself.
 * The stretches sit at even shares of the clip, clear of its first and last
 * minutes, where a camera is often still being raised or lowered.
 */
object Excerpts {

    /** A clip longer than this is searched on stretches of itself first. */
    const val ABOVE_MS = 5 * 60_000L

    /** How many stretches, and how long each. */
    const val COUNT = 3
    const val LENGTH_MS = 10_000L

    /** How many moments of each stretch are scored. */
    const val MOMENTS_EACH = 4

    /**
     * The stretches of a clip of [durationMs], each from its first to its
     * last millisecond, in order; none for a clip of [aboveMs] or less.
     */
    fun windows(durationMs: Long, aboveMs: Long = ABOVE_MS): List<LongRange> {
        if (durationMs <= aboveMs || durationMs < LENGTH_MS) return emptyList()
        return (1..COUNT).map { i ->
            val middle = durationMs * i / (COUNT + 1)
            val start = (middle - LENGTH_MS / 2).coerceIn(0, durationMs - LENGTH_MS)
            start..start + LENGTH_MS
        }
    }
}
