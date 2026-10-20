package app.entesaver.core.logic

import kotlin.math.ceil

/**
 * Turns the daily upload allowance into hourly slices, and decides how many
 * copies may be in flight at once.
 *
 * Releasing a whole day's worth in one burst makes per-file proof impossible:
 * once ten files leave together, the cloud app's byte counter cannot say which
 * of them arrived. Sending them a few at a time, and often only one, is what
 * turns a byte count into evidence about a specific file.
 */
object Pacing {

    /** Slices per day. Twelve gives roughly two-hourly releases. */
    const val SLICES_PER_DAY = 12

    /** A copy stops waiting for per-file proof after this long. */
    const val IN_FLIGHT_TIMEOUT_MS = 6 * 3_600_000L

    /** One at a time unless the cloud tells us when a file has landed. */
    const val IN_FLIGHT_WITHOUT_ORACLE = 1
    const val IN_FLIGHT_WITH_ORACLE = 4

    /**
     * Bytes this maintenance pass may release.
     *
     * Always at least one file's worth: a cap smaller than the next file must
     * not stall the pipeline forever, and the anchor rule needs the folder to
     * stay populated.
     */
    fun sliceBytes(dailyCapBytes: Long): Long {
        if (dailyCapBytes < 0) return -1L // unlimited
        if (dailyCapBytes == 0L) return 0L
        return ceil(dailyCapBytes.toDouble() / SLICES_PER_DAY).toLong().coerceAtLeast(1L)
    }

    /**
     * Whether a file of about [nextBytes] may still be replaced on this phone
     * today, with [replacedToday] written already. Replace on this phone has
     * no upload folder to pace - Ente uploads each replaced file as it backs
     * the album up - so the daily limit is kept where the files are written.
     * The first file of a day always fits, as in the folder (ReleasePlanner):
     * a file bigger than the limit would otherwise wait for ever.
     */
    fun replaceFitsToday(dailyCapBytes: Long, replacedToday: Long, nextBytes: Long): Boolean =
        dailyCapBytes < 0 || replacedToday <= 0L || replacedToday + nextBytes <= dailyCapBytes

    /** What is left of today's allowance after [releasedToday]. */
    fun remainingToday(dailyCapBytes: Long, releasedToday: Long): Long {
        if (dailyCapBytes < 0) return -1L
        return (dailyCapBytes - releasedToday).coerceAtLeast(0L)
    }

    /** Bytes this pass may actually send: the slice, capped by what is left. */
    fun allowanceNow(dailyCapBytes: Long, releasedToday: Long): Long {
        if (dailyCapBytes < 0) return -1L
        val left = remainingToday(dailyCapBytes, releasedToday)
        if (left <= 0) return 0L
        return minOf(sliceBytes(dailyCapBytes), left)
    }

    /**
     * At most this many days of unused allowance may be carried forward.
     *
     * A phone that was off for a week should not then push a week of uploads
     * in one afternoon - that is exactly the mobile-data bill the cap exists
     * to prevent. One extra day is enough to absorb a normal gap.
     */
    const val MAX_CATCH_UP_DAYS = 1

    /**
     * Today's allowance, including anything carried over from a day the app
     * could not use.
     */
    fun dailyBudgetWithCatchUp(dailyCapBytes: Long, carriedBytes: Long): Long {
        if (dailyCapBytes < 0) return -1L
        val maxCarry = dailyCapBytes * MAX_CATCH_UP_DAYS
        return dailyCapBytes + carriedBytes.coerceIn(0L, maxCarry)
    }

    /**
     * What yesterday left behind, given how much of its budget went unused.
     * Anything beyond the carry limit is simply forgotten.
     */
    fun carryForward(dailyCapBytes: Long, releasedYesterday: Long): Long {
        if (dailyCapBytes < 0) return 0L
        val unused = (dailyCapBytes - releasedYesterday).coerceAtLeast(0L)
        return unused.coerceAtMost(dailyCapBytes * MAX_CATCH_UP_DAYS)
    }

    /**
     * A queue longer than this is a backlog, not a steady state.
     *
     * Pacing buys per-file proof and it costs throughput: one copy at a time
     * is a handful of files a day. That trade is right once someone is caught
     * up - every new photo provable, and eventually reclaimable - and badly
     * wrong for a ten-year gallery that has not been through once yet. So a
     * backlog goes out at full slice speed on batch evidence, and pacing
     * takes over when the queue is short enough for it to be worth having.
     */
    const val BACKLOG_BURST_ITEMS = 20

    /**
     * How many copies this pass may release, or null for "no per-item limit"
     * (the byte slice still applies).
     *
     * Per-file proof needs the cloud app's byte counter, so where the user has
     * not granted Usage Access there is nothing to be gained by holding files
     * back at all. [pacingPossible] is false there, and while a copy timed
     * out without a grade (see [releaseLimit]).
     */
    fun releaseSlots(
        slotsFree: Int,
        stagedWaiting: Int,
        pacingPossible: Boolean
    ): Int? = when {
        !pacingPossible -> null
        stagedWaiting > BACKLOG_BURST_ITEMS -> null
        else -> slotsFree
    }

    /**
     * The release limit for this pass, from every released copy still
     * [EvidenceRules.Waiting] for per-file proof.
     *
     * A copy without a grade holds a slot until it times out, and a VERIFIED
     * one until its own window after verification ends: then the next copy
     * goes out. Nothing beside a graded copy can be proved by traffic, but
     * the queue does not wait for it to leave. An AGED copy holds no slot -
     * it may sit there for weeks. Neither graded kind ever lifts the limit:
     * copies released in bulk beside them would only become the next
     * blockers.
     *
     * The limit is lifted only while a copy without a grade has timed out.
     * That copy will not leave for days, and nothing released beside it can
     * be proved, so holding the queue for it would only stall it.
     */
    fun releaseLimit(
        waiting: List<EvidenceRules.Waiting>,
        now: Long,
        canMeasure: Boolean,
        cloudHasFreeUpOracle: Boolean,
        cleanStreak: Int,
        stagedWaiting: Int
    ): Int? {
        val held = waiting.mapNotNull { if (it.graded) it.verifiedAt else it.releasedAt }
        val stalled = waiting.any { !it.graded && isTimedOut(it.releasedAt, now) }
        return releaseSlots(
            slotsFree = slotsFree(held, now, cloudHasFreeUpOracle, cleanStreak),
            stagedWaiting = stagedWaiting,
            pacingPossible = canMeasure && !stalled
        )
    }

    /**
     * The confidence ladder.
     *
     * A fixed in-flight limit is either too cautious forever or too trusting
     * from the start. One file at a time proves the accounting works on this
     * phone and this cloud app; once it has been proved often enough there is
     * nothing left to learn from holding files back, and continuing to do so
     * just means a ten-year gallery never finishes.
     *
     * Each entry is "this many clean confirmations earns this many in flight".
     * [UNLIMITED_AFTER] confirmations releases freely, with one file in every
     * [SAMPLE_EVERY] sent alone so per-file proof keeps arriving.
     */
    val LADDER: List<Pair<Int, Int>> = listOf(
        10 to 8,
        50 to 32
    )

    const val UNLIMITED_AFTER = 200
    const val SAMPLE_EVERY = 20

    /**
     * In-flight limit for a given run of clean confirmations, or null for
     * "no per-item limit".
     *
     * [cleanStreak] is consecutive confirmations with no failure. Any failure
     * resets it, which drops the limit back down a rung on its own.
     */
    fun inFlightLimit(cloudHasFreeUpOracle: Boolean, cleanStreak: Int): Int? {
        if (cleanStreak >= UNLIMITED_AFTER) return null
        val earned = LADDER.lastOrNull { (needed, _) -> cleanStreak >= needed }?.second
        return earned ?: startingLimit(cloudHasFreeUpOracle)
    }

    /** Where every phone starts, before anything has been confirmed. */
    fun startingLimit(cloudHasFreeUpOracle: Boolean): Int =
        if (cloudHasFreeUpOracle) IN_FLIGHT_WITH_ORACLE else IN_FLIGHT_WITHOUT_ORACLE

    /**
     * How often to send one file alone, so per-file proof keeps arriving even
     * once the limit is high. Doubles in frequency after a failure, because
     * that is when evidence is worth most.
     */
    fun sampleEvery(recentFailure: Boolean): Int =
        if (recentFailure) SAMPLE_EVERY / 2 else SAMPLE_EVERY

    /** True when this release should go out on its own as a proof sample. */
    fun isSampleTurn(releasedSinceSample: Int, recentFailure: Boolean): Boolean =
        releasedSinceSample >= sampleEvery(recentFailure)

    /** A copy released this long ago has stopped being usable as paced proof. */
    fun isTimedOut(releasedAt: Long, now: Long): Boolean =
        now - releasedAt >= IN_FLIGHT_TIMEOUT_MS

    /**
     * How many more copies may go out now: the limit, minus those still
     * waiting, ignoring any that have already timed out.
     *
     * A timed-out copy frees its slot, but it is still in the folder, so
     * nothing released beside it can be proved alone. [releaseLimit] drops
     * the per-item limit while one is there: releases go on, and no paced
     * proof is claimed.
     */
    fun slotsFree(
        inFlightReleasedAt: List<Long>,
        now: Long,
        cloudHasFreeUpOracle: Boolean,
        cleanStreak: Int = 0
    ): Int {
        val waiting = inFlightReleasedAt.count { !isTimedOut(it, now) }
        val limit = inFlightLimit(cloudHasFreeUpOracle, cleanStreak) ?: return Int.MAX_VALUE
        return (limit - waiting).coerceAtLeast(0)
    }

    /**
     * Compression is never paced.
     *
     * The release queue holds copies back so their uploads can be told apart;
     * that has nothing to do with how fast files may be optimised. Tying the
     * two together was the throughput bug: a phone with one file in flight
     * also optimised one file at a time, so a full gallery would have taken
     * years. Optimising runs to the space caps and stops there.
     */
    fun compressionAllowed(stageBytes: Long, stageCapBytes: Long): Boolean =
        stageCapBytes <= 0 || stageBytes < stageCapBytes
}
