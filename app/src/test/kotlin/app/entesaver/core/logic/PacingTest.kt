package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PacingTest {

    private val cap = 250L * 1_000_000 // 250 MB

    @Test
    fun `a slice is a twelfth of the day, rounded up`() {
        // Rounded up rather than down: twelve rounded-down slices would leave
        // a remainder that never goes out.
        val slice = Pacing.sliceBytes(cap)
        assertTrue(slice * Pacing.SLICES_PER_DAY >= cap)
        assertTrue((slice - 1) * Pacing.SLICES_PER_DAY < cap)
    }

    @Test
    fun `unlimited stays unlimited all the way through`() {
        assertEquals(-1L, Pacing.sliceBytes(-1))
        assertEquals(-1L, Pacing.remainingToday(-1, 999))
        assertEquals(-1L, Pacing.allowanceNow(-1, 999))
        assertEquals(-1L, Pacing.dailyBudgetWithCatchUp(-1, 500))
    }

    @Test
    fun `a slice is never zero, so one file can always move`() {
        // A cap smaller than the slice count must not round down to nothing,
        // or the pipeline would stall for good.
        assertTrue(Pacing.sliceBytes(5) >= 1)
    }

    @Test
    fun `allowance is capped by what is left of the day`() {
        val nearlySpent = cap - 1_000
        assertEquals(1_000L, Pacing.allowanceNow(cap, nearlySpent))
        assertEquals(0L, Pacing.allowanceNow(cap, cap))
        assertEquals(0L, Pacing.allowanceNow(cap, cap * 2))
    }

    @Test
    fun `without an oracle exactly one copy may be in flight`() {
        assertEquals(1, Pacing.inFlightLimit(cloudHasFreeUpOracle = false, cleanStreak = 0))
        assertEquals(4, Pacing.inFlightLimit(cloudHasFreeUpOracle = true, cleanStreak = 0))
    }

    @Test
    fun `a waiting copy holds the only slot`() {
        val now = 10_000_000L
        val justReleased = listOf(now - 60_000)
        assertEquals(0, Pacing.slotsFree(justReleased, now, cloudHasFreeUpOracle = false))
        assertEquals(3, Pacing.slotsFree(justReleased, now, cloudHasFreeUpOracle = true))
    }

    @Test
    fun `a timed-out copy stops blocking the queue`() {
        val now = 100_000_000L
        val stale = listOf(now - Pacing.IN_FLIGHT_TIMEOUT_MS - 1)
        assertTrue(Pacing.isTimedOut(stale.first(), now))
        assertEquals(1, Pacing.slotsFree(stale, now, cloudHasFreeUpOracle = false))
    }

    private val hour = 3_600_000L

    private fun limit(waiting: List<EvidenceRules.Waiting>, now: Long, staged: Int = 3) = Pacing.releaseLimit(
        waiting = waiting,
        now = now,
        canMeasure = true,
        cloudHasFreeUpOracle = false,
        cleanStreak = 0,
        stagedWaiting = staged
    )

    @Test
    fun `only a copy timed out without a grade lifts the limit`() {
        val now = 100_000_000L
        val fresh = EvidenceRules.Waiting(id = 2, releasedAt = now - 60_000, bytes = 1000, gone = false)
        val timedOut = fresh.copy(id = 1, releasedAt = now - Pacing.IN_FLIGHT_TIMEOUT_MS - 1)
        val aged = fresh.copy(id = 3, releasedAt = now - 12 * 24 * hour, graded = true)
        // A copy that can still be proved holds the slot for its proof...
        assertEquals(0, limit(listOf(fresh), now))
        // ...but one that timed out holds nothing back for days: releases go
        // on at the byte slice, and nothing beside it is ever paced-proved.
        assertNull(limit(listOf(timedOut), now))
        assertNull(limit(listOf(timedOut, fresh), now))
        assertNull(EvidenceRules.aloneInFlight(listOf(timedOut, fresh), emptyList(), now, tx = 1000))
        // An AGED copy holds no slot, but never lifts the limit: copies sent
        // in bulk beside it would only be the next ones nothing can judge.
        assertEquals(1, limit(listOf(aged), now))
        assertEquals(0, limit(listOf(aged, fresh), now))
        assertNull(EvidenceRules.aloneInFlight(listOf(aged, fresh), emptyList(), now, tx = 1000))
    }

    @Test
    fun `a VERIFIED copy left in the folder paces releases and proves nothing beside it`() {
        // Copy 1 went out alone, but Ente also sent camera photos, so it was
        // only VERIFIED by its batch - and it stays in the folder, below the
        // space cap, for weeks. Ente may still send it, or any part of it, at
        // any time.
        val verifiedAt = 50 * hour
        val v = EvidenceRules.Waiting(
            id = 1, releasedAt = verifiedAt - hour, bytes = 3_000_000, gone = false,
            graded = true, verifiedAt = verifiedAt
        )
        var waiting = listOf(v)
        var releasedAt: Long? = null
        // Hourly passes. Until its window ends the copy holds the one slot,
        // then the next copy holds it; never without a limit, which is how
        // bulk releases made more such copies.
        for (h in 1..10) {
            val now = verifiedAt + h * hour
            val slots = limit(waiting, now)
            assertTrue("pass $h: $slots", slots != null && slots <= 1)
            if (slots == 1 && releasedAt == null) {
                assertTrue("pass $h", now - verifiedAt >= Pacing.IN_FLIGHT_TIMEOUT_MS)
                releasedAt = now
                waiting = waiting + EvidenceRules.Waiting(id = 2, releasedAt = now, bytes = 3_000_000, gone = false)
            }
        }
        assertNotNull("a copy goes out once the window has ended", releasedAt)
        val now = releasedAt!! + 2 * hour
        // Whatever went out and whatever the sizes, copy 2 is not credited:
        // copy 1 may have sent any amount of it.
        for (bytes in listOf(1_000_000L, 3_000_000L, 10_000_000L)) {
            val sized = waiting.map { if (it.id == 2L) it.copy(bytes = bytes) else it }
            for (tx in listOf(bytes, v.bytes + bytes, (bytes * 1.2).toLong())) {
                assertNull("$bytes/$tx", EvidenceRules.aloneInFlight(sized, emptyList(), now, tx))
            }
        }
        // Copy 2 timing out unproved is what lifts the limit, not copy 1.
        assertNull(limit(waiting, releasedAt + Pacing.IN_FLIGHT_TIMEOUT_MS))
        // Upgraded from 12.1 with such a copy already there: it holds no
        // slot and never lifts the limit.
        val later = verifiedAt + 30 * 24 * hour
        val fresh = EvidenceRules.Waiting(id = 3, releasedAt = later, bytes = 3_000_000, gone = false)
        assertEquals(1, limit(listOf(v), later))
        assertEquals(0, limit(listOf(v, fresh), later))
        assertNull(EvidenceRules.aloneInFlight(listOf(v, fresh), emptyList(), later + hour, tx = 3_000_000))
    }

    @Test
    fun `releases keep flowing while graded copies block proof`() {
        // A folder of AGED and long-VERIFIED copies: nothing can be proved
        // by traffic beside them, and the queue does not wait for that. Each
        // copy released holds the slot for its own window, then the next
        // one goes out.
        val start = 100 * 24 * hour
        val blockers = listOf(
            EvidenceRules.Waiting(
                id = 1, releasedAt = start - 40 * 24 * hour, bytes = 40_000_000, gone = false, graded = true
            ),
            EvidenceRules.Waiting(
                id = 2, releasedAt = start - 40 * 24 * hour, bytes = 3_000_000, gone = false,
                graded = true, verifiedAt = start - 30 * 24 * hour
            )
        )
        var waiting = blockers
        var lastRelease = start - Pacing.IN_FLIGHT_TIMEOUT_MS
        for (h in 0 until 48) {
            val now = start + h * hour
            val slots = limit(waiting, now)
            if (slots == null || slots > 0) {
                lastRelease = now
                waiting = waiting + EvidenceRules.Waiting(id = 10L + h, releasedAt = now, bytes = 5_000_000, gone = false)
                assertNull(EvidenceRules.aloneInFlight(waiting, emptyList(), now + hour, tx = 5_000_000))
            }
            assertTrue("pass $h", now - lastRelease <= Pacing.IN_FLIGHT_TIMEOUT_MS)
        }
    }

    @Test
    fun `an unused day carries forward, but only one`() {
        assertEquals(cap, Pacing.carryForward(cap, releasedYesterday = 0))
        assertEquals(cap / 2, Pacing.carryForward(cap, releasedYesterday = cap / 2))
        assertEquals(0L, Pacing.carryForward(cap, releasedYesterday = cap))
        // Yesterday cannot leave more than a full day behind.
        assertTrue(Pacing.carryForward(cap, releasedYesterday = -1) <= cap)
    }

    @Test
    fun `catch-up never lets a week of uploads land in one afternoon`() {
        val carried = cap * 7
        assertEquals(cap * 2, Pacing.dailyBudgetWithCatchUp(cap, carried))
    }

    @Test
    fun `a backlog is not paced, because throughput matters more`() {
        // One copy at a time on a ten-year gallery would never finish; those
        // go out at slice speed and settle for batch evidence.
        assertEquals(
            null,
            Pacing.releaseSlots(
                slotsFree = 0,
                stagedWaiting = Pacing.BACKLOG_BURST_ITEMS + 1,
                pacingPossible = true
            )
        )
    }

    @Test
    fun `a short queue is paced, so each file can be proved`() {
        assertEquals(
            1,
            Pacing.releaseSlots(slotsFree = 1, stagedWaiting = 3, pacingPossible = true)
        )
        assertEquals(
            0,
            Pacing.releaseSlots(slotsFree = 0, stagedWaiting = 3, pacingPossible = true)
        )
    }

    @Test
    fun `without a way to measure, pacing buys nothing and is skipped`() {
        assertEquals(
            null,
            Pacing.releaseSlots(slotsFree = 0, stagedWaiting = 1, pacingPossible = false)
        )
    }

    @Test
    fun `a spent day gives no allowance even with catch-up`() {
        val budget = Pacing.dailyBudgetWithCatchUp(cap, cap)
        assertEquals(0L, Pacing.allowanceNow(budget, budget))
        assertFalse(Pacing.allowanceNow(budget, budget / 2) == 0L)
    }

    @Test
    fun `the ladder climbs as confirmations prove the accounting works`() {
        // One at a time until the phone has shown it can be accounted for.
        assertEquals(1, Pacing.inFlightLimit(false, cleanStreak = 0))
        assertEquals(1, Pacing.inFlightLimit(false, cleanStreak = 9))
        assertEquals(8, Pacing.inFlightLimit(false, cleanStreak = 10))
        assertEquals(8, Pacing.inFlightLimit(false, cleanStreak = 49))
        assertEquals(32, Pacing.inFlightLimit(false, cleanStreak = 50))
        assertEquals(32, Pacing.inFlightLimit(false, cleanStreak = 199))
        // Past the top rung there is no per-item limit left to apply.
        assertNull(Pacing.inFlightLimit(false, cleanStreak = 200))
        assertNull(Pacing.inFlightLimit(false, cleanStreak = 5_000))
    }

    @Test
    fun `a cloud with an oracle starts higher but climbs the same ladder`() {
        assertEquals(4, Pacing.inFlightLimit(true, cleanStreak = 0))
        assertEquals(8, Pacing.inFlightLimit(true, cleanStreak = 10))
        assertNull(Pacing.inFlightLimit(true, cleanStreak = 200))
    }

    @Test
    fun `a failure drops the limit back to the bottom`() {
        // The engine resets the streak on any failure, so the ladder position
        // is a pure function of it: nothing else needs to remember the drop.
        assertEquals(32, Pacing.inFlightLimit(false, cleanStreak = 60))
        assertEquals(1, Pacing.inFlightLimit(false, cleanStreak = 0))
    }

    @Test
    fun `samples keep arriving once the limit is high, twice as often after a failure`() {
        assertEquals(20, Pacing.sampleEvery(recentFailure = false))
        assertEquals(10, Pacing.sampleEvery(recentFailure = true))
        assertFalse(Pacing.isSampleTurn(releasedSinceSample = 19, recentFailure = false))
        assertTrue(Pacing.isSampleTurn(releasedSinceSample = 20, recentFailure = false))
        assertTrue(Pacing.isSampleTurn(releasedSinceSample = 10, recentFailure = true))
    }

    @Test
    fun `slots are unbounded once the ladder is topped out`() {
        val now = 1_000_000L
        val many = List(100) { now }
        assertEquals(Int.MAX_VALUE, Pacing.slotsFree(many, now, false, cleanStreak = 200))
    }

    @Test
    fun `compression is never limited by the release queue`() {
        // The throughput bug this guards: one file in flight also meant one
        // file optimised at a time, so a full gallery would take years.
        assertTrue(Pacing.compressionAllowed(stageBytes = 0, stageCapBytes = 1_000))
        assertTrue(Pacing.compressionAllowed(stageBytes = 999, stageCapBytes = 1_000))
        assertFalse(Pacing.compressionAllowed(stageBytes = 1_000, stageCapBytes = 1_000))
        // No cap configured means no limit at all.
        assertTrue(Pacing.compressionAllowed(stageBytes = 9_999_999, stageCapBytes = 0))
    }

    @Test
    fun `replace on this phone keeps to the daily limit, and the day's first file always fits`() {
        val mb = 1_048_576L
        assertTrue("unlimited", Pacing.replaceFitsToday(-1, 50_000 * mb, 900 * mb))
        assertTrue("within the limit", Pacing.replaceFitsToday(500 * mb, 300 * mb, 150 * mb))
        assertTrue("up to it exactly", Pacing.replaceFitsToday(500 * mb, 300 * mb, 200 * mb))
        assertFalse("past it waits for tomorrow", Pacing.replaceFitsToday(500 * mb, 300 * mb, 201 * mb))
        // A clip bigger than the whole limit would otherwise never be done.
        assertTrue(Pacing.replaceFitsToday(500 * mb, 0, 2_000 * mb))
    }

    @Test
    fun `the daily limit is counted where a file is replaced, and kept by scheduled runs`() {
        val stager = java.io.File("src/main/kotlin/app/entesaver/media/Stager.kt").readText()
        assertTrue(stager.contains("DayBudget(context).addReplaced(now, outcome.bytes)"))
        val worker = java.io.File("src/main/kotlin/app/entesaver/work/CompressWorker.kt").readText()
        assertTrue(worker.contains("live.saveMode == SaveMode.IN_PLACE && !manual &&"))
        assertTrue(worker.contains("RunDecider.Wait.DAILY_LIMIT.name"))
    }
}
