package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioPlanTest {

    @Test
    fun `a camera's heavy stereo track becomes HE-AAC at 48 kbps`() {
        assertEquals(AudioPlan.Decision.Encode(48_000, he = true), AudioPlan.decide("audio/mp4a-latm", 2, 256_000, 48_000))
    }

    @Test
    fun `a lean track is copied, never written above what it was`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, 64_000))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, 72_000))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 1, 48_000))
    }

    @Test
    fun `a WhatsApp forward's 96 kbps is made HE-AAC too`() {
        assertEquals(AudioPlan.Decision.Encode(48_000, he = true), AudioPlan.decide("audio/mp4a-latm", 2, 96_000, 44_100))
    }

    @Test
    fun `an old phone's AMR is copied as it is`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/3gpp", 1, 12_200))
    }

    @Test
    fun `a heavy mono track aims at the mono rate`() {
        assertEquals(AudioPlan.Decision.Encode(32_000, he = true), AudioPlan.decide("audio/mp4a-latm", 1, 128_000, 48_000))
    }

    @Test
    fun `a track sampled too low for HE-AAC gets plain AAC`() {
        assertEquals(AudioPlan.Decision.Encode(48_000, he = false), AudioPlan.decide("audio/mp4a-latm", 1, 96_000, 22_050))
        assertEquals(AudioPlan.Decision.Encode(64_000, he = false), AudioPlan.decide("audio/mp4a-latm", 2, 128_000, 16_000))
    }

    @Test
    fun `a format the writer cannot carry is re-encoded, no higher than it was`() {
        assertEquals(AudioPlan.Decision.Encode(48_000, he = true), AudioPlan.decide("audio/ac3", 2, 96_000))
        assertEquals(AudioPlan.Decision.Encode(96_000, he = true), AudioPlan.decide("audio/ac3", 6, 384_000))
        assertEquals(AudioPlan.Decision.Encode(24_000, he = true), AudioPlan.decide("audio/ac3", 1, 16_000))
    }

    @Test
    fun `an unknown rate keeps a copyable track and aims for the rest`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, null))
        assertEquals(AudioPlan.Decision.Encode(48_000, he = true), AudioPlan.decide("audio/eac3", 2, 0))
        assertEquals(AudioPlan.Decision.Encode(48_000, he = true), AudioPlan.decide(null, 2, null))
    }

    @Test
    fun `an encoder that will not write HE-AAC gets plain AAC, still no higher than the source`() {
        assertEquals(AudioPlan.Decision.Encode(64_000, he = false), AudioPlan.plain(2, 256_000))
        assertEquals(AudioPlan.Decision.Encode(48_000, he = false), AudioPlan.plain(1, null))
        assertEquals(AudioPlan.Decision.Encode(56_000, he = false), AudioPlan.plain(2, 56_000))
    }
}
