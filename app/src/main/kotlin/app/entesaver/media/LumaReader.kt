package app.entesaver.media

import android.content.Context
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import app.entesaver.core.logic.Vmaf
import java.io.Closeable
import java.io.File

/**
 * A video's frames as VMAF reads them: the decoder's own brightness plane.
 *
 * Read through a colour picture (MediaMetadataRetriever's bitmaps), a frame
 * comes back with its brightness worked out again from red, green and blue -
 * stretched from the range video keeps it in to a picture's full range,
 * clipped where a colour falls outside them, and by weights that need not be
 * the ones it was filmed with. A copy and its original go through the same
 * change, so the two still compare, but VMAF then reads lower than libvmaf
 * does on the files themselves. Here the planes are the decoder's own, as
 * libvmaf takes them.
 *
 * Brightness is read as it is shown. Video keeps it between 16 and 235, and a
 * level outside them shows as one of them, so it is read as one; a file that
 * says it fills the whole range (some phones' cameras do) is read squeezed
 * into it. A copy whose editor clipped a level no screen shows, or made a
 * full-range original limited, is then not marked down for it.
 *
 * One decoder serves every frame of a file, and each [read] seeks to the key
 * frame before the time asked for and decodes forward, so a moment and its
 * neighbours come from one pass. A picture of more than [MAX_PIXELS] is
 * halved until it is not, by averaging each 2x2 square, the same way for a
 * copy and its original. A plane lies the way the file stores it, turned by
 * [turn]: a copy's, by how its rotation differs from its original's, so the
 * two are compared the same way round.
 */
internal class LumaReader private constructor(
    private val extractor: MediaExtractor,
    private val decoder: MediaCodec,
    /** How far the file's frames are turned, clockwise, to be shown. */
    val rotation: Int,
    /** Each stored level as it is shown (LIMITED or FULL). */
    private var levels: ByteArray
) : Closeable {

    /** One frame: when it is shown, and its brightness. */
    class Frame(val timeUs: Long, val plane: Vmaf.Plane)

    /** How far each plane is turned, clockwise, before it is handed out. */
    var turn = 0

    private var started = false

    /** Whether a pass ran out of time: a decoder that stalls once is not waited on again. */
    private var stalled = false

    /**
     * Decodes from the key frame before [fromUs] and hands [more] each frame
     * shown from [fromUs] on, in order, for as long as it returns true. It
     * stops sooner at the end of the clip, at a frame it cannot read, and
     * after [PASS_MS], after which it reads nothing more.
     */
    fun read(fromUs: Long, more: (Frame) -> Boolean) {
        if (stalled) return
        if (started) decoder.flush()
        started = true
        extractor.seekTo(fromUs.coerceAtLeast(0), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val info = MediaCodec.BufferInfo()
        val deadline = System.currentTimeMillis() + PASS_MS
        var inputDone = false
        while (true) {
            if (System.currentTimeMillis() >= deadline) {
                stalled = true
                return
            }
            if (!inputDone) {
                val i = decoder.dequeueInputBuffer(WAIT_US)
                if (i >= 0) {
                    val buffer = decoder.getInputBuffer(i) ?: return
                    val n = extractor.readSampleData(buffer, 0)
                    if (n < 0) {
                        decoder.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        decoder.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            val o = decoder.dequeueOutputBuffer(info, WAIT_US)
            // The decoder's word on the range, from the stream itself, over the container's.
            if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) levels = levelsOf(decoder.outputFormat, levels)
            if (o < 0) continue
            val end = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
            val timeUs = info.presentationTimeUs
            val wanted = info.size > 0 && timeUs >= fromUs
            val plane = if (wanted) decoder.getOutputImage(o)?.use { lumaOf(it, levels) } else null
            decoder.releaseOutputBuffer(o, false)
            if (wanted && (plane == null || !more(Frame(timeUs, turned(plane, turn))))) return
            if (end) return
        }
    }

    override fun close() {
        runCatching { decoder.stop() }
        runCatching { decoder.release() }
        runCatching { extractor.release() }
    }

    companion object {

        /** A picture of more pixels than this is halved until it is not: 4K is read at 1080p. */
        const val MAX_PIXELS = 2_800_000L

        private const val WAIT_US = 10_000L

        /** The longest one [read] may take. */
        private const val PASS_MS = 20_000L

        /** A limited-range level as it is shown: 16 to 235, anything outside them as the nearer. */
        private val LIMITED = ByteArray(256) { it.coerceIn(16, 235).toByte() }

        /** A full-range level squeezed into 16 to 235, as a limited-range file would hold it. */
        private val FULL = ByteArray(256) { (16 + (it * 219 + 127) / 255).toByte() }

        private fun levelsOf(format: MediaFormat, otherwise: ByteArray): ByteArray =
            if (!format.containsKey(MediaFormat.KEY_COLOR_RANGE)) {
                otherwise
            } else if (format.getInteger(MediaFormat.KEY_COLOR_RANGE) == MediaFormat.COLOR_RANGE_FULL) {
                FULL
            } else {
                LIMITED
            }

        /** The video at [uri], ready to read; null when no decoder here will take it. */
        fun open(context: Context, uri: Uri): LumaReader? = open { setDataSource(context, uri, null) }

        fun open(file: File): LumaReader? = open { setDataSource(file.absolutePath) }

        private fun open(source: MediaExtractor.() -> Unit): LumaReader? {
            val extractor = MediaExtractor()
            var decoder: MediaCodec? = null
            return try {
                extractor.source()
                val track = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
                } ?: throw IllegalStateException("no picture")
                extractor.selectTrack(track)
                val format = extractor.getTrackFormat(track)
                val rotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                    format.getInteger(MediaFormat.KEY_ROTATION)
                } else {
                    0
                }
                format.setInteger(
                    MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
                )
                decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
                decoder.configure(format, null, null, 0)
                decoder.start()
                LumaReader(extractor, decoder, rotation, levelsOf(format, LIMITED))
            } catch (e: Exception) {
                runCatching { decoder?.release() }
                runCatching { extractor.release() }
                null
            }
        }

        /**
         * The visible part of [image]'s brightness plane, a byte a pixel, each
         * level as [levels] shows it; of a 10-bit frame (P010, two bytes a
         * pixel), the top eight bits, which are its second byte. Null when it
         * cannot be read.
         */
        private fun lumaOf(image: Image, levels: ByteArray): Vmaf.Plane? = try {
            val y = image.planes.first()
            val crop = image.cropRect
            val w = crop.width()
            val h = crop.height()
            if (w < Vmaf.MIN_SIZE || h < Vmaf.MIN_SIZE) {
                null
            } else {
                val step = y.pixelStride
                val high = if (step == 2) 1 else 0
                val buffer = y.buffer
                val out = ByteArray(w * h)
                val row = ByteArray(w * step)
                for (r in 0 until h) {
                    buffer.position((crop.top + r) * y.rowStride + crop.left * step)
                    buffer.get(row, 0, minOf(row.size, buffer.remaining()))
                    for (c in 0 until w) out[r * w + c] = levels[row[c * step + high].toInt() and 0xFF]
                }
                halved(Vmaf.Plane(out, w, h))
            }
        } catch (e: RuntimeException) {
            null
        }

        /** [plane] halved, by 2x2 averages, until it has no more than [MAX_PIXELS]. */
        fun halved(plane: Vmaf.Plane): Vmaf.Plane {
            var p = plane
            while (p.width.toLong() * p.height > MAX_PIXELS && p.width / 2 >= Vmaf.MIN_SIZE && p.height / 2 >= Vmaf.MIN_SIZE) {
                val w = p.width / 2
                val h = p.height / 2
                val src = p.pixels
                val sw = p.width
                val dst = ByteArray(w * h)
                for (r in 0 until h) {
                    val a = 2 * r * sw
                    val b = a + sw
                    for (c in 0 until w) {
                        val sum = (src[a + 2 * c].toInt() and 0xFF) + (src[a + 2 * c + 1].toInt() and 0xFF) +
                            (src[b + 2 * c].toInt() and 0xFF) + (src[b + 2 * c + 1].toInt() and 0xFF)
                        dst[r * w + c] = ((sum + 2) / 4).toByte()
                    }
                }
                p = Vmaf.Plane(dst, w, h)
            }
            return p
        }

        /** [plane] turned [degrees] clockwise: a quarter turn swaps its width and height. */
        fun turned(plane: Vmaf.Plane, degrees: Int): Vmaf.Plane {
            val w = plane.width
            val h = plane.height
            val src = plane.pixels
            return when ((degrees % 360 + 360) % 360) {
                90 -> Vmaf.Plane(ByteArray(w * h) { i -> src[(h - 1 - i % h) * w + i / h] }, h, w)
                180 -> Vmaf.Plane(ByteArray(w * h) { i -> src[w * h - 1 - i] }, w, h)
                270 -> Vmaf.Plane(ByteArray(w * h) { i -> src[(i % h) * w + (w - 1 - i / h)] }, h, w)
                else -> plane
            }
        }
    }
}
