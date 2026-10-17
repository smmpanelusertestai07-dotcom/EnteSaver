package app.entesaver.core.logic

/**
 * How photos and videos are optimised: one way, the same on every phone,
 * with nothing to choose.
 *
 * Every file stays in its own format, at no more than Google Photos'
 * Storage saver keeps - 16 MP for a photo, 1080p for a video - and is made as
 * small as it can be while it still measures as its original does
 * ([QualityLadder], [Ssim]). A plain picture gets few bytes and a detailed
 * one the bytes it needs, which a single quality dial for every file cannot
 * do. The phone decides only what its own hardware can make: HEVC where it
 * encodes HEVC, HEIC where it encodes HEIC.
 */

/** The format a photo is in, and stays in. */
enum class PhotoFormat { JPEG, HEIC, WEBP, PNG }

/** The largest a photo copy is made; [maxMp] 0 keeps every pixel. */
data class PhotoSpec(val maxMp: Int) {
    val maxPixels: Long get() = if (maxMp <= 0) Long.MAX_VALUE else maxMp * 1_000_000L
}

/** The largest a video copy is made: its long side and frame rate (0 keeps the source's own). */
data class VideoSpec(val longSide: Int, val fpsCap: Int) {
    val longSideLimit: Int get() = if (longSide <= 0) Int.MAX_VALUE else longSide
}

object MediaSettings {

    /** 1080p's long side: what every phone's hardware encoder takes. */
    const val FULL_HD = 1920

    /** Storage saver's own limits: 16 MP photos, 1080p videos. */
    val PHOTO = PhotoSpec(maxMp = 16)
    val VIDEO = VideoSpec(longSide = FULL_HD, fpsCap = 30)

    /** A frame rate this high or more is slow motion: kept as filmed. */
    const val SLOW_MOTION_FPS = 90f

    /**
     * The frame rate a video is written at: capped only for an ordinary high
     * frame rate (31-89 fps). A slow-motion clip keeps every frame, or its
     * slow motion would be gone.
     */
    fun outputFps(sourceFps: Float, cap: Int): Float? {
        if (cap <= 0 || !sourceFps.isFinite()) return null
        if (sourceFps <= cap + 0.5f || sourceFps >= SLOW_MOTION_FPS) return null
        return cap.toFloat()
    }

    /** The name a short side is known by: 1080p for 1920 on the long side. */
    fun pLabel(longSide: Int): String = when (longSide) {
        3840 -> "2160p"
        2560 -> "1440p"
        1920 -> "1080p"
        1280 -> "720p"
        else -> "${longSide}px"
    }

    /**
     * The key encode results are grouped under, so an estimate only ever
     * quotes files made the same way: format and size for a photo
     * ("jpeg-16"), codec and size for a video ("hevc-1920"). Keys written
     * by versions with quality presets carry a third part; it is read past.
     */
    fun photoKey(format: PhotoFormat, spec: PhotoSpec = PHOTO): String = "${format.name.lowercase()}-${spec.maxMp}"

    fun videoKey(codec: VideoCodec, spec: VideoSpec = VIDEO): String = "${codec.name.lowercase()}-${spec.longSide}"

    /** A photo key read back, for a file's details. */
    data class PhotoKey(val format: PhotoFormat, val maxMp: Int)

    /** A video key read back, for a file's details. */
    data class VideoKey(val codec: VideoCodec, val longSide: Int)

    fun parsePhotoKey(key: String): PhotoKey? {
        val parts = key.split('-')
        if (parts.size !in 2..3) return null
        val format = PhotoFormat.entries.firstOrNull { it.name.equals(parts[0], ignoreCase = true) } ?: return null
        val mp = parts[1].toIntOrNull() ?: return null
        return PhotoKey(format, mp)
    }

    fun parseVideoKey(key: String): VideoKey? {
        val parts = key.split('-')
        if (parts.size !in 2..3) return null
        val codec = VideoCodec.entries.firstOrNull { it.name.equals(parts[0], ignoreCase = true) } ?: return null
        val side = parts[1].toIntOrNull() ?: return null
        return VideoKey(codec, side)
    }
}
