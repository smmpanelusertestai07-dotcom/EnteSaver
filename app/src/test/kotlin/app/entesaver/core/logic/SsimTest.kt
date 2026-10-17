package app.entesaver.core.logic

import java.util.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SsimTest {

    private fun plane(w: Int, h: Int, f: (Int, Int) -> Int) =
        ByteArray(w * h) { i -> f(i % w, i / w).coerceIn(0, 255).toByte() }

    private val w = 96
    private val h = 64
    private val picture = plane(w, h) { x, y -> (x * 3 + y * 2 + ((x / 8 + y / 8) % 2) * 40) % 256 }

    @Test
    fun `a picture is identical to itself`() {
        assertEquals(1.0, Ssim.of(picture, picture.copyOf(), w, h), 1e-9)
    }

    @Test
    fun `more damage scores lower`() {
        val rnd = Random(7)
        fun noisy(amp: Int) = ByteArray(picture.size) { i ->
            ((picture[i].toInt() and 0xFF) + rnd.nextInt(2 * amp + 1) - amp).coerceIn(0, 255).toByte()
        }
        val light = Ssim.of(picture, noisy(4), w, h)
        val heavy = Ssim.of(picture, noisy(40), w, h)
        assertTrue("light noise $light should stay high", light > 0.9)
        assertTrue("heavy noise $heavy should score lower than light $light", heavy < light)
    }

    @Test
    fun `blur is caught, not only noise`() {
        val blurred = plane(w, h) { x, y ->
            var s = 0
            for (dy in -2..2) for (dx in -2..2) {
                val xx = (x + dx).coerceIn(0, w - 1)
                val yy = (y + dy).coerceIn(0, h - 1)
                s += picture[yy * w + xx].toInt() and 0xFF
            }
            s / 25
        }
        assertTrue(Ssim.of(picture, blurred, w, h) < 0.95)
    }

    @Test
    fun `a plane smaller than a window still compares`() {
        val a = plane(5, 3) { x, y -> x * 20 + y }
        assertEquals(1.0, Ssim.of(a, a.copyOf(), 5, 3), 1e-9)
    }

    @Test
    fun `luma follows the BT601 weights`() {
        val luma = Ssim.lumaOf(intArrayOf(0xFFFFFFFF.toInt(), 0xFF000000.toInt(), 0xFFFF0000.toInt()))
        assertEquals(255, luma[0].toInt() and 0xFF)
        assertEquals(0, luma[1].toInt() and 0xFF)
        assertEquals(76, luma[2].toInt() and 0xFF)
    }
}
