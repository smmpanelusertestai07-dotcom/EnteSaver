package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioPlanTest {

    @Test
    fun `a camera's heavy stereo track is re-encoded at the aim`() {
        assertEquals(AudioPlan.Decision.Encode(128_000), AudioPlan.decide("audio/mp4a-latm", 2, 256_000))
    }

    @Test
    fun `a lean track is copied, never written above what it was`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, 96_000))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, 140_000))
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 1, 64_000))
    }

    @Test
    fun `an old phone's AMR is copied as it is`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/3gpp", 1, 12_200))
    }

    @Test
    fun `a heavy mono track aims at the mono rate`() {
        assertEquals(AudioPlan.Decision.Encode(64_000), AudioPlan.decide("audio/mp4a-latm", 1, 128_000))
    }

    @Test
    fun `a format the writer cannot carry is re-encoded, no higher than it was`() {
        assertEquals(AudioPlan.Decision.Encode(96_000), AudioPlan.decide("audio/ac3", 2, 96_000))
        assertEquals(AudioPlan.Decision.Encode(128_000), AudioPlan.decide("audio/ac3", 6, 384_000))
        assertEquals(AudioPlan.Decision.Encode(32_000), AudioPlan.decide("audio/ac3", 1, 16_000))
    }

    @Test
    fun `an unknown rate keeps a copyable track and aims for the rest`() {
        assertEquals(AudioPlan.Decision.Keep, AudioPlan.decide("audio/mp4a-latm", 2, null))
        assertEquals(AudioPlan.Decision.Encode(128_000), AudioPlan.decide("audio/eac3", 2, 0))
        assertEquals(AudioPlan.Decision.Encode(128_000), AudioPlan.decide(null, 2, null))
    }
}
