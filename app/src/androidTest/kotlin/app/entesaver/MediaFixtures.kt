package app.entesaver

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import app.entesaver.media.LegacyMedia
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.random.Random

/**
 * Builds real media in MediaStore so the end-to-end test works on genuine
 * files rather than mocks. Test originals live in DCIM/EnteSaverTest, which
 * the scanner treats exactly like camera output.
 *
 * From Android 10 a fixture is a pending MediaStore item, written and then
 * published. Android 9 has neither pending items nor RELATIVE_PATH, so there
 * a fixture is a file written into its folder and handed to the media
 * scanner - the way a camera's photo arrives on that Android.
 */
object MediaFixtures {

    const val TEST_ALBUM = "DCIM/EnteSaverTest"

    /** The phone's own storage, as this Android's MediaStore names it: "external" before Android 10. */
    val volume: String
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) MediaStore.VOLUME_EXTERNAL_PRIMARY else "external"

    /** A detailed photo that JPEG cannot trivially shrink to nothing. */
    fun makeBitmap(width: Int, height: Int, seed: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val random = Random(seed)
        canvas.drawColor(Color.rgb(random.nextInt(256), random.nextInt(256), random.nextInt(256)))
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        // Noise-like content keeps the encoder honest about file size.
        repeat(600) {
            paint.color = Color.rgb(random.nextInt(256), random.nextInt(256), random.nextInt(256))
            canvas.drawCircle(
                random.nextFloat() * width,
                random.nextFloat() * height,
                random.nextFloat() * (width / 12f) + 4f,
                paint
            )
        }
        return bitmap
    }

    /**
     * Inserts a JPEG into MediaStore with EXIF date + GPS, and returns its uri.
     * [captureMillis] becomes both DATE_TAKEN and the EXIF timestamp so the
     * test can prove the pipeline preserves it.
     */
    fun insertPhoto(
        context: Context,
        name: String,
        width: Int = 3000,
        height: Int = 2000,
        seed: Int = 1,
        captureMillis: Long = 1_600_000_000_000L
    ): Uri {
        val bitmap = makeBitmap(width, height, seed)
        val raw = ByteArrayOutputStream().also {
            bitmap.compress(Bitmap.CompressFormat.JPEG, 98, it)
        }.toByteArray()
        bitmap.recycle()

        // Stamp EXIF through a temp file (ExifInterface needs a seekable file).
        val temp = File(context.cacheDir, name)
        temp.writeBytes(raw)
        runCatching {
            val exif = ExifInterface(temp.absolutePath)
            exif.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2020:09:13 12:26:40")
            exif.setAttribute(ExifInterface.TAG_MAKE, "EnteSaverTest")
            exif.setAttribute(ExifInterface.TAG_MODEL, "Fixture")
            exif.setLatLong(48.8584, 2.2945)
            exif.saveAttributes()
        }
        val bytes = temp.readBytes()
        temp.delete()

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val uri = publishFile(context, "$TEST_ALBUM/", name, "image/jpeg", captureMillis) { it.write(bytes) }
            awaitIndexed(context, uri, name)
            return uri
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "$TEST_ALBUM/")
            put(MediaStore.MediaColumns.DATE_TAKEN, captureMillis)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = requireNotNull(context.contentResolver.insert(collection, values)) {
            "MediaStore refused the fixture insert"
        }
        context.contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }
        publishWithDate(context, uri, captureMillis)
        awaitIndexed(context, uri, name)
        return uri
    }

    /**
     * Waits until MediaStore reports a real size for a just-published file.
     *
     * The scanner skips any row whose SIZE is zero, and on Android 10
     * MediaProvider does not always have the size ready the instant IS_PENDING
     * is cleared. A fixture that is written but not yet measured is therefore
     * invisible to the app, and every test that needed it failed with
     * "the list never appeared" - which says nothing about what went wrong.
     * Waiting here makes the fixture ready before it is used, on every
     * Android, and says so plainly if it never becomes ready.
     */
    fun awaitIndexed(context: Context, uri: Uri, name: String, timeoutMs: Long = 10_000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val size = context.contentResolver.query(
                uri, arrayOf(MediaStore.MediaColumns.SIZE), null, null, null
            )?.use { if (it.moveToFirst()) it.getLong(0) else 0L } ?: 0L
            if (size > 0) return
            Thread.sleep(100)
        }
        throw AssertionError(
            "MediaStore never reported a size for the fixture $name, so the app " +
                "could not have seen it either"
        )
    }

    /**
     * Encodes a small H.264 clip and inserts it. Returns null when the device
     * has no usable encoder - the caller then skips video assertions instead
     * of failing on an emulator limitation.
     */
    fun insertVideo(
        context: Context,
        name: String,
        width: Int = 1280,
        height: Int = 720,
        frames: Int = 20,
        captureMillis: Long = 1_600_000_000_000L,
        withAudio: Boolean = false,
        fps: Int = 10,
        textured: Boolean = false
    ): Uri? {
        val temp = File(context.cacheDir, name)
        if (!encodeH264(temp, width, height, frames, withAudio, fps, textured)) {
            temp.delete()
            return null
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val uri = publishFile(context, "$TEST_ALBUM/", name, "video/mp4", captureMillis) { out ->
                temp.inputStream().use { it.copyTo(out) }
            }
            temp.delete()
            awaitIndexed(context, uri, name)
            return uri
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "$TEST_ALBUM/")
            put(MediaStore.MediaColumns.DATE_TAKEN, captureMillis)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = context.contentResolver.insert(collection, values) ?: return null
        context.contentResolver.openOutputStream(uri)!!.use { out ->
            temp.inputStream().use { it.copyTo(out) }
        }
        publishWithDate(context, uri, captureMillis)
        temp.delete()
        awaitIndexed(context, uri, name)
        return uri
    }

    /**
     * Un-pends the item and only then stamps DATE_TAKEN. Publishing triggers a
     * MediaProvider scan that rewrites the metadata, so a date sent in the same
     * update can be thrown away.
     */
    private fun publishWithDate(context: Context, uri: Uri, captureMillis: Long) {
        val resolver = context.contentResolver
        resolver.update(
            uri,
            ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
            null,
            null
        )
        stampDate(context, uri, captureMillis)
    }

    /**
     * [uri]'s DATE_TAKEN set to [captureMillis], once the scan that reads the
     * file has run. It should be done by the time update() returns, but the
     * date is read back and set again rather than let a slow emulator turn
     * into a mystery test failure.
     */
    private fun stampDate(context: Context, uri: Uri, captureMillis: Long) {
        val resolver = context.contentResolver
        repeat(5) {
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.DATE_TAKEN, captureMillis) },
                null,
                null
            )
            if (dateTaken(context, uri) == captureMillis) return
            Thread.sleep(200)
        }
    }

    /**
     * A file the way it arrives on Android 9: written into [relativeDir]
     * under shared storage, handed to the media scanner, and its uri given
     * back. [captureMillis], when there is one, is stamped as DATE_TAKEN
     * once the scanner has read the file, as the pending flow does from
     * Android 10. A [name] already in the folder gets " (1)", as
     * MediaProvider names it from Android 10 and the app does on Android 9:
     * written over, a second fixture of the same name was the first one,
     * under the same entry.
     */
    @Suppress("DEPRECATION")
    fun publishFile(
        context: Context,
        relativeDir: String,
        name: String,
        mime: String,
        captureMillis: Long? = null,
        write: (OutputStream) -> Unit
    ): Uri {
        val dir = File(Environment.getExternalStorageDirectory(), relativeDir.trim('/'))
        dir.mkdirs()
        val file = LegacyMedia.claimName(dir, name)
            ?: throw AssertionError("no free name for the fixture $name")
        FileOutputStream(file).use(write)
        val uri = scan(context, file, mime)
            ?: throw AssertionError("the media scanner never added the fixture $name")
        if (captureMillis != null) stampDate(context, uri, captureMillis)
        return uri
    }

    /** The uri the media scanner gives [file], or null when it gave none in time. */
    fun scan(context: Context, file: File, mime: String?): Uri? {
        val done = CountDownLatch(1)
        val result = AtomicReference<Uri?>(null)
        MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), mime?.let { arrayOf(it) }) { _, uri ->
            result.set(uri)
            done.countDown()
        }
        done.await(30, TimeUnit.SECONDS)
        return result.get()
    }

    /** The DATE_TAKEN MediaStore currently reports, or 0. */
    fun dateTaken(context: Context, uri: Uri): Long =
        context.contentResolver.query(
            uri, arrayOf(MediaStore.MediaColumns.DATE_TAKEN), null, null, null
        )?.use { if (it.moveToFirst()) it.getLong(0) else 0L } ?: 0L

    /** Minimal buffer-mode encoder: NV12 frames in, MP4 out. */
    /**
     * A real H.264 clip, and with [withAudio] a real AAC track beside it.
     *
     * The audio is silence, encoded through the device's own AAC encoder and
     * muxed as a second track, because the property under test is that a
     * track which went in comes out - a clip with no audio can prove nothing
     * about whether the optimiser keeps sound.
     */
    private fun encodeH264(
        out: File,
        width: Int,
        height: Int,
        frames: Int,
        withAudio: Boolean = false,
        fps: Int = 10,
        textured: Boolean = false
    ): Boolean {
        val frameUs = 1_000_000L / fps
        var codec: MediaCodec? = null
        var muxer: MediaMuxer? = null
        // Encoded up front so both tracks are known before the muxer starts:
        // MediaMuxer refuses a track added after start().
        val audio = if (withAudio) encodeSilentAac(frames * frameUs) ?: return false else null
        return try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
                .apply {
                    setInteger(
                        MediaFormat.KEY_COLOR_FORMAT,
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
                    )
                    setInteger(MediaFormat.KEY_BIT_RATE, 8_000_000)
                    setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            val frameBytes = width * height * 3 / 2
            val frame = ByteArray(frameBytes)
            val info = MediaCodec.BufferInfo()
            var track = -1
            var muxing = false
            var sent = 0
            var done = false
            var guard = 0

            while (!done && guard++ < frames * 40) {
                if (sent <= frames) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        buffer.clear()
                        if (sent == frames) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0, sent * frameUs,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                        } else {
                            fillFrame(frame, width, height, sent, textured)
                            buffer.put(frame)
                            codec.queueInputBuffer(inIndex, 0, frameBytes, sent * frameUs, 0)
                        }
                        sent++
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        track = muxer.addTrack(codec.outputFormat)
                        val audioTrack = audio?.let { muxer.addTrack(it.format) } ?: -1
                        muxer.start()
                        muxing = true
                        audio?.samples?.forEach { (bytes, timeUs) ->
                            val ai = MediaCodec.BufferInfo().apply {
                                set(0, bytes.size, timeUs, 0)
                            }
                            muxer.writeSampleData(audioTrack, ByteBuffer.wrap(bytes), ai)
                        }
                    }
                    outIndex >= 0 -> {
                        val encoded = codec.getOutputBuffer(outIndex)!!
                        if (muxing && info.size > 0 &&
                            (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                        ) {
                            encoded.position(info.offset)
                            encoded.limit(info.offset + info.size)
                            muxer.writeSampleData(track, encoded, info)
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) done = true
                    }
                }
            }
            muxing && out.length() > 0
        } catch (e: Exception) {
            false
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
        }
    }

    private class AacTrack(val format: MediaFormat, val samples: List<Pair<ByteArray, Long>>)

    /** [durationUs] of silence as AAC-LC, 44.1 kHz mono, ready to mux. */
    private fun encodeSilentAac(durationUs: Long): AacTrack? {
        val sampleRate = 44_100
        val pcmPerFrame = 1024
        var enc: MediaCodec? = null
        return try {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1)
                .apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 64_000)
                }
            enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()
            val pcm = ByteArray(pcmPerFrame * 2) // 16-bit mono, all zero
            val frameUs = pcmPerFrame * 1_000_000L / sampleRate
            val total = (durationUs / frameUs).toInt() + 1
            val info = MediaCodec.BufferInfo()
            val samples = mutableListOf<Pair<ByteArray, Long>>()
            var outFormat: MediaFormat? = null
            var sent = 0
            var done = false
            var guard = 0
            while (!done && guard++ < total * 40) {
                if (sent <= total) {
                    val i = enc.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val b = enc.getInputBuffer(i)!!
                        b.clear()
                        if (sent == total) {
                            enc.queueInputBuffer(i, 0, 0, sent * frameUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        } else {
                            b.put(pcm)
                            enc.queueInputBuffer(i, 0, pcm.size, sent * frameUs, 0)
                        }
                        sent++
                    }
                }
                val o = enc.dequeueOutputBuffer(info, 10_000)
                when {
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> outFormat = enc.outputFormat
                    o >= 0 -> {
                        val buf = enc.getOutputBuffer(o)!!
                        if (info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                            val bytes = ByteArray(info.size)
                            buf.position(info.offset)
                            buf.get(bytes)
                            samples += bytes to info.presentationTimeUs
                        }
                        enc.releaseOutputBuffer(o, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) done = true
                    }
                }
            }
            val f = outFormat ?: return null
            if (samples.isEmpty()) null else AacTrack(f, samples)
        } catch (e: Exception) {
            null
        } finally {
            runCatching { enc?.stop() }
            runCatching { enc?.release() }
        }
    }

    /**
     * A moving gradient. [textured] lays a fine still pattern over it: costly
     * in every key frame, cheap between them, the way a real scene is - so a
     * clip at a high bitrate is as large as a real one, and an encode at the
     * app's own target has something to save.
     */
    private fun fillFrame(frame: ByteArray, width: Int, height: Int, index: Int, textured: Boolean = false) {
        val ySize = width * height
        for (y in 0 until height) {
            for (x in 0 until width) {
                frame[y * width + x] = if (textured) {
                    ((x + y + index * 12) % 192 + (((x * 31) xor (y * 17)) and 0x3F)).toByte()
                } else {
                    ((x + y + index * 12) and 0xFF).toByte()
                }
            }
        }
        var i = ySize
        while (i < frame.size) {
            frame[i] = ((i + index) and 0xFF).toByte()
            i++
        }
    }

    /** Removes every fixture this run created. */
    fun cleanUp(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            cleanUpFiles(context)
            return
        }
        for (collection in listOf(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        )) {
            runCatching {
                context.contentResolver.query(
                    collection,
                    arrayOf(MediaStore.MediaColumns._ID),
                    "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                    arrayOf("$TEST_ALBUM%"),
                    null
                )?.use { c ->
                    while (c.moveToNext()) {
                        val uri = ContentUris.withAppendedId(collection, c.getLong(0))
                        runCatching { context.contentResolver.delete(uri, null, null) }
                    }
                }
            }
        }
    }

    /**
     * [cleanUp] on Android 9: the rows, found by their path, and then what
     * is left in the folder - a replaced photo's hidden original among it,
     * which MediaStore never lists.
     */
    @Suppress("DEPRECATION")
    private fun cleanUpFiles(context: Context) {
        for (collection in listOf(
            MediaStore.Images.Media.getContentUri(volume),
            MediaStore.Video.Media.getContentUri(volume)
        )) {
            runCatching {
                context.contentResolver.delete(
                    collection, "${MediaStore.MediaColumns.DATA} LIKE ?", arrayOf("%/$TEST_ALBUM/%")
                )
            }
        }
        File(Environment.getExternalStorageDirectory(), TEST_ALBUM).listFiles()?.forEach { it.delete() }
    }
}
