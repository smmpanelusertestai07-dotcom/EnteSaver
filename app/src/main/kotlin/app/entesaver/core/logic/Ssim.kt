package app.entesaver.core.logic

import kotlin.math.max
import kotlin.math.min

/**
 * How alike two pictures look: the structural similarity index (SSIM) of
 * their brightness, from 0 (nothing alike) to 1 (the same picture).
 *
 * This is the yardstick the optimiser aims by. Instead of one fixed quality
 * for every file - too much for a plain wall, too little for leaves in the
 * wind - each file is made as small as it can be while it still measures
 * above [Targets], against its own original. SSIM is used rather than plain
 * pixel error because it follows what the eye notices: blur and blocking
 * lower it, invisible noise barely does.
 *
 * Brightness only, in 8x8 windows that overlap by half: the eye judges detail
 * by brightness, and the windows keep it fast enough for a phone - a 1080p
 * frame is about 130,000 windows of simple sums, a few milliseconds.
 */
object Ssim {

    private const val WINDOW = 8
    private const val STEP = 4
    private const val C1 = 6.5025 // (0.01 * 255)^2
    private const val C2 = 58.5225 // (0.03 * 255)^2

    /**
     * Mean SSIM of two brightness planes of the same size, [width] x [height],
     * one byte (0-255) a pixel, row by row. A plane smaller than one window
     * is compared as a single window.
     */
    fun of(a: ByteArray, b: ByteArray, width: Int, height: Int): Double {
        require(width > 0 && height > 0) { "empty plane" }
        require(a.size >= width * height && b.size >= width * height) { "plane smaller than its size" }
        val win = min(WINDOW, min(width, height))
        val step = max(1, min(STEP, win / 2))
        var total = 0.0
        var count = 0
        var y = 0
        while (y + win <= height) {
            var x = 0
            while (x + win <= width) {
                total += window(a, b, width, x, y, win)
                count++
                x += step
            }
            y += step
        }
        return if (count == 0) 1.0 else total / count
    }

    private fun window(a: ByteArray, b: ByteArray, stride: Int, x0: Int, y0: Int, win: Int): Double {
        var sa = 0L
        var sb = 0L
        var saa = 0L
        var sbb = 0L
        var sab = 0L
        for (dy in 0 until win) {
            var i = (y0 + dy) * stride + x0
            for (dx in 0 until win) {
                val pa = a[i].toInt() and 0xFF
                val pb = b[i].toInt() and 0xFF
                sa += pa
                sb += pb
                saa += pa * pa
                sbb += pb * pb
                sab += pa * pb
                i++
            }
        }
        val n = (win * win).toDouble()
        val ma = sa / n
        val mb = sb / n
        val va = saa / n - ma * ma
        val vb = sbb / n - mb * mb
        val cov = sab / n - ma * mb
        return ((2 * ma * mb + C1) * (2 * cov + C2)) / ((ma * ma + mb * mb + C1) * (va + vb + C2))
    }

    /**
     * The brightness plane of ARGB pixels (BT.601 weights, as JPEG and
     * video encoders use), for [of].
     */
    fun lumaOf(argb: IntArray): ByteArray = ByteArray(argb.size).also { lumaInto(argb, argb.size, it, 0) }

    /**
     * The brightness of the first [count] ARGB pixels of [argb], written into
     * [out] from [offset]: one row at a time, so a frame never needs a second
     * full-size copy of itself in memory.
     */
    fun lumaInto(argb: IntArray, count: Int, out: ByteArray, offset: Int) {
        for (i in 0 until count) {
            val p = argb[i]
            val r = (p shr 16) and 0xFF
            val g = (p shr 8) and 0xFF
            val bl = p and 0xFF
            out[offset + i] = ((r * 299 + g * 587 + bl * 114 + 500) / 1000).toByte()
        }
    }

    /**
     * The scores a copy must reach against its own original.
     *
     * Chosen to sit at or above what Google Photos' Storage saver gives: a
     * 16 MP photo and a 1080p video that look the same as the original at
     * the size a phone shows them. Measured on full-size crops for a photo,
     * where blocking shows first, and on whole frames for a video.
     */
    object Targets {
        const val PHOTO = 0.965
        const val VIDEO = 0.950
    }
}
