package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * An original is compared with its copy in the copy's colour, worked out as
 * ffmpeg works it out before the savings benchmark's libvmaf scores the two:
 * the tables and sums here are checked against ffmpeg 7.0.2's own output.
 */
class RecolourTest {

    private val bt601 = Recolour.Space(Recolour.Matrix.BT601, full = false)
    private val bt709 = Recolour.Space(Recolour.Matrix.BT709, full = false)

    @Test
    fun `the same colour reads the same`() {
        assertNull(Recolour.change(bt601, bt601))
        assertNull(Recolour.change(bt709.copy(full = true), bt709.copy(full = true)))
    }

    @Test
    fun `a full-range level is squeezed into 16 to 235 as ffmpeg squeezes it`() {
        val t = (Recolour.change(bt709.copy(full = true), bt709) as Recolour.Levels).table
        val ffmpeg = intArrayOf(16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 25, 26, 27, 28, 29, 30, 31, 31, 32)
        for (level in ffmpeg.indices) assertEquals("level $level", ffmpeg[level], t[level].toInt() and 0xFF)
        assertEquals(235, t[255].toInt() and 0xFF)
        assertEquals(234, t[254].toInt() and 0xFF)
    }

    @Test
    fun `a limited-range level is stretched over 0 to 255 as ffmpeg stretches it`() {
        val t = (Recolour.change(bt709, bt709.copy(full = true)) as Recolour.Levels).table
        val ffmpeg = mapOf(0 to 0, 16 to 0, 17 to 1, 18 to 2, 19 to 3, 20 to 5, 23 to 8, 228 to 247, 232 to 252, 235 to 255, 255 to 255)
        for ((level, out) in ffmpeg) assertEquals("level $level", out, t[level].toInt() and 0xFF)
    }

    @Test
    fun `grey keeps its brightness whatever the proportions, less what rounding down takes`() {
        val through = Recolour.change(bt601, bt709) as Recolour.Through
        for (y in 16..235) assertTrue("grey $y", through.luma(y, 128, 128) in y - 1..y)
        assertEquals(16, through.luma(16, 128, 128))
        assertEquals(235, through.luma(235, 128, 128))
    }

    @Test
    fun `a BT601 colour reads in BT709 as through eight-bit red, green and blue`() {
        val through = Recolour.change(bt601, bt709) as Recolour.Through
        // Red: brightness 81, blue-difference 90, red-difference 240 (BT.601's
        // 255, 0, 0) is BT.709's 62; a strong blue and a strong green move the
        // other way and further.
        assertEquals(62, through.luma(81, 90, 240))
        assertEquals(32, through.luma(41, 240, 110))
        assertEquals(173, through.luma(145, 54, 34))
        // Brightness below 16 or above 235 stands for no red, green or blue
        // beyond 0 and 255: it reads at the end of the range.
        assertEquals(16, through.luma(5, 128, 128))
        assertEquals(235, through.luma(250, 128, 128))
    }

    @Test
    fun `a pixel's colour moves its brightness by BT601 against BT709's proportions`() {
        val through = Recolour.change(bt601, bt709) as Recolour.Through
        // Within the colours red, green and blue can show, the move is linear:
        // about -0.116 of blue-difference and -0.208 of red-difference.
        val moved = through.luma(120, 140, 150) - 120
        val expected = -0.11555 * 12 - 0.20794 * 22
        assertTrue("moved $moved, expected about $expected", kotlin.math.abs(moved - expected) <= 1.0)
    }
}
