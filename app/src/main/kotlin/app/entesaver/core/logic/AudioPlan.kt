package app.entesaver.core.logic

/**
 * What happens to a video's sound.
 *
 * Sound is a small part of a video's size, and the easiest part to make
 * worse. So it is copied across untouched whenever the copy can carry it as
 * it is and it is already lean - a WhatsApp forward's 96 kbps, an old
 * phone's AMR - and re-encoded only when it is heavy, like a camera's
 * 256 kbps. It is never written above what it was: a 96 kbps track
 * "re-encoded" at 128 is a bigger file that sounds no better, which is how
 * some small videos used to come out no smaller than they went in.
 */
object AudioPlan {

    /** AAC-LC rates a re-encode aims at: clear speech and music on a phone. */
    const val STEREO_BPS = 128_000
    const val MONO_BPS = 64_000

    /** The least a re-encode is ever given. */
    const val MIN_BPS = 32_000

    /** A track up to this share above the aim is close enough to keep. */
    const val KEEP_HEADROOM = 1.15

    /** Sound formats the MP4 writer takes as they are. */
    private val COPYABLE = setOf(
        "audio/mp4a-latm", "audio/3gpp", "audio/amr-wb", "audio/opus", "audio/vorbis"
    )

    sealed interface Decision {
        /** Copied into the new file untouched. */
        data object Keep : Decision

        /** Re-encoded as AAC at [bps]. */
        data class Encode(val bps: Int) : Decision
    }

    /** The rate a re-encode aims at for this many channels. */
    fun aimFor(channels: Int): Int = if (channels == 1) MONO_BPS else STEREO_BPS

    /**
     * [mime], [channels] and [sourceBps] describe the original's sound track
     * (a rate of null or 0 when the file does not say).
     */
    fun decide(mime: String?, channels: Int, sourceBps: Int?): Decision {
        val aim = aimFor(channels)
        val known = sourceBps?.takeIf { it > 0 }
        val copyable = mime != null && mime.lowercase() in COPYABLE
        if (copyable && (known == null || known <= aim * KEEP_HEADROOM)) return Decision.Keep
        val bps = if (known == null) aim else minOf(aim, known)
        return Decision.Encode(bps.coerceAtLeast(MIN_BPS))
    }
}
