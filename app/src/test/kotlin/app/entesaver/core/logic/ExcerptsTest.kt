package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ExcerptsTest {

    @Test
    fun `a clip of five minutes or less is searched on whole`() {
        assertTrue(Excerpts.windows(Excerpts.ABOVE_MS).isEmpty())
        assertTrue(Excerpts.windows(60_000).isEmpty())
    }

    @Test
    fun `a long clip gets stretches spread evenly, each as long as the rest, inside the clip`() {
        val duration = 26 * 60_000L
        val windows = Excerpts.windows(duration)
        assertEquals(Excerpts.COUNT, windows.size)
        windows.forEach { assertEquals(Excerpts.LENGTH_MS, it.last - it.first) }
        // A quarter, a half and three quarters of the way through.
        assertEquals(duration / 4, (windows[0].first + windows[0].last) / 2)
        assertEquals(duration / 2, (windows[1].first + windows[1].last) / 2)
        assertTrue(windows.zipWithNext().all { (a, b) -> a.last < b.first })
        assertTrue(windows.first().first > 0 && windows.last().last < duration)
    }

    @Test
    fun `stretches stay inside a clip not much longer than they are`() {
        val windows = Excerpts.windows(20_000, aboveMs = 1_000)
        assertEquals(Excerpts.COUNT, windows.size)
        assertTrue(windows.all { it.first >= 0 && it.last <= 20_000 && it.last - it.first == Excerpts.LENGTH_MS })
        // Shorter than one stretch: none at all.
        assertTrue(Excerpts.windows(9_000, aboveMs = 1_000).isEmpty())
    }
}
