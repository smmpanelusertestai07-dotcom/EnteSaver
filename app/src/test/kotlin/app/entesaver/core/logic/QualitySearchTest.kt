package app.entesaver.core.logic

import kotlin.math.ln
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QualitySearchTest {

    private val mbps = 1_000_000L

    /** A clip whose copies score 86 at 8 Mbps and 12 points more for every doubling, as Android's AVC encoder does on a daylight pan. */
    private fun day(videoBps: Double): Double = (86 + 12 * ln(videoBps / (8.0 * mbps)) / ln(2.0)).coerceIn(0.0, 100.0)

    /** Copies made by an encoder that lands at [landing] times what it is asked for, never under [floorBps]. */
    private fun make(asked: Int, curve: (Double) -> Double, landing: Double = 1.0, floorBps: Double = 0.0): QualitySearch.Try {
        val rate = maxOf(asked * landing, floorBps)
        return QualitySearch.Try(asked, rate.toLong(), (rate * 40 / 8).toLong(), curve(rate))
    }

    /** Runs the search from [firstAsk] until it settles; the tries and how it ended. */
    private fun run(
        firstAsk: Int,
        curve: (Double) -> Double,
        target: Double = 86.0,
        sourceVideoBps: Long = 20 * mbps,
        landing: Double = 1.0,
        floorBps: Double = 0.0,
        maxTries: Int = 3
    ): Pair<List<QualitySearch.Try>, QualitySearch.Step> {
        val tries = mutableListOf(make(firstAsk, curve, landing, floorBps))
        while (true) {
            val step = QualitySearch.next(
                tries, target, maxBytes = sourceVideoBps * 40 / 8 * 9 / 10, maxVideoBps = sourceVideoBps * 85 / 100,
                minAskBps = 150_000, maxTries = maxTries
            )
            if (step !is QualitySearch.Step.Encode) return tries to step
            tries += make(step.askedBps, curve, landing, floorBps)
        }
    }

    @Test
    fun `a first copy above the target is brought down to the least that still reaches it`() {
        val (tries, end) = run((10 * mbps).toInt(), ::day)
        assertTrue(end is QualitySearch.Step.Keep)
        val kept = tries[(end as QualitySearch.Step.Keep).index]
        assertTrue("kept copy scores ${kept.score}", kept.score >= 86.0)
        assertTrue("kept copy is ${kept.videoBps}", kept.videoBps < 9 * mbps)
    }

    @Test
    fun `a first copy below the target is followed by one above it, then the line between them`() {
        val (tries, end) = run((4 * mbps).toInt(), ::day)
        assertEquals(3, tries.size)
        assertTrue(tries[1].score >= 86.0)
        val kept = tries[(end as QualitySearch.Step.Keep).index]
        assertTrue("kept copy scores ${kept.score}", kept.score >= 86.0)
        // The line through 4 and 12 Mbps lands on the clip's own 8 Mbps, to within a tenth.
        assertEquals(8.0 * mbps, kept.videoBps.toDouble(), 0.8 * mbps)
    }

    @Test
    fun `a forward that would need more than a copy may carry stays as it is after one try`() {
        val forward = { bps: Double -> (86 + 12 * ln(bps / 1_500_000.0) / ln(2.0)).coerceIn(0.0, 100.0) }
        val (tries, end) = run(935_000, forward, sourceVideoBps = 1_100_000)
        assertEquals(1, tries.size)
        assertEquals(QualitySearch.Step.Original, end)
    }

    @Test
    fun `an encoder that lands at half again what it is asked for is asked for less`() {
        val (tries, end) = run((8 * mbps).toInt(), ::day, landing = 1.5)
        val kept = tries[(end as QualitySearch.Step.Keep).index]
        assertTrue(kept.score >= 86.0)
        assertTrue("kept ${kept.videoBps}", kept.videoBps < 9 * mbps)
        assertTrue(tries.drop(1).all { it.askedBps < it.videoBps })
    }

    @Test
    fun `an encoder that cannot go below its floor is followed up to the most a copy may carry, then back`() {
        // Fast motion: 63 at the encoder's floor of 5.6 Mbps, 86 at 12.
        val motion = { bps: Double -> (86 + 20 * ln(bps / (12.0 * mbps)) / ln(2.0)).coerceIn(0.0, 100.0) }
        val (tries, end) = run((1.9 * mbps).toInt(), motion, sourceVideoBps = 19 * mbps, floorBps = 5.6 * mbps)
        val kept = tries[(end as QualitySearch.Step.Keep).index]
        assertTrue(kept.score >= 86.0)
        assertTrue("kept ${kept.videoBps}", kept.videoBps <= 19 * mbps * 85 / 100)
    }

    @Test
    fun `no copy is kept that weighs more than the caller allows`() {
        val tries = listOf(QualitySearch.Try(18_000_000, 18_000_000, 100, 99.0))
        val step = QualitySearch.next(tries, 86.0, maxBytes = 99, maxVideoBps = 17_000_000, minAskBps = 150_000, maxTries = 1)
        assertEquals(QualitySearch.Step.Original, step)
    }

    @Test
    fun `the smallest passing copy is kept when the tries run out`() {
        val tries = listOf(
            QualitySearch.Try(10_000_000, 10_000_000, 1000, 90.0),
            QualitySearch.Try(7_000_000, 7_000_000, 700, 86.2),
            QualitySearch.Try(6_000_000, 6_000_000, 600, 85.0)
        )
        val step = QualitySearch.next(tries, 86.0, maxBytes = 2000, maxVideoBps = 17_000_000, minAskBps = 150_000, maxTries = 3)
        assertEquals(QualitySearch.Step.Keep(1), step)
    }

    @Test
    fun `a copy is not made again at a rate already tried`() {
        val tries = listOf(
            QualitySearch.Try(8_000_000, 8_000_000, 800, 85.9),
            QualitySearch.Try(8_200_000, 8_200_000, 820, 86.3)
        )
        val step = QualitySearch.next(tries, 86.0, maxBytes = 2000, maxVideoBps = 17_000_000, minAskBps = 150_000, maxTries = 5)
        assertEquals(QualitySearch.Step.Keep(1), step)
    }
}
