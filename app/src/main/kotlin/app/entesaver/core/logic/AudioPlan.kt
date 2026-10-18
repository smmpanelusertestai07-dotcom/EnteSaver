package app.entesaver.core.logic

/**
 * What happens to a video's sound.
 *
 * Sound is copied across untouched when the copy can carry it as it is and
 * it is already lean - a WhatsApp forward's 64 kbps, an old phone's AMR - and
 * re-encoded otherwise, as HE-AAC: 48 kbps stereo, 32 kbps mono. HE-AAC
 * rebuilds the treble from a few bits of side information (spectral band
 * replication), so speech and music at those rates sound through a phone's
 * speaker or earphones as a camera's 256 kbps does, at a fifth of the size -
 * and at the picture rates BitrateCalc sets, a camera's sound would
 * otherwise be a seventh of a video. A track sampled below 32 kHz, where
 * HE-AAC has no room to work, or an encoder that will not write it ([plain]),
 * gets plain AAC at [LC_STEREO_BPS] / [LC_MONO_BPS]. Sound is never written
 * above what it was: a 64 kbps track "re-encoded" at 96 is a bigger file that
 * sounds no better.
 */
object AudioPlan {

    /** HE-AAC rates a re-encode aims at. */
    const val STEREO_BPS = 48_000
    const val MONO_BPS = 32_000

    /** Plain AAC (AAC-LC) rates, for a track or an encoder HE-AAC does not suit. */
    const val LC_STEREO_BPS = 64_000
    const val LC_MONO_BPS = 48_000

    /** The least a re-encode is ever given. */
    const val MIN_BPS = 24_000

    /** HE-AAC needs a track sampled at this rate or above. */
    const val HE_MIN_SAMPLE_RATE = 32_000

    /** A copyable track this lean, or up to [KEEP_HEADROOM] above it, is kept as it is. */
    const val KEEP_STEREO_BPS = 64_000
    const val KEEP_MONO_BPS = 48_000
    const val KEEP_HEADROOM = 1.15

    /** Sound formats the MP4 writer takes as they are. */
    private val COPYABLE = setOf(
        "audio/mp4a-latm", "audio/3gpp", "audio/amr-wb", "audio/opus", "audio/vorbis"
    )

    sealed interface Decision {
        /** Copied into the new file untouched. */
        data object Keep : Decision

        /** Re-encoded at [bps]: as HE-AAC when [he], as plain AAC otherwise. */
        data class Encode(val bps: Int, val he: Boolean) : Decision
    }

    /** More than two channels share the rate two would get, twice over. */
    private fun scaled(stereo: Int, mono: Int, channels: Int): Int = when {
        channels == 1 -> mono
        channels > 2 -> stereo * 2
        else -> stereo
    }

    /**
     * [mime], [channels], [sourceBps] and [sampleRate] describe the
     * original's sound track (a rate of null or 0 when the file does not say).
     */
    fun decide(mime: String?, channels: Int, sourceBps: Int?, sampleRate: Int? = null): Decision {
        val known = sourceBps?.takeIf { it > 0 }
        val copyable = mime != null && mime.lowercase() in COPYABLE
        val keepUpTo = scaled(KEEP_STEREO_BPS, KEEP_MONO_BPS, channels)
        if (copyable && (known == null || known <= keepUpTo * KEEP_HEADROOM)) return Decision.Keep
        val he = sampleRate == null || sampleRate <= 0 || sampleRate >= HE_MIN_SAMPLE_RATE
        val aim = if (he) scaled(STEREO_BPS, MONO_BPS, channels) else scaled(LC_STEREO_BPS, LC_MONO_BPS, channels)
        val bps = if (known == null) aim else minOf(aim, known)
        return Decision.Encode(bps.coerceAtLeast(MIN_BPS), he)
    }

    /** The same track for an encoder that would not write HE-AAC: plain AAC, still never above the source. */
    fun plain(channels: Int, sourceBps: Int?): Decision.Encode {
        val aim = scaled(LC_STEREO_BPS, LC_MONO_BPS, channels)
        val known = sourceBps?.takeIf { it > 0 }
        return Decision.Encode((if (known == null) aim else minOf(aim, known)).coerceAtLeast(MIN_BPS), he = false)
    }
}
