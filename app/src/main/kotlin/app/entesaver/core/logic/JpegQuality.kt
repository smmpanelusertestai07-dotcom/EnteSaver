package app.entesaver.core.logic

import java.io.InputStream
import kotlin.math.abs

/**
 * The quality a JPEG was saved at (1-100, the familiar libjpeg scale), read
 * from the file's own quantisation table - no pixel is decoded.
 *
 * A JPEG keeps the table its encoder divided the picture by; the larger the
 * numbers, the more was thrown away. Compared with the standard table at
 * every quality, it says roughly where the file stands. A camera that wrote
 * at 95 leaves a great deal to save; a WhatsApp forward written at 70 has
 * little left, and the optimiser starts its search accordingly instead of
 * spending encodes on settings that cannot win.
 */
object JpegQuality {

    /** The standard (Annex K) luminance table; the sum is order-independent. */
    private val STANDARD_LUMA = intArrayOf(
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99
    )

    /** Sum of the standard table scaled to each quality 1..100, libjpeg's rule. */
    private val SCALED_SUMS: IntArray = IntArray(101).also { sums ->
        for (q in 1..100) {
            val scale = if (q < 50) 5000 / q else 200 - 2 * q
            sums[q] = STANDARD_LUMA.sumOf { v -> ((v * scale + 50) / 100).coerceIn(1, 255) }
        }
    }

    /** The quality of the first (luminance) table in [jpeg], or null if none is found. */
    fun estimate(jpeg: InputStream): Int? =
        runCatching { lumaTable(jpeg) }.getOrNull()?.let { estimateFromTable(it) }

    /** The quality whose standard table is closest to [table] (64 entries, any order). */
    fun estimateFromTable(table: IntArray): Int? {
        if (table.size != 64) return null
        val sum = table.sum()
        var best = 0
        var bestDiff = Int.MAX_VALUE
        for (q in 1..100) {
            val diff = abs(SCALED_SUMS[q] - sum)
            if (diff < bestDiff) {
                bestDiff = diff
                best = q
            }
        }
        return best.takeIf { it > 0 }
    }

    /**
     * The first quantisation table (id 0, by convention the luminance one)
     * in a JPEG stream, read marker by marker up to the start of the scan.
     */
    fun lumaTable(input: InputStream): IntArray? {
        val s = input.buffered()
        if (s.read() != 0xFF || s.read() != 0xD8) return null
        while (true) {
            var b = s.read()
            if (b < 0) return null
            if (b != 0xFF) return null
            while (b == 0xFF) b = s.read()
            if (b < 0) return null
            val marker = b
            if (marker == 0xD9 || marker == 0xDA) return null // end of image or start of scan: no table
            if (marker in 0xD0..0xD7 || marker == 0x01) continue // markers without a length
            val len = (readU8(s) shl 8) or readU8(s)
            if (len < 2) return null
            if (marker != 0xDB) {
                skipFully(s, (len - 2).toLong())
                continue
            }
            var left = len - 2
            while (left > 0) {
                val pq = readU8(s)
                left--
                val precision16 = (pq shr 4) != 0
                val id = pq and 0x0F
                val table = IntArray(64)
                for (i in 0 until 64) {
                    table[i] = if (precision16) (readU8(s) shl 8) or readU8(s) else readU8(s)
                }
                left -= if (precision16) 128 else 64
                if (id == 0) return table
            }
        }
    }

    private fun readU8(s: InputStream): Int {
        val v = s.read()
        if (v < 0) throw java.io.EOFException()
        return v
    }

    private fun skipFully(s: InputStream, n: Long) {
        var left = n
        while (left > 0) {
            val skipped = s.skip(left)
            if (skipped <= 0) {
                if (s.read() < 0) throw java.io.EOFException()
                left--
            } else {
                left -= skipped
            }
        }
    }
}
