package app.entesaver.media

import org.junit.Assert.assertEquals
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

    @Test
    fun `a phone short of memory reads fewer, never fewer than the least a score needs`() {
        assertEquals(7, VideoQuality.planesFor(1920, 1080, 64 * mb))
        assertEquals(VideoQuality.MIN_MOMENTS, VideoQuality.planesFor(1920, 1080, 8 * mb))
    }
}
