package app.entesaver.core.logic

import java.util.zip.CRC32
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OptimisedMarkTest {

    private fun b(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    /** SOI, an APP1 (EXIF) of [exifLen] payload bytes, a DQT stub, then the scan. */
    private fun jpeg(exifLen: Int = 6): ByteArray {
        val app1 = b(0xFF, 0xE1, 0x00, exifLen + 2) + ByteArray(exifLen) { 0x45 }
        return b(0xFF, 0xD8) + app1 + b(0xFF, 0xDB, 0x00, 0x03, 0x00) + b(0xFF, 0xDA, 0x00, 0x02) + b(0x11, 0x22)
    }

    @Test
    fun `a JPEG gets its comment after the EXIF block, the rest untouched`() {
        val src = jpeg()
        val marked = OptimisedMark.markJpeg(src)!!
        val comAt = 2 + 4 + 6
        assertEquals(0xFF, marked[comAt].toInt() and 0xFF)
        assertEquals(0xFE, marked[comAt + 1].toInt() and 0xFF)
        val len = ((marked[comAt + 2].toInt() and 0xFF) shl 8) or (marked[comAt + 3].toInt() and 0xFF)
        assertEquals(OptimisedMark.TEXT, String(marked, comAt + 4, len - 2, Charsets.US_ASCII))
        assertArrayEquals(src.copyOfRange(0, comAt), marked.copyOfRange(0, comAt))
        assertArrayEquals(src.copyOfRange(comAt, src.size), marked.copyOfRange(comAt + 2 + len, marked.size))
        assertTrue(OptimisedMark.isMarked(marked))
        assertFalse(OptimisedMark.isMarked(src))
    }

    @Test
    fun `something that is not a JPEG is not marked as one`() {
        assertNull(OptimisedMark.markJpeg(b(0x89, 0x50, 0x4E, 0x47)))
        assertNull(OptimisedMark.markJpeg(b(0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x40)))
    }

    @Test
    fun `a PNG gets a valid text chunk straight after its header`() {
        val ihdrData = ByteArray(13) { it.toByte() }
        val ihdrCrc = CRC32().apply { update("IHDR".toByteArray()); update(ihdrData) }.value.toInt()
        val png = b(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) +
            b(0, 0, 0, 13) + "IHDR".toByteArray() + ihdrData + int(ihdrCrc) +
            b(0, 0, 0, 0) + "IEND".toByteArray() + b(0xAE, 0x42, 0x60, 0x82)
        val marked = OptimisedMark.markPng(png)!!
        val at = 33
        val len = readInt(marked, at)
        assertEquals("tEXt", String(marked, at + 4, 4, Charsets.US_ASCII))
        val data = marked.copyOfRange(at + 8, at + 8 + len)
        assertEquals("Comment\u0000${OptimisedMark.TEXT}", String(data, Charsets.US_ASCII))
        val crc = CRC32().apply { update("tEXt".toByteArray()); update(data) }.value.toInt()
        assertEquals(crc, readInt(marked, at + 8 + len))
        assertArrayEquals(png.copyOfRange(at, png.size), marked.copyOfRange(at + 12 + len, marked.size))
        assertTrue(OptimisedMark.isMarked(marked))
    }

    @Test
    fun `a video's metadata key is recognised wherever it sits`() {
        val tail = ByteArray(40) + OptimisedMark.VIDEO_KEY.toByteArray() + ByteArray(8)
        assertTrue(OptimisedMark.isMarked(ByteArray(64), tail))
        assertFalse(OptimisedMark.isMarked(ByteArray(64), ByteArray(64)))
    }

    private fun int(v: Int) = b(v ushr 24 and 0xFF, v ushr 16 and 0xFF, v ushr 8 and 0xFF, v and 0xFF)

    private fun readInt(a: ByteArray, at: Int) =
        ((a[at].toInt() and 0xFF) shl 24) or ((a[at + 1].toInt() and 0xFF) shl 16) or
            ((a[at + 2].toInt() and 0xFF) shl 8) or (a[at + 3].toInt() and 0xFF)
}
