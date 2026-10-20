package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioPlanTest {

    @Test
    fun `a camera's heavy stereo track is written again as AAC at 128 kbps`() {
        assertEquals(AudioPlan.Decision.Encode(128_000), AudioPlan.decide("audio/mp4a-latm", 2, 256_000))
        assertEquals(AudioPlan.Decision.Encode(128_000), AudioPlan.decide("audio/mp4a-latm", 2, 192_000))
    }

    @Test
    fun `a lean track is copied untouched, never written above what it was`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, 64_000))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, 128_000))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, 160_000))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 1, 96_000))
    }

    @Test
    fun `a WhatsApp forward's 96 kbps is copied as it is`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, 96_000))
    }

    @Test
    fun `an old phone's AMR, and Opus and Vorbis, are copied whatever their rate`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/3gpp", 1, 12_200))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/amr-wb", 1, 23_850))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/opus", 2, 256_000))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/vorbis", 2, 320_000))
    }

    @Test
    fun `a heavy mono track aims at the mono rate, and more channels at twice stereo's`() {
        assertEquals(AudioPlan.Decision.Encode(64_000), AudioPlan.decide("audio/mp4a-latm", 1, 128_000))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 6, 320_000))
        assertEquals(AudioPlan.Decision.Encode(256_000), AudioPlan.decide("audio/mp4a-latm", 6, 384_000))
    }

    @Test
    fun `a format the copy can neither carry nor write again keeps the whole video as it is`() {
        assertEquals(AudioPlan.Decision.KeepsVideoAsIs, AudioPlan.decide("audio/ac3", 2, 96_000))
        assertEquals(AudioPlan.Decision.KeepsVideoAsIs, AudioPlan.decide("audio/eac3", 6, 384_000))
        assertEquals(AudioPlan.Decision.KeepsVideoAsIs, AudioPlan.decide("audio/mpeg", 2, 128_000))
        assertEquals(AudioPlan.Decision.KeepsVideoAsIs, AudioPlan.decide(null, 2, null))
    }

    @Test
    fun `an unknown rate keeps a copyable track`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, null))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("AUDIO/MP4A-LATM", 2, 0))
    }
}
