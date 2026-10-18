package app.entesaver.media

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import app.entesaver.core.logic.BitrateCalc
import app.entesaver.core.logic.FormatResolver
import app.entesaver.core.logic.JpegQuality
import app.entesaver.core.logic.OptimisedMark
import app.entesaver.core.logic.PhotoFormat
import app.entesaver.core.logic.PhotoSpec
import app.entesaver.core.logic.QualityLadder
import app.entesaver.core.logic.Ssim
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Photo pipeline: decode upright within the size limit, write it back in its
 * own format at the lowest quality that still measures as the original does
 * - found on a mosaic of the photo's own squares before the real encode -
 * and copy all important EXIF (dates, GPS, camera) with orientation normal.
 * If the result is not clearly smaller, or would lose something the
 * original carries, the original is copied as-is.
 */
object PhotoCompressor {

    private val RAW_EXTS = setOf(
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "orf", "raf", "rw2", "pef"
    )
    private val AS_IS_EXTS = setOf("gif", "apng", "svg", "psd") + RAW_EXTS

    private val EXIF_TAGS = arrayOf(
        ExifInterface.TAG_DATETIME,
        ExifInterface.TAG_DATETIME_ORIGINAL,
        ExifInterface.TAG_DATETIME_DIGITIZED,
        ExifInterface.TAG_OFFSET_TIME,
        ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
        ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
        ExifInterface.TAG_SUBSEC_TIME,
        ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,
        ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
        ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LATITUDE_REF,
        ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE,
        ExifInterface.TAG_GPS_ALTITUDE_REF,
        ExifInterface.TAG_GPS_TIMESTAMP,
        ExifInterface.TAG_GPS_DATESTAMP,
        ExifInterface.TAG_GPS_PROCESSING_METHOD,
        ExifInterface.TAG_MAKE,
        ExifInterface.TAG_MODEL,
        ExifInterface.TAG_F_NUMBER,
        ExifInterface.TAG_EXPOSURE_TIME,
        ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
        ExifInterface.TAG_FOCAL_LENGTH,
        ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
        ExifInterface.TAG_FLASH,
        ExifInterface.TAG_WHITE_BALANCE,
        ExifInterface.TAG_METERING_MODE,
        ExifInterface.TAG_EXPOSURE_PROGRAM,
        ExifInterface.TAG_EXPOSURE_BIAS_VALUE,
        ExifInterface.TAG_MAX_APERTURE_VALUE,
        ExifInterface.TAG_DIGITAL_ZOOM_RATIO,
        ExifInterface.TAG_SCENE_CAPTURE_TYPE,
        ExifInterface.TAG_LENS_MAKE,
        ExifInterface.TAG_LENS_MODEL,
        ExifInterface.TAG_ARTIST,
        ExifInterface.TAG_COPYRIGHT,
        ExifInterface.TAG_IMAGE_DESCRIPTION,
        ExifInterface.TAG_USER_COMMENT
    )

    /**
     * Makes the optimised copy of one photo, or copies it as it is when a
     * copy would lose something or would not be clearly smaller.
     *
     * [heicWorks] is this phone's answer from [HeicSupport]: HEIC is written
     * only where the phone's own hardware has proved it can.
     */
    fun compress(
        context: Context,
        uri: Uri,
        displayName: String,
        srcBytes: Long,
        spec: PhotoSpec,
        heicWorks: Boolean,
        tempDir: File
    ): CompressResult {
        val ext = displayName.substringAfterLast('.', "").lowercase()
        val source = FormatResolver.sourceFormat(displayName)
        if (source == null || ext in AS_IS_EXTS) {
            return copyAsIs(context, uri, displayName, tempDir, "format_as_is")
        }
        // Made by Ente Saver already: a second pass would only measure the
        // copy against itself and take it down another step.
        if (MarkReader.isMarked(context, uri, srcBytes)) {
            return copyAsIs(context, uri, displayName, tempDir, "already_optimised")
        }

        // Motion photos and multi-picture / depth JPEGs carry an embedded video
        // or depth map that re-encoding would throw away, so they are copied
        // byte-for-byte. The reason is shown in the item's details.
        val traits = MediaTraits.photoTraits(context, uri)
        traits.asIsReason?.let { reason ->
            return copyAsIs(context, uri, displayName, tempDir, reason)
        }
        // The decoder's own word too, for a moving picture the head did not
        // name: re-encoded, it would keep its first frame and nothing else.
        if (decoderSaysAnimated(context, uri)) {
            return copyAsIs(context, uri, displayName, tempDir, "animated")
        }
        val format = when (
            val decision = FormatResolver.resolve(source, heicWorks, traits.ultraHdr, Build.VERSION.SDK_INT)
        ) {
            is FormatResolver.Decision.AsIs -> return copyAsIs(context, uri, displayName, tempDir, decision.reason)
            is FormatResolver.Decision.Encode -> decision.format
        }
        // A lossless original is written lossless again: smaller only by
        // better packing, never by a changed pixel.
        val lossless = format == PhotoFormat.PNG || (format == PhotoFormat.WEBP && isLosslessWebp(context, uri))
        if (lossless && format == PhotoFormat.WEBP && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return copyAsIs(context, uri, displayName, tempDir, "format_as_is")
        }

        // Read EXIF (with original GPS if ACCESS_MEDIA_LOCATION is granted).
        val exifValues = HashMap<String, String>()
        var orientation = ExifInterface.ORIENTATION_NORMAL
        try {
            openOriginal(context, uri)?.use { input ->
                val exif = ExifInterface(input)
                orientation = exif.getAttributeInt(
                    ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL
                )
                for (tag in EXIF_TAGS) {
                    exif.getAttribute(tag)?.let { exifValues[tag] = it }
                }
            }
        } catch (e: Exception) {
            // EXIF is best effort; keep going.
        }
        // The quality a JPEG was saved at: a copy is never written finer.
        val sourceQuality = if (format == PhotoFormat.JPEG) {
            runCatching { context.contentResolver.openInputStream(uri)?.use { JpegQuality.estimate(it) } }.getOrNull()
        } else {
            null
        }

        // Bounds pass.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        try {
            context.contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, bounds)
            }
        } catch (e: Exception) {
            return copyAsIs(context, uri, displayName, tempDir, "decode_bounds_failed")
        }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            return copyAsIs(context, uri, displayName, tempDir, "undecodable")
        }
        val maxPixels = spec.maxPixels
        val downscaled = bounds.outWidth.toLong() * bounds.outHeight.toLong() > maxPixels
        val ladder = if (lossless) null else QualityLadder.forPhoto(sourceQuality)
        if (!lossless && ladder == null && !downscaled) {
            // Saved coarser already than any quality a copy would be tried at.
            return copyAsIs(context, uri, displayName, tempDir, "already_efficient")
        }

        val bitmap: Bitmap = try {
            decodeUpright(context, uri, bounds.outWidth, bounds.outHeight, orientation, maxPixels)
                ?: return copyAsIs(context, uri, displayName, tempDir, "decode_failed")
        } catch (e: OutOfMemoryError) {
            return copyAsIs(context, uri, displayName, tempDir, "oom")
        }

        try {
            // See-through areas: JPEG and HEIC have no alpha, so a sticker
            // would come out on black. Only the original keeps them.
            if (!FormatResolver.carriesTransparency(format) && hasSeeThrough(bitmap)) {
                return copyAsIs(context, uri, displayName, tempDir, "transparency")
            }
            // Android 16 cameras write HDR photos as HEIC with an ISO 21496-1
            // gain map, which the markers MediaTraits looks for do not name.
            // The decoder knows; only JPEG carries a gain map forward here.
            val gainMapped = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && bitmap.hasGainmap()
            if (gainMapped && format != PhotoFormat.JPEG) {
                return copyAsIs(context, uri, displayName, tempDir, "ultra_hdr_kept")
            }
            val ultraHdr = traits.ultraHdr || gainMapped
            val colourSpace = bitmap.colorSpace
            if (!FormatResolver.keepsColour(format, srgb = colourSpace == null || colourSpace.isSrgb)) {
                return copyAsIs(context, uri, displayName, tempDir, "wide_colour")
            }

            val quality = when {
                lossless -> 100
                ladder == null -> (sourceQuality ?: QualityLadder.PHOTO_UNMEASURED.toInt()).coerceAtMost(LOWEST_RUNG)
                else -> searchQuality(bitmap, format, ladder, tempDir)
            }
            if (!downscaled && sourceQuality != null && quality >= sourceQuality - SAME_QUALITY_MARGIN) {
                // As fine as the original was saved: the copy would weigh
                // the same and be one generation further from the camera.
                return copyAsIs(context, uri, displayName, tempDir, "already_efficient")
            }

            val outFile = encode(context, bitmap, format, quality, lossless, exifValues, tempDir)
            if (outFile == null) {
                // This phone passed the HEIC test but failed on this photo;
                // enough of these undo the pass.
                if (format == PhotoFormat.HEIC) HeicSupport.noteFailure(context)
                return copyAsIs(context, uri, displayName, tempDir, "encode_failed")
            }

            // Measured after the EXIF and the note went in. The block copied
            // off the original carries every tag, and two of them - the
            // description and the user comment - have no length limit. A
            // copy at the original's own size is not smaller enough to be
            // worth a generation: kept only when it saves a tenth or more,
            // or when it had to be made smaller to fit the size limit.
            val limit = if (downscaled) srcBytes else (srcBytes * WORTH_IT).toLong()
            if (outFile.length() <= 0 || outFile.length() >= limit) {
                outFile.delete()
                return copyAsIs(context, uri, displayName, tempDir, "not_smaller")
            }
            // An Ultra HDR photo is only re-made when its gain map survives;
            // otherwise its HDR would quietly be gone from the copy.
            if (ultraHdr && !MediaTraits.hasGainMap(outFile)) {
                outFile.delete()
                return copyAsIs(context, uri, displayName, tempDir, "ultra_hdr_kept")
            }

            return CompressResult(
                outFile,
                outFile.length(),
                asIs = false,
                reason = "compressed_${format.name.lowercase()}",
                ext = ext,
                srcPixels = bounds.outWidth.toLong() * bounds.outHeight.toLong(),
                outPixels = bitmap.width.toLong() * bitmap.height.toLong()
            )
        } finally {
            bitmap.recycle()
        }
    }

    /** Below this the original's own quality is used for a copy made only to fit the size limit. */
    private const val LOWEST_RUNG = 62

    /** A quality this close to the original's is the original's. */
    private const val SAME_QUALITY_MARGIN = 2

    /** A copy is kept only at nine tenths of the original or less, unless it had to shrink to fit. */
    private const val WORTH_IT = 0.9

    /** Each square the quality is measured on, and how many a side of the mosaic. */
    private const val TILE = 256
    private const val TILES = 3

    /**
     * The lowest quality at which [bitmap] still looks like itself: tried on
     * a mosaic of nine squares from across the photo, encoded and decoded
     * the way the whole photo will be. JPEG works in 8x8 blocks that start
     * on the same 16-pixel grid in the mosaic as in the photo, so a square
     * comes out of the mosaic exactly as it will out of the full encode.
     */
    private fun searchQuality(bitmap: Bitmap, format: PhotoFormat, ladder: QualityLadder, tempDir: File): Int {
        val target = Ssim.Targets.PHOTO
        val mosaic = mosaicOf(bitmap) ?: return ladder.settle(emptyList(), target).roundToInt()
        try {
            val reference = FrameQuality.lumaOf(mosaic)
            val points = mutableListOf<QualityLadder.Point>()
            while (true) {
                when (val step = ladder.next(points, target)) {
                    is QualityLadder.Step.Encode -> return step.share.roundToInt()
                    is QualityLadder.Step.Probe -> {
                        val ssim = roundTrip(mosaic, format, step.share.roundToInt(), tempDir)?.let { decoded ->
                            try {
                                FrameQuality.score(listOf(reference), listOf(FrameQuality.lumaOf(decoded)))
                            } finally {
                                decoded.recycle()
                            }
                        } ?: return ladder.settle(points, target).roundToInt()
                        points += QualityLadder.Point(step.share, ssim)
                    }
                }
            }
        } finally {
            mosaic.recycle()
        }
    }

    /** Nine squares from across [photo] in one small picture, or the photo itself when it is that small. */
    private fun mosaicOf(photo: Bitmap): Bitmap? = try {
        val w = photo.width
        val h = photo.height
        if (w <= TILE * TILES && h <= TILE * TILES) {
            photo.copy(Bitmap.Config.ARGB_8888, false)
        } else {
            val tw = minOf(TILE, w)
            val th = minOf(TILE, h)
            val space = photo.colorSpace?.takeIf { photo.config == Bitmap.Config.ARGB_8888 }
                ?: ColorSpace.get(ColorSpace.Named.SRGB)
            val mosaic = Bitmap.createBitmap(tw * TILES, th * TILES, Bitmap.Config.ARGB_8888, photo.hasAlpha(), space)
            val canvas = Canvas(mosaic)
            for (row in 0 until TILES) {
                for (col in 0 until TILES) {
                    val x = tileStart(w, tw, col)
                    val y = tileStart(h, th, row)
                    canvas.drawBitmap(
                        photo,
                        Rect(x, y, x + tw, y + th),
                        Rect(col * tw, row * th, (col + 1) * tw, (row + 1) * th),
                        null
                    )
                }
            }
            mosaic
        }
    } catch (e: Exception) {
        null
    } catch (oom: OutOfMemoryError) {
        null
    }

    /** Where square [index] of a row starts: centred in its third, on the 16-pixel grid. */
    private fun tileStart(size: Int, tile: Int, index: Int): Int {
        val centre = (2 * index + 1) * size / (2 * TILES)
        val start = (centre - tile / 2).coerceIn(0, size - tile)
        return start - start % 16
    }

    /** [mosaic] written as [format] at [quality] and read back; null when the encoder would not. */
    private fun roundTrip(mosaic: Bitmap, format: PhotoFormat, quality: Int, tempDir: File): Bitmap? = try {
        if (format == PhotoFormat.HEIC) {
            val file = File(tempDir, "probe_${System.nanoTime()}.heic")
            try {
                HeicSupport.write(mosaic, file, quality, exif = null, timeoutMs = HEIC_PHOTO_LIMIT_MS)
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, _, _ ->
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
            } finally {
                file.delete()
            }
        } else {
            val bytes = ByteArrayOutputStream().also { mosaic.compress(compressFormatFor(format, false), quality, it) }
                .toByteArray()
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }
    } catch (e: Exception) {
        null
    } catch (oom: OutOfMemoryError) {
        null
    }

    /** Whether a WebP file is the lossless kind (its image chunk is VP8L). */
    private fun isLosslessWebp(context: Context, uri: Uri): Boolean = try {
        context.contentResolver.openInputStream(uri)?.use { input ->
            val head = ByteArray(64 * 1024)
            var n = 0
            while (n < head.size) {
                val r = input.read(head, n, head.size - n)
                if (r < 0) break
                n += r
            }
            FormatResolver.webpIsLossless(head.copyOf(n))
        } ?: false
    } catch (e: Exception) {
        false
    }

    /**
     * The photo, upright and no bigger than [maxPixels], in one decode.
     *
     * The platform decoder scales while it decodes and turns the photo the
     * way its EXIF says, so a 50 MP photo becomes a 16 MP bitmap without a
     * 50 MP one ever being held - on a 4 GB phone, the difference between a
     * photo that is optimised and one the system kills the app over. The
     * older route (sample, scale, rotate: three bitmaps) remains for any
     * photo that decoder will not open.
     */
    private fun decodeUpright(
        context: Context,
        uri: Uri,
        width: Int,
        height: Int,
        orientation: Int,
        maxPixels: Long
    ): Bitmap? {
        val swaps = orientation in SWAPPING_ORIENTATIONS
        val uprightW = if (swaps) height else width
        val uprightH = if (swaps) width else height
        decodeWithImageDecoder(context, uri, maxPixels)?.let { decoded ->
            // Trusted only when it came out the shape the EXIF says it is.
            val wantLandscape = uprightW >= uprightH
            val isLandscape = decoded.width >= decoded.height
            if (uprightW == uprightH || wantLandscape == isLandscape) return decoded
            decoded.recycle()
        }
        return decodeWithBitmapFactory(context, uri, width, height, orientation, maxPixels)
    }

    private fun decodeWithImageDecoder(context: Context, uri: Uri, maxPixels: Long): Bitmap? = try {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
            // Software memory: a hardware bitmap cannot be compressed.
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val w = info.size.width
            val h = info.size.height
            val pixels = w.toLong() * h.toLong()
            if (pixels > maxPixels) {
                val scale = sqrt(maxPixels.toDouble() / pixels)
                decoder.setTargetSize(
                    (w * scale).toInt().coerceAtLeast(1),
                    (h * scale).toInt().coerceAtLeast(1)
                )
            }
        }
    } catch (e: Exception) {
        null
    }

    /** Thrown to stop a decode once its header has been read. */
    private class StopDecode : RuntimeException()

    /**
     * Whether the platform decoder reads the file as animated. Only the
     * header is read: the listener stops the decode once it has looked.
     */
    private fun decoderSaysAnimated(context: Context, uri: Uri): Boolean {
        var animated = false
        try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { _, info, _ ->
                animated = info.isAnimated
                throw StopDecode()
            }
        } catch (e: Exception) {
            // StopDecode, or a file this decoder cannot open; the head check
            // in MediaTraits has already had its say.
        }
        return animated
    }

    /** True when any pixel is less than fully opaque; read a row at a time. */
    private fun hasSeeThrough(bitmap: Bitmap): Boolean {
        if (!bitmap.hasAlpha()) return false
        val row = IntArray(bitmap.width)
        for (y in 0 until bitmap.height) {
            bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
            if (FormatResolver.anyTransparent(row)) return true
        }
        return false
    }

    private fun decodeWithBitmapFactory(
        context: Context,
        uri: Uri,
        width: Int,
        height: Int,
        orientation: Int,
        maxPixels: Long
    ): Bitmap? {
        val sample = BitrateCalc.sampleSizeFor(width, height, maxPixels)
        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sample }
        var bitmap: Bitmap = try {
            context.contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, decodeOpts)
            } ?: return null
        } catch (e: Exception) {
            return null
        }
        // Exact downscale if the sampled decode is still over budget.
        val pixels = bitmap.width.toLong() * bitmap.height.toLong()
        if (pixels > maxPixels) {
            val scale = sqrt(maxPixels.toDouble() / pixels)
            val w = (bitmap.width * scale).toInt().coerceAtLeast(1)
            val h = (bitmap.height * scale).toInt().coerceAtLeast(1)
            val scaled = Bitmap.createScaledBitmap(bitmap, w, h, true)
            if (scaled !== bitmap) {
                bitmap.recycle()
                bitmap = scaled
            }
        }
        // Bake EXIF orientation into pixels.
        val matrix = orientationMatrix(orientation)
        if (matrix != null) {
            val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            if (rotated !== bitmap) {
                bitmap.recycle()
                bitmap = rotated
            }
        }
        return bitmap
    }

    /**
     * Writes [bitmap] as [format] with the original's EXIF, orientation
     * normal; null when the encoder would not, with nothing left behind.
     */
    private fun encode(
        context: Context,
        bitmap: Bitmap,
        format: PhotoFormat,
        quality: Int,
        lossless: Boolean,
        exifValues: Map<String, String>,
        tempDir: File
    ): File? {
        val outFile = File(tempDir, "photo_${System.nanoTime()}.${FormatResolver.extensionOf(format)}")
        val ok = try {
            when (format) {
                PhotoFormat.HEIC -> {
                    HeicSupport.write(
                        bitmap, outFile, quality,
                        exif = ExifBlock.build(exifValues, tempDir),
                        timeoutMs = HEIC_PHOTO_LIMIT_MS
                    )
                    true
                }
                else -> FileOutputStream(outFile).use { fos ->
                    bitmap.compress(compressFormatFor(format, lossless), quality, fos)
                }
            }
        } catch (e: Exception) {
            false
        }
        if (!ok || outFile.length() <= 0) {
            outFile.delete()
            return null
        }
        if (format != PhotoFormat.HEIC) {
            // Write EXIF onto the copy; orientation is now normal.
            try {
                val outExif = ExifInterface(outFile.absolutePath)
                for ((tag, value) in exifValues) outExif.setAttribute(tag, value)
                outExif.setAttribute(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL.toString()
                )
                outExif.saveAttributes()
            } catch (e: Exception) {
                // EXIF write failure is not fatal.
            }
        }
        // The note that keeps the copy from being optimised again.
        try {
            val marked = when (format) {
                PhotoFormat.JPEG -> OptimisedMark.markJpeg(outFile.readBytes())
                PhotoFormat.PNG -> OptimisedMark.markPng(outFile.readBytes())
                PhotoFormat.HEIC -> OptimisedMark.markHeif(outFile.readBytes())
                PhotoFormat.WEBP -> OptimisedMark.markWebp(outFile.readBytes())
            }
            if (marked != null) outFile.writeBytes(marked)
        } catch (e: Exception) {
            // Without the note the app's own records still know the copy.
        }
        return outFile
    }

    @Suppress("DEPRECATION")
    private fun compressFormatFor(format: PhotoFormat, lossless: Boolean): Bitmap.CompressFormat = when {
        format == PhotoFormat.PNG -> Bitmap.CompressFormat.PNG
        format != PhotoFormat.WEBP -> Bitmap.CompressFormat.JPEG
        // Lossless and the small, sharp lossy WebP arrived in Android 11; the
        // older one is lossy below quality 100.
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
            if (lossless) Bitmap.CompressFormat.WEBP_LOSSLESS else Bitmap.CompressFormat.WEBP_LOSSY
        else -> Bitmap.CompressFormat.WEBP
    }

    /** How long one photo's HEIC encode may take before it goes out as JPEG. */
    private const val HEIC_PHOTO_LIMIT_MS = 30_000L

    private val SWAPPING_ORIENTATIONS = setOf(
        ExifInterface.ORIENTATION_ROTATE_90,
        ExifInterface.ORIENTATION_ROTATE_270,
        ExifInterface.ORIENTATION_TRANSPOSE,
        ExifInterface.ORIENTATION_TRANSVERSE
    )

    private fun orientationMatrix(orientation: Int): Matrix? {
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                m.postRotate(90f); m.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                m.postRotate(270f); m.postScale(-1f, 1f)
            }
            else -> return null
        }
        return m
    }

    /** Original stream incl. location EXIF when permitted; falls back to redacted. */
    private fun openOriginal(context: Context, uri: Uri): InputStream? = try {
        context.contentResolver.openInputStream(MediaStore.setRequireOriginal(uri))
    } catch (e: Exception) {
        try {
            context.contentResolver.openInputStream(uri)
        } catch (e2: Exception) {
            null
        }
    }

    fun copyAsIs(
        context: Context,
        uri: Uri,
        displayName: String,
        tempDir: File,
        reason: String
    ): CompressResult {
        val ext = displayName.substringAfterLast('.', "bin").lowercase().ifEmpty { "bin" }
        val outFile = File(tempDir, "asis_${System.nanoTime()}.$ext")
        try {
            context.contentResolver.openInputStream(uri).use { input ->
                requireNotNull(input) { "open failed" }
                FileOutputStream(outFile).use { output -> input.copyTo(output, 64 * 1024) }
            }
        } catch (t: Throwable) {
            // A copy that stopped halfway is not a copy. The fragment would
            // otherwise sit in the work folder counting against the staging
            // limit until some later run swept it - and the disk being full
            // is precisely how this fails in the first place.
            outFile.delete()
            throw t
        }
        return CompressResult(outFile, outFile.length(), asIs = true, reason = reason, ext = ext)
    }
}
