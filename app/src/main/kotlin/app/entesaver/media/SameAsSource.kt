package app.entesaver.media

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.MediaFormatUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.container.MdtaMetadataEntry
import androidx.media3.container.Mp4LocationData
import androidx.media3.container.XmpData
import androidx.media3.muxer.Muxer
import androidx.media3.muxer.MuxerUtil
import androidx.media3.transformer.InAppMp4Muxer
import app.entesaver.core.logic.OptimisedMark
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * What of a video's file Media3 does not carry into a re-encoded copy, read
 * from the original and put back.
 *
 * Media3 carries the date, an Android camera's place, the rotation and the
 * camera's own notes (com.android.*, com.apple.quicktime.*) by itself. It
 * does not carry XMP, a place written with its altitude, the language of
 * each track, or the file type a MOV or 3GP file says it is: the copy gets
 * those from here. What no copy can keep - a third track (a Live Photo's
 * still-image track, a timecode, a second sound track) or a Samsung camera's
 * trailer, which holds its slow-motion and editing data - keeps the whole
 * video as it is ([keepsWhole]).
 */
@OptIn(UnstableApi::class)
internal class SameAsSource private constructor(
    /** The original's file-type box, when it names a type other than plain MP4. */
    private val ftyp: ByteArray?,
    private val xmp: ByteArray?,
    /** The place, as the original's ©xyz box writes it. */
    private val xyz: String?,
    private val videoLanguage: String?,
    private val audioLanguage: String?,
    /** The picture's colour: its transfer is what says whether it is HDR. */
    val colorInfo: ColorInfo?,
    /** Why the video must stay as it is; null when a copy can keep all of it. */
    val keepsWhole: String?
) {

    /**
     * The MP4 writer for one copy: the index at the front, so a player -
     * Ente's on the web too - starts before the whole file is read; the
     * note that keeps the copy from being optimised again ([OptimisedMark]);
     * and what of the original Media3 does not carry. Room is left after the
     * file-type box for the original's own one ([restoreType]).
     */
    fun muxerFactory(): Muxer.Factory {
        val inner = InAppMp4Muxer.Factory { entries ->
            if (entries.none { it is Mp4LocationData }) placeOf(xyz)?.let { entries.add(it) }
            xmp?.let { entries.add(XmpData(it)) }
            entries.add(
                MdtaMetadataEntry(
                    OptimisedMark.VIDEO_KEY, "1".toByteArray(Charsets.US_ASCII), MdtaMetadataEntry.TYPE_INDICATOR_STRING
                )
            )
            // The writer refuses what it cannot write, rather than skipping it.
            entries.removeAll { !MuxerUtil.isMetadataSupported(it) }
        }.setAttemptStreamableOutputEnabled(true).setFreeSpaceAfterFileTypeBoxBytes(TYPE_ROOM)
        return object : Muxer.Factory {
            override fun create(path: String): Muxer {
                val muxer = inner.create(path)
                return object : Muxer by muxer {
                    override fun addTrack(format: Format): Int {
                        val language = if (MimeTypes.isVideo(format.sampleMimeType)) videoLanguage else audioLanguage
                        return muxer.addTrack(
                            if (format.language == null && language != null) {
                                format.buildUpon().setLanguage(language).build()
                            } else {
                                format
                            }
                        )
                    }
                }
            }

            override fun getSupportedSampleMimeTypes(trackType: Int) = inner.getSupportedSampleMimeTypes(trackType)

            override fun supportsWritingNegativeTimestampsInEditList() =
                inner.supportsWritingNegativeTimestampsInEditList()
        }
    }

    /**
     * The original's file-type box written over the copy's, so a MOV says it
     * is a MOV and a 3GP a 3GP. The writer left [TYPE_ROOM] bytes free
     * after its own 28-byte box; nothing the index points at moves.
     */
    fun restoreType(copy: File) {
        val original = ftyp ?: return
        val room = PLAIN_FTYP_BYTES + 8 + TYPE_ROOM
        val rest = room - original.size
        if (rest < 0 || rest in 1 until 8) return
        runCatching {
            RandomAccessFile(copy, "rw").use { f ->
                val head = ByteArray(room).also { f.readFully(it) }
                val b = ByteBuffer.wrap(head)
                if (b.getInt(0) != PLAIN_FTYP_BYTES || b.getInt(4) != FTYP ||
                    b.getInt(PLAIN_FTYP_BYTES) != 8 + TYPE_ROOM || b.getInt(PLAIN_FTYP_BYTES + 4) != FREE
                ) {
                    return@use
                }
                f.seek(0)
                f.write(original)
                if (rest > 0) {
                    f.writeInt(rest)
                    f.writeInt(FREE)
                }
            }
        }
    }

    companion object {

        /** Free bytes left after the copy's file-type box, for the original's. */
        private const val TYPE_ROOM = 64
        private const val PLAIN_FTYP_BYTES = 28
        private const val FTYP = 0x66747970
        private const val FREE = 0x66726565

        /** How far from the end a Samsung camera's trailer is looked for. */
        private const val TAIL_BYTES = 64 * 1024

        private val XMP_UUID = "BE7ACFCB97A942E89C71999491E3AFAC".chunked(2).map { it.toInt(16).toByte() }.toByteArray()

        /** Why a video stays as it is, beyond its codec: tracks and trailers no copy keeps. */
        const val TRACKS_KEPT = "tracks_kept"
        const val TRAILER_KEPT = "trailer_kept"

        fun read(context: Context, uri: Uri): SameAsSource? = runCatching {
            var boxes = Boxes()
            var sef = false
            context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                FileInputStream(pfd.fileDescriptor).channel.use { ch ->
                    boxes = Boxes.read(ch)
                    val size = ch.size()
                    val tail = ByteBuffer.allocate(minOf(size, TAIL_BYTES.toLong()).toInt())
                    ch.read(tail, size - tail.capacity())
                    sef = endsWithSef(tail.array())
                }
            } ?: return@runCatching null
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(context, uri, null)
                val formats = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                val video = formats.filter { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
                val audio = formats.filter { it.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
                val keepsWhole = when {
                    // Dolby Vision's own layer is lost in any re-encode; HEVC under it is not the whole picture.
                    boxes.dolbyVision -> VideoCompressor.CODEC_KEPT
                    video.size != 1 || audio.size > 1 || formats.size != video.size + audio.size -> TRACKS_KEPT
                    sef -> TRAILER_KEPT
                    else -> null
                }
                SameAsSource(
                    ftyp = boxes.ftyp?.takeIf { brandOf(it) != "isom" },
                    xmp = boxes.xmp,
                    xyz = boxes.xyz,
                    videoLanguage = video.firstOrNull()?.let(::languageOf),
                    audioLanguage = audio.firstOrNull()?.let(::languageOf),
                    colorInfo = video.firstOrNull()?.let { runCatching { MediaFormatUtil.getColorInfo(it) }.getOrNull() },
                    keepsWhole = keepsWhole
                )
            } finally {
                runCatching { extractor.release() }
            }
        }.getOrNull()

        /** A Samsung camera's trailer ends in "SEFT", whatever it holds. */
        private fun endsWithSef(tail: ByteArray): Boolean =
            tail.size >= 4 && String(tail, tail.size - 4, 4, Charsets.ISO_8859_1) == "SEFT"

        private fun languageOf(format: MediaFormat): String? =
            format.getString(MediaFormat.KEY_LANGUAGE)?.takeIf { it.isNotBlank() && it != "und" }

        private fun brandOf(ftyp: ByteArray): String =
            if (ftyp.size >= 12) String(ftyp, 8, 4, Charsets.ISO_8859_1) else ""

        /** The place in an ISO 6709 string - "+28.6139+077.2090/", or with an altitude after - as Media3 writes it. */
        internal fun placeOf(xyz: String?): Mp4LocationData? {
            val m = Regex("^([+-]\\d+(?:\\.\\d+)?)([+-]\\d+(?:\\.\\d+)?)").find(xyz?.trim() ?: return null) ?: return null
            val lat = m.groupValues[1].toFloatOrNull() ?: return null
            val lon = m.groupValues[2].toFloatOrNull() ?: return null
            return if (lat in -90f..90f && lon in -180f..180f) Mp4LocationData(lat, lon) else null
        }
    }

    /**
     * The boxes read straight from the original's file: its type, its XMP,
     * its ©xyz, and whether its picture carries Dolby Vision ('dvcC', 'dvvC'
     * or 'dvwC' in the index).
     */
    private class Boxes(
        val ftyp: ByteArray? = null,
        val xmp: ByteArray? = null,
        val xyz: String? = null,
        val dolbyVision: Boolean = false
    ) {
        companion object {
            /** The most of a box this reads whole: a file type, an XMP packet, a place. */
            private const val MAX_READ = 1 shl 20

            /** The largest index searched for Dolby Vision; a phone's is a few hundred KB. */
            private const val MAX_MOOV = 16 shl 20

            private val DOLBY = listOf("dvcC", "dvvC", "dvwC").map { it.toByteArray(Charsets.ISO_8859_1) }

            /** A Dolby Vision configuration box: its 32-byte size, then its name. */
            private fun ByteArray.hasBox(code: ByteArray): Boolean =
                (4..size - code.size).any { i ->
                    this[i - 4] == 0.toByte() && this[i - 3] == 0.toByte() && this[i - 2] == 0.toByte() &&
                        this[i - 1] == 32.toByte() && code.indices.all { this[i + it] == code[it] }
                }

            fun read(ch: FileChannel): Boxes {
                var ftyp: ByteArray? = null
                var xmp: ByteArray? = null
                var xyz: String? = null
                var dolby = false
                fun bytes(at: Long, n: Int): ByteArray =
                    ByteBuffer.allocate(n).also { ch.read(it, at) }.array()
                fun walk(from: Long, to: Long, depth: Int) {
                    var pos = from
                    while (pos + 8 <= to) {
                        val h = ByteBuffer.wrap(bytes(pos, 16))
                        var size = h.int.toLong() and 0xFFFFFFFFL
                        val type = String(ByteArray(4).also { h.get(it) }, Charsets.ISO_8859_1)
                        var head = 8
                        if (size == 1L) {
                            size = h.long
                            head = 16
                        } else if (size == 0L) {
                            size = to - pos
                        }
                        if (size < head || pos + size > to) return
                        val body = pos + head
                        val len = size - head
                        when {
                            depth == 0 && type == "ftyp" && size <= 92 -> ftyp = bytes(pos, size.toInt())
                            depth == 0 && type == "uuid" && len in 17..MAX_READ.toLong() &&
                                bytes(body, 16).contentEquals(XMP_UUID) -> xmp = bytes(body + 16, len.toInt() - 16)
                            depth == 0 && type == "moov" -> {
                                if (size <= MAX_MOOV) {
                                    val moov = bytes(pos, size.toInt())
                                    dolby = DOLBY.any { moov.hasBox(it) }
                                }
                                walk(body, pos + size, 1)
                            }
                            depth == 1 && type == "udta" -> walk(body, pos + size, 2)
                            depth == 2 && type == "XMP_" && xmp == null && len in 1..MAX_READ.toLong() ->
                                xmp = bytes(body, len.toInt())
                            depth == 2 && type == "©xyz" && len in 5..256L ->
                                xyz = String(bytes(body + 4, len.toInt() - 4), Charsets.UTF_8)
                        }
                        pos += size
                    }
                }
                walk(0, ch.size(), 0)
                return Boxes(ftyp, xmp, xyz, dolby)
            }
        }
    }
}
