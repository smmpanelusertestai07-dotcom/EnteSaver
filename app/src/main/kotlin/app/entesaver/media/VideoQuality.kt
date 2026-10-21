package app.entesaver.media

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.Log
import app.entesaver.BuildConfig
import app.entesaver.core.logic.Vmaf
import java.io.File
import kotlin.math.roundToLong

/**
 * How a copy of a video looks beside its original, measured: VMAF ([Vmaf]) on
 * frames from across the clip.
 *
 * The original is read once ([of]): a frame at each of [MOMENTS] moments spread
 * evenly through it, clear of the first and last, and the frames just before
 * and after each, which VMAF's motion term is worked out from. Each copy is
 * then read at the same moments ([score]) - a copy keeps its original's
 * timestamps - so a second or third copy of the same clip costs only its own
 * frames.
 *
 * An encoder takes turns between kinds of frame - a full one, then one it
 * spends less on - and a copy's frames read a few points apart by turns. On
 * the savings benchmark's clips, moments an even number of frames apart all
 * fell on the same kind: six moments of a 20-second clip read 94 where every
 * frame read 90, twelve read 85. So moment number i is moved on, by up to
 * [PHASES] - 1 frames, to a frame whose number from the start of the copy
 * leaves i's remainder when divided by [PHASES]: every place in a turn of up
 * to [PHASES] frames is then read as often, however far apart the moments
 * fall. Fewer moments are read where the app's memory would not hold them
 * (planesFor). Where a copy's times run a frame or two off its original's, as an
 * older Android can read some files' times, the copy is lined up first: at
 * the moment that moves most, the frame within [SHIFT_FRAMES] either way that
 * clearly matches best says by how much.
 *
 * Frames are read as their decoder gives them (LumaReader): brightness only,
 * a byte a pixel, which is all VMAF looks at - the original's in its copies'
 * colour ([look]), as the savings benchmark's ffmpeg brings it before its
 * libvmaf compares the two (Recolour), so it is read once its first copy says
 * what that is. Where a phone's decoder will not
 * hand them over that way, the original and its copies are all read instead
 * as MediaMetadataRetriever's pictures, whose brightness is worked out again
 * from their colours: the two still compare, though VMAF then reads a little
 * low, which can only keep a copy larger.
 *
 * A 4K picture is read at 1080p, the most a phone's screen shows of it, which
 * also keeps its frames to the memory of a 1080p clip's; anything smaller -
 * a tall screen recording included, which a phone shows pixel for pixel - is
 * read at its own size. A moment whose frames cannot be read is left out;
 * with too few read, there is no score (null), which the caller never takes
 * as a pass.
 */
internal class VideoQuality private constructor(
    private val moments: List<Moment>,
    private val way: Way,
    /** One frame's time at the clip's own rate. */
    private val frameUs: Long,
    /** The colour of the copies the original was read for (LumaReader.colourOf); null for as stored. */
    val look: LumaReader.Colour?
) {

    /** What a copy measured: mean and lowest VMAF over the moments, the phone model's mean, and how many were read. */
    data class Score(val vmaf: Double, val lowest: Double, val phone: Double, val moments: Int)

    /**
     * One moment of the original: when it is in the copy, its brightness, and
     * its motion term. A copy of the whole clip shows it at the original's own
     * time; a copy of a stretch of it, that much after the stretch began.
     */
    private class Moment(val copyTimeUs: Long, val plane: Vmaf.Plane, val motion2: Double)

    /** How the original was read, which its copies are read the same way as. */
    private sealed interface Way {

        /** As its decoder gave the frames, from a file whose frames turn [rotation] to be shown. */
        class Decoded(val rotation: Int) : Way

        /** As MediaMetadataRetriever's pictures, [scaled] down for a large picture. */
        class Pictures(val scaled: Boolean) : Way
    }

    /**
     * The copy's frames at the original's moments, scored; null when too few
     * could be read, or the copy is not of the colour the original was read in.
     */
    fun score(copy: File): Score? = try {
        when (way) {
            is Way.Decoded -> LumaReader.open(copy)?.use { reader ->
                reader.turn = reader.rotation - way.rotation
                val shiftUs = shiftOf(reader)
                if (BuildConfig.DEBUG) Log.d(TAG, "copy ${copy.name}: shift $shiftUs us, turn ${reader.turn}")
                if (look != null && reader.colour != look) return null
                scored { m -> frameAt(reader, m.copyTimeUs + shiftUs) }
            }
            is Way.Pictures -> {
                val mmr = MediaMetadataRetriever()
                try {
                    mmr.setDataSource(copy.absolutePath)
                    scored { m -> pictureAt(mmr, m.copyTimeUs, way.scaled) }
                } finally {
                    runCatching { mmr.release() }
                }
            }
        }
    } catch (e: Exception) {
        null
    } catch (e: OutOfMemoryError) {
        null
    }

    /** Each moment scored against the copy's frame at it, as [planeAt] reads that. */
    private fun scored(planeAt: (Moment) -> Vmaf.Plane?): Score? {
        val scores = mutableListOf<Double>()
        for (m in moments) {
            val plane = planeAt(m) ?: continue
            if (plane.width != m.plane.width || plane.height != m.plane.height) continue
            val features = Vmaf.features(m.plane, plane)
            scores += Vmaf.score(features, m.motion2)
            if (BuildConfig.DEBUG) {
                Log.d(
                    TAG,
                    "moment ${m.copyTimeUs}: original ${digest(m.plane)} copy ${digest(plane)} motion2 ${m.motion2} " +
                        "adm2 ${features.adm2} vif ${features.vif0} ${features.vif1} ${features.vif2} " +
                        "${features.vif3} vmaf ${scores.last()}"
                )
            }
        }
        // The phone model's score is each moment's, then their mean, as
        // libvmaf pools it: its curve flattens near the top, so the curve
        // of the mean would read a little high.
        return if (scores.size < minOf(MIN_MOMENTS, moments.size)) {
            null
        } else {
            Score(scores.average(), scores.min(), scores.map { Vmaf.phone(it) }.average(), scores.size)
        }
    }

    /** The copy's frame shown at [timeUs]: the first at or after it, less half a frame. */
    private fun frameAt(reader: LumaReader, timeUs: Long): Vmaf.Plane? {
        var plane: Vmaf.Plane? = null
        reader.read(timeUs - frameUs / 2) { f ->
            plane = f.plane
            if (BuildConfig.DEBUG) Log.d(TAG, "copy frame for $timeUs: ${f.timeUs}")
            false
        }
        return plane
    }

    /**
     * How far the copy's times run from its original's: at the moment that
     * moves most, from the copy's frame at the moment's own time to the one
     * within [SHIFT_FRAMES] either way that matches the original's best. None
     * unless that one matches clearly better - in a still scene none does,
     * and there the frames are alike anyway.
     */
    private fun shiftOf(reader: LumaReader): Long {
        val m = moments.maxByOrNull { it.motion2 } ?: return 0
        val near = mutableListOf<Pair<Long, Double>>()
        val lastUs = m.copyTimeUs + SHIFT_FRAMES * frameUs - frameUs / 2
        reader.read(m.copyTimeUs - SHIFT_FRAMES * frameUs - frameUs / 2) { f ->
            if (f.plane.width == m.plane.width && f.plane.height == m.plane.height) {
                near += f.timeUs to difference(m.plane, f.plane)
            }
            f.timeUs < lastUs
        }
        val own = near.firstOrNull { it.first >= m.copyTimeUs - frameUs / 2 } ?: return 0
        val best = near.minByOrNull { it.second } ?: return 0
        return if (best.second < own.second * CLEARLY) best.first - own.first else 0
    }

    companion object {

        /** Several scores as one, each counted by the moments it was read at. */
        fun pooled(scores: List<Score>): Score? {
            val moments = scores.sumOf { it.moments }
            if (moments == 0) return null
            return Score(
                scores.sumOf { it.vmaf * it.moments } / moments,
                scores.minOf { it.lowest },
                scores.sumOf { it.phone * it.moments } / moments,
                moments
            )
        }

        /** Fewer moments read than this, and a copy has no score. */
        const val MIN_MOMENTS = 4

        /**
         * How many moments a clip is read at. On the benchmark's clips, the
         * mean of 24 came within half a point of every frame's (one standard
         * deviation), of 12 within one.
         */
        const val MOMENTS = 24

        /** The longest turn of kinds of frame the moments are spread over (see the class). */
        const val PHASES = 4

        /** The original's moments may take up this share of the app's memory at most: a quarter. */
        private const val MEMORY_SHARE = 4

        /** How many frames either way a copy is looked at to line it up with its original. */
        const val SHIFT_FRAMES = 3

        /** A frame matches clearly better when its difference is under this share of the other's. */
        private const val CLEARLY = 0.5

        /** A picture read as MediaMetadataRetriever's is scaled to within this each way when large. */
        private const val LONG_SIDE = 1920

        /**
         * How many moments of a [width] x [height] picture this phone holds:
         * [MOMENTS], or as many as fit in [MEMORY_SHARE] of the memory the app
         * may use, a byte a pixel as read (a large picture halved) - never
         * fewer than [MIN_MOMENTS].
         */
        fun planesFor(width: Int, height: Int, maxMemoryBytes: Long = Runtime.getRuntime().maxMemory()): Int {
            var pixels = width.toLong() * height
            while (pixels > LumaReader.MAX_PIXELS) pixels /= 4
            val fit = maxMemoryBytes / MEMORY_SHARE / pixels.coerceAtLeast(1)
            return fit.coerceIn(MIN_MOMENTS.toLong(), MOMENTS.toLong()).toInt()
        }

        /**
         * The original at [uri], read in its copies' colour [look] at
         * [planesFor] moments of its [durationMs], frames [fps] apart for the
         * motion term; null when too few moments could be read.
         */
        fun of(
            context: Context,
            uri: Uri,
            durationMs: Long,
            fps: Float,
            width: Int,
            height: Int,
            look: LumaReader.Colour? = null
        ): VideoQuality? = read(
            context, uri, 0..durationMs, durationMs, planesFor(width, height), fps, width, height, fromStart = false, look
        )

        /**
         * The same for a copy of one stretch of the original, from the first
         * to the last millisecond of [windowMs] (Excerpts): [count] moments of
         * it, found in the copy that far after it began.
         */
        fun ofWindow(
            context: Context,
            uri: Uri,
            windowMs: LongRange,
            durationMs: Long,
            count: Int,
            fps: Float,
            width: Int,
            height: Int,
            look: LumaReader.Colour? = null
        ): VideoQuality? = read(context, uri, windowMs, durationMs, count, fps, width, height, fromStart = true, look)

        private fun read(
            context: Context,
            uri: Uri,
            windowMs: LongRange,
            durationMs: Long,
            count: Int,
            fps: Float,
            width: Int,
            height: Int,
            fromStart: Boolean,
            look: LumaReader.Colour?
        ): VideoQuality? {
            if (durationMs <= 0 || windowMs.last <= windowMs.first) return null
            val frameUs = (1_000_000.0 / (if (fps.isFinite() && fps > 1f) fps else 30f)).toLong()
            val startUs = windowMs.first * 1000
            val lengthUs = (windowMs.last - windowMs.first) * 1000
            val times = momentTimes(startUs, lengthUs, count, frameUs)
                .filter { it - frameUs >= 0 && it + frameUs < durationMs * 1000 }
            val needed = minOf(MIN_MOMENTS, count)
            if (times.size < needed) return null
            val sinceUs = if (fromStart) startUs else 0L
            val decoded = guarded {
                LumaReader.open(context, uri)?.use { reader ->
                    reader.into = look
                    decodedMoments(reader, times, frameUs, sinceUs).takeIf { it.size >= needed }
                        ?.let { VideoQuality(it, Way.Decoded(reader.rotation), frameUs, look) }
                }
            }
            if (decoded != null) return decoded
            val scaled = width.toLong() * height > LumaReader.MAX_PIXELS
            return guarded {
                pictureMoments(context, uri, times, frameUs, sinceUs, scaled).takeIf { it.size >= needed }
                    ?.let { VideoQuality(it, Way.Pictures(scaled), frameUs, look) }
            }
        }

        /**
         * When each of [count] moments of a stretch [lengthUs] long from
         * [startUs] is read, frames [frameUs] apart: spread evenly, and moment
         * number i moved on to the frame whose number from [startUs] leaves
         * i's remainder by [PHASES] (see the class).
         */
        fun momentTimes(startUs: Long, lengthUs: Long, count: Int, frameUs: Long): List<Long> =
            (0 until count).map { i ->
                val frame = (lengthUs * (i + 0.5) / count / frameUs).roundToLong()
                startUs + (frame + Math.floorMod(i - frame, PHASES.toLong())) * frameUs
            }

        private inline fun <T> guarded(block: () -> T?): T? = try {
            block()
        } catch (e: Exception) {
            null
        } catch (e: OutOfMemoryError) {
            null
        }

        /**
         * The original's moments as its decoder gives them, one pass each: at
         * each of [times], the first frame shown at or after it, less half a
         * frame, and the frames just before and after that one - or the next,
         * where the first is the first read and has none before it. A copy is
         * read at that frame's own time, less [sinceUs].
         */
        private fun decodedMoments(
            reader: LumaReader,
            times: List<Long>,
            frameUs: Long,
            sinceUs: Long
        ): List<Moment> {
            val moments = mutableListOf<Moment>()
            for (t in times) {
                val seen = ArrayList<LumaReader.Frame>(4)
                var here = -1
                reader.read(t - 2 * frameUs) { f ->
                    seen += f
                    if (here < 0 && seen.size >= 2 && f.timeUs >= t - frameUs / 2) {
                        here = seen.size - 1
                    } else if (here < 0 && seen.size > 2) {
                        seen.removeAt(0)
                    }
                    here < 0 || seen.size < here + 2
                }
                if (here < 1 || seen.size < here + 2) continue
                val at = seen[here]
                val moment = momentOf(seen[here - 1].plane, at.plane, seen[here + 1].plane, at.timeUs - sinceUs)
                if (BuildConfig.DEBUG) {
                    Log.d(
                        TAG,
                        "original moment $t: before ${seen[here - 1].timeUs} here ${at.timeUs} " +
                            "after ${seen[here + 1].timeUs} motion2 ${moment?.motion2}"
                    )
                }
                moments += moment ?: continue
            }
            return moments
        }

        /** The same as MediaMetadataRetriever's pictures, at each of [times] and a frame either side. */
        private fun pictureMoments(
            context: Context,
            uri: Uri,
            times: List<Long>,
            frameUs: Long,
            sinceUs: Long,
            scaled: Boolean
        ): List<Moment> {
            val mmr = MediaMetadataRetriever()
            try {
                mmr.setDataSource(context, uri)
                val moments = mutableListOf<Moment>()
                for (t in times) {
                    val here = pictureAt(mmr, t, scaled) ?: continue
                    val before = pictureAt(mmr, t - frameUs, scaled) ?: continue
                    val after = pictureAt(mmr, t + frameUs, scaled) ?: continue
                    moments += momentOf(before, here, after, t - sinceUs) ?: continue
                }
                return moments
            } finally {
                runCatching { mmr.release() }
            }
        }

        /** A moment of [here], its motion term from the frames [before] and [after] it. */
        private fun momentOf(before: Vmaf.Plane, here: Vmaf.Plane, after: Vmaf.Plane, copyTimeUs: Long): Moment? {
            if (listOf(before, after).any { it.width != here.width || it.height != here.height }) return null
            val blur = Vmaf.motionBlur(here)
            val motion2 = minOf(
                Vmaf.motion(Vmaf.motionBlur(before), blur, here.width, here.height),
                Vmaf.motion(blur, Vmaf.motionBlur(after), here.width, here.height)
            )
            return Moment(copyTimeUs, here, motion2)
        }

        /** The savings benchmark's diagnostics only (debug builds): each moment as read and scored. */
        private const val TAG = "VideoQuality"

        /** A plane's size, mean and a sum of its bytes, to match against another reading of the same frame. */
        private fun digest(p: Vmaf.Plane): String {
            var sum = 0L
            for (i in 0 until p.width * p.height) sum += p.pixels[i].toInt() and 0xFF
            return "${p.width}x${p.height} sum $sum"
        }

        /** The mean squared difference of two planes, on every fourth pixel each way. */
        private fun difference(a: Vmaf.Plane, b: Vmaf.Plane): Double {
            var sum = 0L
            var n = 0
            for (y in 0 until a.height step 4) {
                val row = y * a.width
                for (x in 0 until a.width step 4) {
                    val d = (a.pixels[row + x].toInt() and 0xFF) - (b.pixels[row + x].toInt() and 0xFF)
                    sum += d * d
                    n++
                }
            }
            return sum.toDouble() / n.coerceAtLeast(1)
        }

        /**
         * The brightness of the picture shown at [timeUs], [scaled] to within
         * [LONG_SIDE] each way - the same for the original and every copy.
         */
        private fun pictureAt(mmr: MediaMetadataRetriever, timeUs: Long, scaled: Boolean): Vmaf.Plane? {
            val bitmap: Bitmap = (
                if (scaled) {
                    mmr.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST, LONG_SIDE, LONG_SIDE)
                } else {
                    mmr.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                }
                ) ?: return null
            return try {
                val luma = FrameQuality.lumaOf(bitmap)
                Vmaf.Plane(luma.plane, luma.width, luma.height)
            } finally {
                bitmap.recycle()
            }
        }
    }
}
