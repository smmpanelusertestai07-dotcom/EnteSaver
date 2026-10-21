package app.entesaver.core.logic

/**
 * What happens to a video's sound: it stays in its own codec, at its own
 * sample rate and channels.
 *
 * A track the copy can carry as it is is copied across untouched - a
 * WhatsApp forward's 96 kbps, Telegram's 128, an old phone's AMR, any Opus or
 * Vorbis - so nothing about it changes at all. Only a heavy AAC track, such
 * as a camera's 256 kbps, is written again, and as AAC-LC, the AAC a camera
 * writes: 128 kbps stereo, 64 kbps mono, which through a phone's speaker or
 * earphones sounds as the original does. Sound is never written above what
 * it was. A track in a codec the copy can neither carry nor write again
 * keeps the whole video as it is ([Decision.KeepsVideoAsIs]), since its
 * sound could not stay the same.
 */
object AudioPlan {

    /** AAC-LC rates a heavy track is written at. */
    const val STEREO_BPS = 128_000
    const val MONO_BPS = 64_000

    /** The least a re-encode is ever given. */
    const val MIN_BPS = 24_000

    /** A track up to this rate is copied as it is. */
    const val KEEP_STEREO_BPS = 160_000
    const val KEEP_MONO_BPS = 96_000

    /** AAC: the codec phones and apps write, and the only one written again. */
    const val AAC = "audio/mp4a-latm"

    /** Sound formats the MP4 writer takes as they are. */
    private val COPYABLE = setOf(AAC, "audio/3gpp", "audio/amr-wb", "audio/opus", "audio/vorbis")

    sealed interface Decision {
        /** Copied into the new file untouched. */
        data object Keep : Decision

        /** Written again as AAC-LC at [bps]. */
        data class Encode(val bps: Int) : Decision

        /** A codec the copy cannot keep: the video is left as it is. */
        data object KeepsVideoAsIs : Decision
    }

    /** More than two channels share the rate two would get, twice over. */
    private fun scaled(stereo: Int, mono: Int, channels: Int): Int = when {
        channels == 1 -> mono
        channels > 2 -> stereo * 2
        else -> stereo
    }

    /**
     * [mime], [channels] and [sourceBps] describe the original's sound track
     * (a rate of null or 0 when the file does not say).
     */
    fun decide(mime: String?, channels: Int, sourceBps: Int?): Decision {
        val type = mime?.lowercase()
        if (type == null || type !in COPYABLE) return Decision.KeepsVideoAsIs
        val known = sourceBps?.takeIf { it > 0 }
        if (type != AAC || known == null || known <= scaled(KEEP_STEREO_BPS, KEEP_MONO_BPS, channels)) {
            return Decision.Keep
        }
        val aim = scaled(STEREO_BPS, MONO_BPS, channels)
        return Decision.Encode(minOf(aim, known).coerceAtLeast(MIN_BPS))
    }
}
