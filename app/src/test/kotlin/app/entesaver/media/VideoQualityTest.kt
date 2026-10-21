package app.entesaver.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A clip is read at two dozen moments, as many as a phone's memory holds a
 * quarter of: the mean of fewer strays further from every frame's.
 */
class VideoQualityTest {

    private val mb = 1_000_000L

    @Test
    fun `a phone with room reads two dozen moments of a 1080p clip`() {
        assertEquals(VideoQuality.MOMENTS, VideoQuality.planesFor(1920, 1080, 512 * mb))
    }

    @Test
    fun `a 4K clip is read at 1080p, so it costs a 1080p clip's memory`() {
        assertEquals(VideoQuality.planesFor(1920, 1080, 64 * mb), VideoQuality.planesFor(3840, 2160, 64 * mb))
    }

    /**
     * Moments an odd number of frames apart once all fell on the same kind of
     * frame: 24 moments of a 20-second clip are 25 frames apart. Whatever the
     * spacing, each place in a turn of four frames is read as often.
     */
    @Test
    fun `every place in a turn of four frames is read as often, whatever the clip's length`() {
        val frameUs = 1_000_000L / 30
        for (frames in 300..1_800 step 7) {
            val times = VideoQuality.momentTimes(0, frames * frameUs, VideoQuality.MOMENTS, frameUs)
            val places = times.groupingBy { (it / frameUs % VideoQuality.PHASES).toInt() }.eachCount()
            val each = List(VideoQuality.PHASES) { places[it] ?: 0 }
            assertEquals("a clip of $frames frames: $places", List(VideoQuality.PHASES) { 6 }, each)
        }
    }

    @Test
    fun `the moments still spread over the whole clip, each within a turn of its even place`() {
        val frameUs = 1_000_000L / 30
        val length = 600 * frameUs
        val times = VideoQuality.momentTimes(0, length, VideoQuality.MOMENTS, frameUs)
        times.forEachIndexed { i, t ->
            val even = length * (i + 0.5) / VideoQuality.MOMENTS
            assertTrue("moment $i at $t, even place $even", t >= even - frameUs && t <= even + VideoQuality.PHASES * frameUs)
        }
    }

    @Test
    fun `a phone short of memory reads fewer, never fewer than the least a score needs`() {
        assertEquals(7, VideoQuality.planesFor(1920, 1080, 64 * mb))
        assertEquals(VideoQuality.MIN_MOMENTS, VideoQuality.planesFor(1920, 1080, 8 * mb))
    }
}
