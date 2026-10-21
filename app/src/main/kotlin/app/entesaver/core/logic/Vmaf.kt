/*
 * Ported from Netflix's libvmaf (https://github.com/Netflix/vmaf),
 * Copyright 2016-2020 Netflix, Inc., BSD-2-Clause-Patent licence.
 */
package app.entesaver.core.logic

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * How a frame of a video copy looks beside the same frame of its original:
 * Netflix's VMAF with its vmaf_v0.6.1 model, from 0 (unwatchable) to 100 (no
 * loss anyone would see).
 *
 * VMAF is what video encoders are tuned and judged by, so a copy measured
 * with it can be set beside any published figure. It combines three
 * measures, all of the picture's brightness alone: VIF, how much of the
 * original's detail survives, at four scales; ADM, how much detail was lost
 * as against noise added; and motion, how much the original itself moves
 * from frame to frame, since movement hides loss. A small trained model
 * (VmafModel) turns the six numbers into the score.
 *
 * This is libvmaf's floating-point path (float_vif, float_adm and
 * float_motion) worked through step for step, with float where libvmaf uses
 * float and double where it uses double: the same filters, the same mirrored
 * edges, the same sums in the same order. So it gives libvmaf's numbers, not
 * numbers like them - the unit test holds it to libvmaf's own output. Two
 * things can still part them in the last digit. On x86, libvmaf's ADM
 * divides by the processor's approximate reciprocal; on a phone's ARM
 * processor it divides exactly, as this does. And glibc's powf is not quite
 * correctly rounded, where this is. Neither moves a score by 0.0001.
 *
 * libvmaf keeps whole frames of floats for every step, over 100 MB for a
 * 1080p pair; this works a row at a time and needs about 6 MB besides the
 * two planes.
 */
object Vmaf {

    /**
     * The smallest plane measured, each way. VMAF works down to a sixteenth
     * of the picture's size, where its filters need two pixels to work with;
     * on less they would reach past the edge.
     */
    const val MIN_SIZE = 32

    /** A brightness plane: one byte (0-255) a pixel, row by row, no padding. */
    class Plane(val pixels: ByteArray, val width: Int, val height: Int) {
        init {
            require(width >= MIN_SIZE && height >= MIN_SIZE) { "a plane needs at least $MIN_SIZE pixels each way" }
            require(pixels.size >= width * height) { "plane smaller than its size" }
        }
    }

    /**
     * The five numbers VMAF takes from a pair of frames: adm2, and VIF at
     * scales 0 (full size) to 3 (an eighth). Each is about 1 for a perfect
     * copy and lower the more is lost. The model's sixth number, motion2,
     * needs the original's neighbouring frames, so it is passed separately.
     */
    data class Features(val adm2: Double, val vif0: Double, val vif1: Double, val vif2: Double, val vif3: Double)

    /** What libvmaf's float extractors measure between [reference] and [distorted], planes of one size. */
    fun features(reference: Plane, distorted: Plane): Features {
        require(reference.width == distorted.width && reference.height == distorted.height) { "planes differ in size" }
        val vif = Vif.of(reference, distorted)
        return Features(Adm.of(reference, distorted), vif[0], vif[1], vif[2], vif[3])
    }

    /**
     * The original frame blurred as VMAF's motion measure needs it: a
     * width x height grid of floats, row by row - 8 MB for a 1080p frame.
     * Each frame is blurred once; [motion] compares two blurs.
     */
    fun motionBlur(reference: Plane): FloatArray {
        val w = reference.width
        val h = reference.height
        val p = reference.pixels
        val out = FloatArray(w * h)
        val row = FloatArray(w)
        val pad = FloatArray(w + 2 * RADIUS)
        for (i in 0 until h) {
            vertical(BLUR, i, w, h, row) { ((p[it].toInt() and 0xFF) - 128).toFloat() }
            horizontal(BLUR, row, w, pad, out, i * w)
        }
        return out
    }

    /**
     * How much the original moves from one frame to the next: the mean
     * absolute difference of their [motionBlur]s, each [width] x [height].
     *
     * The model's motion2 for a frame is the smaller of its motion from the
     * frame before and to the frame after - which is what libvmaf gives every
     * frame but the first (0) and the last (its motion from the one before).
     */
    fun motion(previousBlur: FloatArray, blur: FloatArray, width: Int, height: Int): Double {
        require(previousBlur.size >= width * height && blur.size >= width * height) { "blur smaller than its size" }
        var sum = 0f
        for (i in 0 until height) {
            var line = 0f
            val o = i * width
            for (j in 0 until width) line += abs(previousBlur[o + j] - blur[o + j])
            sum += line
        }
        return (sum / (width * height).toFloat()).toDouble()
    }

    /** The vmaf_v0.6.1 score of a frame's [features] and [motion2], clipped to 0-100 as the model says. */
    fun score(features: Features, motion2: Double): Double = clip(prediction(features, motion2))

    /**
     * The phone model: [score] bent upwards for a picture seen on a phone's
     * small screen, where loss is harder to see - never below the score it
     * is given, and clipped to 0-100.
     *
     * libvmaf bends a frame's prediction before clipping it, this a clipped
     * score; the two agree for any score above 0, and below that, where
     * libvmaf can say less, this says 1.7 - a copy that bad fails either way.
     * libvmaf's phone score for a whole clip is the mean of its frames'; the
     * curve flattens towards 100, so the curve of a mean score can come out
     * a little higher.
     */
    fun phone(score: Double): Double {
        val bent = 0.0 + VmafModel.PHONE_P0 + VmafModel.PHONE_P1 * score + VmafModel.PHONE_P2 * score * score
        return clip(if (bent < score) score else bent)
    }

    /** libsvm's nu-SVR with a radial kernel, between libvmaf's rescaling of its input and of its output. */
    private fun prediction(f: Features, motion2: Double): Double {
        val x = doubleArrayOf(f.adm2, motion2, f.vif0, f.vif1, f.vif2, f.vif3)
        for (k in x.indices) x[k] = VmafModel.SLOPES[k + 1] * x[k] + VmafModel.INTERCEPTS[k + 1]
        val sv = VmafModel.SUPPORT_VECTORS
        var sum = 0.0
        var i = 0
        while (i < sv.size) {
            var distance = 0.0
            for (k in x.indices) {
                val d = x[k] - sv[i + 1 + k]
                distance += d * d
            }
            sum += sv[i] * exp(-VmafModel.GAMMA * distance)
            i += VmafModel.ROW
        }
        sum -= VmafModel.RHO
        return (sum - VmafModel.INTERCEPTS[0]) / VmafModel.SLOPES[0]
    }

    private fun clip(score: Double): Double {
        val low = if (score < VmafModel.MIN_SCORE) VmafModel.MIN_SCORE else score
        return if (low > VmafModel.MAX_SCORE) VmafModel.MAX_SCORE else low
    }

    /** libvmaf's motion blur, five taps; its constants are doubles stored as floats, as in C. */
    private val BLUR = floats(0.054488685, 0.244201342, 0.402619947, 0.244201342, 0.054488685)
    private const val RADIUS = 2

    /** A row index reflected back inside 0 until [n] without repeating the edge, as libvmaf's filters do. */
    private fun mirror(i: Int, n: Int): Int = if (i < 0) -i else if (i >= n) 2 * n - i - 2 else i

    /** C's float array initialised from double constants: each rounded once, from the double. */
    private fun floats(vararg v: Double) = FloatArray(v.size) { v[it].toFloat() }

    /** C's powf: the power in double, rounded to float. glibc's own is a last bit off for about one input in 1,600. */
    private fun powf(x: Float, y: Float): Float = x.toDouble().pow(y.toDouble()).toFloat()

    /**
     * The vertical half of a separable filter [f] at row [i] of a [w] x [h]
     * picture read through [src], into [out]: each sum starts at 0 and adds
     * the taps top to bottom, as libvmaf's does.
     */
    private inline fun vertical(f: FloatArray, i: Int, w: Int, h: Int, out: FloatArray, src: (Int) -> Float) {
        out.fill(0f, 0, w)
        val r = f.size / 2
        for (k in f.indices) {
            val o = mirror(i - r + k, h) * w
            val c = f[k]
            for (j in 0 until w) out[j] += c * src(o + j)
        }
    }

    /**
     * The horizontal half of [f] over the first [w] of [src], into [dst] from
     * [at], through [pad]. Four taps a sweep, added one after another as
     * libvmaf adds them; only the trips through memory are fewer.
     */
    private fun horizontal(f: FloatArray, src: FloatArray, w: Int, pad: FloatArray, dst: FloatArray, at: Int = 0) {
        padRow(f, src, w, pad)
        dst.fill(0f, at, at + w)
        var k = 0
        while (k + 4 <= f.size) {
            val c0 = f[k]
            val c1 = f[k + 1]
            val c2 = f[k + 2]
            val c3 = f[k + 3]
            for (j in 0 until w) {
                val p = j + k
                dst[at + j] = dst[at + j] + c0 * pad[p] + c1 * pad[p + 1] + c2 * pad[p + 2] + c3 * pad[p + 3]
            }
            k += 4
        }
        while (k < f.size) {
            val c = f[k]
            for (j in 0 until w) dst[at + j] += c * pad[j + k]
            k++
        }
    }

    /** [horizontal] at even columns only: the [w] / 2 values a halving keeps, into [dst] from [at]. */
    private fun horizontalEven(f: FloatArray, src: FloatArray, w: Int, pad: FloatArray, dst: FloatArray, at: Int) {
        padRow(f, src, w, pad)
        val n = w / 2
        dst.fill(0f, at, at + n)
        for (k in f.indices) {
            val c = f[k]
            for (j in 0 until n) dst[at + j] += c * pad[2 * j + k]
        }
    }

    /** [src]'s first [w] values with [f]'s reach mirrored on either side, so pad[j + k] is tap k of column j. */
    private fun padRow(f: FloatArray, src: FloatArray, w: Int, pad: FloatArray) {
        val r = f.size / 2
        src.copyInto(pad, r, 0, w)
        for (m in 1..r) {
            pad[r - m] = src[m]
            pad[r + w - 1 + m] = src[w - 1 - m]
        }
    }

    /**
     * Visual information fidelity: how much of the original's detail the
     * copy still carries, at four scales, each half the last.
     *
     * At each scale a Gaussian gives every pixel the local mean and spread of
     * both pictures and how they move together; from those, the detail the
     * copy keeps against what it adds as noise. libvmaf filters whole frames
     * and then sums; here each row is filtered, measured and added as it
     * comes, which gives the same sums. The next scale is the filtered
     * picture at every other row and column.
     */
    private object Vif {

        /** The noise VIF assumes the eye adds, as a variance. */
        private const val SIGMA_NSQ = 2.0

        /** How many times stronger than the original's a copy's detail may be and still count as kept. */
        private const val GAIN_LIMIT = 100.0f

        /** Below this a spread counts as none. */
        private const val EPS = 1.0e-10f

        /** powf(SIGMA_NSQ, 2) / 255^2, rounded to a float as C stores it. */
        private val SIGMA_MAX_INV = (4.0 / (255.0 * 255.0)).toFloat()

        /** The Gaussian of each scale: 17, 9, 5 and 3 taps. */
        private val FILTERS = Array(4) { gaussian((1 shl (4 - it)) + 1) }

        /** libvmaf's fast log2: the exponent, plus a polynomial for the mantissa. */
        private val LOG2_POLY = floats(
            -0.012671635276421, 0.064841182402670, -0.157048836463065, 0.257167726303123,
            -0.353800560300520, 0.480131410397451, -0.721314327952201, 1.442694803896991, 0.0
        )

        /** VIF at scales 0 to 3. */
        fun of(reference: Plane, distorted: Plane): DoubleArray {
            var w = reference.width
            var h = reference.height
            val rp = reference.pixels
            val dp = distorted.pixels
            val rows = Rows(w)
            val out = DoubleArray(4)
            out[0] = scale(FILTERS[0], w, h, rows, { ((rp[it].toInt() and 0xFF) - 128).toFloat() }) {
                ((dp[it].toInt() and 0xFF) - 128).toFloat()
            }
            var ref = FloatArray((w / 2) * (h / 2))
            var dis = FloatArray(ref.size)
            halve(FILTERS[1], w, h, rows, ref, dis, { ((rp[it].toInt() and 0xFF) - 128).toFloat() }) {
                ((dp[it].toInt() and 0xFF) - 128).toFloat()
            }
            w /= 2
            h /= 2
            for (s in 1..3) {
                val r = ref
                val d = dis
                out[s] = atLeastZero(scale(FILTERS[s], w, h, rows, { r[it] }) { d[it] })
                if (s == 3) break
                ref = FloatArray((w / 2) * (h / 2))
                dis = FloatArray(ref.size)
                halve(FILTERS[s + 1], w, h, rows, ref, dis, { r[it] }) { d[it] }
                w /= 2
                h /= 2
            }
            return out
        }

        /** C's MAX(x, 0.0), the floor libvmaf puts under scales 1 to 3. */
        private fun atLeastZero(x: Double) = if (x > 0.0) x else 0.0

        /** The row buffers, sized for the full width and the widest filter. */
        private class Rows(w: Int) {
            val v = Array(5) { FloatArray(w) }
            val m = Array(5) { FloatArray(w) }
            val pad = FloatArray(w + 16)
        }

        /** One scale's information ratio: the numerator's sum over the denominator's. */
        private inline fun scale(
            f: FloatArray,
            w: Int,
            h: Int,
            rows: Rows,
            ref: (Int) -> Float,
            dis: (Int) -> Float
        ): Double {
            val v = rows.v
            val m = rows.m
            var num = 0f
            var den = 0f
            val r = f.size / 2
            for (i in 0 until h) {
                for (b in v) b.fill(0f, 0, w)
                val sa = v[0]
                val sb = v[1]
                val saa = v[2]
                val sbb = v[3]
                val sab = v[4]
                // Four taps a sweep, as in horizontal; then one at a time.
                var k = 0
                while (k + 4 <= f.size) {
                    val o0 = mirror(i - r + k, h) * w
                    val o1 = mirror(i - r + k + 1, h) * w
                    val o2 = mirror(i - r + k + 2, h) * w
                    val o3 = mirror(i - r + k + 3, h) * w
                    val c0 = f[k]
                    val c1 = f[k + 1]
                    val c2 = f[k + 2]
                    val c3 = f[k + 3]
                    for (j in 0 until w) {
                        val a0 = ref(o0 + j)
                        val a1 = ref(o1 + j)
                        val a2 = ref(o2 + j)
                        val a3 = ref(o3 + j)
                        val b0 = dis(o0 + j)
                        val b1 = dis(o1 + j)
                        val b2 = dis(o2 + j)
                        val b3 = dis(o3 + j)
                        sa[j] = sa[j] + c0 * a0 + c1 * a1 + c2 * a2 + c3 * a3
                        sb[j] = sb[j] + c0 * b0 + c1 * b1 + c2 * b2 + c3 * b3
                        saa[j] = saa[j] + c0 * (a0 * a0) + c1 * (a1 * a1) + c2 * (a2 * a2) + c3 * (a3 * a3)
                        sbb[j] = sbb[j] + c0 * (b0 * b0) + c1 * (b1 * b1) + c2 * (b2 * b2) + c3 * (b3 * b3)
                        sab[j] = sab[j] + c0 * (a0 * b0) + c1 * (a1 * b1) + c2 * (a2 * b2) + c3 * (a3 * b3)
                    }
                    k += 4
                }
                while (k < f.size) {
                    val o = mirror(i - r + k, h) * w
                    val c = f[k]
                    for (j in 0 until w) {
                        val a = ref(o + j)
                        val b = dis(o + j)
                        sa[j] += c * a
                        sb[j] += c * b
                        saa[j] += c * (a * a)
                        sbb[j] += c * (b * b)
                        sab[j] += c * (a * b)
                    }
                    k++
                }
                for (q in 0 until 5) horizontal(f, v[q], w, rows.pad, m[q])
                var rowNum = 0f
                var rowDen = 0f
                val mu1 = m[0]
                val mu2 = m[1]
                val xx = m[2]
                val yy = m[3]
                val xy = m[4]
                for (j in 0 until w) {
                    val m1 = mu1[j]
                    val m2 = mu2[j]
                    var s1 = xx[j] - m1 * m1
                    var s2 = yy[j] - m2 * m2
                    val s12 = xy[j] - m1 * m2
                    s1 = if (s1 > 0f) s1 else 0f
                    s2 = if (s2 > 0f) s2 else 0f
                    var g = s12 / (s1 + EPS)
                    var sv = s2 - g * s12
                    if (s1 < EPS) {
                        g = 0f
                        sv = s2
                        s1 = 0f
                    }
                    if (s2 < EPS) {
                        g = 0f
                        sv = 0f
                    }
                    if (g < 0f) {
                        sv = s2
                        g = 0f
                    }
                    sv = if (sv > EPS) sv else EPS
                    g = if (g < GAIN_LIMIT) g else GAIN_LIMIT
                    var numVal = log2((1.0 + (g * g * s1).toDouble() / (sv.toDouble() + SIGMA_NSQ)).toFloat())
                    var denVal = log2((1.0 + s1.toDouble() / SIGMA_NSQ).toFloat())
                    if (s12 < 0f) numVal = 0f
                    if (s1 < SIGMA_NSQ) {
                        numVal = 1f - s2 * SIGMA_MAX_INV
                        denVal = 1f
                    }
                    rowNum += numVal
                    rowDen += denVal
                }
                num += rowNum
                den += rowDen
            }
            return num.toDouble() / den.toDouble()
        }

        /**
         * The next scale of both pictures: [f] - the next scale's own filter,
         * as libvmaf uses - at every other row and column, into [ref] and [dis].
         */
        private inline fun halve(
            f: FloatArray,
            w: Int,
            h: Int,
            rows: Rows,
            ref: FloatArray,
            dis: FloatArray,
            refSrc: (Int) -> Float,
            disSrc: (Int) -> Float
        ) {
            val n = w / 2
            for (i in 0 until h / 2) {
                vertical(f, 2 * i, w, h, rows.v[0], refSrc)
                vertical(f, 2 * i, w, h, rows.v[1], disSrc)
                horizontalEven(f, rows.v[0], w, rows.pad, ref, i * n)
                horizontalEven(f, rows.v[1], w, rows.pad, dis, i * n)
            }
        }

        /**
         * libvmaf's log2f: the exponent exactly, the mantissa by [LOG2_POLY].
         * Not quite log2, but what the model was trained on.
         */
        private fun log2(x: Float): Float {
            if (x == 0f) return Float.NEGATIVE_INFINITY
            if (x < 0f) return Float.NaN
            val bits = x.toRawBits()
            val exponent = (bits and 0x7F800000) ushr 23
            val remain = Float.fromBits((bits and 0x007FFFFF) or 0x3F800000) - 1.0f
            var p = 0f
            for (c in LOG2_POLY) p = p * remain + c
            return (exponent - 127).toFloat() + p
        }

        /**
         * libvmaf's Gaussian of [size] taps, its spread a fifth of that, made
         * the way libvmaf makes it - divided, oddly, by its own normalising
         * factor, which the final division by the sum cancels - so every tap
         * is the same float.
         */
        private fun gaussian(size: Int): FloatArray {
            val stdev = size / 5.0f
            val out = FloatArray(size)
            var sum = 0f
            val k = (size - 1) / 2
            for (i in 0 until size) {
                val x = (i - k).toFloat().toDouble()
                val num = exp(-0.5 * x / stdev * x / stdev).toFloat()
                val den = (1 / (stdev * sqrt(2 * PI))).toFloat()
                out[i] = num / den
                sum += out[i]
            }
            for (i in 0 until size) out[i] /= sum
            return out
        }
    }

    /**
     * The detail loss measure: how much of the original's detail the copy
     * lost, as against noise it added, at four scales of a wavelet.
     *
     * Each scale splits a picture into its blur and three bands of detail
     * (across, down, diagonal). The copy's detail is divided into what it
     * kept of the original's and what it added; the kept part is weighted
     * by how visible each band is, less what busy surroundings would hide,
     * and summed as a cube-root norm against the original's own detail.
     * The outer tenth of each side is left out. A scale's blur is the next
     * scale's picture; everything else is worked out a row at a time.
     */
    private object Adm {

        /** The db2 wavelet's low and high pass, doubles stored as floats as in C. */
        private val LO = floats(0.482962913144690, 0.836516303737469, 0.224143868041857, -0.129409522550921)
        private val HI = floats(-0.129409522550921, -0.224143868041857, 0.836516303737469, -0.482962913144690)

        /** The share of each side left out. */
        private const val BORDER = 0.1

        /** How many times stronger a copy's detail may be and still count as kept. */
        private const val GAIN_LIMIT = 100.0

        /** The noise floor added to every sum, per pixel measured. */
        private const val NOISE_WEIGHT = 0.03125

        /** libvmaf's 1/30 and 1/15, written as the doubles it uses. */
        private const val ONE_BY_30 = 0.0333333351
        private const val ONE_BY_15 = 0.0666666701

        /** Keeps a division by no detail finite. */
        private const val EPS = 1e-30f

        /** Within a degree: the test for a copy's detail pointing the original's way. */
        private val COS_1DEG_SQ = (cos(1.0 * PI / 180.0) * cos(1.0 * PI / 180.0)).toFloat()

        /** 1.0f / p for libvmaf's p-norm of 3, as powf receives it. */
        private val CUBE_ROOT = (1.0 / 3.0).toFloat()

        /** Watson's model parameters for brightness, and the 7-9 wavelet's amplitudes at scales 0 to 3. */
        private val A = 0.495.toFloat()
        private val K = 0.466.toFloat()
        private val F0 = 0.401.toFloat()
        private val G = floats(1.501, 1.0, 0.534, 1.0)
        private val AMPLITUDES = arrayOf(
            floats(0.62171, 0.67234, 0.72709, 0.67234),
            floats(0.34537, 0.41317, 0.49428, 0.41317),
            floats(0.18004, 0.22727, 0.28688, 0.22727),
            floats(0.091401, 0.11792, 0.15214, 0.11792)
        )

        /** How visible each scale's bands are (Watson et al., 1997): across and down share one weight. */
        private val ACROSS_DOWN = FloatArray(4) { 1.0f / quantStep(it, 1) }
        private val DIAGONAL = FloatArray(4) { 1.0f / quantStep(it, 2) }

        fun of(reference: Plane, distorted: Plane): Double {
            var w = reference.width
            var h = reference.height
            val limit = 1e-10 * (w * h) / (1920.0 * 1080.0)
            val rp = reference.pixels
            val dp = distorted.pixels
            val work = Work(w)
            var num = 0.0
            var den = 0.0
            var ref = FloatArray(0)
            var dis = FloatArray(0)
            for (s in 0 until 4) {
                val next = if (s < 3) ((w + 1) / 2) * ((h + 1) / 2) else 0
                val nextRef = FloatArray(next)
                val nextDis = FloatArray(next)
                if (s == 0) {
                    scale(s, w, h, work, nextRef, nextDis, { ((rp[it].toInt() and 0xFF) - 128).toFloat() }) {
                        ((dp[it].toInt() and 0xFF) - 128).toFloat()
                    }
                } else {
                    val r = ref
                    val d = dis
                    scale(s, w, h, work, nextRef, nextDis, { r[it] }) { d[it] }
                }
                num += work.num
                den += work.den
                ref = nextRef
                dis = nextDis
                w = (w + 1) / 2
                h = (h + 1) / 2
            }
            num = if (num < limit) 0.0 else num
            den = if (den < limit) 0.0 else den
            return if (den == 0.0) 1.0 else num / den
        }

        /**
         * Row buffers for one scale, sized for the full width: the wavelet's
         * two passes, one row of each band, and the last three rows of what
         * the masking step reads around each pixel.
         */
        private class Work(w: Int) {
            val half = (w + 1) / 2
            val lo = FloatArray(w)
            val hi = FloatArray(w)
            val refBands = Array(4) { FloatArray(half) }
            val disBands = Array(4) { FloatArray(half) }
            val kept = Array(3) { FloatArray(3 * half) }
            val added = Array(3) { FloatArray(3 * half) }
            val spread = Array(3) { FloatArray(3 * half) }
            val indexX = IntArray(4 * half)
            var num = 0f
            var den = 0f
        }

        /**
         * One scale of a [w] x [h] picture pair read through [refSrc] and
         * [disSrc]: its numerator and denominator into [work], its blurs into
         * [nextRef] and [nextDis] (when they have room).
         */
        private inline fun scale(
            s: Int,
            w: Int,
            h: Int,
            work: Work,
            nextRef: FloatArray,
            nextDis: FloatArray,
            refSrc: (Int) -> Float,
            disSrc: (Int) -> Float
        ) {
            val w2 = (w + 1) / 2
            val h2 = (h + 1) / 2
            indices(w, work.indexX)
            // Where the measure is taken, and where the steps before it are
            // worked out: a tap further each way. Both as libvmaf rounds them.
            val left = (w2 * BORDER - 0.5).toInt()
            val top = (h2 * BORDER - 0.5).toInt()
            val right = w2 - left
            val bottom = h2 - top
            val rawLeft = (w2 * BORDER - 0.5 - 1).toInt()
            val rawTop = (h2 * BORDER - 0.5 - 1).toInt()
            val cLeft = maxOf(rawLeft, 0)
            val cTop = maxOf(rawTop, 0)
            val cRight = minOf(w2 - rawLeft + 2, w2)
            val cBottom = minOf(h2 - rawTop + 2, h2)
            val fHv = ACROSS_DOWN[s]
            val fD = DIAGONAL[s]
            var denH = 0f
            var denV = 0f
            var denD = 0f
            val cm = FloatArray(3)
            for (i in 0 until h2) {
                dwtRow(i, w, h, work, work.refBands, refSrc)
                dwtRow(i, w, h, work, work.disBands, disSrc)
                if (nextRef.isNotEmpty()) {
                    work.refBands[0].copyInto(nextRef, i * w2, 0, w2)
                    work.disBands[0].copyInto(nextDis, i * w2, 0, w2)
                }
                if (i in top until bottom) {
                    var rowH = 0f
                    var rowV = 0f
                    var rowD = 0f
                    val bh = work.refBands[2]
                    val bv = work.refBands[1]
                    val bd = work.refBands[3]
                    for (j in left until right) {
                        val ah = abs(fHv * bh[j])
                        val av = abs(fHv * bv[j])
                        val ad = abs(fD * bd[j])
                        rowH += ah * ah * ah
                        rowV += av * av * av
                        rowD += ad * ad * ad
                    }
                    denH += rowH
                    denV += rowV
                    denD += rowD
                }
                if (i in cTop until cBottom) decouple(i % 3, cLeft, cRight, w2, work, fHv, fD)
                if (i >= 1 && i - 1 in top until bottom) mask(i - 1, h2, w2, left, right, work, fHv, fD, cm)
            }
            if (h2 - 1 in top until bottom) mask(h2 - 1, h2, w2, left, right, work, fHv, fD, cm)
            val noise = powf(((right - left) * (bottom - top) * NOISE_WEIGHT).toFloat(), CUBE_ROOT)
            work.num = (powf(cm[0], CUBE_ROOT) + noise) + (powf(cm[1], CUBE_ROOT) + noise) +
                (powf(cm[2], CUBE_ROOT) + noise)
            work.den = (powf(denH, CUBE_ROOT) + noise) + (powf(denV, CUBE_ROOT) + noise) +
                (powf(denD, CUBE_ROOT) + noise)
        }

        /** The four source columns of each output column of a [w]-wide row, reflected at the edges as libvmaf does. */
        private fun indices(w: Int, out: IntArray) {
            val n = (w + 1) / 2
            for (j in 0 until n) {
                val i0 = 2 * j - 1
                out[j] = if (i0 < 0) -i0 else if (i0 >= w) 2 * w - i0 - 1 else i0
                out[n + j] = reflect(2 * j, w)
                out[2 * n + j] = reflect(2 * j + 1, w)
                out[3 * n + j] = reflect(2 * j + 2, w)
            }
        }

        private fun reflect(i: Int, n: Int) = if (i >= n) 2 * n - i - 1 else i

        /**
         * Row [i] of the db2 wavelet of a [w] x [h] picture read through
         * [src], into [bands]: blur, then across, down and diagonal detail
         * in the order libvmaf stores them (a, v, h, d).
         */
        private inline fun dwtRow(i: Int, w: Int, h: Int, work: Work, bands: Array<FloatArray>, src: (Int) -> Float) {
            val t0 = 2 * i - 1
            val r0 = (if (t0 < 0) -t0 else if (t0 >= h) 2 * h - t0 - 1 else t0) * w
            val r1 = reflect(2 * i, h) * w
            val r2 = reflect(2 * i + 1, h) * w
            val r3 = reflect(2 * i + 2, h) * w
            val lo = work.lo
            val hi = work.hi
            val l0 = LO[0]
            val l1 = LO[1]
            val l2 = LO[2]
            val l3 = LO[3]
            val h0 = HI[0]
            val h1 = HI[1]
            val h2 = HI[2]
            val h3 = HI[3]
            for (j in 0 until w) {
                val s0 = src(r0 + j)
                val s1 = src(r1 + j)
                val s2 = src(r2 + j)
                val s3 = src(r3 + j)
                lo[j] = 0f + l0 * s0 + l1 * s1 + l2 * s2 + l3 * s3
                hi[j] = 0f + h0 * s0 + h1 * s1 + h2 * s2 + h3 * s3
            }
            val n = (w + 1) / 2
            val x = work.indexX
            val a = bands[0]
            val v = bands[1]
            val hh = bands[2]
            val d = bands[3]
            for (j in 0 until n) {
                val j0 = x[j]
                val j1 = x[n + j]
                val j2 = x[2 * n + j]
                val j3 = x[3 * n + j]
                a[j] = 0f + l0 * lo[j0] + l1 * lo[j1] + l2 * lo[j2] + l3 * lo[j3]
                v[j] = 0f + h0 * lo[j0] + h1 * lo[j1] + h2 * lo[j2] + h3 * lo[j3]
                hh[j] = 0f + l0 * hi[j0] + l1 * hi[j1] + l2 * hi[j2] + l3 * hi[j3]
                d[j] = 0f + h0 * hi[j0] + h1 * hi[j1] + h2 * hi[j2] + h3 * hi[j3]
            }
        }

        /**
         * The copy's detail in this row split into what it kept of the
         * original's and what it added; the added part weighted by how
         * visible it is, and a thirtieth of that kept for the masking step.
         * Written to ring row [slot].
         */
        private fun decouple(slot: Int, from: Int, until: Int, w2: Int, work: Work, fHv: Float, fD: Float) {
            val o = slot * w2
            val rb = work.refBands
            val db = work.disBands
            for (j in from until until) {
                val oh = rb[2][j]
                val ov = rb[1][j]
                val od = rb[3][j]
                val th = db[2][j]
                val tv = db[1][j]
                val td = db[3][j]
                var kh = th / (oh + EPS)
                var kv = tv / (ov + EPS)
                var kd = td / (od + EPS)
                kh = if (kh < 0f) 0f else if (kh > 1f) 1f else kh
                kv = if (kv < 0f) 0f else if (kv > 1f) 1f else kv
                kd = if (kd < 0f) 0f else if (kd > 1f) 1f else kd
                var rh = kh * oh
                var rv = kv * ov
                var rd = kd * od
                // Within a degree of the original's direction, the copy's
                // detail counts as kept even where it is stronger, up to
                // a hundredfold.
                val dot = oh * th + ov * tv
                val oMag = oh * oh + ov * ov
                val tMag = th * th + tv * tv
                val aligned = dot >= 0f && dot * dot >= COS_1DEG_SQ * oMag * tMag
                if (aligned) {
                    rh = gained(rh, th)
                    rv = gained(rv, tv)
                    rd = gained(rd, td)
                }
                work.kept[0][o + j] = rh
                work.kept[1][o + j] = rv
                work.kept[2][o + j] = rd
                val ah = fHv * (th - rh)
                val av = fHv * (tv - rv)
                val ad = fD * (td - rd)
                work.added[0][o + j] = ah
                work.added[1][o + j] = av
                work.added[2][o + j] = ad
                work.spread[0][o + j] = (ONE_BY_30 * abs(ah)).toFloat()
                work.spread[1][o + j] = (ONE_BY_30 * abs(av)).toFloat()
                work.spread[2][o + j] = (ONE_BY_30 * abs(ad)).toFloat()
            }
        }

        /** libvmaf's enhancement gain: [kept] scaled up towards [copy], in double as C does it. */
        private fun gained(kept: Float, copy: Float): Float {
            var k = kept
            if (k > 0.0) {
                val g = k * GAIN_LIMIT
                k = (if (g < copy) g else copy.toDouble()).toFloat()
            }
            if (k < 0.0) {
                val g = k * GAIN_LIMIT
                k = (if (g > copy) g else copy.toDouble()).toFloat()
            }
            return k
        }

        /**
         * Contrast masking for row [i]: each pixel's kept detail, weighted,
         * less what the added detail around it would hide, cubed and added
         * to [acc] (across, down, diagonal). Above the first row and left of
         * the first column it reads the row or column inside; below the last
         * and right of the last, the last again - as libvmaf does.
         */
        private fun mask(
            i: Int,
            h2: Int,
            w2: Int,
            left: Int,
            right: Int,
            work: Work,
            fHv: Float,
            fD: Float,
            acc: FloatArray
        ) {
            val up = (if (i == 0) 1 else i - 1) % 3 * w2
            val mid = i % 3 * w2
            val down = (if (i == h2 - 1) h2 - 1 else i + 1) % 3 * w2
            var rowH = 0f
            var rowV = 0f
            var rowD = 0f
            for (j in left until right) {
                val jl = if (j == 0) 1 else j - 1
                val jr = if (j == w2 - 1) w2 - 1 else j + 1
                var thr = 0f
                for (t in 0 until 3) {
                    val s = work.spread[t]
                    var sum = 0f
                    sum += s[up + jl]
                    sum += s[up + j]
                    sum += s[up + jr]
                    sum += s[mid + jl]
                    sum = (sum + ONE_BY_15 * abs(work.added[t][mid + j])).toFloat()
                    sum += s[mid + jr]
                    sum += s[down + jl]
                    sum += s[down + j]
                    sum += s[down + jr]
                    thr += sum
                }
                var xh = abs(work.kept[0][mid + j] * fHv) - thr
                var xv = abs(work.kept[1][mid + j] * fHv) - thr
                var xd = abs(work.kept[2][mid + j] * fD) - thr
                xh = if (xh < 0f) 0f else xh
                xv = if (xv < 0f) 0f else xv
                xd = if (xd < 0f) 0f else xd
                rowH += xh * xh * xh
                rowV += xv * xv * xv
                rowD += xd * xd * xd
            }
            acc[0] += rowH
            acc[1] += rowV
            acc[2] += rowD
        }

        /**
         * The smallest visible step of band [theta] at scale [lambda], for a
         * 1080-line screen seen from three times its height.
         */
        private fun quantStep(lambda: Int, theta: Int): Float {
            val r = (3.0 * 1080 * PI / 180.0).toFloat()
            val temp = log10(2.0.pow(lambda + 1) * F0 * G[theta] / r).toFloat()
            return (2.0 * A * 10.0.pow((K * temp * temp).toDouble()) / AMPLITUDES[lambda][theta]).toFloat()
        }
    }
}
