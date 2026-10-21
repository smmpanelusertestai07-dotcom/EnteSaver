package app.entesaver.core.logic

import kotlin.math.roundToInt

/**
 * A frame's brightness worked out again in another video's colour, the way
 * ffmpeg does before its libvmaf compares the two - and so the way the
 * savings benchmark's scores are made.
 *
 * Video keeps brightness and colour apart, but the brightness level stands
 * for red, green and blue in proportions a file may name ([Matrix]: BT.601,
 * BT.709, BT.2020), within a range of levels it may name too (16 to 235, or
 * the whole 0 to 255). Its copy may name others: Media3 writes BT.709 for a
 * file that does not say. Compared level for level, a copy that shows the
 * same colours as its original would then read as changed - three points of
 * VMAF on the benchmark's clips - so ffmpeg first brings the original into the
 * copy's colour, and so is it done here: a change of range alone level for
 * level ([Levels]), and of proportions through the eight-bit red, green and
 * blue a pixel stands for, each kept within 0 to 255 ([Through]), as ffmpeg's
 * swscale converts one into the other. On the pilot's clip this read 89.79
 * where ffmpeg's own read 89.81. swscale rounds the red, green and blue down
 * where this rounds them to the nearest, as a phone's GPU does: the same
 * score within a few hundredths, and a grey that keeps its level.
 *
 * A file that names no proportions is read as ffmpeg reads one, BT.601, and
 * one that names no range as limited.
 */
object Recolour {

    /** The share of red and of blue in brightness; green has the rest. */
    enum class Matrix(val kr: Double, val kb: Double) {
        BT601(0.299, 0.114),
        BT709(0.2126, 0.0722),
        BT2020(0.2627, 0.0593)
    }

    /** A colour as far as brightness goes: its proportions, and whether its levels fill 0 to 255. */
    data class Space(val matrix: Matrix, val full: Boolean)

    /** How a level of one colour reads in another. */
    sealed interface Change

    /** A change of range alone: each brightness level read off [table]. */
    class Levels(val table: ByteArray) : Change

    /** A change of proportions: each level worked out again from its pixel's colour ([luma]). */
    class Through internal constructor(from: Space, into: Space) : Change {

        // Red, green and blue from a pixel's brightness and colour levels, in
        // 65536ths, a half added to the brightness so each rounds to the
        // nearest: red is brightness plus a share of red-difference, blue of
        // blue-difference, green less a share of both.
        private val base = IntArray(256)
        private val redOfV = IntArray(256)
        private val greenOfU = IntArray(256)
        private val greenOfV = IntArray(256)
        private val blueOfU = IntArray(256)

        // Brightness from red, green and blue, in 65536ths, and what is added before rounding.
        private val toR: Int
        private val toG: Int
        private val toB: Int
        private val offset: Int

        init {
            val m = from.matrix
            val kg = 1 - m.kr - m.kb
            for (level in 0..255) {
                val y = if (from.full) level.toDouble() else (level - 16) * 255.0 / 219
                val c = if (from.full) level - 128.0 else (level - 128) * 255.0 / 224
                base[level] = fixed(y) + (1 shl (SHIFT - 1))
                redOfV[level] = fixed(2 * (1 - m.kr) * c)
                blueOfU[level] = fixed(2 * (1 - m.kb) * c)
                greenOfU[level] = fixed(-2 * m.kb * (1 - m.kb) / kg * c)
                greenOfV[level] = fixed(-2 * m.kr * (1 - m.kr) / kg * c)
            }
            val n = into.matrix
            val scale = if (into.full) 1.0 else 219.0 / 255
            toR = fixed(scale * n.kr)
            toG = fixed(scale * (1 - n.kr - n.kb))
            toB = fixed(scale * n.kb)
            offset = (if (into.full) 0 else 16 shl SHIFT) + (1 shl (SHIFT - 1))
        }

        /** The brightness, in this colour, of a pixel of brightness [y] and colour [u] (blue) and [v] (red), each 0 to 255. */
        fun luma(y: Int, u: Int, v: Int): Int {
            val b0 = base[y]
            val r = ((b0 + redOfV[v]) shr SHIFT).coerceIn(0, 255)
            val g = ((b0 + greenOfU[u] + greenOfV[v]) shr SHIFT).coerceIn(0, 255)
            val b = ((b0 + blueOfU[u]) shr SHIFT).coerceIn(0, 255)
            return (toR * r + toG * g + toB * b + offset) shr SHIFT
        }
    }

    private const val SHIFT = 16

    private fun fixed(x: Double): Int = (x * (1 shl SHIFT)).roundToInt()

    /** A full-range level squeezed into 16 to 235, as ffmpeg squeezes it. */
    private val SQUEEZE = ByteArray(256) { (16 + (it * 219 + 127) / 255).toByte() }

    /** A limited-range level stretched over 0 to 255, as ffmpeg stretches it. */
    private val STRETCH = ByteArray(256) { ((it - 16) * 255 + 109).floorDiv(219).coerceIn(0, 255).toByte() }

    /** How [from]'s levels read in [into]; null where they read the same. */
    fun change(from: Space, into: Space): Change? = when {
        from.matrix != into.matrix -> Through(from, into)
        from.full == into.full -> null
        from.full -> Levels(SQUEEZE)
        else -> Levels(STRETCH)
    }
}
