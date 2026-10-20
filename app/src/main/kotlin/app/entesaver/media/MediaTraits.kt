package app.entesaver.media

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * Real-world file traits that change how an item must be handled:
 *  - HDR video (HLG / PQ / Dolby Vision) needs tone-mapping or HDR-capable output,
 *    never a silent washed-out SDR re-encode.
 *  - Motion photos and multi-picture / depth JPEGs carry an embedded video or
 *    depth map that re-compression would destroy, so they are copied as-is.
 */
object MediaTraits {

    enum class Hdr { NONE, HLG, PQ, DOLBY_VISION }

    /** Reads the video track's colour info; NONE when the file is plain SDR. */
    fun hdrOf(context: Context, uri: Uri): Hdr {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(context, uri, null)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                if (mime.equals(MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION, ignoreCase = true)) {
                    return Hdr.DOLBY_VISION
                }
                if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                    return when (format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)) {
                        MediaFormat.COLOR_TRANSFER_HLG -> Hdr.HLG
                        MediaFormat.COLOR_TRANSFER_ST2084 -> Hdr.PQ
                        else -> Hdr.NONE
                    }
                }
                return Hdr.NONE
            }
            Hdr.NONE
        } catch (e: Exception) {
            Hdr.NONE
        } finally {
            runCatching { extractor.release() }
        }
    }

    /**
     * Why a photo must be copied byte-for-byte, or null when it may be compressed.
     *
     * This runs on every single photo, so what it allocates matters more than
     * what it does. It used to take a fixed 512 KB buffer whatever the photo's
     * size, copy it to trim it, and then turn the whole thing into a 512
     * thousand character String - about a megabyte and a half of rubbish per
     * item, which on a phone holding tens of thousands of photos is what made
     * a run stutter and the heap thrash. The markers are plain ASCII, so they
     * are matched against the file's own bytes instead, and only as many bytes
     * as the file actually has are ever held.
     */
    fun embeddedPayloadReason(context: Context, uri: Uri): String? =
        photoTraits(context, uri).asIsReason

    /**
     * What a photo carries besides its picture.
     *
     * [asIsReason] is why it must be copied byte for byte, or null. An Ultra
     * HDR photo - a JPEG with a gain map that brightens its highlights on an
     * HDR screen - is told apart from a depth or multi-picture one: it holds
     * a container directory and a second picture too, but Android 14 can
     * write the gain map back into a smaller JPEG, so it is reported as
     * [ultraHdr] instead and the encoder decides.
     */
    data class PhotoTraits(val asIsReason: String?, val ultraHdr: Boolean)

    fun photoTraits(context: Context, uri: Uri): PhotoTraits {
        val head = readChunk(context, uri, MAX_SCAN) ?: return PhotoTraits(null, false)
        val traits = traitsOf(head)
        if (traits.asIsReason != null) return traits
        // Older Samsung motion photos name their video only in a trailer
        // after the picture, megabytes past the head. One more small read.
        readTail(context, uri, TAIL_SCAN)?.let(::tailReason)?.let { return PhotoTraits(it, false) }
        // A HEIC motion photo keeps its video in a box of its own at the end
        // of the file. That box's name sits at its start, a whole clip before
        // the tail, so the boxes are walked by their sizes to reach it.
        if (isIsoMedia(head) && hasTopLevelBox(context, uri, MPVD)) return PhotoTraits("motion_photo", false)
        return traits
    }

    /** True when the file is ISO media (HEIC, AVIF, MP4): an "ftyp" box first. */
    fun isIsoMedia(head: ByteArray): Boolean = head.size >= 12 && regionMatchesAt(head, 4, FTYP)

    /**
     * True when an ISO media file has a box named [type] at its top level.
     *
     * Google's motion photo format puts a HEIC or AVIF photo's video in a
     * top-level "mpvd" box after all the others; a Samsung trailer that ends
     * in "SEFT" is still found by [tailReason]. Each box starts with its size
     * and its name, so a few small reads hop from box to box without touching
     * the picture or the clip. [readAt] returns up to the asked number of
     * bytes at an offset, or null. A size that cannot be right, a box that runs to the end of the
     * file, or too many boxes ends the walk with false: the photo is then
     * judged as it was before this walk existed.
     */
    fun hasTopLevelBox(fileSize: Long, type: ByteArray, readAt: (Long, Int) -> ByteArray?): Boolean {
        var pos = 0L
        var boxes = 0
        while (pos + 8 <= fileSize && boxes < MAX_TOP_BOXES) {
            boxes++
            val header = readAt(pos, minOf(16L, fileSize - pos).toInt()) ?: return false
            if (header.size < 8) return false
            if (regionMatchesAt(header, 4, type)) return true
            val size = when (val small = readIntBe(header, 0).toLong() and 0xFFFFFFFFL) {
                // The box runs to the end of the file: nothing follows it.
                0L -> return false
                // The real size is the 64-bit one after the name.
                1L -> if (header.size < 16) return false else readLongBe(header, 8)
                else -> small
            }
            if (size < 8 || size > fileSize - pos) return false
            pos += size
        }
        return false
    }

    fun traitsOf(head: ByteArray): PhotoTraits {
        val ultra = ULTRA_HDR_MARKER_BYTES.any { containsBytes(head, it) }
        val realDepth = DEPTH_DATA_MARKER_BYTES.any { containsBytes(head, it) }
        val reason = when {
            MOTION_MARKER_BYTES.any { containsBytes(head, it) } -> "motion_photo"
            isAnimated(head) -> "animated"
            realDepth -> "depth_photo"
            ultra -> null
            DEPTH_MARKER_BYTES.any { containsBytes(head, it) } -> "depth_photo"
            hasMpfSegment(head) -> "multi_picture"
            else -> null
        }
        return PhotoTraits(reason, ultra && reason == null)
    }

    /** True when a written file still carries its gain map. */
    fun hasGainMap(file: java.io.File): Boolean = runCatching {
        file.inputStream().use { readUpTo(it, MAX_SCAN) }.let { head ->
            ULTRA_HDR_MARKER_BYTES.any { containsBytes(head, it) }
        }
    }.getOrDefault(false)

    /**
     * True when the file says it holds more than one frame: an animated
     * WebP, an APNG, or an AVIF or HEIF image sequence.
     *
     * The decoder hands back the first frame only, so re-encoding one of
     * these keeps a still and throws the animation away. Each format says
     * so in its first few bytes, so the head already read is enough.
     */
    fun isAnimated(head: ByteArray): Boolean = when {
        regionStarts(head, PNG_SIGNATURE) -> pngHasAnimation(head)
        head.size >= 21 && regionStarts(head, RIFF) && regionMatchesAt(head, 8, WEBP) &&
            regionMatchesAt(head, 12, VP8X) -> (head[20].toInt() and 0x02) != 0
        isIsoMedia(head) -> ftypBrands(head).any { it in SEQUENCE_BRANDS }
        else -> false
    }

    /** APNG: an "acTL" chunk ahead of the first picture data. */
    private fun pngHasAnimation(bytes: ByteArray): Boolean {
        var i = PNG_SIGNATURE.size
        while (i + 8 <= bytes.size) {
            val length = readIntBe(bytes, i)
            if (length < 0) return false
            val type = String(bytes, i + 4, 4, Charsets.ISO_8859_1)
            if (type == "acTL") return true
            if (type == "IDAT" || type == "IEND") return false
            val next = i.toLong() + 12 + length
            if (next > bytes.size) return false
            i = next.toInt()
        }
        return false
    }

    /** The major and compatible brands of an ISO media file's "ftyp" box. */
    private fun ftypBrands(bytes: ByteArray): List<String> {
        val boxEnd = minOf(readIntBe(bytes, 0).toLong(), bytes.size.toLong()).toInt()
        val brands = mutableListOf<String>()
        var i = 8
        while (i + 4 <= boxEnd) {
            // Offset 12 is the minor version, not a brand.
            if (i != 12) brands += String(bytes, i, 4, Charsets.ISO_8859_1)
            i += 4
        }
        return brands
    }

    /**
     * Why a photo must be copied as it is, judged from the last bytes of the
     * file; null when they say nothing.
     *
     * Samsung phones before about 2020 stored a motion photo's video in a
     * trailer after the JPEG, with no motion marker in the head at all. The
     * trailer ends with a directory: "SEFH", a count, twelve bytes per entry
     * (two of padding, a little-endian type, an offset and a length), then
     * the directory's length and "SEFT". Type 0x0A30 is the motion video.
     */
    fun tailReason(tail: ByteArray): String? {
        if (TAIL_MOTION_MARKER_BYTES.any { containsBytes(tail, it) }) return "motion_photo"
        val n = tail.size
        if (n < 8 || !regionMatchesAt(tail, n - 4, SEFT)) return null
        val dirLength = readIntLe(tail, n - 8)
        val sefh = n - 8 - dirLength
        if (dirLength < 12 || sefh < 0 || !regionMatchesAt(tail, sefh, SEFH)) return null
        val count = readIntLe(tail, sefh + 8)
        if (count <= 0) return null
        for (e in 0 until count) {
            val at = sefh + 12 + 12 * e
            if (at + 12 > n - 8) break
            val type = (tail[at + 2].toInt() and 0xFF) or ((tail[at + 3].toInt() and 0xFF) shl 8)
            if (type == SEF_MOTION_VIDEO) return "motion_photo"
        }
        return null
    }

    private fun readIntBe(bytes: ByteArray, at: Int): Int =
        ((bytes[at].toInt() and 0xFF) shl 24) or ((bytes[at + 1].toInt() and 0xFF) shl 16) or
            ((bytes[at + 2].toInt() and 0xFF) shl 8) or (bytes[at + 3].toInt() and 0xFF)

    private fun readLongBe(bytes: ByteArray, at: Int): Long =
        ((readIntBe(bytes, at).toLong() and 0xFFFFFFFFL) shl 32) or (readIntBe(bytes, at + 4).toLong() and 0xFFFFFFFFL)

    private fun readIntLe(bytes: ByteArray, at: Int): Int =
        (bytes[at].toInt() and 0xFF) or ((bytes[at + 1].toInt() and 0xFF) shl 8) or
            ((bytes[at + 2].toInt() and 0xFF) shl 16) or ((bytes[at + 3].toInt() and 0xFF) shl 24)

    private fun regionStarts(bytes: ByteArray, needle: ByteArray): Boolean = regionMatchesAt(bytes, 0, needle)

    /** [regionMatches] with the bounds checked here. */
    private fun regionMatchesAt(bytes: ByteArray, at: Int, needle: ByteArray): Boolean =
        at >= 0 && at + needle.size <= bytes.size && regionMatches(bytes, at, needle)

    private val PNG_SIGNATURE = byteArrayOf(
        0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 0x0D, 0x0A, 0x1A, 0x0A
    )
    private val RIFF = "RIFF".toByteArray(Charsets.ISO_8859_1)
    private val WEBP = "WEBP".toByteArray(Charsets.ISO_8859_1)
    private val VP8X = "VP8X".toByteArray(Charsets.ISO_8859_1)
    private val FTYP = "ftyp".toByteArray(Charsets.ISO_8859_1)
    private val SEFH = "SEFH".toByteArray(Charsets.ISO_8859_1)
    private val SEFT = "SEFT".toByteArray(Charsets.ISO_8859_1)

    /** AVIF and HEIF image-sequence brands: a moving picture, not a still. */
    private val SEQUENCE_BRANDS = setOf("avis", "msf1", "hevc", "hevx")

    /** Samsung's trailer type for a motion photo's video. */
    private const val SEF_MOTION_VIDEO = 0x0A30

    /** The trailer block's own name. */
    private val TAIL_MOTION_MARKER_BYTES = listOf("MotionPhoto_Data")
        .map { it.toByteArray(Charsets.ISO_8859_1) }

    /** Google's motion-video box in a HEIC or AVIF photo ([hasTopLevelBox]). */
    private val MPVD = "mpvd".toByteArray(Charsets.ISO_8859_1)

    /** A HEIC has a handful of top-level boxes; past this the file is not one. */
    private const val MAX_TOP_BOXES = 64

    /**
     * The gain map's own XMP namespace and version tag (Ultra HDR), and the
     * ISO 21496-1 name a JPEG carries when its gain map is described the ISO
     * way only. A HEIC gain map has no such text; PhotoCompressor asks the
     * decoder for that one.
     */
    private val ULTRA_HDR_MARKER_BYTES = listOf(
        "hdrgm:Version", "http://ns.adobe.com/hdr-gain-map/1.0/", "urn:iso:std:iso:ts:21496:-1"
    ).map { it.toByteArray(Charsets.ISO_8859_1) }

    /** Depth and portrait data proper, as opposed to the container that also holds a gain map. */
    private val DEPTH_DATA_MARKER_BYTES = listOf(
        "GDepth:Data", "GImage:Data", "http://ns.google.com/photos/1.0/depthmap/"
    ).map { it.toByteArray(Charsets.ISO_8859_1) }

    /** Google/Samsung motion photo (a still with an embedded MP4). */
    private val MOTION_MARKERS = listOf(
        "MotionPhoto",
        "MicroVideo",
        "MotionPhotoVersion",
        "MotionPhotoPresentationTimestampUs",
        "GCamera:MicroVideoOffset"
    )

    /** The same markers as bytes, so nothing has to be decoded to look. */
    private val MOTION_MARKER_BYTES = MOTION_MARKERS.map { it.toByteArray(Charsets.ISO_8859_1) }

    /** Portrait / depth data that only survives inside the original file. */
    private val DEPTH_MARKERS = listOf(
        "GDepth:Data",
        "GImage:Data",
        "Container:Directory",
        "http://ns.google.com/photos/1.0/depthmap/"
    )

    private val DEPTH_MARKER_BYTES = DEPTH_MARKERS.map { it.toByteArray(Charsets.ISO_8859_1) }

    private const val MAX_SCAN = 512 * 1024

    /** How much of the end of a file is read for a trailer ([tailReason]). */
    private const val TAIL_SCAN = 64 * 1024

    /**
     * How much is read before the buffer is grown.
     *
     * Motion-photo and depth XMP sits in the APP segments right behind the
     * start of the file, so most photos are answered by the first chunk and
     * never pay for the rest. Only a file that keeps going gets a bigger
     * buffer, and even then never more than [MAX_SCAN].
     */
    private const val SCAN_CHUNK = 64 * 1024

    /** The APP2 payload tag that marks a multi-picture JPEG: "MPF" and a NUL. */
    private val MPF_TAG = byteArrayOf(
        'M'.code.toByte(), 'P'.code.toByte(), 'F'.code.toByte(), 0
    )

    /**
     * Walks the JPEG marker chain looking for an APP2 "MPF" segment
     * (multi-picture: HDR pairs, bokeh source images).
     *
     * Not every marker carries a two-byte length, and assuming they all do is
     * how this walk used to lose its place. The restart markers 0xD0-0xD7 and
     * the TEM marker 0x01 stand entirely alone, and a file is allowed to pad
     * with any run of 0xFF bytes before the marker itself. Reading the two
     * bytes after one of those as a length gives a number out of the picture
     * data, and the walk then jumps to an arbitrary offset and either gives up
     * on the spot or wanders about reading noise. What a person would have
     * seen is a multi-picture photo - a phone's own HDR or portrait shot -
     * being re-compressed like an ordinary JPEG, throwing away the second
     * image it carries. Both shapes are now handled where they occur.
     */
    private fun hasMpfSegment(bytes: ByteArray): Boolean {
        if (bytes.size < 4) return false
        if ((bytes[0].toInt() and 0xFF) != 0xFF || (bytes[1].toInt() and 0xFF) != 0xD8) return false
        var i = 2
        while (i + 1 < bytes.size) {
            if ((bytes[i].toInt() and 0xFF) != 0xFF) return false
            // Fill bytes: any run of 0xFF before the marker byte is padding.
            var m = i + 1
            while (m < bytes.size && (bytes[m].toInt() and 0xFF) == 0xFF) m++
            if (m >= bytes.size) return false
            val marker = bytes[m].toInt() and 0xFF
            // Start of scan / end of image: no more metadata segments follow.
            if (marker == 0xDA || marker == 0xD9) return false
            if (marker == 0x01 || (marker in 0xD0..0xD7)) {
                // Stands alone: no length, no payload, the next marker follows.
                i = m + 1
                continue
            }
            // Two length bytes must both be present before they can be read.
            if (m + 2 >= bytes.size) return false
            val length = ((bytes[m + 1].toInt() and 0xFF) shl 8) or (bytes[m + 2].toInt() and 0xFF)
            if (length < 2) return false
            if (marker == 0xE2 && m + 3 + MPF_TAG.size <= bytes.size) {
                if (regionMatches(bytes, m + 3, MPF_TAG)) return true
            }
            i = m + 1 + length
        }
        return false
    }

    /** True when [needle] appears anywhere in [haystack]. */
    private fun containsBytes(haystack: ByteArray, needle: ByteArray): Boolean {
        if (needle.isEmpty() || needle.size > haystack.size) return false
        val last = haystack.size - needle.size
        for (i in 0..last) {
            if (haystack[i] == needle[0] && regionMatches(haystack, i, needle)) return true
        }
        return false
    }

    /** True when [needle] sits at [at] in [bytes]; the caller checks the bounds. */
    private fun regionMatches(bytes: ByteArray, at: Int, needle: ByteArray): Boolean {
        for (j in needle.indices) {
            if (bytes[at + j] != needle[j]) return false
        }
        return true
    }

    private fun readChunk(context: Context, uri: Uri, max: Int): ByteArray? = try {
        context.contentResolver.openInputStream(uri)?.use { input -> readUpTo(input, max) }
    } catch (e: Exception) {
        null
    }

    /**
     * The last [max] bytes of the file, or null when they cannot be read
     * directly - the head alone then decides, as it always did.
     */
    private fun readTail(context: Context, uri: Uri, max: Int): ByteArray? = try {
        context.contentResolver.openFileDescriptor(uri, "r")?.let { pfd ->
            ParcelFileDescriptor.AutoCloseInputStream(pfd).use { input ->
                val channel = input.channel
                val size = channel.size()
                val n = minOf(size, max.toLong()).toInt()
                if (n <= 0) null else readAt(channel, size - n, n)
            }
        }
    } catch (e: Exception) {
        null
    }

    /** [hasTopLevelBox] on the file itself; false when it cannot be read directly. */
    private fun hasTopLevelBox(context: Context, uri: Uri, type: ByteArray): Boolean = try {
        context.contentResolver.openFileDescriptor(uri, "r")?.let { pfd ->
            ParcelFileDescriptor.AutoCloseInputStream(pfd).use { input ->
                val channel = input.channel
                hasTopLevelBox(channel.size(), type) { at, n -> readAt(channel, at, n) }
            }
        } ?: false
    } catch (e: Exception) {
        false
    }

    /** Exactly [n] bytes at [at], or null when the file ends first. */
    private fun readAt(channel: FileChannel, at: Long, n: Int): ByteArray? {
        val buffer = ByteBuffer.allocate(n)
        var pos = at
        while (buffer.hasRemaining()) {
            val read = channel.read(buffer, pos)
            if (read <= 0) return null
            pos += read
        }
        return buffer.array()
    }

    /**
     * Reads at most [max] bytes, holding only as many as the file has.
     *
     * The old version took the full [max] up front - half a megabyte for a
     * thumbnail-sized photo - and then copied the whole thing again to trim
     * it. It starts small now and only grows when the file keeps going, so a
     * small photo costs a small buffer and nothing is copied twice.
     */
    private fun readUpTo(input: InputStream, max: Int): ByteArray {
        var buffer = ByteArray(minOf(max, SCAN_CHUNK))
        var read = 0
        while (read < max) {
            if (read == buffer.size) {
                buffer = buffer.copyOf(minOf(max, buffer.size * 2))
            }
            val n = input.read(buffer, read, buffer.size - read)
            if (n <= 0) break
            read += n
        }
        return if (read == buffer.size) buffer else buffer.copyOf(read)
    }
}
