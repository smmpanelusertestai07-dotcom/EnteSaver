package app.entesaver.core.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class QualityFloorTest {

    @Test
    fun `the floor is on from Android 12, on a handheld, between 320x240 and 1920x1088`() {
        assertTrue(QualityFloor.applies(31, handheld = true, 1920, 1080))
        assertTrue(QualityFloor.applies(34, handheld = true, 1080, 1920))
        assertTrue(QualityFloor.applies(34, handheld = true, 1920, 1088))
        assertTrue(QualityFloor.applies(34, handheld = true, 322, 240))
        assertFalse(QualityFloor.applies(30, handheld = true, 1920, 1080))
        assertFalse(QualityFloor.applies(34, handheld = false, 1920, 1080))
        assertFalse(QualityFloor.applies(34, handheld = true, 320, 240))
        assertFalse(QualityFloor.applies(34, handheld = true, 2560, 1440))
    }

    @Test
    fun `a request under the floor comes out at the floor and a fifth`() {
        // 1080p HEVC: 1.50 bits per pixel, 3.1 Mbps, then 20% for a chip
        // without QP bounds.
        assertEquals(3_732_480, QualityFloor.vbrBps(900_000, 1920, 1080, VideoCodec.HEVC))
        assertEquals(3_732_480, QualityFloor.vbrBps(900_000, 1080, 1920, VideoCodec.HEVC))
        // 720p HEVC 1.80, 480p HEVC 2.30; H.264 asks for more.
        assertEquals(1_990_656, QualityFloor.vbrBps(489_897, 1280, 720, VideoCodec.HEVC))
        assertEquals(1_131_379, QualityFloor.vbrBps(265_415, 854, 480, VideoCodec.HEVC))
        assertEquals(4_727_808, QualityFloor.vbrBps(1_305_000, 1920, 1080, VideoCodec.H264))
    }

    @Test
    fun `a picture smaller than 480p takes the 480p floor`() {
        // The emulator logged 691200 bps for a 640x360 H.264 clip: the 480p
        // rate on its pixels. Its encoder takes QP bounds, so it got no boost;
        // a phone chip without them gets a fifth more.
        val raised = QualityFloor.vbrBps(602_752, 640, 360, VideoCodec.H264)
        assertEquals((640 * 360 * 3.00 * 1.2).toInt(), raised)
    }

    @Test
    fun `a request over the floor gets the boost, never past the ceiling`() {
        val floor = 1920 * 1080 * 1.50
        assertEquals((floor * 1.2 * 1.2).toInt(), QualityFloor.vbrBps((floor * 1.2).toInt(), 1920, 1080, VideoCodec.HEVC))
        assertEquals((floor * 1.75).toInt(), QualityFloor.vbrBps((floor * 1.6).toInt(), 1920, 1080, VideoCodec.HEVC))
        // At or over the ceiling, the request stands.
        assertEquals(6_000_000, QualityFloor.vbrBps(6_000_000, 1920, 1080, VideoCodec.HEVC))
    }

    @Test
    fun `1920x1088 is past every size the table names, so it has no floor`() {
        assertEquals(900_000, QualityFloor.vbrBps(900_000, 1920, 1088, VideoCodec.HEVC))
    }

    @Test
    fun `every rate the app asks for is under the floor where the floor applies`() {
        // Why the compressor writes in CBR there: VBR could never land on the
        // rate BitrateCalc chose, even for the fastest motion.
        val sizes = listOf(1920 to 1080, 1280 to 720, 960 to 540, 854 to 480, 640 to 360)
        for ((w, h) in sizes) {
            for (codec in VideoCodec.entries) {
                val asked = (BitrateCalc.targetBps(w, h, 30f, codec) * VideoShare.MAX).toInt()
                assertTrue("$w x $h $codec: $asked", QualityFloor.vbrBps(asked, w, h, codec) > asked)
            }
        }
    }
}
