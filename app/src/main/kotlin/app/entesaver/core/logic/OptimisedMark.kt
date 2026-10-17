package app.entesaver.core.logic

import java.util.zip.CRC32

/**
 * The note an optimised file carries, so it is never optimised twice.
 *
 * The app's own records say which files it has made, but records go with an
 * uninstall or a cleared app; a second pass over an optimised photo would
 * then measure it against itself and could take it down another step. So
 * the file says so itself, where every viewer ignores it: a JPEG comment, a
 * PNG text chunk, an MP4 metadata key. A file that carries the note is left
 * alone.
 */
object OptimisedMark {

    /** The words a JPEG or PNG copy carries. */
    const val TEXT = "Optimised by Ente Saver"

    /** The MP4 metadata key a video copy carries. */
    const val VIDEO_KEY = "app.entesaver.optimised"

    /** How much of a file's start and end is read to look for the note. */
    const val HEAD_BYTES = 128 * 1024
    const val TAIL_BYTES = 256 * 1024

    private val TEXT_BYTES = TEXT.toByteArray(Charsets.US_ASCII)
    private val KEY_BYTES = VIDEO_KEY.toByteArray(Charsets.US_ASCII)
    private val PNG_SIGNATURE = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    /** Whether any of [parts] - a file's head, its tail - carries the note. */
    fun isMarked(vararg parts: ByteArray): Boolean = parts.any { indexOf(it, TEXT_BYTES) >= 0 || indexOf(it, KEY_BYTES) >= 0 }

    /**
     * [jpeg] with a comment segment carrying [TEXT] after its APPn segments,
     * where the EXIF block stays first; null when it is not a JPEG.
     */
    fun markJpeg(jpeg: ByteArray): ByteArray? {
        if (jpeg.size < 4 || u(jpeg[0]) != 0xFF || u(jpeg[1]) != 0xD8) return null
        var at = 2
        while (at + 4 <= jpeg.size && u(jpeg[at]) == 0xFF && u(jpeg[at + 1]) in 0xE0..0xEF) {
            val len = (u(jpeg[at + 2]) shl 8) or u(jpeg[at + 3])
            if (len < 2 || at + 2 + len > jpeg.size) return null
            at += 2 + len
        }
        val len = TEXT_BYTES.size + 2
        val com = byteArrayOf(0xFF.toByte(), 0xFE.toByte(), (len shr 8).toByte(), len.toByte()) + TEXT_BYTES
        return jpeg.copyOfRange(0, at) + com + jpeg.copyOfRange(at, jpeg.size)
    }

    /**
     * [png] with a "Comment" text chunk carrying [TEXT] straight after its
     * header chunk; null when it is not a PNG.
     */
    fun markPng(png: ByteArray): ByteArray? {
        if (png.size < 33 || !png.copyOfRange(0, 8).contentEquals(PNG_SIGNATURE)) return null
        val ihdrLen = readIntBe(png, 8)
        if (ihdrLen != 13 || !png.copyOfRange(12, 16).contentEquals("IHDR".toByteArray(Charsets.US_ASCII))) return null
        val afterHeader = 8 + 4 + 4 + ihdrLen + 4
        val type = "tEXt".toByteArray(Charsets.US_ASCII)
        val data = "Comment".toByteArray(Charsets.US_ASCII) + byteArrayOf(0) + TEXT_BYTES
        val crc = CRC32().apply {
            update(type)
            update(data)
        }.value
        val chunk = intBe(data.size) + type + data + intBe(crc.toInt())
        return png.copyOfRange(0, afterHeader) + chunk + png.copyOfRange(afterHeader, png.size)
    }

    private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
        if (needle.isEmpty() || haystack.size < needle.size) return -1
        outer@ for (i in 0..haystack.size - needle.size) {
            for (j in needle.indices) if (haystack[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }

    private fun u(b: Byte): Int = b.toInt() and 0xFF

    private fun readIntBe(b: ByteArray, at: Int): Int =
        (u(b[at]) shl 24) or (u(b[at + 1]) shl 16) or (u(b[at + 2]) shl 8) or u(b[at + 3])

    private fun intBe(v: Int): ByteArray = byteArrayOf((v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte())
}
