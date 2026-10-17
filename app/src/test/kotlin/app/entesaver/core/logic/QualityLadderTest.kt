package app.entesaver.core.logic

import app.entesaver.core.logic.QualityLadder.Point
import app.entesaver.core.logic.QualityLadder.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QualityLadderTest {

    private val target = 0.95
    private val video = QualityLadder.VIDEO

    @Test
    fun `a video starts at the standard rate`() {
        assertEquals(Step.Probe(1.0), video.next(emptyList(), target))
    }

    @Test
    fun `an easy video walks down while it still passes`() {
        assertEquals(Step.Probe(0.7), video.next(listOf(Point(1.0, 0.97)), target))
        assertEquals(Step.Probe(0.5), video.next(listOf(Point(1.0, 0.97), Point(0.7, 0.96)), target))
        assertEquals(Step.Encode(0.5), video.next(listOf(Point(1.0, 0.97), Point(0.7, 0.96), Point(0.5, 0.955)), target))
    }

    @Test
    fun `when the cheaper rung fails, the one above it is kept`() {
        assertEquals(Step.Encode(0.7), video.next(listOf(Point(1.0, 0.97), Point(0.7, 0.96), Point(0.5, 0.93)), target))
        assertEquals(Step.Encode(1.0), video.next(listOf(Point(1.0, 0.96), Point(0.7, 0.93)), target))
    }

    @Test
    fun `a hard video climbs, and is kept at the rung that passed`() {
        assertEquals(Step.Probe(1.4), video.next(listOf(Point(1.0, 0.92)), target))
        assertEquals(Step.Encode(1.4), video.next(listOf(Point(1.0, 0.92), Point(1.4, 0.951)), target))
    }

    @Test
    fun `a video that fails twice gets the top rung, measured or not`() {
        assertEquals(Step.Probe(2.0), video.next(listOf(Point(1.0, 0.90), Point(1.4, 0.93)), target))
        assertEquals(Step.Encode(2.0), video.next(listOf(Point(1.0, 0.90), Point(1.4, 0.93), Point(2.0, 0.94)), target))
    }

    @Test
    fun `measuring cut short keeps what passed, or steps above what failed`() {
        assertEquals(1.0, video.settle(emptyList(), target), 0.0)
        assertEquals(0.7, video.settle(listOf(Point(1.0, 0.96), Point(0.7, 0.955)), target), 0.0)
        assertEquals(1.4, video.settle(listOf(Point(1.0, 0.90)), target), 0.0)
        assertEquals(2.0, video.settle(listOf(Point(2.0, 0.90)), target), 0.0)
    }

    @Test
    fun `every walk ends on one of the ladder's own rungs within its probes`() {
        val ssims = listOf(0.80, 0.94, 0.95, 0.99)
        for (ladder in listOf(video, QualityLadder.forPhoto(null)!!, QualityLadder.forPhoto(80)!!)) {
            for (a in ssims) for (b in ssims) for (c in ssims) {
                val answers = listOf(a, b, c)
                val points = mutableListOf<Point>()
                var step = ladder.next(points, target)
                while (step is Step.Probe) {
                    points += Point(step.share, answers[points.size])
                    step = ladder.next(points, target)
                }
                val share = (step as Step.Encode).share
                assertTrue("settled on $share", share in ladder.rungs)
                assertTrue("${points.size} probes", points.size <= ladder.maxProbes)
                assertTrue("measured twice", points.map { it.share }.distinct().size == points.size)
            }
        }
    }

    @Test
    fun `a photo walks down three rungs when every one looks right`() {
        val photo = QualityLadder.forPhoto(95)!!
        assertEquals(Step.Probe(78.0), photo.next(emptyList(), target))
        assertEquals(Step.Probe(70.0), photo.next(listOf(Point(78.0, 0.97)), target))
        assertEquals(Step.Probe(62.0), photo.next(listOf(Point(78.0, 0.97), Point(70.0, 0.96)), target))
        assertEquals(
            Step.Encode(70.0),
            photo.next(listOf(Point(78.0, 0.97), Point(70.0, 0.96), Point(62.0, 0.94)), target)
        )
    }

    @Test
    fun `a detailed photo climbs, and is kept at the rung that passed`() {
        val photo = QualityLadder.forPhoto(null)!!
        assertEquals(Step.Probe(85.0), photo.next(listOf(Point(78.0, 0.93)), target))
        assertEquals(Step.Encode(85.0), photo.next(listOf(Point(78.0, 0.93), Point(85.0, 0.955)), target))
    }

    @Test
    fun `a photo is never tried finer than its original was saved`() {
        assertEquals(listOf(62.0, 70.0, 78.0), QualityLadder.forPhoto(80)!!.rungs)
        assertEquals(70.0, QualityLadder.forPhoto(72)!!.first, 0.0)
        assertNull(QualityLadder.forPhoto(55))
    }
}
