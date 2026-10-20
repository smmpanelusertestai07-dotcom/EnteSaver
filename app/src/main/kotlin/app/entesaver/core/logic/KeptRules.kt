package app.entesaver.core.logic

/**
 * The one test a video copy must pass to be kept: it is the same video as
 * its original, at a lower bitrate. Same codec; the same size, as it is
 * shown; every frame - a slow-motion clip keeps its slow motion, a 60 fps
 * clip its smoothness; the same colour (HDR stays HDR); and the same sound,
 * in the same codec, channels and sample rate. The rotation the file is
 * stored with may differ when the picture is shown the same way round.
 */
object KeptRules {

    /** A video's sound track as its file describes it. */
    data class Sound(val mime: String?, val channels: Int, val sampleRate: Int)

    /** A video's picture and sound as its file describes them; null where it does not say. */
    data class Picture(
        val mime: String?,
        val width: Int,
        val height: Int,
        val rotation: Int,
        val frameCount: Int?,
        /** MediaFormat's colour transfer (SDR, HLG, PQ), when the file names one. */
        val colorTransfer: Int? = null,
        /** The sound track; null for a silent video. */
        val sound: Sound? = null
    ) {
        /** Width and height as the picture is shown, rotation applied. */
        val shown: Pair<Int, Int>
            get() = if (rotation % 180 != 0) height to width else width to height
    }

    /** Frames a copy may hold fewer or more of: an encoder's last frame or two. */
    const val FRAME_SLACK = 2

    /** MediaFormat.COLOR_TRANSFER_SDR_VIDEO: what a file with no colour of its own is taken to be. */
    private const val SDR = 3

    /** What [copy] changed about [source]; empty when it kept everything ([codecMime] is the codec it was to keep). */
    fun changes(source: Picture, codecMime: String, copy: Picture): List<String> {
        val changed = mutableListOf<String>()
        if (!codecMime.equals(copy.mime, ignoreCase = true) || !codecMime.equals(source.mime, ignoreCase = true)) {
            changed += "codec"
        }
        if (copy.shown != source.shown) changed += "size"
        val before = source.frameCount
        val after = copy.frameCount
        if (before != null && after != null && kotlin.math.abs(before - after) > maxOf(FRAME_SLACK, before / 100)) {
            changed += "frames"
        }
        if ((source.colorTransfer ?: SDR) != (copy.colorTransfer ?: SDR)) changed += "colour"
        val was = source.sound
        val now = copy.sound
        if ((was == null) != (now == null) ||
            (was != null && now != null && (!was.mime.equals(now.mime, ignoreCase = true) ||
                was.channels != now.channels || was.sampleRate != now.sampleRate))
        ) {
            changed += "sound"
        }
        return changed
    }
}
