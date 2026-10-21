package app.entesaver.media

import android.content.Context
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import app.entesaver.core.logic.Recolour
import app.entesaver.core.logic.Vmaf
import java.io.Closeable
import java.io.File
import java.util.Locale

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
 * The decoder is Android's own, the one MediaMetadataRetriever decodes with
 * and the same on every phone, which decodes as exactly as libvmaf's does. A
 * chip's, or an emulator's, need not: on the savings benchmark's emulator its
 * host decoder read copies about three points below libvmaf.
 *
 * Brightness is read as it is shown: video keeps it between 16 and 235, and a
 * level outside them shows as one of them, so it is read as one - a copy whose
 * editor clipped a level no screen shows is not marked down for it. Set [into]
 * another file's colour (Colour), a frame is read as it shows in that one: an
 * original in its copy's, as ffmpeg brings it before the savings benchmark's
 * libvmaf compares the two (Recolour). A copy that shows its original's
 * colours by other proportions of red, green and blue, as Media3 writes a file
 * that names none, is then not marked down for that either.
 *
 * One decoder serves every frame of a file. A [read] decodes on from where the
 * last stopped when that is the shorter way to the time asked for, and seeks
 * to the key frame before it when that is: a moment and its neighbours come
 * from one pass, and the moments of a short clip from about one pass of the
 * whole of it. A picture of more than [MAX_PIXELS] is
 * halved until it is not, by averaging each 2x2 square, the same way for a
 * copy and its original. A plane lies the way the file stores it, turned by
 * [turn]: a copy's, by how its rotation differs from its original's, so the
 * two are compared the same way round.
 */
internal class LumaReader private constructor(
    private val extractor: MediaExtractor,
    /** The same file and track, to look up key frames without moving [extractor]. */
    private val probe: MediaExtractor,
    private val decoder: MediaCodec,
    /** How far the file's frames are turned, clockwise, to be shown. */
    val rotation: Int,
    /** The file's colour: the container's word, then the decoder's (from the stream itself). */
    colour: Colour
) : Closeable {

    /**
     * How a file's levels stand for colours, from MediaFormat: the proportions
     * of red, green and blue its brightness is worked out from ([standard],
     * a COLOR_STANDARD_), the range its levels fill ([range]) and how bright
     * they are ([transfer]) - each 0 where the file does not say.
     */
    data class Colour(val standard: Int, val range: Int, val transfer: Int) {

        /** As far as brightness goes; null for HDR, which is read as stored. */
        val space: Recolour.Space?
            get() = if (transfer == MediaFormat.COLOR_TRANSFER_ST2084 || transfer == MediaFormat.COLOR_TRANSFER_HLG) {
                null
            } else {
                Recolour.Space(
                    when (standard) {
                        MediaFormat.COLOR_STANDARD_BT709 -> Recolour.Matrix.BT709
                        MediaFormat.COLOR_STANDARD_BT2020 -> Recolour.Matrix.BT2020
                        else -> Recolour.Matrix.BT601
                    },
                    range == MediaFormat.COLOR_RANGE_FULL
                )
            }
    }

    /** The file's colour, the decoder's word on it once it has one. */
    var colour: Colour = colour
        private set

    /** The colour frames are read in: null, or the file's own, for as it shows itself. */
    var into: Colour? = null

    /** How this file's levels read in [into], for the pair it was worked out for. */
    private var change: Pair<Pair<Colour, Colour?>, Recolour.Change?>? = null

    /** One frame: when it is shown, and its brightness. */
    class Frame(val timeUs: Long, val plane: Vmaf.Plane)

    /** How far each plane is turned, clockwise, before it is handed out. */
    var turn = 0

    private var started = false

    /** Whether a pass ran out of time: a decoder that stalls once is not waited on again. */
    private var stalled = false

    /** Whether the end of the file has been handed to the decoder. */
    private var inputDone = false

    /** The latest time handed to the decoder, and the latest frame it has shown. */
    private var queuedUs = Long.MIN_VALUE
    private var shownUs = Long.MIN_VALUE

    /**
     * Hands [more] each frame shown from [fromUs] on, in order, for as long as
     * it returns true: decoding on from the last read where nothing it has
     * shown is past [fromUs] and no key frame lies between, else from the key
     * frame before [fromUs]. It stops sooner at the end of the clip, at a
     * frame it cannot read, and after [PASS_MS], after which it reads nothing
     * more.
     */
    fun read(fromUs: Long, more: (Frame) -> Boolean) {
        if (stalled) return
        if (!started || inputDone || fromUs <= shownUs || keyFrameBefore(fromUs) > queuedUs) {
            if (started) decoder.flush()
            started = true
            inputDone = false
            queuedUs = Long.MIN_VALUE
            shownUs = Long.MIN_VALUE
            extractor.seekTo(fromUs.coerceAtLeast(0), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        }
        val info = MediaCodec.BufferInfo()
        val deadline = System.currentTimeMillis() + PASS_MS
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
                        val sampleUs = extractor.sampleTime
                        decoder.queueInputBuffer(i, 0, n, sampleUs, 0)
                        queuedUs = maxOf(queuedUs, sampleUs)
                        extractor.advance()
                    }
                }
            }
            val o = decoder.dequeueOutputBuffer(info, WAIT_US)
            // The decoder's word on the colour, from the stream itself, over the container's.
            if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) colour = colourOf(decoder.outputFormat, colour)
            if (o < 0) continue
            val end = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
            val timeUs = info.presentationTimeUs
            if (info.size > 0) shownUs = maxOf(shownUs, timeUs)
            val wanted = info.size > 0 && timeUs >= fromUs
            val plane = if (wanted) decoder.getOutputImage(o)?.use { lumaOf(it, currentChange()) } else null
            decoder.releaseOutputBuffer(o, false)
            if (wanted && (plane == null || !more(Frame(timeUs, turned(plane, turn))))) return
            if (end) return
        }
    }

    /** How this file's levels read in [into], or as shown in its own colour; null for a full range as stored. */
    private fun currentChange(): Recolour.Change? {
        val key = colour to into
        change?.let { if (it.first == key) return it.second }
        val from = colour.space
        val to = into?.space
        val worked = (if (from == null || to == null) null else Recolour.change(from, to))
            ?: Recolour.Levels(LIMITED).takeIf { (into ?: colour).range != MediaFormat.COLOR_RANGE_FULL }
        change = key to worked
        return worked
    }

    /** When the key frame at or before [timeUs] is shown. */
    private fun keyFrameBefore(timeUs: Long): Long {
        probe.seekTo(timeUs.coerceAtLeast(0), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        return probe.sampleTime
    }

    override fun close() {
        runCatching { decoder.stop() }
        runCatching { decoder.release() }
        runCatching { extractor.release() }
        runCatching { probe.release() }
    }

    companion object {

        /** A picture of more pixels than this is halved until it is not: 4K is read at 1080p. */
        const val MAX_PIXELS = 2_800_000L

        private const val WAIT_US = 10_000L

        /** The longest one [read] may take. */
        private const val PASS_MS = 20_000L

        /** A limited-range level as it is shown: 16 to 235, anything outside them as the nearer. */
        private val LIMITED = ByteArray(256) { it.coerceIn(16, 235).toByte() }

        /** [format]'s word on the colour, each part of it over [otherwise]'s. */
        private fun colourOf(format: MediaFormat, otherwise: Colour): Colour {
            fun key(name: String, was: Int) = if (format.containsKey(name)) format.getInteger(name) else was
            return Colour(
                key(MediaFormat.KEY_COLOR_STANDARD, otherwise.standard),
                key(MediaFormat.KEY_COLOR_RANGE, otherwise.range),
                key(MediaFormat.KEY_COLOR_TRANSFER, otherwise.transfer)
            )
        }

        /**
         * The colour of the video in [file] as its decoder reads it, from its
         * first frame; null when it cannot be read.
         */
        fun colourOf(file: File): Colour? = open(file)?.use { reader ->
            var read = false
            reader.read(0) {
                read = true
                false
            }
            reader.colour.takeIf { read }
        }

        /** The video at [uri], ready to read; null when no decoder here will take it. */
        fun open(context: Context, uri: Uri): LumaReader? = open { setDataSource(context, uri, null) }

        fun open(file: File): LumaReader? = open { setDataSource(file.absolutePath) }

        private fun open(source: MediaExtractor.() -> Unit): LumaReader? {
            val extractor = MediaExtractor()
            val probe = MediaExtractor()
            var decoder: MediaCodec? = null
            return try {
                extractor.source()
                probe.source()
                val track = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
                } ?: throw IllegalStateException("no picture")
                extractor.selectTrack(track)
                probe.selectTrack(track)
                val format = extractor.getTrackFormat(track)
                val rotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                    format.getInteger(MediaFormat.KEY_ROTATION)
                } else {
                    0
                }
                format.setInteger(
                    MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
                )
                val mime = format.getString(MediaFormat.KEY_MIME)!!
                val own = androidsOwnDecoder(
                    mime, format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT)
                )
                decoder = if (own != null) MediaCodec.createByCodecName(own) else MediaCodec.createDecoderByType(mime)
                decoder.configure(format, null, null, 0)
                decoder.start()
                LumaReader(extractor, probe, decoder, rotation, colourOf(format, Colour(0, 0, 0)))
            } catch (e: Exception) {
                runCatching { decoder?.release() }
                runCatching { extractor.release() }
                runCatching { probe.release() }
                null
            }
        }

        /**
         * Android's own decoder for [mime] at [width] x [height], by name; null
         * when none of them takes it, and the phone's default decodes it.
         */
        private fun androidsOwnDecoder(mime: String, width: Int, height: Int): String? = runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
                val name = info.name.lowercase(Locale.ROOT)
                !info.isEncoder && (name.startsWith("c2.android.") || name.startsWith("omx.google.")) &&
                    info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
                    info.getCapabilitiesForType(mime).videoCapabilities?.isSizeSupported(width, height) == true
            }?.name
        }.getOrNull()

        /**
         * The visible part of [image]'s brightness plane, a byte a pixel, each
         * level as [change] reads it - where it changes the proportions, from
         * the pixel's colour too, each colour level covering its square of
         * four; of a 10-bit frame (P010, two bytes a pixel), the top eight
         * bits, which are its second byte, its proportions unchanged. Null when
         * it cannot be read.
         */
        private fun lumaOf(image: Image, change: Recolour.Change?): Vmaf.Plane? = try {
            val y = image.planes.first()
            val crop = image.cropRect
            val w = crop.width()
            val h = crop.height()
            if (w < Vmaf.MIN_SIZE || h < Vmaf.MIN_SIZE) {
                null
            } else {
                val step = y.pixelStride
                val high = if (step == 2) 1 else 0
                val through = (change as? Recolour.Through)?.takeIf { step == 1 && image.planes.size >= 3 }
                val levels = (change as? Recolour.Levels)?.table
                val buffer = y.buffer
                val out = ByteArray(w * h)
                val row = ByteArray(w * step)
                val u = image.planes.getOrNull(1)
                val v = image.planes.getOrNull(2)
                val left = crop.left / 2
                val cw = (crop.left + w + 1) / 2 - left
                val uRow = ByteArray(if (through != null) (cw - 1) * u!!.pixelStride + 1 else 0)
                val vRow = ByteArray(if (through != null) (cw - 1) * v!!.pixelStride + 1 else 0)
                for (r in 0 until h) {
                    buffer.position((crop.top + r) * y.rowStride + crop.left * step)
                    buffer.get(row, 0, minOf(row.size, buffer.remaining()))
                    val o = r * w
                    if (through != null) {
                        val cr = (crop.top + r) / 2
                        if (r == 0 || cr != (crop.top + r - 1) / 2) {
                            rowOf(u!!, cr, left, uRow)
                            rowOf(v!!, cr, left, vRow)
                        }
                        val us = u!!.pixelStride
                        val vs = v!!.pixelStride
                        for (c in 0 until w) {
                            val k = (crop.left + c) / 2 - left
                            out[o + c] = through.luma(
                                row[c].toInt() and 0xFF, uRow[k * us].toInt() and 0xFF, vRow[k * vs].toInt() and 0xFF
                            ).toByte()
                        }
                    } else if (levels != null) {
                        for (c in 0 until w) out[o + c] = levels[row[c * step + high].toInt() and 0xFF]
                    } else {
                        for (c in 0 until w) out[o + c] = row[c * step + high]
                    }
                }
                halved(Vmaf.Plane(out, w, h))
            }
        } catch (e: RuntimeException) {
            null
        }

        /** Row [r] of colour [plane], from its column [left], into [into]. */
        private fun rowOf(plane: Image.Plane, r: Int, left: Int, into: ByteArray) {
            val buffer = plane.buffer
            buffer.position(r * plane.rowStride + left * plane.pixelStride)
            buffer.get(into, 0, minOf(into.size, buffer.remaining()))
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
