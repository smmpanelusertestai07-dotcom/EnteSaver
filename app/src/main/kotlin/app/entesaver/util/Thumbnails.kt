package app.entesaver.util

import android.content.ContentResolver
import android.content.ContentUris
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size

/**
 * A gallery item's picture at about [size], for a list or a preview.
 *
 * From Android 10 MediaStore makes it, from its own cache where it can
 * (ContentResolver.loadThumbnail). Android 9 has no such call. There the
 * gallery's own small thumbnail is used - the one every gallery of that
 * Android draws, so it is usually on disk already - and a size beyond it is
 * decoded from the image, or from a frame of the video, at the size asked
 * for. Either way the picture is no more than a little larger than [size],
 * and a failure throws, as loadThumbnail does, so every caller's placeholder
 * still shows.
 */
object Thumbnails {

    /** The long edge of Android 9's MINI_KIND thumbnail, 512 x 384. */
    private const val MINI_KIND_EDGE = 512

    fun load(resolver: ContentResolver, uri: Uri, size: Size): Bitmap {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return resolver.loadThumbnail(uri, size, null)
        val video = runCatching { resolver.getType(uri) }.getOrNull()?.startsWith("video/") == true ||
            "video" in uri.pathSegments
        val id = runCatching { ContentUris.parseId(uri) }.getOrDefault(-1L)
        val cached = if (id >= 0 && uri.authority == MediaStore.AUTHORITY && maxOf(size.width, size.height) <= MINI_KIND_EDGE) {
            runCatching { cachedThumbnail(resolver, uri, id, video) }.getOrNull()
        } else {
            null
        }
        return scaledDown(cached ?: decoded(resolver, uri, size, video), size)
    }

    /**
     * The gallery's MINI_KIND thumbnail. A photo's is stored as the sensor
     * saw it, which is why Android 9's galleries turn it by the photo's
     * orientation; it is turned here the same way.
     */
    @Suppress("DEPRECATION")
    private fun cachedThumbnail(resolver: ContentResolver, uri: Uri, id: Long, video: Boolean): Bitmap? {
        if (video) {
            return MediaStore.Video.Thumbnails.getThumbnail(resolver, id, MediaStore.Video.Thumbnails.MINI_KIND, null)
        }
        val bitmap = MediaStore.Images.Thumbnails.getThumbnail(resolver, id, MediaStore.Images.Thumbnails.MINI_KIND, null)
            ?: return null
        val degrees = runCatching {
            resolver.query(uri, arrayOf(MediaStore.Images.ImageColumns.ORIENTATION), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getInt(0) else 0 } ?: 0
        }.getOrDefault(0)
        if (degrees % 360 == 0) return bitmap
        val turned = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(degrees.toFloat()) }, true
        )
        if (turned !== bitmap) bitmap.recycle()
        return turned
    }

    /** The image itself, or a frame of the video, decoded at about [size]. */
    private fun decoded(resolver: ContentResolver, uri: Uri, size: Size, video: Boolean): Bitmap {
        if (!video) {
            return ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val sample = minOf(info.size.width / size.width, info.size.height / size.height)
                if (sample > 1) decoder.setTargetSampleSize(sample)
            }
        }
        val retriever = MediaMetadataRetriever()
        return try {
            val file = resolver.openFileDescriptor(uri, "r") ?: error("cannot open $uri")
            file.use {
                retriever.setDataSource(it.fileDescriptor)
                retriever.getScaledFrameAtTime(-1, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, size.width, size.height)
            } ?: error("no frame in $uri")
        } finally {
            runCatching { retriever.release() }
        }
    }

    /** Down to the size asked for, as loadThumbnail does with a picture larger than it. */
    private fun scaledDown(bitmap: Bitmap, size: Size): Bitmap {
        val sample = minOf(bitmap.width / size.width, bitmap.height / size.height)
        if (sample <= 1) return bitmap
        val smaller = Bitmap.createScaledBitmap(bitmap, bitmap.width / sample, bitmap.height / sample, true)
        if (smaller !== bitmap) bitmap.recycle()
        return smaller
    }
}
