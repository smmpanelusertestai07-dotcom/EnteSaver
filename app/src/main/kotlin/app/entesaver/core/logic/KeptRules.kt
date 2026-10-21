package app.entesaver.core.logic

/**
 * The one test a video copy must pass to be kept: it is the same video as
 * its original, at a lower bitrate. Same codec; the same size, as it is
 * shown; every frame - a slow-motion clip keeps its slow motion, a 60 fps
 * clip its smoothness; the same colour (HDR stays HDR); the same sound,
 * in the same codec, channels and sample rate; and the same date and place
 * it was filmed, as a gallery reads them. The rotation the file is stored
 * with may differ when the picture is shown the same way round.
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
        val sound: Sound? = null,
        /** When it was filmed, as Android's reader hands it to a gallery ("20261020T184855.000Z"). */
        val date: String? = null,
        /** Where it was filmed, as ISO 6709 text ("+28.6139+077.2090/"). */
        val place: String? = null
    ) {
        /** Width and height as the picture is shown, rotation applied. */
        val shown: Pair<Int, Int>
            get() = if (rotation % 180 != 0) height to width else width to height
    }

    /** Frames a copy may hold fewer or more of: an encoder's last frame or two. */
    const val FRAME_SLACK = 2

    /** MediaFormat.COLOR_TRANSFER_SDR_VIDEO: what a file with no colour of its own is taken to be. */
    private const val SDR = 3

    /** The last of the four decimals a phone writes a place in: about 11 metres. */
    private const val PLACE_SLACK = 0.0001

    private val LAT_LON = Regex("^([+-]\\d+(?:\\.\\d+)?)([+-]\\d+(?:\\.\\d+)?)")

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
        if (source.date != null && copy.date != source.date) changed += "date"
        if (source.place != null && !samePlace(source.place, copy.place)) changed += "place"
        return changed
    }

    /**
     * Whether two places name the same point: the same text, or the same
     * latitude and longitude to the four decimals a phone writes -
     * "+28.6139+077.2090/" and "+28.6139+77.2090/" are one place.
     */
    fun samePlace(a: String?, b: String?): Boolean {
        if (a == b) return true
        val p = latLon(a) ?: return false
        val q = latLon(b) ?: return false
        return kotlin.math.abs(p.first - q.first) < PLACE_SLACK && kotlin.math.abs(p.second - q.second) < PLACE_SLACK
    }

    private fun latLon(place: String?): Pair<Double, Double>? {
        val m = LAT_LON.find(place?.trim() ?: return null) ?: return null
        val lat = m.groupValues[1].toDoubleOrNull() ?: return null
        val lon = m.groupValues[2].toDoubleOrNull() ?: return null
        return lat to lon
    }
}
