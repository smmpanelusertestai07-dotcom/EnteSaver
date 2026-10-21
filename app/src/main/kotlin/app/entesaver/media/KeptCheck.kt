package app.entesaver.media

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import app.entesaver.core.logic.KeptRules
import java.io.File

/**
 * What a video copy changed about its original, read back from the file the
 * encoder wrote and from the original itself: its codec, the size it is
 * shown at, how many frames it holds, its colour, its sound, and the date and
 * place it was filmed ([KeptRules]). A copy that changed any of them is not a
 * copy of the video, however small, and is thrown away.
 */
internal object KeptCheck {

    fun changes(context: Context, uri: Uri, source: VideoCompressor.Probe, codecMime: String, copy: File): List<String> {
        val written = read({ setDataSource(copy.absolutePath) }) { setDataSource(copy.absolutePath) }
            ?: return listOf("unreadable")
        val original = read({ setDataSource(context, uri) }) { setDataSource(context, uri, null) }
            ?: return listOf("unreadable")
        // The size, rotation and frames the compressor itself went by.
        val was = original.copy(
            mime = source.videoMime,
            width = source.width,
            height = source.height,
            rotation = source.rotation,
            frameCount = source.frameCount
        )
        return KeptRules.changes(was, codecMime, written)
    }

    private fun read(
        openMeta: MediaMetadataRetriever.() -> Unit,
        open: MediaExtractor.() -> Unit
    ): KeptRules.Picture? {
        val mmr = MediaMetadataRetriever()
        val extractor = MediaExtractor()
        return try {
            mmr.openMeta()
            extractor.open()
            val formats = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
            val video = formats.firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
            val audio = formats.firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            KeptRules.Picture(
                mime = video?.getString(MediaFormat.KEY_MIME),
                width = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0,
                height = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0,
                rotation = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0,
                frameCount = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)
                    ?.toIntOrNull()?.takeIf { it > 0 },
                colorTransfer = video?.intOrNull(MediaFormat.KEY_COLOR_TRANSFER),
                sound = audio?.let {
                    KeptRules.Sound(
                        it.getString(MediaFormat.KEY_MIME),
                        it.intOrNull(MediaFormat.KEY_CHANNEL_COUNT) ?: 0,
                        it.intOrNull(MediaFormat.KEY_SAMPLE_RATE) ?: 0
                    )
                },
                date = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE)?.takeIf { it.isNotBlank() },
                place = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)?.takeIf { it.isNotBlank() }
            )
        } catch (e: Exception) {
            null
        } finally {
            runCatching { mmr.release() }
            runCatching { extractor.release() }
        }
    }

    private fun MediaFormat.intOrNull(key: String): Int? =
        if (containsKey(key)) runCatching { getInteger(key) }.getOrNull() else null
}
