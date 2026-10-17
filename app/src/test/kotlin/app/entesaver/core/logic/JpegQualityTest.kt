package app.entesaver.core.logic

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class JpegQualityTest {

    private val std = intArrayOf(
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99
    )

    /** libjpeg's own scaling of the standard table to [q]. */
    private fun tableAt(q: Int): IntArray {
        val scale = if (q < 50) 5000 / q else 200 - 2 * q
        return IntArray(64) { ((std[it] * scale + 50) / 100).coerceIn(1, 255) }
    }

    /** The head of a JPEG as an encoder writes it: SOI, APP0, a DQT for each table, then the scan. */
    private fun jpegHead(vararg tables: Pair<Int, IntArray>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(byteArrayOf(0xFF.toByte(), 0xD8.toByte()))
        val app0 = byteArrayOf(0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00)
        out.write(byteArrayOf(0xFF.toByte(), 0xE0.toByte(), 0x00, (app0.size + 2).toByte()))
        out.write(app0)
        for ((id, table) in tables) {
            out.write(byteArrayOf(0xFF.toByte(), 0xDB.toByte(), 0x00, 67))
            out.write(id)
            for (v in table) out.write(v)
        }
        out.write(byteArrayOf(0xFF.toByte(), 0xDA.toByte(), 0x00, 0x08))
        return out.toByteArray()
    }

    @Test
    fun `the quality a JPEG was written at is read back from its table`() {
        for (q in listOf(30, 50, 70, 82, 90, 95, 100)) {
            assertEquals(q, JpegQuality.estimate(ByteArrayInputStream(jpegHead(0 to tableAt(q), 1 to tableAt(q)))))
        }
    }

    @Test
    fun `the luminance table is the one read, whatever follows`() {
        assertEquals(92, JpegQuality.estimate(ByteArrayInputStream(jpegHead(1 to tableAt(40), 0 to tableAt(92)))))
    }

    @Test
    fun `the standard table itself is quality 50`() {
        assertEquals(50, JpegQuality.estimateFromTable(std))
    }

    @Test
    fun `a file that is not a JPEG has no quality`() {
        assertNull(JpegQuality.estimate(ByteArrayInputStream(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47))))
        assertNull(JpegQuality.estimate(ByteArrayInputStream(byteArrayOf())))
    }

    @Test
    fun `a JPEG cut off before its table has no quality`() {
        val full = jpegHead(0 to tableAt(80))
        assertNull(JpegQuality.estimate(ByteArrayInputStream(full.copyOf(12))))
    }
}
