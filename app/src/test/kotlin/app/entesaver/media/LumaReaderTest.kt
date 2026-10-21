package app.entesaver.media

import app.entesaver.core.logic.Vmaf
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * A copy is scored against its original the same way round and at the same
 * size: a frame turned as its file says it is shown, and a large one halved,
 * exactly - or a copy stored on its side would score as a different picture.
 */
class LumaReaderTest {

    private fun plane(width: Int, height: Int) =
        Vmaf.Plane(ByteArray(width * height) { (it % 251).toByte() }, width, height)

    @Test
    fun `a quarter turn clockwise brings the bottom-left corner to the top-left`() {
        val p = plane(40, 32)
        val t = LumaReader.turned(p, 90)
        assertEquals(32, t.width)
        assertEquals(40, t.height)
        assertEquals("top-left", p.pixels[31 * 40], t.pixels[0])
        assertEquals("top-right", p.pixels[0], t.pixels[31])
        assertEquals("bottom-right", p.pixels[39], t.pixels[40 * 32 - 1])
    }

    @Test
    fun `turns add up, and turning back gives the frame as it was`() {
        val p = plane(40, 32)
        var t = p
        repeat(4) { t = LumaReader.turned(t, 90) }
        assertArrayEquals(p.pixels, t.pixels)
        assertArrayEquals(p.pixels, LumaReader.turned(LumaReader.turned(p, 90), -90).pixels)
        assertArrayEquals(p.pixels, LumaReader.turned(LumaReader.turned(p, 180), 180).pixels)
        assertArrayEquals(LumaReader.turned(p, 270).pixels, LumaReader.turned(p, -90).pixels)
        assertSame("no turn is the same frame", p, LumaReader.turned(p, 360))
    }

    @Test
    fun `a 4K frame is read at 1080p, each pixel the mean of its square of four`() {
        val pixels = ByteArray(3840 * 2160)
        pixels[0] = 10
        pixels[1] = 20
        pixels[3840] = 30
        pixels[3841] = 41
        val h = LumaReader.halved(Vmaf.Plane(pixels, 3840, 2160))
        assertEquals(1920, h.width)
        assertEquals(1080, h.height)
        assertEquals("(10 + 20 + 30 + 41) / 4, rounded", 25, h.pixels[0].toInt())
        assertEquals(0, h.pixels[1].toInt())
    }

    @Test
    fun `a 1080p frame is read at its own size`() {
        val p = plane(1920, 1080)
        assertSame(p, LumaReader.halved(p))
    }
}
