package app.entesaver.core.logic

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaceBoxTest {

    private fun box(type: String, vararg parts: ByteArray): ByteArray {
        val body = parts.fold(ByteArray(0)) { a, b -> a + b }
        return ByteBuffer.allocate(8 + body.size).putInt(8 + body.size)
            .put(type.toByteArray(Charsets.ISO_8859_1)).put(body).array()
    }

    /** A ©xyz box as a camera writes one: text length, language, then the place. */
    private fun xyz(place: String): ByteArray {
        val text = place.toByteArray(Charsets.US_ASCII)
        return box(PlaceBox.XYZ, ByteBuffer.allocate(4).putShort(text.size.toShort()).putShort(0x15C7).array(), text)
    }

    private val camera = xyz("+28.6139+077.2090/")
    private val media3 = xyz("+28.6139+77.2090/")
    private val mvhd = box("mvhd", ByteArray(100) { 1 })
    private val trak = box("trak", box("tkhd", ByteArray(84) { 2 }))

    /** Where a box of [type] starts among a file's top-level boxes, and its size. */
    private fun topBox(file: ByteArray, type: String): Pair<Int, Int>? {
        var pos = 0
        while (pos + 8 <= file.size) {
            val b = ByteBuffer.wrap(file)
            var size = b.getInt(pos).toLong() and 0xFFFFFFFFL
            if (size == 1L) size = b.getLong(pos + 8)
            if (String(file, pos + 4, 4, Charsets.ISO_8859_1) == type) return pos to size.toInt()
            pos += size.toInt()
        }
        return null
    }

    private fun contains(hay: ByteArray, needle: ByteArray): Boolean =
        (0..hay.size - needle.size).any { i -> needle.indices.all { hay[i + it] == needle[it] } }

    /** An mdat as Media3 writes one: a 64-bit size, then the picture and sound. */
    private fun mdat(payload: Int): ByteArray =
        ByteBuffer.allocate(16 + payload).putInt(1).put("mdat".toByteArray(Charsets.ISO_8859_1))
            .putLong(16L + payload).put(ByteArray(payload) { 7 }).array()

    private fun restored(file: ByteArray, xyz: ByteArray = camera): Pair<Boolean, ByteArray> {
        val f = File.createTempFile("place", ".mp4")
        try {
            f.writeBytes(file)
            val ok = RandomAccessFile(f, "rw").use { PlaceBox.restore(it.channel, xyz, 1 shl 20) }
            return ok to f.readBytes()
        } finally {
            f.delete()
        }
    }

    @Test
    fun `the camera's own place box replaces Media3's in the index`() {
        val moov = box("moov", mvhd, box("udta", media3), trak)
        val out = PlaceBox.withPlace(moov, camera)
        assertNotNull(out)
        assertArrayEquals(box("moov", mvhd, box("udta", camera), trak), out)
    }

    @Test
    fun `an index without a place gets the camera's, after the movie header`() {
        val moov = box("moov", mvhd, trak)
        assertArrayEquals(box("moov", mvhd, box("udta", camera), trak), PlaceBox.withPlace(moov, camera))
        // Other notes in the user data stay as they are.
        val other = box("cprt", ByteArray(6))
        assertArrayEquals(
            box("moov", mvhd, box("udta", other, camera), trak),
            PlaceBox.withPlace(box("moov", mvhd, box("udta", other), trak), camera)
        )
    }

    @Test
    fun `an index this cannot read is left alone`() {
        assertNull(PlaceBox.withPlace(ByteArray(4), camera))
        val broken = box("moov", mvhd).also { ByteBuffer.wrap(it).putInt(8, 9999) }
        assertNull(PlaceBox.withPlace(broken, camera))
        // Not a place box at all.
        assertNull(PlaceBox.withPlace(box("moov", mvhd), box("abcd", ByteArray(4))))
    }

    @Test
    fun `an index at the front grows into the free box after it, and the picture does not move`() {
        val xmp = box("uuid", ByteArray(40) { 3 })
        val moov = box("moov", mvhd, box("udta", media3), trak)
        val file = box("ftyp", ByteArray(20)) + box("free", ByteArray(64)) + moov + xmp +
            box("free", ByteArray(300)) + mdat(5000)
        val (ok, out) = restored(file)
        assertTrue(ok)
        assertEquals(file.size, out.size)
        assertEquals(topBox(file, "mdat"), topBox(out, "mdat"))
        assertArrayEquals(file.copyOfRange(topBox(file, "mdat")!!.first, file.size), out.copyOfRange(topBox(out, "mdat")!!.first, out.size))
        val (at, size) = topBox(out, "moov")!!
        assertArrayEquals(box("moov", mvhd, box("udta", camera), trak), out.copyOfRange(at, at + size))
        // The XMP moved along with it, and the free box is one byte smaller.
        assertTrue(contains(out, xmp))
        assertEquals(308 - 1, topBox(out.copyOfRange(at + size + xmp.size, out.size), "free")!!.second)
    }

    @Test
    fun `an index at the end grows the file, and a shorter place shrinks it`() {
        val moov = box("moov", mvhd, box("udta", media3), trak)
        val file = box("ftyp", ByteArray(20)) + box("free", ByteArray(64)) + mdat(5000) + moov
        val (ok, out) = restored(file)
        assertTrue(ok)
        assertEquals(file.size + 1, out.size)
        assertEquals(topBox(file, "mdat"), topBox(out, "mdat"))
        val (at, size) = topBox(out, "moov")!!
        assertArrayEquals(box("moov", mvhd, box("udta", camera), trak), out.copyOfRange(at, at + size))

        val (back, again) = restored(out, media3)
        assertTrue(back)
        assertArrayEquals(file, again)
    }

    @Test
    fun `without room for the place, or in a layout Media3 does not write, the file stays as it was`() {
        val moov = box("moov", mvhd, box("udta", media3), trak)
        // A free box of 8 bytes cannot give one and still be a box.
        val tight = box("ftyp", ByteArray(20)) + moov + box("free") + mdat(100)
        val (ok, out) = restored(tight)
        assertFalse(ok)
        assertArrayEquals(tight, out)
        // The index straight before the picture: nowhere to grow.
        val packed = box("ftyp", ByteArray(20)) + moov + mdat(100)
        val (ok2, out2) = restored(packed)
        assertFalse(ok2)
        assertArrayEquals(packed, out2)
    }

    @Test
    fun `a place already the same changes nothing`() {
        val file = box("ftyp", ByteArray(20)) + box("moov", mvhd, box("udta", camera), trak) + box("free", ByteArray(16)) + mdat(10)
        val (ok, out) = restored(file)
        assertTrue(ok)
        assertArrayEquals(file, out)
    }
}
