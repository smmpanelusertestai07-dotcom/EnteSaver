package app.entesaver.core.logic

/**
 * How photos and videos are optimised: one way, the same on every phone,
 * with nothing to choose.
 *
 * A photo stays in its own format, at no more than Google Photos' Storage
 * saver keeps - 16 MP - and is made as small as it can be while it still
 * measures as its original does ([QualityLadder], [Ssim]). A video keeps
 * everything but its bitrate: its codec (H.264 stays H.264, HEVC stays HEVC),
 * its size, its frame rate, its rotation, HDR and sound, and its date and
 * place. How many bits its picture is given is read from what it shows
 * ([VideoShare], [BitrateCalc]) - a plain picture few, a detailed or moving
 * one the bits it needs - which a single quality dial for every file cannot
 * do. The phone decides only what its own hardware can write: a video its
 * chip cannot write in its own codec, size and frame rate is left as it is.
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

    /** Storage saver's photo limit, 16 MP; a video keeps its own size and frame rate. */
    val PHOTO = PhotoSpec(maxMp = 16)
    val VIDEO = VideoSpec(longSide = 0, fpsCap = 0)

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
     * ("jpeg-16"), codec and size for a video ("h264-0", 0 for a video kept
     * at its own size). Keys written by earlier versions - "hevc-1920" for a
     * video made HEVC at 1080p, or with a third part from the quality presets
     * - are read past.
     */
    fun photoKey(format: PhotoFormat, spec: PhotoSpec = PHOTO): String = "${format.name.lowercase()}-${spec.maxMp}"

    fun videoKey(codec: VideoCodec, spec: VideoSpec = VIDEO): String = "${codec.name.lowercase()}-${spec.longSide}"

    /** The key a video left exactly as it was is grouped under: it has no new codec to name. */
    fun videoKeyAsIs(spec: VideoSpec = VIDEO): String = "asis-${spec.longSide}"

    /**
     * Every key a video handled the way new ones are is grouped under: one
     * per codec a copy keeps, and one for a video left as it was - a real
     * outcome, which an estimate must count too.
     */
    fun videoKeys(spec: VideoSpec = VIDEO): List<String> =
        VideoCodec.entries.map { videoKey(it, spec) } + videoKeyAsIs(spec)

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
