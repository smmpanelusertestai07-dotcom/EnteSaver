package app.entesaver.core.logic

import app.entesaver.media.ExifBlock
import app.entesaver.media.MediaTraits
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which format a photo is written in and which codec a video gets, on the
 * phone in hand - and the pieces that keep a photo's metadata and HDR.
 */
class EncoderChoiceTest {

    private fun encode(format: PhotoFormat) = FormatResolver.Decision.Encode(format)

    @Test
    fun `a photo is written back in its own format`() {
        for (format in PhotoFormat.entries) {
            assertEquals(encode(format), FormatResolver.resolve(format, heicWorks = true, isUltraHdr = false, sdkInt = 30))
        }
        // A HEIC on a phone whose chip failed its own test is kept whole.
        assertEquals(
            FormatResolver.Decision.AsIs("format_as_is"),
            FormatResolver.resolve(PhotoFormat.HEIC, heicWorks = false, isUltraHdr = false, sdkInt = 30)
        )
        assertEquals(encode(PhotoFormat.JPEG), FormatResolver.resolve(PhotoFormat.JPEG, heicWorks = false, isUltraHdr = false, sdkInt = 29))
    }

    @Test
    fun `the format comes from the file's own name`() {
        assertEquals(PhotoFormat.JPEG, FormatResolver.sourceFormat("IMG_20240101_101010.jpg"))
        assertEquals(PhotoFormat.JPEG, FormatResolver.sourceFormat("scan.JPEG"))
        assertEquals(PhotoFormat.HEIC, FormatResolver.sourceFormat("photo.heif"))
        assertEquals(PhotoFormat.WEBP, FormatResolver.sourceFormat("sticker.webp"))
        assertEquals(PhotoFormat.PNG, FormatResolver.sourceFormat("Screenshot_1.png"))
        assertNull(FormatResolver.sourceFormat("animation.gif"))
        assertNull(FormatResolver.sourceFormat("RAW_0001.dng"))
        assertNull(FormatResolver.sourceFormat("no-extension"))
    }

    @Test
    fun `an Ultra HDR photo keeps its HDR or is left alone`() {
        // Only JPEG carries the gain map, and only Android 14 writes it back.
        assertEquals(encode(PhotoFormat.JPEG), FormatResolver.resolve(PhotoFormat.JPEG, heicWorks = true, isUltraHdr = true, sdkInt = 34))
        assertTrue(FormatResolver.resolve(PhotoFormat.JPEG, heicWorks = true, isUltraHdr = true, sdkInt = 33) is FormatResolver.Decision.AsIs)
        for (other in PhotoFormat.entries - PhotoFormat.JPEG) {
            assertTrue(FormatResolver.resolve(other, heicWorks = true, isUltraHdr = true, sdkInt = 36) is FormatResolver.Decision.AsIs)
        }
    }

    @Test
    fun `only formats with transparency keep a see-through photo, and HEIC keeps only sRGB`() {
        assertTrue(FormatResolver.carriesTransparency(PhotoFormat.PNG))
        assertTrue(FormatResolver.carriesTransparency(PhotoFormat.WEBP))
        assertFalse(FormatResolver.carriesTransparency(PhotoFormat.JPEG))
        assertFalse(FormatResolver.carriesTransparency(PhotoFormat.HEIC))
        assertFalse(FormatResolver.keepsColour(PhotoFormat.HEIC, srgb = false))
        assertTrue(FormatResolver.keepsColour(PhotoFormat.JPEG, srgb = false))
        assertTrue(FormatResolver.keepsColour(PhotoFormat.HEIC, srgb = true))
    }

    @Test
    fun `a lossless WebP is told from a lossy one by its image chunk`() {
        fun webp(vararg chunks: Pair<String, Int>) = ascii("RIFF") + le32(100) + ascii("WEBP") +
            chunks.fold(ByteArray(0)) { acc, (fourCc, size) -> acc + ascii(fourCc) + le32(size) + ByteArray(size + (size and 1)) }
        assertTrue(FormatResolver.webpIsLossless(webp("VP8L" to 20)))
        assertFalse(FormatResolver.webpIsLossless(webp("VP8 " to 20)))
        // Extended: header, a colour profile, alpha, then the picture.
        assertTrue(FormatResolver.webpIsLossless(webp("VP8X" to 10, "ICCP" to 33, "VP8L" to 8)))
        assertFalse(FormatResolver.webpIsLossless(webp("VP8X" to 10, "ALPH" to 7, "VP8 " to 8)))
        assertFalse(FormatResolver.webpIsLossless(ascii("not a webp at all")))
    }

    /**
     * MediaProvider makes a file's extension agree with the type it is given.
     * The kept light copy used a table that knew only JPEG and MP4, so a HEIC
     * or WebP copy of a JPEG original was declared JPEG and landed as
     * "name.heic.jpg" - a name nothing that tracks the copy could recognise.
     */
    @Test
    fun `every format the app writes has its own MIME type`() {
        val sentinel = "application/x-not-mapped"
        for (format in PhotoFormat.entries) {
            val ext = FormatResolver.extensionOf(format)
            assertTrue(
                "$ext has no MIME type of its own",
                FormatResolver.mimeOf("IMG_0001__0123456789abcdef.$ext", sentinel) != sentinel
            )
        }
        assertEquals("image/heic", FormatResolver.mimeOf("a.heic", "image/jpeg"))
        assertEquals("image/webp", FormatResolver.mimeOf("a.WEBP", "image/jpeg"))
        assertEquals("video/mp4", FormatResolver.mimeOf("a.mp4", "video/quicktime"))
        assertEquals("image/png", FormatResolver.mimeOf("a.png", "image/jpeg"))
        // Anything unknown keeps what the original said it was.
        assertEquals("video/x-matroska", FormatResolver.mimeOf("a.mkv", "video/x-matroska"))
    }

    @Test
    fun `a video keeps its own codec, and one no phone writes is kept whole`() {
        assertEquals(VideoCodec.H264, VideoCodecResolver.keptCodec("video/avc"))
        assertEquals(VideoCodec.HEVC, VideoCodecResolver.keptCodec("video/hevc"))
        assertEquals(VideoCodec.HEVC, VideoCodecResolver.keptCodec("VIDEO/HEVC"))
        for (other in listOf("video/mp4v-es", "video/3gpp", "video/x-vnd.on2.vp9", "video/x-vnd.on2.vp8", "video/av01",
            "video/dolby-vision", "video/mjpeg", null)) {
            assertNull("$other has no copy in its own codec", VideoCodecResolver.keptCodec(other))
        }
    }

    @Test
    fun `a copy is kept only when it is the same video at a lower bitrate`() {
        val src = KeptRules.Picture("video/avc", 1920, 1080, 90, 900)
        assertEquals(emptyList<String>(), KeptRules.changes(src, "video/avc", src))
        // Stored the other way round but shown the same: the same picture.
        assertEquals(emptyList<String>(), KeptRules.changes(src, "video/avc", KeptRules.Picture("video/avc", 1080, 1920, 0, 900)))
        // An encoder's last frame or two may go.
        assertEquals(emptyList<String>(), KeptRules.changes(src, "video/avc", src.copy(frameCount = 898)))
        assertEquals(listOf("codec"), KeptRules.changes(src, "video/avc", src.copy(mime = "video/hevc")))
        assertEquals(listOf("codec"), KeptRules.changes(src, "video/hevc", src.copy(mime = "video/hevc")))
        assertEquals(listOf("size"), KeptRules.changes(src, "video/avc", src.copy(width = 1280, height = 720)))
        assertEquals(listOf("size"), KeptRules.changes(src, "video/avc", src.copy(rotation = 0)))
        assertEquals("a 60 fps clip written at 30", listOf("frames"), KeptRules.changes(src, "video/avc", src.copy(frameCount = 450)))
        // A file that does not say how many frames it holds is judged on the rest.
        assertEquals(emptyList<String>(), KeptRules.changes(src.copy(frameCount = null), "video/avc", src))
    }

    @Test
    fun `a copy keeps the date and place it was filmed`() {
        val src = KeptRules.Picture(
            "video/avc", 1920, 1080, 90, 900, date = "20261020T184855.000Z", place = "+28.6139+077.2090/"
        )
        assertEquals(emptyList<String>(), KeptRules.changes(src, "video/avc", src))
        // Media3's wording of the same point is the same place.
        assertEquals(emptyList<String>(), KeptRules.changes(src, "video/avc", src.copy(place = "+28.6139+77.2090/")))
        assertEquals(listOf("date"), KeptRules.changes(src, "video/avc", src.copy(date = "20261021T090000.000Z")))
        assertEquals(listOf("date"), KeptRules.changes(src, "video/avc", src.copy(date = null)))
        assertEquals(listOf("place"), KeptRules.changes(src, "video/avc", src.copy(place = null)))
        assertEquals(listOf("place"), KeptRules.changes(src, "video/avc", src.copy(place = "+28.6150+077.2090/")))
        // A video with no date or place has none to lose.
        val bare = src.copy(date = null, place = null)
        assertEquals(emptyList<String>(), KeptRules.changes(bare, "video/avc", src))
        assertTrue(KeptRules.samePlace("+28.6139+077.2090+215.000/", "+28.6139+77.2090/"))
        assertFalse(KeptRules.samePlace("+28.6139+077.2090/", "-28.6139+077.2090/"))
        assertFalse(KeptRules.samePlace("somewhere", "+28.6139+077.2090/"))
    }

    @Test
    fun `the EXIF block is lifted whole from a JPEG's APP1 segment`() {
        val tiff = byteArrayOf(0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08)
        val exif = byteArrayOf(0x45, 0x78, 0x69, 0x66, 0, 0) + tiff
        val app0 = byteArrayOf(0xFF.toByte(), 0xE0.toByte(), 0x00, 0x04, 0x4A, 0x46)
        val app1 = byteArrayOf(0xFF.toByte(), 0xE1.toByte(), 0x00, (exif.size + 2).toByte()) + exif
        val sos = byteArrayOf(0xFF.toByte(), 0xDA.toByte(), 0x00, 0x02)
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + app0 + app1 + sos
        assertArrayEquals(exif, ExifBlock.payloadOf(jpeg))
        // No EXIF segment before the picture data: nothing, never a guess.
        assertNull(ExifBlock.payloadOf(byteArrayOf(0xFF.toByte(), 0xD8.toByte()) + app0 + sos))
        assertNull(ExifBlock.payloadOf(byteArrayOf(1, 2, 3, 4)))
        // A segment that claims to run past the end of the file is refused.
        assertNull(ExifBlock.payloadOf(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE1.toByte(), 0x7F, 0x00)))
    }

    @Test
    fun `an Ultra HDR photo is told apart from a depth photo`() {
        val ultra = ("xxxx<x:xmpmeta hdrgm:Version=\"1.0\"><Container:Directory>" +
            "http://ns.adobe.com/hdr-gain-map/1.0/").toByteArray(Charsets.ISO_8859_1)
        val traits = MediaTraits.traitsOf(ultra)
        assertTrue(traits.ultraHdr)
        assertNull(traits.asIsReason)

        val portrait = "xxxx<Container:Directory> GDepth:Data hdrgm:Version".toByteArray(Charsets.ISO_8859_1)
        val depth = MediaTraits.traitsOf(portrait)
        assertFalse("depth data is never re-encoded", depth.ultraHdr)
        assertEquals("depth_photo", depth.asIsReason)

        val motion = "xxxx MotionPhoto hdrgm:Version".toByteArray(Charsets.ISO_8859_1)
        assertEquals("motion_photo", MediaTraits.traitsOf(motion).asIsReason)

        val plain = "an ordinary photo".toByteArray(Charsets.ISO_8859_1)
        assertEquals(MediaTraits.PhotoTraits(null, false), MediaTraits.traitsOf(plain))
    }

    private fun ascii(s: String) = s.toByteArray(Charsets.ISO_8859_1)

    private fun be32(v: Int) = byteArrayOf((v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte())

    private fun le32(v: Int) = byteArrayOf(v.toByte(), (v ushr 8).toByte(), (v ushr 16).toByte(), (v ushr 24).toByte())

    private fun pngChunk(type: String, size: Int) = be32(size) + ascii(type) + ByteArray(size) + ByteArray(4)

    private val pngSignature = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    @Test
    fun `an animated picture is copied as it is, a still one is not`() {
        // APNG: the animation chunk comes before the picture data.
        val apng = pngSignature + pngChunk("IHDR", 13) + pngChunk("acTL", 8) + pngChunk("IDAT", 20)
        assertEquals("animated", MediaTraits.traitsOf(apng).asIsReason)
        val png = pngSignature + pngChunk("IHDR", 13) + pngChunk("IDAT", 20) + pngChunk("IEND", 0)
        assertFalse(MediaTraits.isAnimated(png))
        // A chunk length that runs off the end is not read as anything.
        assertFalse(MediaTraits.isAnimated(pngSignature + be32(Int.MAX_VALUE) + ascii("tEXt")))

        // WebP: the extended header's animation flag.
        fun webp(flags: Int) = ascii("RIFF") + le32(100) + ascii("WEBPVP8X") + le32(10) +
            byteArrayOf(flags.toByte()) + ByteArray(9)
        assertTrue(MediaTraits.isAnimated(webp(0x02)))
        assertFalse("a WebP with alpha only is a still", MediaTraits.isAnimated(webp(0x10)))

        // AVIF and HEIF: a sequence brand in the file-type box.
        fun ftyp(vararg brands: String) = be32(16 + 4 * (brands.size - 1)) + ascii("ftyp") +
            ascii(brands[0]) + be32(0) + brands.drop(1).fold(ByteArray(0)) { acc, b -> acc + ascii(b) }
        assertTrue(MediaTraits.isAnimated(ftyp("avis", "avif", "msf1")))
        assertTrue(MediaTraits.isAnimated(ftyp("heic", "mif1", "msf1")))
        assertFalse(MediaTraits.isAnimated(ftyp("heic", "mif1", "heic")))
        assertFalse(MediaTraits.isAnimated(ftyp("avif", "mif1")))

        assertFalse(MediaTraits.isAnimated(ascii("an ordinary photo")))
    }

    @Test
    fun `a Samsung motion photo is found by the trailer at the end of the file`() {
        // SEFH, version, count, then one 12-byte entry per block; then the
        // directory length and SEFT.
        fun trailer(type: Int): ByteArray {
            val entry = byteArrayOf(0, 0, type.toByte(), (type ushr 8).toByte()) + le32(4_000_000) + le32(3_900_000)
            val dir = ascii("SEFH") + le32(0x6B) + le32(1) + entry
            return ByteArray(1000) + dir + le32(dir.size) + ascii("SEFT")
        }
        assertEquals("motion_photo", MediaTraits.tailReason(trailer(0x0A30)))
        // A trailer that holds only a timestamp is an ordinary photo.
        assertNull(MediaTraits.tailReason(trailer(0x0A01)))
        // The block's own name, when it sits close enough to the end.
        assertEquals("motion_photo", MediaTraits.tailReason(ascii("xx MotionPhoto_Data xx")))
        assertNull(MediaTraits.tailReason(ascii("an ordinary photo")))
        // A directory length that points outside the tail is not trusted.
        assertNull(MediaTraits.tailReason(ByteArray(20) + le32(5000) + ascii("SEFT")))
    }

    @Test
    fun `a HEIC motion photo is found by its video box, however long the clip`() {
        fun box(type: String, payload: ByteArray) = be32(8 + payload.size) + ascii(type) + payload
        fun wideBox(type: String, payload: ByteArray) =
            be32(1) + ascii(type) + be32(0) + be32(16 + payload.size) + payload
        val ftyp = box("ftyp", ascii("heic") + be32(0) + ascii("mif1") + ascii("heic"))
        val meta = box("meta", be32(0) + box("hdlr", ByteArray(24)) + box("iloc", ByteArray(40)))
        // Picture tiles past the 512 KB head, then Google's layout: the whole
        // MP4 inside one top-level "mpvd" box, longer than the 64 KB tail.
        val mdat = box("mdat", ByteArray(600_000))
        val clip = box("ftyp", ascii("mp42") + be32(0) + ascii("isom")) +
            box("mdat", ByteArray(150_000) { (it % 251).toByte() }) + box("moov", ByteArray(4_000))
        val mpvd = box("mpvd", clip)
        fun reader(file: ByteArray): (Long, Int) -> ByteArray? = { at, n ->
            file.copyOfRange(at.toInt(), minOf(file.size, at.toInt() + n))
        }
        fun has(file: ByteArray) = MediaTraits.hasTopLevelBox(file.size.toLong(), ascii("mpvd"), reader(file))

        val motion = ftyp + meta + mdat + mpvd
        assertTrue(MediaTraits.isIsoMedia(motion))
        assertTrue(has(motion))
        // Neither the head nor the tail names the video: only the walk finds it.
        assertNull(MediaTraits.traitsOf(motion.copyOf(512 * 1024)).asIsReason)
        assertNull(MediaTraits.tailReason(motion.copyOfRange(motion.size - 64 * 1024, motion.size)))
        // Picture data written with a 64-bit size.
        assertTrue(has(ftyp + meta + wideBox("mdat", ByteArray(70_000)) + mpvd))

        // An ordinary HEIC, and boxes whose sizes cannot be right, are not motion photos.
        assertFalse(has(ftyp + meta + mdat))
        assertFalse(has(ftyp + be32(0) + ascii("mdat") + ByteArray(100) + mpvd))
        assertFalse(has(ftyp + be32(4) + ascii("mdat") + ByteArray(100) + mpvd))
        assertFalse(has(ftyp + be32(Int.MAX_VALUE) + ascii("mdat") + ByteArray(100) + mpvd))
        assertFalse(has(ftyp + ByteArray(5)))
        assertFalse(MediaTraits.isIsoMedia(ascii("an ordinary photo")))
    }

    @Test
    fun `see-through pixels are found`() {
        val opaque = IntArray(64) { 0xFF336699.toInt() }
        assertFalse(FormatResolver.anyTransparent(opaque))
        val clear = opaque.copyOf().also { it[40] = 0x00000000 }
        assertTrue(FormatResolver.anyTransparent(clear))
        val halfClear = opaque.copyOf().also { it[3] = 0x80336699.toInt() }
        assertTrue(FormatResolver.anyTransparent(halfClear))
        assertFalse("only the pixels counted are read", FormatResolver.anyTransparent(clear, count = 40))
    }
}
