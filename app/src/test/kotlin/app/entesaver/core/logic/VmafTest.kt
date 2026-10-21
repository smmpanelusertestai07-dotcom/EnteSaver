package app.entesaver.core.logic

import java.util.zip.CRC32
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [Vmaf] gives libvmaf's own numbers.
 *
 * Each picture here is drawn with integer arithmetic alone - a gradient, a
 * chequerboard, a disc, a band of text-like strokes, noise from a fixed
 * generator - and damaged the same way: blurred, blocked like a codec,
 * noised, brightened, halved, posterised. A script drew the same bytes for
 * libvmaf 3.2.0, built with its float features, and what libvmaf printed is
 * written down below. So are the bytes' checksums: a drawing that drifted
 * fails as that, not as a wrong score.
 *
 * Three clips: 320x180 over five frames, so motion is seen at the first
 * frame, in the middle and at the last; 322x182 and 201x121, whose odd
 * edges and narrow small scales reach every border case of the filters.
 *
 * VIF, motion and adm2 are libvmaf's to the last digit - adm2 as libvmaf
 * works it out on ARM, dividing exactly, as the port does. On x86, where
 * the other numbers came from, libvmaf divides by an approximate reciprocal,
 * which moves adm2 in the eighth digit; that is held too. Scores are held
 * to 0.0001.
 */
class VmafTest {

    /**
     * What libvmaf printed for one frame, as built for x86; and its adm2 as
     * built to divide exactly, as libvmaf does on ARM.
     */
    private class Frame(
        val adm2: Double,
        val vif0: Double,
        val vif1: Double,
        val vif2: Double,
        val vif3: Double,
        val motion: Double,
        val motion2: Double,
        val vmaf: Double,
        val phone: Double,
        val adm2Arm: Double
    )

    private enum class Damage { SAME, BLUR, BLOCKS, NOISE, BRIGHT, HALVED, POSTERISED, BLURRED_NOISE }

    /** A clip: its size, the seed it is drawn from, what each frame's copy suffered, and libvmaf's view of it. */
    private class Clip(
        val width: Int,
        val height: Int,
        val seed: Int,
        val damage: List<Damage>,
        val refCrc: Long,
        val disCrc: Long,
        val frames: List<Frame>
    ) {
        val originals = damage.indices.map { scene(width, height, it, seed) }
        val copies = damage.indices.map { damaged(damage[it], originals[it], width, height, it) }
        fun plane(pixels: ByteArray) = Vmaf.Plane(pixels, width, height)
    }

    private val clips = listOf(
        Clip(
            320, 180, 1, listOf(Damage.SAME, Damage.BLUR, Damage.BLOCKS, Damage.NOISE, Damage.BRIGHT),
            refCrc = 0x168C33AAL, disCrc = 0x21C97579L,
            frames = listOf(
                Frame(
                    adm2 = 1.0, vif0 = 0.9999986470167396,
                    vif1 = 0.9999982431447044, vif2 = 0.9999991717121667,
                    vif3 = 0.9999988257947248, motion = 0.0,
                    motion2 = 0.0, vmaf = 97.42790141203486, phone = 100.0,
                    adm2Arm = 1.0
                ),
                Frame(
                    adm2 = 0.8276256285871079, vif0 = 0.353716473973779,
                    vif1 = 0.9606032219249069, vif2 = 0.9851327343616625,
                    vif3 = 0.9916793563766114, motion = 2.9293837547302246,
                    motion2 = 2.9196183681488037, vmaf = 63.97339372433069, phone = 83.28759508038215,
                    adm2Arm = 0.8276256285871079
                ),
                Frame(
                    adm2 = 0.7389590982748817, vif0 = 0.5390004529466397,
                    vif1 = 0.7899355019686616, vif2 = 0.8674949921324315,
                    vif3 = 0.8898308637610626, motion = 2.9196183681488037,
                    motion2 = 2.9125540256500244, vmaf = 34.32318455004833, phone = 52.654547929895124,
                    adm2Arm = 0.7389590982748817
                ),
                Frame(
                    adm2 = 0.9593693785259236, vif0 = 0.3447749644378669,
                    vif1 = 0.9030630613997027, vif2 = 0.9586000499024797,
                    vif3 = 0.9800992205833421, motion = 2.9125540256500244,
                    motion2 = 2.90401554107666, vmaf = 89.2714968841525, phone = 99.61991296730787,
                    adm2Arm = 0.9593693785259236
                ),
                Frame(
                    adm2 = 1.0, vif0 = 0.9999864198099966,
                    vif1 = 0.999982435504147, vif2 = 0.9999832449667324,
                    vif3 = 0.9999843492618721, motion = 2.90401554107666,
                    motion2 = 2.90401554107666, vmaf = 100.0, phone = 100.0,
                    adm2Arm = 1.0
                )
            )
        ),
        Clip(
            322, 182, 2, listOf(Damage.HALVED, Damage.POSTERISED, Damage.BLURRED_NOISE),
            refCrc = 0xD935B0B5L, disCrc = 0x3FB801F0L,
            frames = listOf(
                Frame(
                    adm2 = 0.8114317502331317, vif0 = 0.5426726868658427,
                    vif1 = 0.9485687488337828, vif2 = 0.987411234089484,
                    vif3 = 0.9927141041165678, motion = 0.0,
                    motion2 = 0.0, vmaf = 56.83762652332528, phone = 77.04842080400114,
                    adm2Arm = 0.8114317716223504
                ),
                Frame(
                    adm2 = 0.9371924768867513, vif0 = 0.5689570134838003,
                    vif1 = 0.7343106163080311, vif2 = 0.7533084348299309,
                    vif3 = 0.7614220753897105, motion = 2.9094440937042236,
                    motion2 = 2.8996071815490723, vmaf = 61.17984440120905, phone = 80.9306037839743,
                    adm2Arm = 0.9371924768867513
                ),
                Frame(
                    adm2 = 0.7661570516639832, vif0 = 0.13923095004370772,
                    vif1 = 0.8710347184754286, vif2 = 0.9439118116867365,
                    vif3 = 0.9690198364864744, motion = 2.8996071815490723,
                    motion2 = 2.8996071815490723, vmaf = 49.8948687059216, phone = 70.28861288556325,
                    adm2Arm = 0.7661570516639832
                )
            )
        ),
        Clip(
            201, 121, 3, listOf(Damage.BLOCKS, Damage.NOISE, Damage.BLUR),
            refCrc = 0xF18B989DL, disCrc = 0xE7D575E4L,
            frames = listOf(
                Frame(
                    adm2 = 0.6867686546689371, vif0 = 0.4157876832868062,
                    vif1 = 0.6977564919309662, vif2 = 0.8141101844922104,
                    vif3 = 0.849785711216851, motion = 0.0,
                    motion2 = 0.0, vmaf = 19.353805073498297, phone = 32.47804063705154,
                    adm2Arm = 0.6867686546689371
                ),
                Frame(
                    adm2 = 0.9663396021793452, vif0 = 0.3513114920904613,
                    vif1 = 0.9016893176858563, vif2 = 0.9557805757325342,
                    vif3 = 0.9737781308529059, motion = 3.540433168411255,
                    motion2 = 3.4983789920806885, vmaf = 90.78065317889846, phone = 100.0,
                    adm2Arm = 0.9663396021793452
                ),
                Frame(
                    adm2 = 0.7755732860087682, vif0 = 0.35553899429057284,
                    vif1 = 0.9593841201834339, vif2 = 0.986713725554316,
                    vif3 = 0.9935989552248218, motion = 3.4983789920806885,
                    motion2 = 3.4983789920806885, vmaf = 54.38619291431626, phone = 74.73924074871486,
                    adm2Arm = 0.7755732860087682
                )
            )
        )
    )

    @Test
    fun `the pictures are the ones libvmaf measured`() {
        for (clip in clips) {
            val ref = CRC32()
            val dis = CRC32()
            clip.originals.forEach { ref.update(it) }
            clip.copies.forEach { dis.update(it) }
            assertEquals("${clip.width}x${clip.height} originals", clip.refCrc, ref.value)
            assertEquals("${clip.width}x${clip.height} copies", clip.disCrc, dis.value)
        }
    }

    @Test
    fun `the features are libvmaf's`() {
        for (clip in clips) for ((t, e) in clip.frames.withIndex()) {
            val f = Vmaf.features(clip.plane(clip.originals[t]), clip.plane(clip.copies[t]))
            val at = "${clip.width}x${clip.height} frame $t"
            assertClose("$at adm2", e.adm2Arm, f.adm2, EXACT)
            assertClose("$at adm2 on x86", e.adm2, f.adm2, ADM)
            assertClose("$at vif0", e.vif0, f.vif0, EXACT)
            assertClose("$at vif1", e.vif1, f.vif1, EXACT)
            assertClose("$at vif2", e.vif2, f.vif2, EXACT)
            assertClose("$at vif3", e.vif3, f.vif3, EXACT)
        }
    }

    @Test
    fun `motion and motion2 are libvmaf's, at the first and last frame too`() {
        for (clip in clips) {
            val motion = motions(clip)
            val last = clip.frames.size - 1
            for ((t, e) in clip.frames.withIndex()) {
                val at = "${clip.width}x${clip.height} frame $t"
                assertClose("$at motion", e.motion, motion[t], EXACT)
                assertClose("$at motion2", e.motion2, motion2(motion, t), EXACT)
            }
            // libvmaf's own rule at the ends: nothing came before the first
            // frame, and nothing after the last but what came before it.
            assertEquals(0.0, clip.frames[0].motion2, 0.0)
            assertEquals(clip.frames[last].motion, clip.frames[last].motion2, 0.0)
        }
    }

    @Test
    fun `the scores are libvmaf's, the phone model's too`() {
        for (clip in clips) {
            val motion = motions(clip)
            for ((t, e) in clip.frames.withIndex()) {
                val f = Vmaf.features(clip.plane(clip.originals[t]), clip.plane(clip.copies[t]))
                val score = Vmaf.score(f, motion2(motion, t))
                val at = "${clip.width}x${clip.height} frame $t"
                assertEquals("$at vmaf", e.vmaf, score, SCORE)
                assertEquals("$at phone", e.phone, Vmaf.phone(score), SCORE)
            }
        }
    }

    @Test
    fun `the model alone turns libvmaf's features into libvmaf's score`() {
        for (clip in clips) for (e in clip.frames) {
            val score = Vmaf.score(Vmaf.Features(e.adm2, e.vif0, e.vif1, e.vif2, e.vif3), e.motion2)
            assertEquals(e.vmaf, score, 1e-9)
            assertEquals(e.phone, Vmaf.phone(score), 1e-9)
        }
    }

    @Test
    fun `the phone curve lifts a score, never lowers it, and stops at 100`() {
        assertEquals(VmafModel.PHONE_P0, Vmaf.phone(0.0), 1e-12)
        assertEquals(100.0, Vmaf.phone(100.0), 0.0)
        for (step in 0..200) {
            val score = step / 2.0
            val phone = Vmaf.phone(score)
            assertTrue("$score became $phone", phone >= score && phone <= 100.0)
        }
    }

    @Test
    fun `a picture that holds still has no motion`() {
        val clip = clips[0]
        val blur = Vmaf.motionBlur(clip.plane(clip.originals[1]))
        assertEquals(0.0, Vmaf.motion(blur, blur.copyOf(), clip.width, clip.height), 0.0)
    }

    @Test
    fun `planes of different sizes, or too small, are refused`() {
        val square = Vmaf.Plane(ByteArray(64 * 64), 64, 64)
        val wide = Vmaf.Plane(ByteArray(64 * 48), 64, 48)
        assertThrows(IllegalArgumentException::class.java) { Vmaf.features(square, wide) }
        assertThrows(IllegalArgumentException::class.java) { Vmaf.Plane(ByteArray(31 * 64), 31, 64) }
        assertThrows(IllegalArgumentException::class.java) { Vmaf.Plane(ByteArray(64), 64, 64) }
    }

    /** Each frame's motion from the one before; libvmaf's 0 for the first. */
    private fun motions(clip: Clip): DoubleArray {
        val blurs = clip.originals.map { Vmaf.motionBlur(clip.plane(it)) }
        return DoubleArray(blurs.size) { t ->
            if (t == 0) 0.0 else Vmaf.motion(blurs[t - 1], blurs[t], clip.width, clip.height)
        }
    }

    /** A frame's motion2 as libvmaf forms it from [motion]: the smaller either side, but at the ends. */
    private fun motion2(motion: DoubleArray, t: Int): Double = when (t) {
        0 -> 0.0
        motion.size - 1 -> motion[t]
        else -> minOf(motion[t], motion[t + 1])
    }

    private fun assertClose(label: String, expected: Double, actual: Double, relative: Double) {
        val off = abs(actual - expected) / maxOf(abs(expected), 1e-12)
        assertTrue("$label: libvmaf $expected, port $actual", off <= relative)
    }

    private companion object {

        /** VIF and motion: libvmaf's to nine digits - in practice to the last. */
        const val EXACT = 1e-9

        /** adm2: x86 libvmaf's approximate division moves it in the eighth digit. */
        const val ADM = 1e-7

        /** Scores, in points of 100. */
        const val SCORE = 1e-4

        /** The script's generator: 32-bit, the top byte of each step. */
        class Lcg(seed: Int) {
            private var s = seed

            fun next(): Int {
                s = s * 1664525 + 1013904223
                return s ushr 24
            }
        }

        fun clamp(v: Int) = v.coerceIn(0, 255)

        fun px(p: ByteArray, i: Int) = p[i].toInt() and 0xFF

        /** Frame [t] of a clip: a gradient, a chequerboard and a disc that move, strokes like text, noise. */
        fun scene(w: Int, h: Int, t: Int, seed: Int): ByteArray {
            val rnd = Lcg(seed * 7919 + t * 104729)
            val out = ByteArray(w * h)
            val r = h / 5
            val cx = w * 2 / 3 + 3 * t
            val cy = h / 2
            val band = h * 3 / 4
            for (y in 0 until h) for (x in 0 until w) {
                var v = 40 + x * 120 / w + y * 60 / h
                if (y < h / 2 && x < w / 2 && ((x + 4 * t) / 16 + y / 16) % 2 == 0) v += 25
                val dx = x - cx
                val dy = y - cy
                if (dx * dx + dy * dy <= r * r) v = 250 - v / 2
                if (y >= band && y < band + 9 && x >= 4) {
                    val gx = (x + 2 * t) % 8
                    val gy = y - band
                    val glyph = ((x + 2 * t) / 8 * 7 + seed) % 5
                    val bar = (gy == 0 || gy == 4 || gy == 8) && ((glyph shr (gy / 4)) and 1) == 1
                    val stroke = gx == 1 || (gx < 6 && bar) || (gx == 5 && glyph >= 3)
                    if (stroke && gx < 7) v = 20
                }
                v += rnd.next() % 3 - 1
                out[y * w + x] = clamp(v).toByte()
            }
            return out
        }

        fun damaged(kind: Damage, p: ByteArray, w: Int, h: Int, t: Int): ByteArray = when (kind) {
            Damage.SAME -> p.copyOf()
            Damage.BLUR -> blur(p, w, h)
            Damage.BLOCKS -> blocks(p, w, h)
            Damage.NOISE -> noise(p, 31 + t)
            Damage.BRIGHT -> ByteArray(p.size) { minOf(255, px(p, it) + 12).toByte() }
            Damage.HALVED -> halved(p, w, h)
            Damage.POSTERISED -> ByteArray(p.size) { (px(p, it) / 16 * 16 + 8).toByte() }
            Damage.BLURRED_NOISE -> noise(blur(p, w, h), 77 + t)
        }

        /** A 3x3 box blur, the edge repeated. */
        fun blur(p: ByteArray, w: Int, h: Int) = ByteArray(w * h) { i ->
            val x = i % w
            val y = i / w
            var s = 0
            for (dy in -1..1) for (dx in -1..1) {
                s += px(p, (y + dy).coerceIn(0, h - 1) * w + (x + dx).coerceIn(0, w - 1))
            }
            (s / 9).toByte()
        }

        /** Each 8x8 block pulled three quarters of the way to its mean, as a starved codec leaves it. */
        fun blocks(p: ByteArray, w: Int, h: Int): ByteArray {
            val out = ByteArray(w * h)
            for (by in 0 until h step 8) for (bx in 0 until w step 8) {
                var s = 0
                var n = 0
                for (y in by until minOf(by + 8, h)) for (x in bx until minOf(bx + 8, w)) {
                    s += px(p, y * w + x)
                    n++
                }
                val m = s / n
                for (y in by until minOf(by + 8, h)) for (x in bx until minOf(bx + 8, w)) {
                    out[y * w + x] = ((3 * m + px(p, y * w + x)) / 4).toByte()
                }
            }
            return out
        }

        fun noise(p: ByteArray, seed: Int): ByteArray {
            val rnd = Lcg(seed)
            return ByteArray(p.size) { clamp(px(p, it) + rnd.next() % 21 - 10).toByte() }
        }

        /** Half the resolution, each 2x2 block its mean. */
        fun halved(p: ByteArray, w: Int, h: Int): ByteArray {
            val out = ByteArray(w * h)
            for (by in 0 until h step 2) for (bx in 0 until w step 2) {
                var s = 0
                var n = 0
                for (y in by until minOf(by + 2, h)) for (x in bx until minOf(bx + 2, w)) {
                    s += px(p, y * w + x)
                    n++
                }
                for (y in by until minOf(by + 2, h)) for (x in bx until minOf(bx + 2, w)) {
                    out[y * w + x] = (s / n).toByte()
                }
            }
            return out
        }
    }
}
