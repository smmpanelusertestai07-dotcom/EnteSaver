package app.entesaver.media

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import app.entesaver.core.logic.Vmaf
import java.io.File

/**
 * How a copy of a video looks beside its original, measured: VMAF ([Vmaf]) on
 * frames from across the clip.
 *
 * The original is read once ([of]): a frame at each of a few moments spread
 * evenly through it, clear of the first and last, and the frames either side
 * of each, which VMAF's motion term is worked out from. Each copy is then read
 * at the same moments ([score]) - a copy keeps its original's timestamps - so
 * a second or third copy of the same clip costs only its own frames.
 *
 * A 4K picture is read at 1080p, the most a phone's screen shows of it, which
 * also keeps its frames to the memory of a 1080p clip's; anything smaller -
 * a tall screen recording included, which a phone shows pixel for pixel - is
 * read at its own size.
 * Brightness only, a byte a pixel: VMAF looks at nothing else. A moment whose
 * frames cannot be read is left out; with too few read, there is no score
 * (null), which the caller never takes as a pass.
 */
internal class VideoQuality private constructor(private val moments: List<Moment>) {

    /** What a copy measured: mean and lowest VMAF over the moments, the phone model's mean, and how many were read. */
    data class Score(val vmaf: Double, val lowest: Double, val phone: Double, val moments: Int)

    /**
     * One moment of the original: when it is in the copy, its brightness, and
     * its motion term. A copy of the whole clip shows it at the original's own
     * time; a copy of a stretch of it, that much after the stretch began.
     */
    private class Moment(val copyTimeUs: Long, val plane: Vmaf.Plane, val motion2: Double)

    /** The copy's frames at the original's moments, scored; null when too few could be read. */
    fun score(copy: File): Score? {
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(copy.absolutePath)
            val scores = mutableListOf<Double>()
            for (m in moments) {
                val plane = planeAt(mmr, m.copyTimeUs, m.plane.width, m.plane.height) ?: continue
                if (plane.width != m.plane.width || plane.height != m.plane.height) continue
                scores += Vmaf.score(Vmaf.features(m.plane, plane), m.motion2)
            }
            if (scores.size < minOf(MIN_MOMENTS, moments.size)) {
                null
            } else {
                val mean = scores.average()
                Score(mean, scores.min(), Vmaf.phone(mean), scores.size)
            }
        } catch (e: Exception) {
            null
        } catch (e: OutOfMemoryError) {
            null
        } finally {
            runCatching { mmr.release() }
        }
    }

    companion object {

        /** Several scores as one, each counted by the moments it was read at. */
        fun pooled(scores: List<Score>): Score? {
            val moments = scores.sumOf { it.moments }
            if (moments == 0) return null
            val mean = scores.sumOf { it.vmaf * it.moments } / moments
            return Score(mean, scores.minOf { it.lowest }, Vmaf.phone(mean), moments)
        }

        /** Fewer moments read than this, and a copy has no score. */
        const val MIN_MOMENTS = 4

        /** One moment for every this many seconds of clip, between [FEWEST] and [MOST]. */
        private const val SECONDS_PER_MOMENT = 3.0
        const val FEWEST = 6
        const val MOST = 12

        /** A picture of more pixels than this is read scaled to within [LONG_SIDE] each way. */
        private const val MAX_PIXELS = 2_800_000L
        private const val LONG_SIDE = 1920

        /** How many moments a clip of [durationMs] is read at. */
        fun momentsFor(durationMs: Long): Int =
            (durationMs / 1000.0 / SECONDS_PER_MOMENT).toInt().coerceIn(FEWEST, MOST)

        /**
         * The original at [uri], read at [momentsFor] moments of its
         * [durationMs], frames [fps] apart for the motion term; null when too
         * few moments could be read.
         */
        fun of(context: Context, uri: Uri, durationMs: Long, fps: Float, width: Int, height: Int): VideoQuality? =
            read(context, uri, 0..durationMs, durationMs, momentsFor(durationMs), fps, width, height, fromStart = false)

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
            height: Int
        ): VideoQuality? = read(context, uri, windowMs, durationMs, count, fps, width, height, fromStart = true)

        private fun read(
            context: Context,
            uri: Uri,
            windowMs: LongRange,
            durationMs: Long,
            count: Int,
            fps: Float,
            width: Int,
            height: Int,
            fromStart: Boolean
        ): VideoQuality? {
            if (durationMs <= 0 || windowMs.last <= windowMs.first) return null
            val stepUs = (1_000_000.0 / (if (fps.isFinite() && fps > 1f) fps else 30f)).toLong()
            val startUs = windowMs.first * 1000
            val lengthUs = (windowMs.last - windowMs.first) * 1000
            val mmr = MediaMetadataRetriever()
            return try {
                mmr.setDataSource(context, uri)
                val moments = mutableListOf<Moment>()
                for (i in 0 until count) {
                    val t = startUs + (lengthUs * (i + 0.5) / count).toLong()
                    if (t - stepUs < 0 || t + stepUs >= durationMs * 1000) continue
                    val here = planeAt(mmr, t, width, height) ?: continue
                    val before = planeAt(mmr, t - stepUs, width, height) ?: continue
                    val after = planeAt(mmr, t + stepUs, width, height) ?: continue
                    if (listOf(before, after).any { it.width != here.width || it.height != here.height }) continue
                    val blur = Vmaf.motionBlur(here)
                    val motion2 = minOf(
                        Vmaf.motion(Vmaf.motionBlur(before), blur, here.width, here.height),
                        Vmaf.motion(blur, Vmaf.motionBlur(after), here.width, here.height)
                    )
                    moments += Moment(if (fromStart) t - startUs else t, here, motion2)
                }
                if (moments.size < minOf(MIN_MOMENTS, count)) null else VideoQuality(moments)
            } catch (e: Exception) {
                null
            } catch (e: OutOfMemoryError) {
                null
            } finally {
                runCatching { mmr.release() }
            }
        }

        /**
         * The brightness of the frame shown at [timeUs]: a picture of [width] x
         * [height] above [MAX_PIXELS] is read scaled down, the same way for
         * the original and every copy.
         */
        private fun planeAt(mmr: MediaMetadataRetriever, timeUs: Long, width: Int, height: Int): Vmaf.Plane? {
            val big = width.toLong() * height > MAX_PIXELS
            val bitmap: Bitmap = (
                if (big) {
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
