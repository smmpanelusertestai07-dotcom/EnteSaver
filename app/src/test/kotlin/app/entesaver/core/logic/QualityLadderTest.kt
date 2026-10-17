package app.entesaver.core.logic

import app.entesaver.core.logic.QualityLadder.Point
import app.entesaver.core.logic.QualityLadder.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QualityLadderTest {

    private val target = 0.95

    @Test
    fun `a video starts at the middle rung`() {
        assertEquals(Step.Probe(0.7), QualityLadder.next(emptyList(), target))
    }

    @Test
    fun `an easy video that passes the middle tries the rung below`() {
        assertEquals(Step.Probe(0.5), QualityLadder.next(listOf(Point(0.7, 0.97)), target))
    }

    @Test
    fun `an easy video gets the cheapest rung that still passes`() {
        assertEquals(Step.Encode(0.5), QualityLadder.next(listOf(Point(0.7, 0.97), Point(0.5, 0.955)), target))
    }

    @Test
    fun `when the cheaper rung fails, the middle one is kept`() {
        assertEquals(Step.Encode(0.7), QualityLadder.next(listOf(Point(0.7, 0.96), Point(0.5, 0.93)), target))
    }

    @Test
    fun `a hard video that fails the middle tries the standard rate`() {
        assertEquals(Step.Probe(1.0), QualityLadder.next(listOf(Point(0.7, 0.92)), target))
    }

    @Test
    fun `a hard video that passes at the standard rate is encoded there`() {
        assertEquals(Step.Encode(1.0), QualityLadder.next(listOf(Point(0.7, 0.92), Point(1.0, 0.951)), target))
    }

    @Test
    fun `a video that fails even the standard rate gets the top rung`() {
        assertEquals(Step.Encode(1.3), QualityLadder.next(listOf(Point(0.7, 0.90), Point(1.0, 0.93)), target))
    }

    @Test
    fun `measuring cut short keeps what passed, or steps above what failed`() {
        assertEquals(QualityLadder.UNPROBED, QualityLadder.settle(emptyList(), target), 0.0)
        assertEquals(0.7, QualityLadder.settle(listOf(Point(0.7, 0.96)), target), 0.0)
        assertEquals(1.0, QualityLadder.settle(listOf(Point(0.7, 0.90)), target), 0.0)
        assertEquals(1.3, QualityLadder.settle(listOf(Point(1.3, 0.90)), target), 0.0)
    }

    @Test
    fun `every rung the ladder settles on is one of its rungs`() {
        val ssims = listOf(0.80, 0.94, 0.95, 0.99)
        for (a in ssims) for (b in ssims) {
            var points = listOf<Point>()
            var step = QualityLadder.next(points, target)
            while (step is Step.Probe) {
                val share = step.share
                points = points + Point(share, if (points.isEmpty()) a else b)
                step = QualityLadder.next(points, target)
            }
            val share = (step as Step.Encode).share
            assertTrue("settled on $share", QualityLadder.RUNGS.any { it == share })
            assertTrue("${points.size} probes", points.size <= 2)
        }
    }
}
